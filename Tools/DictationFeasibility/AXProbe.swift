import AppKit
import ApplicationServices
import Foundation

func read(_ element: AXUIElement, _ name: String) -> (AXError, CFTypeRef?) {
    var value: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
    return (error, value)
}

func string(_ element: AXUIElement, _ name: String) -> String {
    let (error, value) = read(element, name)
    return error == .success ? "\(value ?? "nil" as CFTypeRef)" : "error:\(error.rawValue)"
}

func rect(_ value: CFTypeRef?) -> CGRect? {
    guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
    var result = CGRect.zero
    return AXValueGetValue(value as! AXValue, .cgRect, &result) ? result : nil
}

let command = CommandLine.arguments.dropFirst().first ?? "inspect"
let system = AXUIElementCreateSystemWide()
AXUIElementSetMessagingTimeout(system, 0.25)
let (focusError, focusValue) = read(system, kAXFocusedUIElementAttribute)
print("ax=\(AXIsProcessTrusted()) focus_error=\(focusError.rawValue)")
guard focusError == .success, let focusValue else { exit(1) }
let focus = focusValue as! AXUIElement
AXUIElementSetMessagingTimeout(focus, 0.25)
var pid: pid_t = 0
AXUIElementGetPid(focus, &pid)
print("pid=\(pid) app=\(NSRunningApplication(processIdentifier: pid)?.localizedName ?? "?") role=\(string(focus, kAXRoleAttribute)) subrole=\(string(focus, kAXSubroleAttribute))")
print("value=\(string(focus, kAXValueAttribute).prefix(200))")
var settable: DarwinBoolean = false
let settableError = AXUIElementIsAttributeSettable(focus, kAXSelectedTextAttribute as CFString, &settable)
print("selected_text_settable_error=\(settableError.rawValue) settable=\(settable.boolValue)")
let (rangeError, rangeValue) = read(focus, kAXSelectedTextRangeAttribute)
print("range_error=\(rangeError.rawValue) range=\(String(describing: rangeValue))")
if rangeError == .success, let rangeValue, CFGetTypeID(rangeValue) == AXValueGetTypeID() {
    var range = CFRange()
    if AXValueGetValue(rangeValue as! AXValue, .cfRange, &range) {
        print("range_location=\(range.location) range_length=\(range.length)")
    }
    var bounds: CFTypeRef?
    let boundsError = AXUIElementCopyParameterizedAttributeValue(focus, kAXBoundsForRangeParameterizedAttribute as CFString, rangeValue, &bounds)
    print("caret_error=\(boundsError.rawValue) caret=\(String(describing: rect(bounds)))")
}
let (frameError, frameValue) = read(focus, "AXFrame")
print("frame_error=\(frameError.rawValue) frame=\(String(describing: rect(frameValue)))")
let (windowError, windowValue) = read(focus, kAXWindowAttribute)
if windowError == .success, let windowValue {
    let window = windowValue as! AXUIElement
    print("window_frame=\(String(describing: rect(read(window, "AXFrame").1)))")
}
if command == "set", CommandLine.arguments.count >= 3 {
    let token = CommandLine.arguments[2]
    let before = string(focus, kAXValueAttribute)
    let error = AXUIElementSetAttributeValue(focus, kAXSelectedTextAttribute as CFString, token as CFTypeRef)
    Thread.sleep(forTimeInterval: 0.15)
    let after = string(focus, kAXValueAttribute)
    print("set_error=\(error.rawValue) changed=\(before != after) token_present=\(after.contains(token)) after=\(after.prefix(200))")
}
if command == "paste", CommandLine.arguments.count >= 3 {
    let token = CommandLine.arguments[2]
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(token, forType: .string)
    let source = CGEventSource(stateID: .combinedSessionState)
    let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
    let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
    down?.flags = .maskCommand
    up?.flags = .maskCommand
    down?.post(tap: .cghidEventTap)
    up?.post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.3)
    print("paste_post_access=\(CGPreflightPostEventAccess()) after=\(string(focus, kAXValueAttribute).prefix(200))")
}
