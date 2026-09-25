import AppKit
import ApplicationServices
import Foundation

private let commandURL = URL(fileURLWithPath: "/private/tmp/scribe-ax-command.json")
private let resultURL = URL(fileURLWithPath: "/private/tmp/scribe-ax-result.json")

func runPendingAXCommand() {
    guard let data = try? Data(contentsOf: commandURL),
          let input = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return }
    try? FileManager.default.removeItem(at: commandURL)
    let result = inspectAX(input)
    if let encoded = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted]) {
        try? encoded.write(to: resultURL, options: .atomic)
    }
}

private func inspectAX(_ input: [String: String]) -> [String: Any] {
    var output: [String: Any] = ["id": input["id"] ?? "", "trusted": AXIsProcessTrusted(), "postAccess": CGPreflightPostEventAccess()]
    let intended = input["bundle"].flatMap { bundle -> NSRunningApplication? in
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundle)
        output["matchingPIDs"] = running.map { $0.processIdentifier }
        if let selectedPID = input["pid"].flatMap(Int32.init),
           let selected = running.first(where: { $0.processIdentifier == selectedPID }) { return selected }
        return running.first(where: { $0.isActive }) ?? running.first
    }
    if input["activate"] == "true", let intended {
        output["activationRequested"] = intended.activate(options: [])
        Thread.sleep(forTimeInterval: 0.4)
    }
    let frontmost = NSWorkspace.shared.frontmostApplication
    output["frontmost"] = frontmost?.localizedName ?? "none"
    let system = AXUIElementCreateSystemWide()
    AXUIElementSetMessagingTimeout(system, 0.25)
    var (focusError, focusValue) = axRead(system, kAXFocusedUIElementAttribute)
    output["focusError"] = focusError.rawValue
    if focusError != .success {
        AXUIElementSetMessagingTimeout(system, 1.0)
        let retry = axRead(system, kAXFocusedUIElementAttribute)
        output["focusRetryError"] = retry.0.rawValue
        if retry.0 == .success { (focusError, focusValue) = retry }
    }
    if let intended {
        output["intendedApp"] = intended.localizedName ?? "unknown"
        output["intendedFrontmost"] = intended.isActive
    }
    var systemPID: pid_t = 0
    if let focusValue { AXUIElementGetPid(focusValue as! AXUIElement, &systemPID) }
    if (focusError != .success || (intended != nil && systemPID != intended?.processIdentifier) || input["manual"] == "false"), let target = intended ?? frontmost {
        let application = AXUIElementCreateApplication(target.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 1.0)
        if input["manual"] == "false" {
            let manual = AXUIElementSetAttributeValue(application, "AXManualAccessibility" as CFString, kCFBooleanFalse)
            output["manualOffError"] = manual.rawValue
        }
        if input["manual"] == "true" {
            let manual = AXUIElementSetAttributeValue(application, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            output["manualError"] = manual.rawValue
            Thread.sleep(forTimeInterval: 1.0)
        }
        if input["enhance"] == "true" {
            let enhanced = AXUIElementSetAttributeValue(application, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            output["enhanceError"] = enhanced.rawValue
            Thread.sleep(forTimeInterval: 2.5)
        }
        let retry = axRead(application, kAXFocusedUIElementAttribute)
        output["appFocusError"] = retry.0.rawValue
        if retry.0 == .success { (focusError, focusValue) = retry }
        if retry.0 != .success {
            let (windowError, window) = axRead(application, kAXFocusedWindowAttribute)
            output["appWindowError"] = windowError.rawValue
            if windowError == .success, let window {
                output["windowRoleHistogram"] = roleHistogram(window as! AXUIElement)
            }
        }
    }
    guard focusError == .success, let focusValue else { return output }
    let focus = focusValue as! AXUIElement
    AXUIElementSetMessagingTimeout(focus, 0.25)
    var pid: pid_t = 0
    AXUIElementGetPid(focus, &pid)
    output["pid"] = pid
    output["app"] = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "unknown"
    output["role"] = axString(focus, kAXRoleAttribute) ?? "unavailable"
    output["subrole"] = axString(focus, kAXSubroleAttribute) ?? "unavailable"
    let (childrenError, children) = axRead(focus, kAXChildrenAttribute)
    output["childrenError"] = childrenError.rawValue
    if let children = children as? [AXUIElement] {
        output["childRoles"] = children.prefix(12).map { axString($0, kAXRoleAttribute) ?? "unavailable" }
    }
    let (childFocusError, childFocus) = axRead(focus, kAXFocusedUIElementAttribute)
    output["childFocusError"] = childFocusError.rawValue
    if childFocusError == .success, let childFocus {
        output["childFocusRole"] = axString(childFocus as! AXUIElement, kAXRoleAttribute) ?? "unavailable"
    }
    let (valueError, value) = axRead(focus, kAXValueAttribute)
    let before = value as? String
    output["valueError"] = valueError.rawValue
    output["valueLength"] = before?.count ?? -1
    output["valueIsScratchSeed"] = before == "seed"
    var settable: DarwinBoolean = false
    let settableError = AXUIElementIsAttributeSettable(focus, kAXSelectedTextAttribute as CFString, &settable)
    output["selectedTextSettableError"] = settableError.rawValue
    output["selectedTextSettable"] = settable.boolValue
    let (rangeError, rangeValue) = axRead(focus, kAXSelectedTextRangeAttribute)
    output["rangeError"] = rangeError.rawValue
    if let rangeValue, CFGetTypeID(rangeValue) == AXValueGetTypeID() {
        var range = CFRange()
        if AXValueGetValue(rangeValue as! AXValue, .cfRange, &range) {
            output["rangeLocation"] = range.location
            output["rangeLength"] = range.length
        }
        var caretValue: CFTypeRef?
        let caretError = AXUIElementCopyParameterizedAttributeValue(focus, kAXBoundsForRangeParameterizedAttribute as CFString, rangeValue, &caretValue)
        output["caretError"] = caretError.rawValue
        if let caret = axRect(caretValue) {
            output["caretAX"] = rectDict(caret)
            let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
            output["caretAppKit"] = rectDict(CGRect(x: caret.minX, y: primaryTop - caret.maxY, width: caret.width, height: caret.height))
        }
    }
    output["elementFrameAX"] = axFrame(focus).map(rectDict) ?? NSNull()
    let (windowError, windowValue) = axRead(focus, kAXWindowAttribute)
    if windowError == .success, let windowValue {
    output["windowFrameAX"] = axFrame(windowValue as! AXUIElement).map(rectDict) ?? NSNull()
        output["scratchWindowTitle"] = (axString(windowValue as! AXUIElement, kAXTitleAttribute) ?? "").contains("scribe-ax-editor-scratch")
    }
    guard let action = input["action"], let token = input["token"], !token.isEmpty else { return output }
    if action == "find" {
        output["descendantTokenPresent"] = descendantContainsToken(focus, token: token)
    } else if action == "clear" {
        guard before == token, axString(focus, kAXRoleAttribute) == kAXTextAreaRole else {
            output["clearSkipped"] = true
            return output
        }
        let source = CGEventSource(stateID: .combinedSessionState)
        let selectDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
        let selectUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        selectDown?.flags = .maskCommand
        selectUp?.flags = .maskCommand
        selectDown?.post(tap: .cghidEventTap)
        selectUp?.post(tap: .cghidEventTap)
        let deleteDown = CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: true)
        let deleteUp = CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: false)
        deleteDown?.post(tap: .cghidEventTap)
        deleteUp?.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.3)
        output["cleared"] = !((axRead(focus, kAXValueAttribute).1 as? String)?.contains(token) ?? true)
    } else if action == "set" {
        let setError = AXUIElementSetAttributeValue(focus, kAXSelectedTextAttribute as CFString, token as CFTypeRef)
        Thread.sleep(forTimeInterval: 0.15)
        let after = axRead(focus, kAXValueAttribute).1 as? String
        output["setError"] = setError.rawValue
        output["afterValueLength"] = after?.count ?? -1
        output["valueChanged"] = before != after
        output["tokenPresent"] = after?.contains(token) ?? false
        if after == nil { readInsertedRange(focus, token: token, output: &output) }
        output["descendantTokenPresent"] = descendantContainsToken(focus, token: token)
    } else if action == "paste" {
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.pasteboardItems?.map { item in
            item.types.reduce(into: [NSPasteboard.PasteboardType: Data]()) { result, type in
                result[type] = item.data(forType: type)
            }
        } ?? []
        pasteboard.clearContents()
        pasteboard.setString(token, forType: .string)
        let insertedCount = pasteboard.changeCount
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.3)
        let after = axRead(focus, kAXValueAttribute).1 as? String
        output["afterValueLength"] = after?.count ?? -1
        output["valueChanged"] = before != after
        output["tokenPresent"] = after?.contains(token) ?? false
        if after == nil { readInsertedRange(focus, token: token, output: &output) }
        output["descendantTokenPresent"] = descendantContainsToken(focus, token: token)
        if pasteboard.changeCount == insertedCount {
            pasteboard.clearContents()
            let items = saved.map { old -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (type, data) in old { item.setData(data, forType: type) }
                return item
            }
            if !items.isEmpty { pasteboard.writeObjects(items) }
        }
    }
    return output
}

private func roleHistogram(_ root: AXUIElement) -> [String: Int] {
    var queue: [(AXUIElement, Int)] = [(root, 0)]
    var counts: [String: Int] = [:]
    var scanned = 0
    while !queue.isEmpty && scanned < 120 {
        let (element, depth) = queue.removeFirst()
        scanned += 1
        counts[axString(element, kAXRoleAttribute) ?? "unavailable", default: 0] += 1
        if depth < 6, let children = axRead(element, kAXChildrenAttribute).1 as? [AXUIElement] {
            queue.append(contentsOf: children.prefix(40).map { ($0, depth + 1) })
        }
    }
    return counts
}

private func descendantContainsToken(_ root: AXUIElement, token: String) -> Bool {
    var queue: [(AXUIElement, Int)] = [(root, 0)]
    var scanned = 0
    while !queue.isEmpty && scanned < 80 {
        let (element, depth) = queue.removeFirst()
        scanned += 1
        if (axRead(element, kAXValueAttribute).1 as? String)?.contains(token) == true { return true }
        if depth < 5, let children = axRead(element, kAXChildrenAttribute).1 as? [AXUIElement] {
            queue.append(contentsOf: children.prefix(30).map { ($0, depth + 1) })
        }
    }
    return false
}

private func readInsertedRange(_ focus: AXUIElement, token: String, output: inout [String: Any]) {
    let (error, selected) = axRead(focus, kAXSelectedTextRangeAttribute)
    output["afterRangeError"] = error.rawValue
    guard let selected, CFGetTypeID(selected) == AXValueGetTypeID() else { return }
    var range = CFRange()
    guard AXValueGetValue(selected as! AXValue, .cfRange, &range) else { return }
    output["afterRangeLocation"] = range.location
    output["afterRangeLength"] = range.length
    let size = token.utf16.count
    guard range.location >= size else { return }
    var inserted = CFRange(location: range.location - size, length: size)
    guard let parameter = AXValueCreate(.cfRange, &inserted) else { return }
    var value: CFTypeRef?
    let readError = AXUIElementCopyParameterizedAttributeValue(focus, kAXStringForRangeParameterizedAttribute as CFString, parameter, &value)
    output["rangeReadbackError"] = readError.rawValue
    output["rangeTokenPresent"] = (value as? String) == token
}

private func axRead(_ element: AXUIElement, _ name: String) -> (AXError, CFTypeRef?) {
    var value: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
    return (error, value)
}

private func axString(_ element: AXUIElement, _ name: String) -> String? {
    axRead(element, name).1 as? String
}

private func axRect(_ value: CFTypeRef?) -> CGRect? {
    guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
    var rect = CGRect.zero
    return AXValueGetValue(value as! AXValue, .cgRect, &rect) ? rect : nil
}

private func axFrame(_ element: AXUIElement) -> CGRect? {
    let position = axRead(element, kAXPositionAttribute).1
    let size = axRead(element, kAXSizeAttribute).1
    guard let position, let size,
          CFGetTypeID(position) == AXValueGetTypeID(),
          CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
    var point = CGPoint.zero
    var dimensions = CGSize.zero
    guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
          AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else { return nil }
    return CGRect(origin: point, size: dimensions)
}

private func rectDict(_ rect: CGRect) -> [String: Double] {
    ["x": rect.minX, "y": rect.minY, "width": rect.width, "height": rect.height]
}
