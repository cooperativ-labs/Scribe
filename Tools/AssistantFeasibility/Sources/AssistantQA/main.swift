@preconcurrency import ApplicationServices
import AppKit
import Assist
import Dictation
import Foundation

// Objective 5 of docs/proposals/assistant.md section 12: the seven-app QA pass,
// driven through the production code. For each app it runs the three cases
// (a reply from screen text with nothing selected, an in-place edit of a
// selection, a rewrite of freshly copied text) using the real
// SourceTextCollector and DictationTextInserter, with a stub assistant in place
// of the model so no account and no spoken instruction are needed. It logs
// roles, counts, paths and timings only; never the text it read or inserted,
// beyond its own fixed tokens. Everything it inserts it removes again, and it
// reports anything it could not remove.

let bundleIDs: [String: String] = [
    "Messages": "com.apple.MobileSMS",
    "WhatsApp": "net.whatsapp.WhatsApp",
    "Signal": "org.whispersystems.signal-desktop",
    "Slack": "com.tinyspeck.slackmacgap",
    "Mail": "com.apple.mail",
    "Notion": "notion.id",
    "Bear": "net.shinyfrog.bear",
]
let defaultApps = ["Messages", "WhatsApp", "Signal", "Slack", "Mail", "Notion", "Bear"]

let stamp = String(UUID().uuidString.prefix(4)).lowercased()
let replyToken = "Scribe QA reply \(stamp)"
let seedSentence = "Scribe QA seed sentence \(stamp)."
let editToken = "Scribe QA edit \(stamp)"
let rewriteToken = "Scribe QA rewrite \(stamp)"
let copiedSample = "Scribe QA copied paragraph \(stamp). The harness put it on the clipboard to exercise the copied-text source."

var apps = defaultApps
var cases: Set<String> = ["reply", "edit", "copied"]
var mailReply = true
var settleMillis = 1500
var keep = false
var axSelect = true
var argsIterator = CommandLine.arguments.dropFirst().makeIterator()
while let arg = argsIterator.next() {
    switch arg {
    case "--cases": cases = Set((argsIterator.next() ?? "").split(separator: ",").map(String.init))
    case "--no-mail-reply": mailReply = false
    case "--settle": settleMillis = Int(argsIterator.next() ?? "") ?? settleMillis
    case "--keep": keep = true
    case "--no-ax-select": axSelect = false
    case "--help", "-h":
        print("usage: assistant-qa [--cases reply,edit,copied] [--no-mail-reply] [--settle ms] [--keep] [App ...]")
        exit(0)
    default:
        if apps == defaultApps { apps = [] }
        apps.append(arg)
    }
}

let started = Date()
func log(_ message: String) {
    let t = String(format: "%7.2fs", Date().timeIntervalSince(started))
    print("[\(t)] \(message)")
    fflush(stdout)
}
func ms(_ duration: Duration) -> String { String(format: "%.0f ms", Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15) }
func sleepMillis(_ n: Int) async { try? await Task.sleep(for: .milliseconds(n)) }

// MARK: - Accessibility helpers (read-only except focus, selection range and the cleanup delete)

func timed(_ e: AXUIElement) -> AXUIElement { AXUIElementSetMessagingTimeout(e, 0.25); return e }
func attr(_ name: String, _ e: AXUIElement) -> CFTypeRef? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
}
func str(_ name: String, _ e: AXUIElement) -> String? { attr(name, e) as? String }
func elements(_ name: String, _ e: AXUIElement) -> [AXUIElement] { (attr(name, e) as? [AXUIElement]) ?? [] }
func element(_ name: String, _ e: AXUIElement) -> AXUIElement? {
    guard let v = attr(name, e), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
    return (v as! AXUIElement)
}
func isSettable(_ name: String, _ e: AXUIElement) -> Bool {
    var settable = DarwinBoolean(false)
    return AXUIElementIsAttributeSettable(e, name as CFString, &settable) == .success && settable.boolValue
}
func selectedRange(_ e: AXUIElement) -> CFRange? {
    guard let v = attr(kAXSelectedTextRangeAttribute as String, e), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
    var range = CFRange()
    return AXValueGetValue((v as! AXValue), .cfRange, &range) ? range : nil
}
func setSelectedRange(_ range: CFRange, _ e: AXUIElement) -> Bool {
    var r = range
    guard let value = AXValueCreate(.cfRange, &r) else { return false }
    return AXUIElementSetAttributeValue(e, kAXSelectedTextRangeAttribute as CFString, value) == .success
}

let textRoles: Set<String> = ["AXTextArea", "AXTextField", "AXComboBox", "AXWebArea", "AXSearchField"]
let client = SystemFocusedFieldAXClient()

@MainActor func focusedTextElement(pid: pid_t) -> AXUIElement? {
    guard let e = client.focusedElement(frontmostPID: pid), client.pid(of: e) == pid else { return nil }
    return e
}

/// Best effort: focus the first text field in the front window when the focused
/// element is not one (Slack's toggle button, Notion's home page).
@MainActor func focusComposer(pid: pid_t) -> Bool {
    let app = timed(AXUIElementCreateApplication(pid))
    guard let window = element(kAXFocusedWindowAttribute as String, app) ?? elements(kAXWindowsAttribute as String, app).first else { return false }
    var queue = [window]
    var visited = 0
    while !queue.isEmpty, visited < 3000 {
        let e = timed(queue.removeFirst())
        visited += 1
        let role = str(kAXRoleAttribute as String, e) ?? ""
        if ["AXTextArea", "AXTextField", "AXComboBox"].contains(role), str(kAXSubroleAttribute as String, e) != "AXSecureTextField",
           isSettable(kAXFocusedAttribute as String, e) {
            return AXUIElementSetAttributeValue(e, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success
        }
        if role == "AXMenu" || role == "AXMenuBar" || role == "AXScrollBar" { continue }
        queue.append(contentsOf: elements(kAXChildrenAttribute as String, e))
    }
    return false
}

/// Whether `token` is in the focused element's value or, for a web area whose
/// root value stays empty (Mail), in a descendant's value. Reads to compare, never logs.
@MainActor func contains(_ token: String, in root: AXUIElement) -> Bool {
    if let v = str(kAXValueAttribute as String, root), v.contains(token) { return true }
    var queue = elements(kAXChildrenAttribute as String, root)
    var visited = 0
    while !queue.isEmpty, visited < 2500 {
        let e = timed(queue.removeFirst())
        visited += 1
        if let v = str(kAXValueAttribute as String, e), v.contains(token) { return true }
        queue.append(contentsOf: elements(kAXChildrenAttribute as String, e))
    }
    return false
}

@MainActor func firstTextArea(pid: pid_t) -> AXUIElement? {
    let app = timed(AXUIElementCreateApplication(pid))
    guard let window = element(kAXFocusedWindowAttribute as String, app) ?? elements(kAXWindowsAttribute as String, app).first else { return nil }
    var queue = [window]
    var visited = 0
    while !queue.isEmpty, visited < 3000 {
        let e = timed(queue.removeFirst())
        visited += 1
        let role = str(kAXRoleAttribute as String, e) ?? ""
        if role == "AXTextArea", let frame = client.frame(of: e), frame.width > 40, frame.height > 10 { return e }
        if role == "AXMenu" || role == "AXMenuBar" || role == "AXScrollBar" { continue }
        queue.append(contentsOf: elements(kAXChildrenAttribute as String, e))
    }
    return nil
}

func click(_ point: CGPoint) {
    let source = CGEventSource(stateID: .privateState)
    CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
    CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
}

// MARK: - Keys

enum Key { static let a: CGKeyCode = 0, z: CGKeyCode = 6, w: CGKeyCode = 13, r: CGKeyCode = 15, n: CGKeyCode = 45, left: CGKeyCode = 123, delete: CGKeyCode = 51, command: CGKeyCode = 55, shift: CGKeyCode = 56 }

func post(_ key: CGKeyCode, flags: CGEventFlags) {
    let source = CGEventSource(stateID: .privateState)
    var held: CGEventFlags = []
    var modifiers: [CGKeyCode] = []
    if flags.contains(.maskCommand) { modifiers.append(Key.command) }
    if flags.contains(.maskShift) { modifiers.append(Key.shift) }
    for m in modifiers {
        held.insert(m == Key.command ? .maskCommand : .maskShift)
        let down = CGEvent(keyboardEventSource: source, virtualKey: m, keyDown: true)
        down?.flags = held
        down?.post(tap: .cghidEventTap)
    }
    let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
    down?.flags = held
    down?.post(tap: .cghidEventTap)
    let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
    up?.flags = held
    up?.post(tap: .cghidEventTap)
    for m in modifiers.reversed() {
        held.remove(m == Key.command ? .maskCommand : .maskShift)
        let upM = CGEvent(keyboardEventSource: source, virtualKey: m, keyDown: false)
        upM?.flags = held
        upM?.post(tap: .cghidEventTap)
    }
}

// MARK: - The stub assistant

struct StubAssistant: TextAssistant {
    let answer: String
    var displayName: String { "Stub" }
    func respond(to request: AssistRequest) async throws -> AssistResponse {
        AssistResponse(text: answer, model: "stub")
    }
}

// MARK: - Per-app pass

struct CaseResult {
    var name: String
    var notes: [String] = []
}

let collector = SourceTextCollector()
let inserter = DictationTextInserter()
var freshness = ClipboardFreshness()
var leftovers: [String] = []

func describe(_ sources: GatheredSources, applicationName: String) -> String {
    let windows = sources.screenText.map { "\($0.isFocused ? "focused" : "other"):\($0.text.count) chars" }.joined(separator: ", ")
    return "selection=\(sources.selectedText.map { "\($0.count) chars" } ?? "none") copied=\(sources.copiedText.map { "\($0.count) chars" } ?? "none") screen=[\(windows)] truncated=\(sources.truncated) hint=\"\(sources.hint(applicationName: applicationName) ?? "none")\""
}

@MainActor func gather(pid: pid_t, clipboard: String?, app: String) async -> GatheredSources {
    let clock = ContinuousClock()
    let t0 = clock.now
    let sources = await collector.collect(pid: pid, clipboardText: clipboard, options: SourceTextOptions())
    log("  gathered in \(ms(clock.now - t0)): \(describe(sources, applicationName: app))")
    return sources
}

@MainActor func insert(_ text: String, label: String, pid: pid_t) async -> DictationInsertionOutcome {
    let clock = ContinuousClock()
    let t0 = clock.now
    let outcome = await inserter.insertGenerated(text)
    let focused = focusedTextElement(pid: pid)
    let present = focused.map { contains(text, in: $0) } ?? false
    log("  \(label): path=\(outcome) in \(ms(clock.now - t0)); read-back \(present ? "found" : "NOT found")")
    return outcome
}

/// Removes what the harness inserted: undo first (the person's own remedy),
/// then a direct selected-range delete where the field supports it.
@MainActor func remove(_ tokens: [String], pid: pid_t, label: String) async {
    guard !keep else { return }
    for attempt in 1...4 {
        guard let focused = focusedTextElement(pid: pid) else { break }
        let remaining = tokens.filter { contains($0, in: focused) }
        if remaining.isEmpty {
            log("  cleanup (\(label)): clean after \(attempt - 1) undo\(attempt == 2 ? "" : "s")")
            return
        }
        post(Key.z, flags: .maskCommand)
        await sleepMillis(500)
    }
    guard let focused = focusedTextElement(pid: pid) else { return }
    for token in tokens where contains(token, in: focused) {
        if let value = str(kAXValueAttribute as String, focused), let range = value.range(of: token), isSettable(kAXSelectedTextRangeAttribute as String, focused) {
            let location = value.distance(from: value.startIndex, to: range.lowerBound)
            let length = value.distance(from: range.lowerBound, to: range.upperBound)
            if setSelectedRange(CFRange(location: location, length: length), focused), client.setSelectedText("", on: focused) {
                log("  cleanup (\(label)): '\(token)' removed through AX after undo did not")
                continue
            }
        }
        leftovers.append("\(label): '\(token)'")
        log("  cleanup (\(label)): '\(token)' LEFT IN FIELD; remove it by hand")
    }
}

@MainActor func runApp(_ app: String) async {
    guard let bundleID = bundleIDs[app] else { log("\(app): unknown app"); return }
    log("=== \(app)")
    guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
        log("  not running; skipped"); return
    }
    let pid = running.processIdentifier
    // A plain command-line process cannot steal activation on macOS 14+, so ask LaunchServices.
    var frontmost = false
    for _ in 0..<2 where !frontmost {
        let open = Process(); open.executableURL = URL(fileURLWithPath: "/usr/bin/open"); open.arguments = ["-b", bundleID]
        try? open.run(); open.waitUntilExit()
        running.activate()
        for _ in 0..<20 {
            await sleepMillis(250)
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid { frontmost = true; break }
        }
    }
    await sleepMillis(settleMillis)
    log("  frontmost after activate: \(frontmost)")
    guard frontmost else { log("  could not bring \(app) forward; skipped"); return }

    var mailComposeOpened = false
    if app == "Mail", mailReply {
        let before = focusedTextElement(pid: pid).flatMap { element(kAXWindowAttribute as String, $0) }
        post(Key.r, flags: .maskCommand)
        await sleepMillis(2500)
        let after = focusedTextElement(pid: pid).flatMap { element(kAXWindowAttribute as String, $0) }
        mailComposeOpened = after != nil && (before == nil || !CFEqual(before, after))
        log("  Mail reply window opened with ⌘R: \(mailComposeOpened)")
    }

    var focused = focusedTextElement(pid: pid)
    var role = focused.flatMap { str(kAXRoleAttribute as String, $0) } ?? "none"
    if !textRoles.contains(role) {
        let moved = focusComposer(pid: pid)
        await sleepMillis(400)
        focused = focusedTextElement(pid: pid)
        role = focused.flatMap { str(kAXRoleAttribute as String, $0) } ?? "none"
        log("  focused element was not a text field; focused a composer through AX: \(moved)")
        if !textRoles.contains(role), let target = firstTextArea(pid: pid), let frame = client.frame(of: target) {
            // What the person does: click into the block. AX frames are top-left; CGEvent wants the same space.
            let point = CGPoint(x: frame.midX, y: frame.minY + min(20, frame.height / 2))
            click(point)
            await sleepMillis(600)
            focused = focusedTextElement(pid: pid)
            role = focused.flatMap { str(kAXRoleAttribute as String, $0) } ?? "none"
            log("  clicked into the first text area instead: focused is now \(role)")
        }
    }
    let subrole = focused.flatMap { str(kAXSubroleAttribute as String, $0) }
    let length = focused.flatMap { client.valueLength(of: $0) }
    let settable = focused.map { client.isSettable(kAXSelectedTextAttribute as String, on: $0) } ?? false
    let range = focused.flatMap { selectedRange($0) }
    let selectedNow = focused.flatMap { client.string(kAXSelectedTextAttribute as String, of: $0) }
    log("  focused: \(role)\(subrole.map { "/\($0)" } ?? "") value=\(length.map(String.init) ?? "unreadable") selectedTextSettable=\(settable) selectedRange=\(range.map { "\($0.location)+\($0.length)" } ?? "unreadable") selectionReads=\(selectedNow.map { "\($0.count) chars" } ?? "no")")
    let canInsert = textRoles.contains(role)

    if cases.contains("gather") {
        log("  case: gather only")
        let sources = await gather(pid: pid, clipboard: nil, app: app)
        let all = ([sources.selectedText, sources.copiedText].compactMap { $0 } + sources.screenText.map(\.text)).joined(separator: "\n")
        let stray = all.components(separatedBy: "Scribe QA").count - 1
        log("  harness tokens visible in the gathered text: \(stray)")
    }

    if cases.contains("reply") {
        log("  case: reply from screen text, nothing selected")
        let sources = await gather(pid: pid, clipboard: nil, app: app)
        if sources.screenText.isEmpty { log("  EMPTY YIELD: no window text") }
        if canInsert {
            _ = await insert(replyToken, label: "insert reply", pid: pid)
            await remove([replyToken], pid: pid, label: "reply")
        } else { log("  insertion skipped: no text field focused") }
    }

    if cases.contains("edit"), canInsert {
        log("  case: in-place edit of a selection")
        _ = await insert(seedSentence, label: "seed", pid: pid)
        await sleepMillis(300)
        post(Key.left, flags: [.maskCommand, .maskShift])
        await sleepMillis(500)
        var selected = focusedTextElement(pid: pid).flatMap { client.string(kAXSelectedTextAttribute as String, of: $0) }
        log("  selection after ⇧⌘←: \(selected.map { "\($0.count) chars (\($0.contains(seedSentence) ? "is the seed" : "not the seed"))" } ?? "unreadable")")
        if axSelect, !(selected?.contains(seedSentence) ?? false), let f = focusedTextElement(pid: pid),
           let value = str(kAXValueAttribute as String, f), let range = value.range(of: seedSentence) {
            let location = value.distance(from: value.startIndex, to: range.lowerBound)
            let length = value.distance(from: range.lowerBound, to: range.upperBound)
            let set = setSelectedRange(CFRange(location: location, length: length), f)
            await sleepMillis(300)
            selected = focusedTextElement(pid: pid).flatMap { client.string(kAXSelectedTextAttribute as String, of: $0) }
            log("  selection through AXSelectedTextRange instead (set \(set)): \(selected.map { "\($0.count) chars (\($0.contains(seedSentence) ? "is the seed" : "not the seed"))" } ?? "unreadable")")
        }
        let sources = await gather(pid: pid, clipboard: nil, app: app)
        _ = await insert(editToken, label: "insert edit", pid: pid)
        if let f = focusedTextElement(pid: pid) {
            log("  replaced selection: \(contains(editToken, in: f) && !contains(seedSentence, in: f) ? "yes" : "NO (seed still present or edit missing)")")
        }
        _ = sources
        await remove([editToken, seedSentence], pid: pid, label: "edit")
    }

    if cases.contains("copied") {
        log("  case: rewrite of freshly copied text")
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        pasteboard.setString(copiedSample, forType: .string)
        let fresh = freshness.take(changeCount: pasteboard.changeCount)
        log("  clipboard set; freshness says new: \(fresh)")
        let sources = await gather(pid: pid, clipboard: fresh ? copiedSample : nil, app: app)
        if sources.copiedText == nil { log("  copied text NOT found") }
        if canInsert {
            let before = pasteboard.changeCount
            _ = await insert(rewriteToken, label: "insert rewrite", pid: pid)
            freshness.adoptOwnChange(before: before, after: pasteboard.changeCount)
            log("  clipboard after insertion still the copied sample: \(pasteboard.string(forType: .string) == copiedSample); a second request would see it as new: \(freshness.take(changeCount: pasteboard.changeCount))")
            await remove([rewriteToken], pid: pid, label: "rewrite")
        }
        pasteboard.clearContents()
        if let saved { pasteboard.setString(saved, forType: .string) }
    }

    if mailComposeOpened, !keep {
        post(Key.w, flags: .maskCommand)
        await sleepMillis(2000)
        let mail = timed(AXUIElementCreateApplication(pid))
        var pressed = false
        for window in elements(kAXWindowsAttribute as String, mail) {
            let sheets = elements("AXSheets", window) + elements(kAXChildrenAttribute as String, window).filter { str(kAXRoleAttribute as String, $0) == "AXSheet" }
            for sheet in sheets {
                for button in elements(kAXChildrenAttribute as String, sheet) where str(kAXRoleAttribute as String, button) == "AXButton" && ["Don’t Save", "Delete"].contains(str(kAXTitleAttribute as String, button) ?? "") {
                    pressed = AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
                }
            }
        }
        log("  Mail reply window closed and draft discarded (Don’t Save): \(pressed)")
        if !pressed { leftovers.append("Mail: a reply draft may be open; close it and choose Delete") }
    }
}

guard AXIsProcessTrusted() else { print("This process is not trusted for Accessibility; run it from a terminal that is."); exit(1) }
log("assistant-qa: apps \(apps.joined(separator: ", ")); cases \(cases.sorted().joined(separator: ", ")); tokens carry '\(stamp)'")
let previous = NSWorkspace.shared.frontmostApplication
for app in apps { await runApp(app) }
previous?.activate()
if leftovers.isEmpty { log("done; nothing left behind") } else { log("done; LEFT BEHIND: \(leftovers.joined(separator: "; "))") }
