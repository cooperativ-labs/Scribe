@preconcurrency import ApplicationServices
import AppKit
import Foundation

// Part B of the assistant feasibility spike: a read-only Accessibility probe.
// For each named app it brings the app to the front, resolves the focused
// element's window and the app's other visible windows, walks their trees with
// the budget and skip rules of docs/proposals/assistant.md section 6.2, and
// prints counts and timings only. No text content is ever printed.

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

// Section 6.2 budgets: a few thousand elements and about 300 ms. The probe keeps
// walking past them (to a hard cap) so the report can say whether they are tight.
var budgetElements = 4000
var budgetMillis = 300.0
var hardCapElements = 15000
var hardCapMillis = 4000.0
var settleMillis = 1500
var shortLabelChars = 4

let textRoles: Set<String> = ["AXStaticText", "AXTextArea", "AXTextField", "AXHeading", "AXLink", "AXButton", "AXWebArea",
                              "AXCell", "AXRow", "AXComboBox", "AXSearchField", "AXCheckBox", "AXRadioButton", "AXMenuButton", "AXPopUpButton"]
let valueRoles: Set<String> = ["AXStaticText", "AXTextArea", "AXTextField", "AXHeading", "AXWebArea", "AXComboBox", "AXSearchField", "AXLink", "AXCell"]

func timed(_ e: AXUIElement) -> AXUIElement { AXUIElementSetMessagingTimeout(e, 0.25); return e }

var axErrorCounts: [Int32: Int] = [:]
@MainActor func attr(_ name: String, _ e: AXUIElement) -> CFTypeRef? {
    var v: CFTypeRef?
    let err = AXUIElementCopyAttributeValue(e, name as CFString, &v)
    if err != .success { if err != .noValue && err != .attributeUnsupported { axErrorCounts[err.rawValue, default: 0] += 1 }; return nil }
    return v
}
@MainActor func str(_ name: String, _ e: AXUIElement) -> String? { attr(name, e) as? String }
@MainActor func bool(_ name: String, _ e: AXUIElement) -> Bool? { (attr(name, e) as? NSNumber)?.boolValue }
@MainActor func elements(_ name: String, _ e: AXUIElement) -> [AXUIElement] { (attr(name, e) as? [AXUIElement]) ?? [] }
@MainActor func element(_ name: String, _ e: AXUIElement) -> AXUIElement? {
    guard let v = attr(name, e), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
    return (v as! AXUIElement)
}
/// One IPC round trip for the attributes the walk needs, instead of six.
@MainActor func batch(_ e: AXUIElement, _ names: [String]) -> [String: CFTypeRef] {
    var values: CFArray?
    let err = AXUIElementCopyMultipleAttributeValues(e, names as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &values)
    guard err == .success, let arr = values as? [CFTypeRef] else { if err != .success { axErrorCounts[err.rawValue, default: 0] += 1 }; return [:] }
    var out: [String: CFTypeRef] = [:]
    for (n, v) in zip(names, arr) where CFGetTypeID(v) != AXValueGetTypeID() || AXValueGetType(v as! AXValue) != .axError { out[n] = v }
    return out
}
var rowCap = 40
var electronWaitMillis = 2500

@MainActor func size(_ e: AXUIElement) -> CGSize? {
    guard let v = attr(kAXSizeAttribute as String, e), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
    var s = CGSize.zero
    return AXValueGetValue(v as! AXValue, .cgSize, &s) ? s : nil
}

struct WindowResult {
    var index = 0
    var isFocusedWindow = false
    var isMain = false
    var subrole = ""
    var sizeDescription = ""
    var elements = 0
    var textElements = 0
    var rawChars = 0
    var filteredChars = 0
    var largestTextChars = 0
    var largestTextRole = ""
    var maxDepth = 0
    var millis = 0.0
    var atBudget: (elements: Int, chars: Int, millis: Double)? = nil
    var cappedBy = ""
    var securesSkipped = 0
    var cycles = 0
    var rowsDropped = 0
    var focusedValueSkipped = false
    var rolesSeen: [String: Int] = [:]
}

/// Depth-first walk of one window. Returns counts only.
@MainActor func walk(window: AXUIElement, focused: AXUIElement?) -> WindowResult {
    var r = WindowResult()
    let t0 = Date()
    var stack: [(AXUIElement, Int)] = [(window, 0)]
    var seenStrings = Set<Int>()
    let visited = NSMutableSet()   // WhatsApp's tree contains its own application element as a child; guard against cycles
    var budgetHit = false
    while let (el, depth) = stack.popLast() {
        r.elements += 1
        r.maxDepth = max(r.maxDepth, depth)
        let elapsed = Date().timeIntervalSince(t0) * 1000
        if !budgetHit && (r.elements > budgetElements || elapsed > budgetMillis) {
            budgetHit = true
            r.atBudget = (r.elements, r.filteredChars, elapsed)
        }
        if r.elements > hardCapElements { r.cappedBy = "elements"; break }
        if elapsed > hardCapMillis { r.cappedBy = "time"; break }
        _ = timed(el)
        if visited.contains(el) { r.cycles += 1; continue }
        visited.add(el)
        let a = batch(el, [kAXRoleAttribute as String, kAXSubroleAttribute as String, kAXValueAttribute as String, kAXTitleAttribute as String, kAXDescriptionAttribute as String, kAXChildrenAttribute as String])
        let role = (a[kAXRoleAttribute as String] as? String) ?? "?"
        let subrole = a[kAXSubroleAttribute as String] as? String
        r.rolesSeen[role, default: 0] += 1
        if role == "AXApplication" && depth > 0 { r.cycles += 1; continue }
        if role == "AXSecureTextField" || subrole == "AXSecureTextField" { r.securesSkipped += 1; continue }
        let isFocused = focused.map { CFEqual($0, el) } ?? false
        if textRoles.contains(role) {
            var text: String? = nil
            if isFocused {
                r.focusedValueSkipped = true
            } else {
                if valueRoles.contains(role) { text = a[kAXValueAttribute as String] as? String }
                if (text ?? "").isEmpty { text = a[kAXTitleAttribute as String] as? String }
                if (text ?? "").isEmpty, role == "AXStaticText" || role == "AXHeading" || role == "AXCell" { text = a[kAXDescriptionAttribute as String] as? String }
            }
            if let text, !text.isEmpty {
                r.textElements += 1
                r.rawChars += text.count
                if text.count > r.largestTextChars { r.largestTextChars = text.count; r.largestTextRole = role }
                let keep = text.count >= shortLabelChars || role == "AXHeading"
                if keep && seenStrings.insert(text.hashValue).inserted { r.filteredChars += text.count }
            }
        }
        if role == "AXMenu" || role == "AXMenuBar" || role == "AXScrollBar" { continue }
        var children = (a[kAXChildrenAttribute as String] as? [AXUIElement]) ?? []
        // Message and note lists have hundreds of rows, each a slow subtree; the source text is rarely there.
        if (role == "AXTable" || role == "AXOutline" || role == "AXList") && children.count > rowCap { r.rowsDropped += children.count - rowCap; children = Array(children.prefix(rowCap)) }
        // Walk lists last so the content area is reached inside the budget.
        let (lists, others) = children.reduce(into: ([AXUIElement](), [AXUIElement]())) { acc, c in
            if let cr = str(kAXRoleAttribute as String, c), cr == "AXTable" || cr == "AXOutline" || cr == "AXList" { acc.0.append(c) } else { acc.1.append(c) }
        }
        for c in (others + lists).reversed() { stack.append((c, depth + 1)) }
    }
    r.millis = Date().timeIntervalSince(t0) * 1000
    return r
}

@MainActor func isElectron(_ app: NSRunningApplication) -> Bool {
    guard let url = app.bundleURL else { return false }
    return FileManager.default.fileExists(atPath: url.appendingPathComponent("Contents/Frameworks/Electron Framework.framework").path)
}

@MainActor func probe(appName: String) {
    guard let bundleID = bundleIDs[appName] else { print("\(appName): unknown app"); return }
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
        print("\n### \(appName): not running; skipped"); return
    }
    axErrorCounts = [:]
    let pid = app.processIdentifier
    // A plain command-line process cannot steal activation on macOS 14+, so ask LaunchServices.
    let open = Process(); open.executableURL = URL(fileURLWithPath: "/usr/bin/open"); open.arguments = ["-b", bundleID]
    try? open.run(); open.waitUntilExit()
    app.activate()
    usleep(UInt32(settleMillis) * 1000)
    let front = NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
    let appEl = timed(AXUIElementCreateApplication(pid))
    var electronNote = "native"
    if isElectron(app) {
        let t = Date()
        let err = AXUIElementSetAttributeValue(appEl, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        // Chromium builds the tree lazily; poll until the focused window exposes something beyond groups.
        var ready = false
        while Date().timeIntervalSince(t) * 1000 < Double(electronWaitMillis) {
            usleep(100_000)
            if let w = element(kAXFocusedWindowAttribute as String, appEl) {
                var probeR = WindowResult()
                let saveCap = hardCapElements; hardCapElements = 300
                probeR = walk(window: w, focused: nil)
                hardCapElements = saveCap
                if probeR.textElements > 0 { ready = true; break }
            }
        }
        electronNote = "electron; AXManualAccessibility set → \(err == .success ? "success" : "error \(err.rawValue)"); tree \(ready ? "exposed text" : "still opaque") after \(Int(Date().timeIntervalSince(t) * 1000)) ms"
    }
    let tFocus = Date()
    var focused = element(kAXFocusedUIElementAttribute as String, timed(AXUIElementCreateSystemWide()))
    var focusPath = "system-wide"
    if focused == nil { focused = element(kAXFocusedUIElementAttribute as String, appEl); focusPath = "app" }
    if let f = focused { var owner: pid_t = 0; if AXUIElementGetPid(f, &owner) == .success, owner != pid { focused = nil; focusPath += " (other pid, ignored)" } }
    let focusMillis = Int(Date().timeIntervalSince(tFocus) * 1000)
    var focusedDescription = "none"
    var focusedWindow: AXUIElement? = nil
    if let f = focused {
        _ = timed(f)
        let role = str(kAXRoleAttribute as String, f) ?? "?"
        let subrole = str(kAXSubroleAttribute as String, f) ?? "-"
        let selected = str(kAXSelectedTextAttribute as String, f)
        var rangeLen = -1
        if let v = attr(kAXSelectedTextRangeAttribute as String, f), CFGetTypeID(v) == AXValueGetTypeID() {
            var range = CFRange(); if AXValueGetValue(v as! AXValue, .cfRange, &range) { rangeLen = range.length }
        }
        let valueLen = str(kAXValueAttribute as String, f)?.count ?? -1
        focusedWindow = element(kAXWindowAttribute as String, f)
        focusedDescription = "role=\(role) subrole=\(subrole) via \(focusPath) in \(focusMillis) ms; value=\(valueLen < 0 ? "unreadable" : "\(valueLen) chars"); AXSelectedText=\(selected.map { "\($0.count) chars" } ?? "unreadable"); selectedRange.length=\(rangeLen); window=\(focusedWindow != nil ? "resolved" : "nil")"
    }
    if focusedWindow == nil { focusedWindow = element(kAXFocusedWindowAttribute as String, appEl) }
    let listed = elements(kAXWindowsAttribute as String, appEl)
    // WhatsApp (Catalyst) lists its own application element as a window when it has none open.
    let all = listed.filter { !CFEqual($0, appEl) }
    let bogus = listed.count - all.count
    if let fw = focusedWindow, CFEqual(fw, appEl) { focusedWindow = nil }
    var ordered: [AXUIElement] = []
    if let fw = focusedWindow { ordered.append(fw) }
    var minimised = 0
    for w in all {
        if let fw = focusedWindow, CFEqual(fw, w) { continue }
        if bool(kAXMinimizedAttribute as String, w) == true { minimised += 1; continue }
        ordered.append(w)
    }
    print("\n### \(appName) (pid \(pid), \(electronNote))")
    print("- frontmost after activate: \(front); windows: \(listed.count) listed\(bogus > 0 ? " (\(bogus) were the application element itself, dropped)" : ""), \(minimised) minimised skipped, \(ordered.count) walked")
    print("- focused element: \(focusedDescription)")
    let tAll = Date()
    var results: [WindowResult] = []
    for (i, w) in ordered.enumerated() {
        var res = walk(window: w, focused: focused)
        res.index = i
        res.isFocusedWindow = focusedWindow.map { CFEqual($0, w) } ?? false
        res.isMain = bool(kAXMainAttribute as String, w) ?? false
        res.subrole = str(kAXSubroleAttribute as String, w) ?? "-"
        res.sizeDescription = size(w).map { "\(Int($0.width))×\(Int($0.height))" } ?? "?"
        results.append(res)
    }
    let totalMillis = Date().timeIntervalSince(tAll) * 1000
    print("| Window | Focused | Subrole | Size | Elements | Text elements | Raw chars | Filtered chars | Largest text | Depth | ms | At budget (elements / chars / ms) | Capped |")
    print("| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |")
    for r in results {
        let budget = r.atBudget.map { "\($0.elements) / \($0.chars) / \(Int($0.millis))" } ?? "not reached"
        print("| \(r.index) | \(r.isFocusedWindow ? "yes" : (r.isMain ? "main" : "no")) | \(r.subrole) | \(r.sizeDescription) | \(r.elements) | \(r.textElements) | \(r.rawChars) | \(r.filteredChars) | \(r.largestTextChars) (\(r.largestTextRole)) | \(r.maxDepth) | \(Int(r.millis)) | \(budget) | \(r.cappedBy.isEmpty ? "no" : r.cappedBy) |")
    }
    let secures = results.reduce(0) { $0 + $1.securesSkipped }
    let topRoles = results.flatMap { $0.rolesSeen }.reduce(into: [String: Int]()) { $0[$1.key, default: 0] += $1.value }
        .sorted { $0.value > $1.value }.prefix(8).map { "\($0.key)×\($0.value)" }.joined(separator: ", ")
    print("- total walk: \(Int(totalMillis)) ms; secure fields skipped: \(secures); cycles/app-element children skipped: \(results.reduce(0) { $0 + $1.cycles }); list rows beyond \(rowCap) dropped: \(results.reduce(0) { $0 + $1.rowsDropped }); focused field value skipped: \(results.contains { $0.focusedValueSkipped }); AX errors: \(axErrorCounts.isEmpty ? "none" : axErrorCounts.map { "\($0.key)×\($0.value)" }.joined(separator: ", "))")
    print("- roles: \(topRoles)")
    if results.count > 1, let best = results.max(by: { $0.filteredChars < $1.filteredChars }), !best.isFocusedWindow {
        print("- source lives in a non-focused window: window \(best.index) holds \(best.filteredChars) filtered chars vs \(results.first { $0.isFocusedWindow }?.filteredChars ?? 0) in the focused window")
    }
}

@MainActor func runProbe() {
        setvbuf(stdout, nil, _IOLBF, 0)
        var apps = defaultApps
        var delay = 0
        var label = ""
        var args = Array(CommandLine.arguments.dropFirst())
        while !args.isEmpty {
            let a = args.removeFirst()
            switch a {
            case "--apps": apps = args.removeFirst().split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
            case "--delay": delay = Int(args.removeFirst()) ?? 0
            case "--label": label = args.removeFirst()
            case "--settle": settleMillis = Int(args.removeFirst()) ?? settleMillis
            case "--budget-ms": budgetMillis = Double(args.removeFirst()) ?? budgetMillis
            case "--budget-elements": budgetElements = Int(args.removeFirst()) ?? budgetElements
            case "--cap-ms": hardCapMillis = Double(args.removeFirst()) ?? hardCapMillis
            case "--cap-elements": hardCapElements = Int(args.removeFirst()) ?? hardCapElements
            case "--row-cap": rowCap = Int(args.removeFirst()) ?? rowCap
            case "--electron-wait": electronWaitMillis = Int(args.removeFirst()) ?? electronWaitMillis
            default: print("unknown argument \(a)"); exit(64)
            }
        }
        print("## window-text-probe \(label) — \(Date()) — AX trusted: \(AXIsProcessTrusted()); budget \(budgetElements) elements / \(Int(budgetMillis)) ms; hard cap \(hardCapElements) / \(Int(hardCapMillis)) ms; settle \(settleMillis) ms")
        guard AXIsProcessTrusted() else { print("Accessibility not granted to this process; nothing probed"); exit(1) }
        if delay > 0 { print("starting in \(delay) s"); sleep(UInt32(delay)) }
        let previous = NSWorkspace.shared.frontmostApplication
        for app in apps { probe(appName: app) }
        previous?.activate()
        print("\ndone")
    }

runProbe()
