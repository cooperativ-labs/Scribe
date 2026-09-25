import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation

if CommandLine.arguments.count == 1 {
    _ = freopen("/private/tmp/scribe-trigger-app.log", "w", stdout)
}
let seconds = CommandLine.arguments.dropFirst().first.flatMap(Double.init) ?? 60
if CommandLine.arguments.contains("--request") || !AXIsProcessTrusted() || !CGPreflightListenEventAccess() {
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    print("AX request result=\(AXIsProcessTrustedWithOptions(options))")
    print("listen request result=\(CGRequestListenEventAccess())")
    fflush(stdout)
}
print("pid=\(ProcessInfo.processInfo.processIdentifier) ax=\(AXIsProcessTrusted()) listen=\(CGPreflightListenEventAccess()) post=\(CGPreflightPostEventAccess())", terminator: "\n")
let flags = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { event in
    print("monitor flags key=\(event.keyCode) raw=\(event.modifierFlags.rawValue) rightBit=\((event.modifierFlags.rawValue & 0x10) != 0) cmd=\(event.modifierFlags.contains(.command)) rightDown=\(CGEventSource.keyState(.combinedSessionState, key: 54)) secure=\(IsSecureEventInputEnabled()) t=\(Date().timeIntervalSince1970)")
    fflush(stdout)
}
let keys = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
    print("monitor keyDown key=\(event.keyCode) rightDown=\(CGEventSource.keyState(.combinedSessionState, key: 54)) t=\(Date().timeIntervalSince1970)")
    fflush(stdout)
}
var tap: CFMachPort?
if CommandLine.arguments.contains("--tap") || CommandLine.arguments.count == 1 {
    let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
    tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly, eventsOfInterest: CGEventMask(mask), callback: { _, type, event, _ in
        let key = event.getIntegerValueField(.keyboardEventKeycode)
    print("tap type=\(type.rawValue) key=\(key) raw=\(event.flags.rawValue) rightBit=\((event.flags.rawValue & 0x10) != 0) commandFlag=\(event.flags.contains(.maskCommand)) rightCombined=\(CGEventSource.keyState(.combinedSessionState, key: 54)) rightHID=\(CGEventSource.keyState(.hidSystemState, key: 54)) secure=\(IsSecureEventInputEnabled()) t=\(Date().timeIntervalSince1970)")
        fflush(stdout)
        return Unmanaged.passUnretained(event)
    }, userInfo: nil)
    print("tap_created=\(tap != nil)")
    if let tap {
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }
}
print("flags_monitor_created=\(flags != nil) keys_monitor_created=\(keys != nil)")
fflush(stdout)
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
var lastSecure = IsSecureEventInputEnabled()
var lastCombined = CGEventSource.keyState(.combinedSessionState, key: 54)
var lastHID = CGEventSource.keyState(.hidSystemState, key: 54)
Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
    let secure = IsSecureEventInputEnabled()
    if secure != lastSecure {
        print("secure_input_changed=\(secure) t=\(Date().timeIntervalSince1970)")
        fflush(stdout)
        lastSecure = secure
    }
}
Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { _ in
    let combined = CGEventSource.keyState(.combinedSessionState, key: 54)
    let hid = CGEventSource.keyState(.hidSystemState, key: 54)
    if combined != lastCombined || hid != lastHID {
        print("polled rightCombined=\(combined) rightHID=\(hid) t=\(Date().timeIntervalSince1970)")
        fflush(stdout)
        lastCombined = combined
        lastHID = hid
    }
}
Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { _ in
    fflush(stdout)
    exit(0)
}
app.run()
if let flags { NSEvent.removeMonitor(flags) }
if let keys { NSEvent.removeMonitor(keys) }
