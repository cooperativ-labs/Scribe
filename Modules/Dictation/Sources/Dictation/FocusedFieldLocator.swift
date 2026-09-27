@preconcurrency import ApplicationServices
import AppKit
import Foundation

/// AXUIElement is a reference to another process; all use is serialized by the locator actor.
public struct FocusedFieldSnapshot: @unchecked Sendable {
    public let pid: pid_t
    public let element: AXUIElement
    public let role: String?
    public let subrole: String?
    public let isSecure: Bool
    public let isTextRole: Bool
    public let selectedTextSettable: Bool
    public let selectedRange: CFRange?
    public let caretRect: CGRect?
    public let elementFrame: CGRect?
    public let windowFrame: CGRect?
    public let valueLength: Int?
}

/// Small synchronous seam so insertion can be tested without controlling another app.
public protocol FocusedFieldAXClient: Sendable {
    func focusedElement(frontmostPID: pid_t) -> AXUIElement?
    func pid(of element: AXUIElement) -> pid_t?
    func string(_ attribute: String, of element: AXUIElement) -> String?
    func valueLength(of element: AXUIElement) -> Int?
    func selectedRange(of element: AXUIElement) -> CFRange?
    /// The selected text, through whichever attribute the field answers.
    func selectedText(of element: AXUIElement) -> String?
    func isSettable(_ attribute: String, on element: AXUIElement) -> Bool
    func setSelectedText(_ text: String, on element: AXUIElement) -> Bool
    func precedingCharacter(of element: AXUIElement, range: CFRange) -> String?
    func frame(of element: AXUIElement) -> CGRect?
    func caretFrame(of element: AXUIElement, range: CFRange) -> CGRect?
    func window(of element: AXUIElement) -> AXUIElement?
    /// Asks a Chromium/Electron app to build its accessibility tree. Returns true when the app accepted it.
    func enableManualAccessibility(pid: pid_t) -> Bool
    /// The application's windows (`kAXWindowsAttribute`), minimised ones included.
    func windows(ofApplication pid: pid_t) -> [AXUIElement]
    /// Role, text and children of one element in a single round trip, for the window-text walk.
    func walkAttributes(of element: AXUIElement) -> AXWalkAttributes?
}

public extension FocusedFieldAXClient {
    func selectedText(of element: AXUIElement) -> String? { string(kAXSelectedTextAttribute as String, of: element) }
    func enableManualAccessibility(pid: pid_t) -> Bool { false }
    func windows(ofApplication pid: pid_t) -> [AXUIElement] { [] }
    func walkAttributes(of element: AXUIElement) -> AXWalkAttributes? { nil }
}

/// What the window-text walk reads from one element. The spike measured six
/// separate reads per element as too slow for WebKit and AppKit tables, so the
/// system client fetches these with one `AXUIElementCopyMultipleAttributeValues`.
public struct AXWalkAttributes: @unchecked Sendable {
    public var role: String?
    public var subrole: String?
    public var value: String?
    public var title: String?
    public var description: String?
    public var children: [AXUIElement]
    /// Top-left screen coordinates, as AX reports them.
    public var frame: CGRect?
    public var isMinimized: Bool

    public init(role: String?, subrole: String? = nil, value: String? = nil, title: String? = nil,
                description: String? = nil, children: [AXUIElement] = [], frame: CGRect? = nil,
                isMinimized: Bool = false) {
        self.role = role
        self.subrole = subrole
        self.value = value
        self.title = title
        self.description = description
        self.children = children
        self.frame = frame
        self.isMinimized = isMinimized
    }
}

public struct SystemFocusedFieldAXClient: FocusedFieldAXClient {
    public init() {}
    private func timed(_ element: AXUIElement) -> AXUIElement {
        AXUIElementSetMessagingTimeout(element, 0.25)
        return element
    }
    /// AX requests aimed at our own process skip IPC and run AppKit's
    /// accessibility handlers on the calling thread. Off the main thread that
    /// races NSTextView layout and deadlocks on its internal locks, so any
    /// request targeting Scribe itself is hopped to the main thread.
    private func onOwner<T>(pid: pid_t?, _ body: () -> T) -> T {
        guard pid == getpid(), !Thread.isMainThread else { return body() }
        return DispatchQueue.main.sync(execute: body)
    }
    private func onOwner<T>(of element: AXUIElement, _ body: () -> T) -> T {
        var owner: pid_t = 0
        return onOwner(pid: AXUIElementGetPid(element, &owner) == .success ? owner : nil, body)
    }
    private func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        onOwner(of: element) {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(timed(element), name as CFString, &value) == .success else { return nil }
            return value
        }
    }
    public func focusedElement(frontmostPID: pid_t) -> AXUIElement? {
        onOwner(pid: frontmostPID) { focusedElementUnchecked(frontmostPID: frontmostPID) }
    }
    private func focusedElementUnchecked(frontmostPID: pid_t) -> AXUIElement? {
        let system = timed(AXUIElementCreateSystemWide())
        if let value = attribute(kAXFocusedUIElementAttribute as String, of: system),
           CFGetTypeID(value) == AXUIElementGetTypeID() { return timed(value as! AXUIElement) }
        let app = timed(AXUIElementCreateApplication(frontmostPID))
        guard let value = attribute(kAXFocusedUIElementAttribute as String, of: app),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return timed(value as! AXUIElement)
    }
    public func pid(of element: AXUIElement) -> pid_t? {
        var result: pid_t = 0
        return AXUIElementGetPid(timed(element), &result) == .success ? result : nil
    }
    public func string(_ name: String, of element: AXUIElement) -> String? {
        attribute(name, of: element) as? String
    }
    public func valueLength(of element: AXUIElement) -> Int? {
        (attribute(kAXValueAttribute as String, of: element) as? String)?.utf16.count
    }
    public func selectedRange(of element: AXUIElement) -> CFRange? {
        guard let value = attribute(kAXSelectedTextRangeAttribute as String, of: element),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange(location: 0, length: 0)
        return AXValueGetValue(value as! AXValue, .cfRange, &range) ? range : nil
    }
    /// `AXSelectedText` first. WebKit web areas (Mail's viewer and compose
    /// body) answer neither it nor `AXSelectedTextRange`, but expose the
    /// selection through their text-marker attributes; Chromium fields answer
    /// the range and `AXStringForRange`. The QA pass measured both
    /// (docs/feasibility/assistant-qa-matrix.md).
    public func selectedText(of element: AXUIElement) -> String? {
        if let text = string(kAXSelectedTextAttribute as String, of: element) { return text }
        if let range = selectedRange(of: element), range.length > 0,
           let text = parameterized(kAXStringForRangeParameterizedAttribute as String, of: element, parameter: rangeValue(range)) as? String {
            return text
        }
        guard let markerRange = attribute("AXSelectedTextMarkerRange", of: element) else { return nil }
        return parameterized("AXStringForTextMarkerRange", of: element, parameter: markerRange) as? String
    }
    private func rangeValue(_ range: CFRange) -> CFTypeRef {
        var mutable = range
        return AXValueCreate(.cfRange, &mutable)!
    }
    private func parameterized(_ name: String, of element: AXUIElement, parameter: CFTypeRef) -> CFTypeRef? {
        onOwner(of: element) {
            var value: CFTypeRef?
            guard AXUIElementCopyParameterizedAttributeValue(timed(element), name as CFString, parameter, &value) == .success else { return nil }
            return value
        }
    }
    public func isSettable(_ name: String, on element: AXUIElement) -> Bool {
        onOwner(of: element) {
            var result = DarwinBoolean(false)
            return AXUIElementIsAttributeSettable(timed(element), name as CFString, &result) == .success && result.boolValue
        }
    }
    public func setSelectedText(_ text: String, on element: AXUIElement) -> Bool {
        onOwner(of: element) {
            AXUIElementSetAttributeValue(timed(element), kAXSelectedTextAttribute as CFString, text as CFString) == .success
        }
    }
    public func precedingCharacter(of element: AXUIElement, range: CFRange) -> String? {
        guard range.location > 0 else { return nil }
        var precedingRange = CFRange(location: range.location - 1, length: 1)
        guard let parameter = AXValueCreate(.cfRange, &precedingRange),
              AXUIElementSetMessagingTimeout(element, 0.25) == .success else { return nil }
        return onOwner(of: element) {
            var value: CFTypeRef?
            guard AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString, parameter, &value) == .success else { return nil }
            return value as? String
        }
    }
    public func frame(of element: AXUIElement) -> CGRect? {
        guard let position = attribute(kAXPositionAttribute as String, of: element),
              let size = attribute(kAXSizeAttribute as String, of: element),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else { return nil }
        return CGRect(origin: point, size: dimensions)
    }
    public func caretFrame(of element: AXUIElement, range: CFRange) -> CGRect? {
        var copy = range
        guard let parameter = AXValueCreate(.cfRange, &copy) else { return nil }
        let result: CFTypeRef? = onOwner(of: element) {
            var result: CFTypeRef?
            return AXUIElementCopyParameterizedAttributeValue(timed(element), kAXBoundsForRangeParameterizedAttribute as CFString, parameter, &result) == .success ? result : nil
        }
        guard let result, CFGetTypeID(result) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        return AXValueGetValue(result as! AXValue, .cgRect, &rect) ? rect : nil
    }
    public func window(of element: AXUIElement) -> AXUIElement? {
        guard let value = attribute(kAXWindowAttribute as String, of: element),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
    public func enableManualAccessibility(pid: pid_t) -> Bool {
        // Electron only exposes its web contents to AX clients that set this
        // documented attribute; VoiceOver-style AXEnhancedUserInterface is avoided
        // because it changes window animation behaviour in the target app.
        onOwner(pid: pid) {
            let app = timed(AXUIElementCreateApplication(pid))
            return AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue) == .success
        }
    }
    public func windows(ofApplication pid: pid_t) -> [AXUIElement] {
        let app = timed(AXUIElementCreateApplication(pid))
        guard let value = attribute(kAXWindowsAttribute as String, of: app) as? [AnyObject] else { return [] }
        // With no window open, some apps list the application element itself.
        return value.compactMap { item in
            guard CFGetTypeID(item) == AXUIElementGetTypeID() else { return nil }
            let window = item as! AXUIElement
            return CFEqual(window, app) ? nil : timed(window)
        }
    }
    private static let walkAttributeNames = [
        kAXRoleAttribute, kAXSubroleAttribute, kAXValueAttribute, kAXTitleAttribute,
        kAXDescriptionAttribute, kAXChildrenAttribute, kAXPositionAttribute, kAXSizeAttribute,
        kAXMinimizedAttribute,
    ] as CFArray
    public func walkAttributes(of element: AXUIElement) -> AXWalkAttributes? {
        let values: [AnyObject]? = onOwner(of: element) {
            var result: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(timed(element), Self.walkAttributeNames, [], &result) == .success else { return nil }
            return result as [AnyObject]?
        }
        guard let values, values.count == 9 else { return nil }
        // Missing attributes come back as AXValue errors in their slots.
        func text(_ index: Int) -> String? { values[index] as? String }
        func axValue(_ index: Int, _ type: AXValueType) -> AXValue? {
            let item = values[index]
            guard CFGetTypeID(item) == AXValueGetTypeID(), AXValueGetType(item as! AXValue) == type else { return nil }
            return (item as! AXValue)
        }
        let children = (values[5] as? [AnyObject])?.compactMap { child -> AXUIElement? in
            CFGetTypeID(child) == AXUIElementGetTypeID() ? timed(child as! AXUIElement) : nil
        } ?? []
        var frame: CGRect?
        var origin = CGPoint.zero
        var size = CGSize.zero
        if let position = axValue(6, .cgPoint), let dimensions = axValue(7, .cgSize),
           AXValueGetValue(position, .cgPoint, &origin), AXValueGetValue(dimensions, .cgSize, &size) {
            frame = CGRect(origin: origin, size: size)
        }
        return AXWalkAttributes(role: text(0), subrole: text(1), value: text(2), title: text(3),
                                description: text(4), children: children, frame: frame,
                                isMinimized: (values[8] as? Bool) ?? false)
    }
}

public actor FocusedFieldLocator {
    private let client: any FocusedFieldAXClient
    private var manualAccessibilityRequested: Set<pid_t> = []
    public init(client: any FocusedFieldAXClient = SystemFocusedFieldAXClient()) { self.client = client }

    private static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXWebArea", "AXComboBox", "AXSearchField"]

    private func focusedElement(frontmostPID: pid_t) -> AXUIElement? {
        guard let element = client.focusedElement(frontmostPID: frontmostPID),
              client.pid(of: element) == frontmostPID else { return nil }
        return element
    }

    /// Electron apps expose only opaque groups until an AX client opts in. The
    /// first request per process waits briefly while Chromium builds the tree.
    private func focusedElementEnablingElectron(frontmostPID: pid_t) async -> AXUIElement? {
        let element = focusedElement(frontmostPID: frontmostPID)
        let isText = element.map { Self.textRoles.contains(client.string(kAXRoleAttribute as String, of: $0) ?? "") } ?? false
        guard !isText, !manualAccessibilityRequested.contains(frontmostPID) else { return element }
        manualAccessibilityRequested.insert(frontmostPID)
        guard client.enableManualAccessibility(pid: frontmostPID) else { return element }
        for _ in 0..<8 {
            try? await Task.sleep(for: .milliseconds(50))
            if let retry = focusedElement(frontmostPID: frontmostPID),
               Self.textRoles.contains(client.string(kAXRoleAttribute as String, of: retry) ?? "") { return retry }
        }
        return focusedElement(frontmostPID: frontmostPID) ?? element
    }

    public func locate(frontmostPID: pid_t, screenTop: CGFloat, screens: [CGRect]) async -> FocusedFieldSnapshot? {
        guard let element = await focusedElementEnablingElectron(frontmostPID: frontmostPID) else { return nil }
        let role = client.string(kAXRoleAttribute as String, of: element)
        let subrole = client.string(kAXSubroleAttribute as String, of: element)
        let secure = subrole == "AXSecureTextField" || role == "AXSecureTextField"
        let textRole = Self.textRoles.contains(role ?? "")
        let range = client.selectedRange(of: element)
        func converted(_ rect: CGRect?) -> CGRect? {
            guard let rect, rect.isFinite, rect.width >= 0, rect.height > 0,
                  !(rect.origin == .zero && rect.size == .zero) else { return nil }
            let appKit = CGRect(x: rect.minX, y: screenTop - rect.maxY, width: rect.width, height: rect.height)
            // AX commonly reports a zero-width insertion caret. CGRect.intersects
            // treats that as empty, though its point still identifies a display.
            return screens.contains(where: { $0.contains(CGPoint(x: appKit.midX, y: appKit.midY)) || $0.intersects(appKit) }) ? appKit : nil
        }
        let caret = range.flatMap { converted(client.caretFrame(of: element, range: $0)) }
        let elementFrame = converted(client.frame(of: element))
        let windowFrame = client.window(of: element).flatMap { converted(client.frame(of: $0)) }
        return FocusedFieldSnapshot(pid: frontmostPID, element: element, role: role, subrole: subrole,
                                    isSecure: secure, isTextRole: textRole,
                                    selectedTextSettable: client.isSettable(kAXSelectedTextAttribute as String, on: element),
                                    selectedRange: range, caretRect: caret,
                                    elementFrame: (elementFrame?.width ?? 0) > 4 ? elementFrame : nil,
                                    windowFrame: windowFrame, valueLength: client.valueLength(of: element))
    }

    public func stillFocused(_ snapshot: FocusedFieldSnapshot, frontmostPID: pid_t) -> Bool {
        guard frontmostPID == snapshot.pid,
              let current = client.focusedElement(frontmostPID: frontmostPID) else { return false }
        return CFEqual(current, snapshot.element)
    }

    public func precedingCharacter(_ snapshot: FocusedFieldSnapshot) -> String? {
        guard let range = snapshot.selectedRange else { return nil }
        return client.precedingCharacter(of: snapshot.element, range: range)
    }

    public func insertDirect(_ text: String, into snapshot: FocusedFieldSnapshot) async -> Bool {
        guard snapshot.selectedTextSettable, !snapshot.isSecure else { return false }
        let before = client.valueLength(of: snapshot.element)
        let range = client.selectedRange(of: snapshot.element)
        guard client.setSelectedText(text, on: snapshot.element) else { return false }
        // Writing AXSelectedText replaces the selected range. With a selection
        // the length alone cannot tell a replacement from a silent failure when
        // the two texts are the same length, so that case relies on the caret.
        let replaced = range?.length ?? 0
        for attempt in 0..<3 {
            let after = client.valueLength(of: snapshot.element)
            let selection = client.selectedRange(of: snapshot.element)
            if replaced == 0, let before, let after,
               after >= before + text.utf16.count { return true }
            if replaced > 0, replaced != text.utf16.count, let before, let after,
               after == before - replaced + text.utf16.count { return true }
            if let range, let selection,
               selection.location >= range.location + text.utf16.count { return true }
            if attempt < 2 { try? await Task.sleep(for: .milliseconds(75)) }
        }
        return false
    }
}

private extension CGRect {
    var isFinite: Bool { [minX, minY, width, height].allSatisfy(\.isFinite) }
}
