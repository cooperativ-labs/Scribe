# Right Command trigger feasibility (macOS 27)

## Probe and permission state

`Tools/DictationFeasibility/TriggerProbe.swift` is a throwaway, Developer ID signed, hardened-runtime, unsandboxed app (`com.scribe.dictation-feasibility-trigger`). It installs `NSEvent` global `flagsChanged` and `keyDown` monitors, a `.listenOnly` CGEvent tap for those event types, logs `CGEventSource.keyState(.combinedSessionState, key: 54)` and `.hidSystemState` in callbacks and every 20 ms, and polls `IsSecureEventInputEnabled()` for changes. It runs the AppKit application event loop, which was necessary for the `NSEvent` callbacks in this probe. It does not alter the app target or register a hotkey.

| State | AX trusted | `CGPreflightListenEventAccess` | `CGPreflightPostEventAccess` | Global monitor handles | Listen-only tap |
| --- | --- | --- | --- | --- | --- |
| Before user grant, app run | false | false | false | both created | not created |
| After user grant, app run | true | true | true | both created | created |
| Signed executable launched directly by the tool runner | false | false | false | both created | could be created outside the file sandbox, but delivery was not verified |

The pre-grant `NSEvent` handle is **not** proof that any key events are delivered: its API can return a monitor object even when access is missing. The CLI runner's identity also differs from launching the signed `.app`, so the app-context rows above are the relevant TCC measurements.

On this macOS 27 installation the app appeared in **Privacy & Security → Device Control and Data Access**, whose description explicitly includes monitoring the keyboard and controlling apps. Enabling its switch required Touch ID or a password. The probe requested AX and listen access in the same launch, and the system showed this combined pane; this run does **not** isolate whether AX alone would have delivered `flagsChanged` or `keyDown`, nor establish that a separate Input Monitoring pane is required on macOS 27. The probe's `CGRequestListenEventAccess()` call returned false before the user grant. After the grant both preflights were true.

To isolate the request path, `TriggerAXOnlyProbe.swift` was signed as a **different bundle ID**. It called `AXIsProcessTrustedWithOptions(prompt: true)` but never called `CGRequestListenEventAccess()` or created an event tap. Before the user grant it reported AX=false, listen=false, post=false. During the first 45-second run, the user granted its system prompt and the process briefly observed AX=true while listen=false and post=false; no physical key was captured in that brief interval. On restart, **all three preflights were true**, and its global monitors delivered physical right-Command press/release and right-Cmd+C `keyDown`. Thus an AX-only *request* led to a combined effective grant on this macOS 27 installation. The run does not prove delivery while listen access is actually denied, and a separate Input Monitoring pane was not observed.

## Event delivery results

| Scenario | Result on this machine |
| --- | --- |
| Right Command (keycode 54) press and release | Physical 2.4 s hold delivered keycode 54 `flagsChanged` press and release to both the global monitor and the listen-only tap. The Command flag rose and fell. The separate AX-request-only app also received both edges after its effective grant became combined. |
| Left Command held while right Command is tapped | Both received keycode 55 down, keycode 54 down, keycode 54 up, keycode 55 up. The general Command flag stayed true on right release, so it cannot identify the right key's release. |
| `CGEventSource.keyState(.combinedSessionState, key: 54)` disambiguation | **Failed:** combined-session and HID-system key state returned false on both keycode 54 callbacks and throughout 20 ms polling during the physical hold. Do not use this for twin-modifier disambiguation on this machine. |
| Global `keyDown` for right-Cmd+C cancellation | A physical right-Cmd+C delivered keycode 8 (`C`) `keyDown` to both the monitor and tap. Chord cancellation can use it when secure input is off. |
| Listen-only `CGEventTap` `flagsChanged` and `keyDown` | Both event types delivered in the signed app after the grant. It provides a viable fallback but showed no delivery advantage in these normal-input traces. |
| Terminal Secure Keyboard Entry | `IsSecureEventInputEnabled()` switched true when Terminal enabled it, and false when disabled. In two right-Cmd+C attempts while it was true, both monitor and tap delivered right-Command `flagsChanged` but neither delivered the `C` `keyDown`. Treat secure input as a blocker for the dictation trigger, even though modifier callbacks continue. |

The physical trace also showed a device-specific right-Command flag bit (`NX_DEVICERCMDKEYMASK`, `0x10`) true on right press and false on release, including while Terminal Secure Keyboard Entry was on. It should be tested with left Command held before relying on it for production. Tracking keycode 54 edges in the event stream is the immediately supported way to disambiguate the twin-modifier trace. Apple's [global monitor documentation](https://developer.apple.com/documentation/appkit/nsevent/addglobalmonitorforevents%28matching%3Ahandler%3A%29) says key-related events require Accessibility trust and that the monitor observes events sent to other apps. Apple's [key-state API](https://developer.apple.com/documentation/coregraphics/cgeventsource/keystate%28_%3Akey%3A%29) documents the API, but its result did not reflect this physical right-key hold.

## Recommendation for the next objective

Keep `DictationTriggerMonitor` behind a small event-source protocol. Use `NSEvent` global monitors for `flagsChanged` and `keyDown` with an AppKit event loop: both delivered physical right-Command and chord events. Keep a listen-only `CGEventTap` as a fallback, also demonstrated to deliver these events. Track keycode 54 press/release edges (and consider the `NX_DEVICERCMDKEYMASK` bit); **remove the proposal's reliance on `CGEventSource.keyState`**, which returned false even during a sustained physical hold. Check `IsSecureEventInputEnabled()` and suppress dictation when true; modifier events may still arrive. On macOS 27, direct users to the observed **Device Control and Data Access** pane and check both `AXIsProcessTrusted()` and `CGPreflightListenEventAccess()` before enabling the respective path. Treat the permission as combined on this OS until a separated grant/deny combination can be tested.

The production path should include a small on-device diagnostic for missing event delivery, because a successfully installed global monitor is not proof of permission or delivered keys.

## Implementation update: selectable dictation key

The production AppKit path now requests and gates on Microphone and Accessibility
only. It does not call the listen-event permission APIs or install a CGEvent tap.
This follows [Apple's global monitor contract](https://developer.apple.com/documentation/appkit/nsevent/addglobalmonitorforevents%28matching%3Ahandler%3A%29),
which specifies Accessibility trust for key events. The combined grant observed
in the original macOS 27 probe is not evidence that a separate Input Monitoring
grant is required; the earlier recommendation to gate both has been removed from
the implementation.

The saved selector supports right Command (54), right Shift (60), and Fn / Globe
(63). The monitor reads the SDK's side-specific modifier masks for right Command
and right Shift, and the function flag for Fn. This avoids inverted press/release
state if monitoring starts with a key held. Hold, double-tap, chord cancellation,
and Secure Keyboard Entry blocking continue through the same trigger state.
Changing keys cancels the current trigger before switching.

Physical validation still needs the signed app with Accessibility granted and
Input Monitoring disabled: exercise each key in another app, hold both sides of
Command/Shift and release the right side first, change keys during a hold, and
enter/leave Secure Keyboard Entry. Fn should be tried with the macOS Keyboard
‘Press Fn/Globe key to’ action set to ‘Do Nothing’; hardware that handles Fn only
in firmware cannot provide the event. Unit tests do not establish TCC delivery.
