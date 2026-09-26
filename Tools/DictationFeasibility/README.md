# Dictation feasibility harnesses

These are throwaway probes, separate from the app and Xcode project. The reports under `docs/feasibility/dictation-*.md` contain the observations and limits.

- `DictationLatencyProbe` is the SwiftPM executable. It depends on the worker package and FluidAudio 0.17.4. Run it with `<Workers/TranscriptionWorker path> <3s.wav> <10s.wav> <30s.wav>`. Its `--vad <directory> <clips...>` mode requires a local FluidAudio `Models/silero-vad/silero-vad-unified-256ms-v6.2.1.mlmodelc` directory and always sets offline mode.
- `TriggerProbe.swift` installs read-only NSEvent monitors and a listen-only event tap, logs modifier state, and polls Secure Keyboard Entry. Compile it as a single-file `swiftc` executable and launch as the signed `.app` described by `ProbeInfo.plist`; launching its executable directly has a different TCC result on this machine.
- `TriggerAXOnlyProbe.swift` requests Accessibility with a separate signed bundle ID, but never requests listen access. It logs keycodes for 45 seconds to test the observed permission split.
- `AXOneShot.swift` plus `AXCommandProbe.swift` performs one scoped AX check per launch. Put a JSON command at `/private/tmp/scribe-ax-command.json`, for example `{"id":"TextEdit","bundle":"com.apple.TextEdit","activate":"true"}`. It writes role, geometry, length and success flags to `/private/tmp/scribe-ax-result.json`, without logging field contents. `action` can be `set`, `paste`, `find`, or `clear`; these require a `token` and must only target a disposable test field. `manual: true` requests Electron's `AXManualAccessibility` setting for the named app when authorized.
- `ax-fields.html` is a local textarea/contenteditable fixture for browser tests. `PermissionProbe.swift` and `AXProbe.swift` are simpler command-line diagnostics.

The local SwiftPM mirror used for this machine's cached FluidAudio source is intentionally not included. Normal SwiftPM resolution uses the package's pinned public URL.
