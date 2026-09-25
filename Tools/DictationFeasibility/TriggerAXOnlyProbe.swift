import AppKit
import ApplicationServices
import Foundation

_ = freopen("/private/tmp/scribe-trigger-axonly.log", "w", stdout)
let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
print("ax_request=\(AXIsProcessTrustedWithOptions(options))")
print("ax=\(AXIsProcessTrusted()) listen=\(CGPreflightListenEventAccess()) post=\(CGPreflightPostEventAccess())")
let flags = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { event in
    print("flags key=\(event.keyCode) rightBit=\((event.modifierFlags.rawValue & 0x10) != 0) ax=\(AXIsProcessTrusted()) listen=\(CGPreflightListenEventAccess())")
    fflush(stdout)
}
let keys = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
    print("keyDown key=\(event.keyCode) ax=\(AXIsProcessTrusted()) listen=\(CGPreflightListenEventAccess())")
    fflush(stdout)
}
print("flags_monitor=\(flags != nil) key_monitor=\(keys != nil)")
fflush(stdout)
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
var lastState = ""
Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
    let state = "ax=\(AXIsProcessTrusted()) listen=\(CGPreflightListenEventAccess()) post=\(CGPreflightPostEventAccess())"
    if state != lastState {
        print("state \(state)")
        fflush(stdout)
        lastState = state
    }
}
Timer.scheduledTimer(withTimeInterval: 45, repeats: false) { _ in exit(0) }
app.run()
