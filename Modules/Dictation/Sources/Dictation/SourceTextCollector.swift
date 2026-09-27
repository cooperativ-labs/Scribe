@preconcurrency import ApplicationServices
import Assist
import Foundation

/// What the assistant may read and how much of it.
public struct SourceTextOptions: Sendable, Equatable {
    public var usesSelection: Bool
    public var usesCopiedText: Bool
    public var usesScreenText: Bool
    /// The three blocks together, in characters.
    public var characterLimit: Int
    /// The window-text walk stops after this many elements or this long,
    /// whichever comes first (proposal 6.2, confirmed by the spike).
    public var elementBudget: Int
    public var timeBudget: Duration
    /// How long to wait for a Chromium app to build its tree the first time.
    public var manualAccessibilityWait: Duration

    public init(usesSelection: Bool = true, usesCopiedText: Bool = true, usesScreenText: Bool = true,
                characterLimit: Int = 40_000, elementBudget: Int = 4_000,
                timeBudget: Duration = .milliseconds(300), manualAccessibilityWait: Duration = .seconds(2)) {
        self.usesSelection = usesSelection
        self.usesCopiedText = usesCopiedText
        self.usesScreenText = usesScreenText
        self.characterLimit = characterLimit
        self.elementBudget = elementBudget
        self.timeBudget = timeBudget
        self.manualAccessibilityWait = manualAccessibilityWait
    }
}

/// The text gathered at key-down, already capped. Held in memory for one
/// request and never written anywhere.
public struct GatheredSources: Sendable, Equatable {
    public var selectedText: String?
    public var copiedText: String?
    public var screenText: [WindowText]
    /// True when a block was cut to the cap or the walk ran out of budget.
    public var truncated: Bool

    public init(selectedText: String? = nil, copiedText: String? = nil, screenText: [WindowText] = [], truncated: Bool = false) {
        self.selectedText = selectedText
        self.copiedText = copiedText
        self.screenText = screenText
        self.truncated = truncated
    }

    public var isEmpty: Bool { selectedText == nil && copiedText == nil && screenText.isEmpty }

    /// The indicator's listening hint: "Using your selection", "Using copied
    /// text and what is on screen in Mail".
    public func hint(applicationName: String?) -> String? {
        var parts: [String] = []
        if selectedText != nil { parts.append("your selection") }
        if copiedText != nil { parts.append("copied text") }
        if !screenText.isEmpty {
            parts.append(applicationName.map { "what is on screen in \($0)" } ?? "what is on screen")
        }
        guard let last = parts.popLast() else { return nil }
        return "Using " + (parts.isEmpty ? last : parts.joined(separator: ", ") + " and " + last)
    }

    public func request(instruction: String, applicationName: String?, locale: String = Locale.current.identifier) -> AssistRequest {
        AssistRequest(instruction: instruction, selectedText: selectedText, copiedText: copiedText,
                      screenText: screenText, truncated: truncated, applicationName: applicationName, locale: locale)
    }
}

/// The clipboard is sent only when it changed since the previous assistant
/// request, so a deliberate copy is honoured and yesterday's clipboard is not
/// dragged into every request. No polling, no timestamps.
public struct ClipboardFreshness: Sendable, Equatable {
    public private(set) var recordedChangeCount: Int?

    public init(recordedChangeCount: Int? = nil) { self.recordedChangeCount = recordedChangeCount }

    /// Records the count for this request and says whether the clipboard is new.
    public mutating func take(changeCount: Int) -> Bool {
        defer { recordedChangeCount = changeCount }
        return recordedChangeCount != changeCount
    }

    /// Scribe's own paste fallback and copy-only result change the count. When
    /// nothing else touched the clipboard meanwhile, that change is not a copy
    /// the person made and must not look fresh at the next request.
    public mutating func adoptOwnChange(before: Int, after: Int) {
        if recordedChangeCount == before { recordedChangeCount = after }
    }
}

/// Reads the selection and the frontmost app's window text through
/// Accessibility, at key-down, concurrently with audio capture.
///
/// The walk follows proposal 6.2 and the rules the window-text spike added:
/// the focused window first, then the app's other visible windows, largest
/// first; one batched attribute read per element; secure fields, menus and
/// scroll bars skipped with their subtrees; tables, outlines and lists cut to
/// 40 rows and walked after their siblings; a visited set, because some apps
/// list the application element as its own window and child.
public actor SourceTextCollector {
    private let client: any FocusedFieldAXClient
    private let ownPID: pid_t
    private var manualAccessibilityRequested: Set<pid_t> = []

    public init(client: any FocusedFieldAXClient = SystemFocusedFieldAXClient(), ownPID: pid_t = getpid()) {
        self.client = client
        self.ownPID = ownPID
    }

    static let rowCap = 40
    static let minimumLength = 4
    private static let skippedRoles: Set<String> = ["AXMenu", "AXMenuBar", "AXMenuBarItem", "AXScrollBar", "AXApplication"]
    private static let rowContainerRoles: Set<String> = ["AXTable", "AXOutline", "AXList"]
    private static let valueRoles: Set<String> = ["AXStaticText", "AXTextArea", "AXTextField", "AXComboBox", "AXSearchField", "AXCell"]
    private static let titleRoles: Set<String> = ["AXHeading", "AXLink", "AXButton", "AXRow"]

    /// `clipboardText` is the clipboard when it is fresh and the source is on;
    /// the caller reads it on the main actor and applies `ClipboardFreshness`.
    public func collect(pid: pid_t, clipboardText: String?, options: SourceTextOptions) async -> GatheredSources {
        var remaining = max(0, options.characterLimit)
        var truncated = false
        func capped(_ text: String?) -> String? {
            guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, remaining > 0 else { return nil }
            let kept = text.count > remaining ? String(text.prefix(remaining)) : text
            if kept.count < text.count { truncated = true }
            remaining -= kept.count
            return kept
        }
        // Scribe's own windows are never read.
        let readsApp = pid != ownPID
        let focused = readsApp ? focusedElement(pid: pid) : nil
        var selection: String?
        if options.usesSelection, let focused, !isSecure(focused) {
            selection = capped(client.selectedText(of: focused))
        }
        let copied = options.usesCopiedText ? capped(clipboardText) : nil
        var screen: [WindowText] = []
        if options.usesScreenText, readsApp, remaining > 0, !Task.isCancelled {
            let walked = await windowText(pid: pid, focused: focused, characterLimit: remaining, options: options)
            screen = walked.windows
            truncated = truncated || walked.truncated
        }
        return GatheredSources(selectedText: selection, copiedText: copied, screenText: screen, truncated: truncated)
    }

    private func focusedElement(pid: pid_t) -> AXUIElement? {
        guard let element = client.focusedElement(frontmostPID: pid), client.pid(of: element) == pid else { return nil }
        return element
    }

    private func isSecure(_ element: AXUIElement) -> Bool {
        client.string(kAXRoleAttribute as String, of: element) == "AXSecureTextField"
            || client.string(kAXSubroleAttribute as String, of: element) == "AXSecureTextField"
    }

    // MARK: Window text

    private func windowText(pid: pid_t, focused: AXUIElement?, characterLimit: Int,
                            options: SourceTextOptions) async -> (windows: [WindowText], truncated: Bool) {
        let focusedWindow = focused.flatMap { client.window(of: $0) }
        await waitForChromiumTree(pid: pid, window: focusedWindow ?? client.windows(ofApplication: pid).first, options: options)
        let windows = orderedWindows(pid: pid, focusedWindow: focusedWindow)
        guard !windows.isEmpty else { return ([], false) }

        let clock = ContinuousClock()
        let end = clock.now.advanced(by: options.timeBudget)
        var elementsLeft = options.elementBudget
        var charactersLeft = characterLimit
        var seen: Set<String> = []
        var visited = VisitedElements()
        var truncated = false
        var result: [WindowText] = []
        for (index, window) in windows.enumerated() {
            guard elementsLeft > 0, charactersLeft > 0, clock.now < end, !Task.isCancelled else { truncated = true; break }
            // The focused window may use half the budget when others follow,
            // so the viewer behind a Mail compose window is still reached.
            let share = index == 0 && windows.count > 1
            var budget = WalkBudget(
                elements: share ? elementsLeft / 2 : elementsLeft,
                deadline: share ? clock.now.advanced(by: (end - clock.now) / 2) : end,
                characters: charactersLeft
            )
            let walked = walk(window.element, focused: focused, budget: &budget, seen: &seen, visited: &visited, clock: clock)
            elementsLeft -= walked.elementsRead
            truncated = truncated || walked.stoppedEarly
            let text = walked.text
            guard !text.isEmpty else { continue }
            charactersLeft -= text.count
            result.append(WindowText(title: window.title, isFocused: window.isFocused, text: text))
        }
        return (result, truncated)
    }

    private struct ListedWindow {
        let element: AXUIElement
        let title: String?
        let isFocused: Bool
        let area: CGFloat
    }

    /// The focused window, then the app's other windows, largest first;
    /// minimised windows are skipped.
    private func orderedWindows(pid: pid_t, focusedWindow: AXUIElement?) -> [ListedWindow] {
        var listed = client.windows(ofApplication: pid)
        if let focusedWindow, !listed.contains(where: { CFEqual($0, focusedWindow) }) {
            listed.insert(focusedWindow, at: 0)
        }
        let described: [ListedWindow] = listed.compactMap { element in
            let attributes = client.walkAttributes(of: element)
            guard attributes?.isMinimized != true else { return nil }
            let isFocused = focusedWindow.map { CFEqual($0, element) } ?? false
            let area = attributes?.frame.map { $0.width * $0.height } ?? 0
            return ListedWindow(element: element, title: attributes?.title, isFocused: isFocused, area: area)
        }
        let front = described.first(where: \.isFocused) ?? described.first
        let others = described.filter { window in front.map { !CFEqual($0.element, window.element) } ?? true }
            .sorted { $0.area > $1.area }
        guard let front else { return others }
        // Without a focused element the frontmost listed window stands in for it.
        return [ListedWindow(element: front.element, title: front.title, isFocused: true, area: front.area)] + others
    }

    /// Chromium and Electron expose only opaque groups until an AX client sets
    /// the manual-accessibility attribute, and the tree takes 150–180 ms to
    /// appear. The first request per process sets it and polls for text.
    private func waitForChromiumTree(pid: pid_t, window: AXUIElement?, options: SourceTextOptions) async {
        guard !manualAccessibilityRequested.contains(pid) else { return }
        manualAccessibilityRequested.insert(pid)
        guard client.enableManualAccessibility(pid: pid), let window else { return }
        let clock = ContinuousClock()
        let giveUp = clock.now.advanced(by: options.manualAccessibilityWait)
        while clock.now < giveUp, !Task.isCancelled {
            var budget = WalkBudget(elements: 300, deadline: clock.now.advanced(by: .milliseconds(50)), characters: 1)
            var seen: Set<String> = []
            var visited = VisitedElements()
            if !walk(window, focused: nil, budget: &budget, seen: &seen, visited: &visited, clock: clock).text.isEmpty { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private struct WalkBudget {
        var elements: Int
        var deadline: ContinuousClock.Instant
        var characters: Int
    }

    private struct Block {
        var lines: [String] = []
        var top: CGFloat?
        var left: CGFloat?
        var order: Int
    }

    /// Depth first through one window. Rows of a table, outline or list are
    /// deferred and walked after everything else, each container as its own
    /// block; blocks are then ordered top to bottom by their first frame.
    private func walk(_ root: AXUIElement, focused: AXUIElement?, budget: inout WalkBudget,
                      seen: inout Set<String>, visited: inout VisitedElements,
                      clock: ContinuousClock) -> (text: String, elementsRead: Int, stoppedEarly: Bool) {
        var blocks = [Block(order: 0)]
        var stack: [AXUIElement] = [root]
        var deferred: [[AXUIElement]] = []
        var read = 0
        var characters = 0
        var stoppedEarly = false
        while true {
            if stack.isEmpty {
                guard !deferred.isEmpty else { break }
                stack = deferred.removeFirst().reversed()
                blocks.append(Block(order: blocks.count))
            }
            if read >= budget.elements || clock.now >= budget.deadline || characters >= budget.characters || Task.isCancelled {
                stoppedEarly = true
                break
            }
            let element = stack.removeLast()
            guard visited.insert(element) else { continue }
            read += 1
            guard let attributes = client.walkAttributes(of: element) else { continue }
            let role = attributes.role ?? ""
            // Below the root, the application element is a loop, not content.
            if Self.skippedRoles.contains(role) { continue }
            if role == "AXSecureTextField" || attributes.subrole == "AXSecureTextField" { continue }
            let isFocusedField = focused.map { CFEqual($0, element) } ?? false
            if !isFocusedField, let text = Self.text(of: attributes, role: role) {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.count >= Self.minimumLength || (role == "AXHeading" && !trimmed.isEmpty),
                   seen.insert(trimmed).inserted {
                    let index = blocks.count - 1
                    blocks[index].lines.append(trimmed)
                    if blocks[index].top == nil, let frame = attributes.frame {
                        blocks[index].top = frame.minY
                        blocks[index].left = frame.minX
                    }
                    characters += trimmed.count + 1
                }
            }
            if Self.rowContainerRoles.contains(role) {
                if !attributes.children.isEmpty { deferred.append(Array(attributes.children.prefix(Self.rowCap))) }
            } else {
                stack.append(contentsOf: attributes.children.reversed())
            }
        }
        // The main walk stays first, in reading order; the deferred lists
        // follow top to bottom, left to right, those without a frame last.
        let lists = blocks.dropFirst().filter { !$0.lines.isEmpty }.sorted { lhs, rhs in
            let l = (lhs.top ?? .greatestFiniteMagnitude, lhs.left ?? 0, lhs.order)
            let r = (rhs.top ?? .greatestFiniteMagnitude, rhs.left ?? 0, rhs.order)
            return l < r
        }
        var text = ([blocks[0]] + lists).flatMap(\.lines).joined(separator: "\n")
        if text.count > budget.characters {
            text = String(text.prefix(max(0, budget.characters)))
            stoppedEarly = true
        }
        budget.elements -= read
        budget.characters -= text.count
        return (text, read, stoppedEarly)
    }

    private static func text(of attributes: AXWalkAttributes, role: String) -> String? {
        if valueRoles.contains(role) { return nonEmpty(attributes.value) ?? nonEmpty(attributes.title) }
        if titleRoles.contains(role) {
            return nonEmpty(attributes.title) ?? nonEmpty(attributes.value) ?? nonEmpty(attributes.description)
        }
        return nil
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }
}

/// AXUIElement identity for the visited set, by `CFEqual`.
private struct VisitedElements {
    private var buckets: [CFHashCode: [AXUIElement]] = [:]

    /// False when the element was already visited.
    mutating func insert(_ element: AXUIElement) -> Bool {
        let hash = CFHash(element)
        if buckets[hash]?.contains(where: { CFEqual($0, element) }) == true { return false }
        buckets[hash, default: []].append(element)
        return true
    }
}
