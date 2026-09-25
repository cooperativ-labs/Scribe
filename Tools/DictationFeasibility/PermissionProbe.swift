import AppKit
import ApplicationServices
import Carbon.HIToolbox

print("pid=\(ProcessInfo.processInfo.processIdentifier)")
print("AX trusted=\(AXIsProcessTrusted())")
print("listen access=\(CGPreflightListenEventAccess())")
print("post access=\(CGPreflightPostEventAccess())")
print("secure input=\(IsSecureEventInputEnabled())")
print("right command down=\(CGEventSource.keyState(.combinedSessionState, key: 54))")
