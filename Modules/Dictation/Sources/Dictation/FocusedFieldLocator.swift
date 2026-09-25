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
    func isSettable(_ attribute: String, on element: AXUIElement) -> Bool
    func setSelectedText(_ text: String, on element: AXUIElement) -> Bool
    func precedingCharacter(of element: AXUIElement, range: CFRange) -> String?
    func frame(of element: AXUIElement) -> CGRect?
    func caretFrame(of element: AXUIElement, range: CFRange) -> CGRect?
    func window(of element: AXUIElement) -> AXUIElement?
}

public struct SystemFocusedFieldAXClient: FocusedFieldAXClient {
    public init() {}
    private func timed(_ element: AXUIElement) -> AXUIElement {
        AXUIElementSetMessagingTimeout(element, 0.25)
        return element
    }
    private func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(timed(element), name as CFString, &value) == .success else { return nil }
        return value
    }
    public func focusedElement(frontmostPID: pid_t) -> AXUIElement? {
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
    public func isSettable(_ name: String, on element: AXUIElement) -> Bool {
        var result = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(timed(element), name as CFString, &result) == .success && result.boolValue
    }
    public func setSelectedText(_ text: String, on element: AXUIElement) -> Bool {
        AXUIElementSetAttributeValue(timed(element), kAXSelectedTextAttribute as CFString, text as CFString) == .success
    }
    public func precedingCharacter(of element: AXUIElement, range: CFRange) -> String? {
        guard range.location > 0 else { return nil }
        var precedingRange = CFRange(location: range.location - 1, length: 1)
        guard let parameter = AXValueCreate(.cfRange, &precedingRange),
              AXUIElementSetMessagingTimeout(element, 0.25) == .success else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString, parameter, &value) == .success else { return nil }
        return value as? String
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
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(timed(element), kAXBoundsForRangeParameterizedAttribute as CFString, parameter, &result) == .success,
              let result, CFGetTypeID(result) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        return AXValueGetValue(result as! AXValue, .cgRect, &rect) ? rect : nil
    }
    public func window(of element: AXUIElement) -> AXUIElement? {
        guard let value = attribute(kAXWindowAttribute as String, of: element),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
}

public actor FocusedFieldLocator {
    private let client: any FocusedFieldAXClient
    public init(client: any FocusedFieldAXClient = SystemFocusedFieldAXClient()) { self.client = client }

    public func locate(frontmostPID: pid_t, screenTop: CGFloat, screens: [CGRect]) -> FocusedFieldSnapshot? {
        guard let element = client.focusedElement(frontmostPID: frontmostPID),
              client.pid(of: element) == frontmostPID else { return nil }
        let role = client.string(kAXRoleAttribute as String, of: element)
        let subrole = client.string(kAXSubroleAttribute as String, of: element)
        let secure = subrole == "AXSecureTextField" || role == "AXSecureTextField"
        let textRole = ["AXTextField", "AXTextArea", "AXWebArea", "AXComboBox", "AXSearchField"].contains(role ?? "")
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
        for attempt in 0..<3 {
            let after = client.valueLength(of: snapshot.element)
            let selection = client.selectedRange(of: snapshot.element)
            if let before, let after,
               after >= before + text.utf16.count { return true }
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
