# Dictation QA (2026-09-25)

## Build and automated checks

| Check | Result |
| --- | --- |
| Debug app and transcription helper, `Scripts/build-app.sh` | Passed. The app, worker, and bundled helper assets built; a final app-only rebuild also passed. |
| Dictation package, `swift test --package-path Modules/Dictation` | Passed: 14 tests, 0 failures. Covers hold, short tap, double tap, chord cancel, twin modifier, secure input state, maximum duration, AX insertion read-back, paste fallback, and text shaping. |
| `bash -n Scripts/package-app.sh` | Passed. The packaging script names the dictation VAD bundle and license notice. |
| Unsigned local Release app build | Passed with arm64 and `CODE_SIGNING_ALLOWED=NO`. This checks Release compilation without notarization. |
| Signed archive and notarization, `Scripts/package-app.sh` | Passed after approval. Apple accepted submission `cf813abb-b08f-4d2d-bb6a-7fa6e22098c8`; stapling, validation, and Gatekeeper acceptance passed. The notarized QA archive is `/private/tmp/scribe-dictation-package/distribution/Scribe.zip`. |

The built Debug app's first-run window visibly shows the optional Dictation row and an **Enable Dictation** button. After approval, the QA app showed Microphone and Accessibility access but lacked keyboard-listening access. The user approved Input Monitoring, yet macOS's application picker did not enable its Open action for the Debug or notarized app bundles. The user chose to install the signed version and have QA run against that single instance. No physical end-to-end dictation was performed yet. The earlier [AX feasibility matrix](../feasibility/dictation-ax-matrix.md) tests field APIs and posted paste in disposable targets; it is not a test of the integrated feature.

## Integrated app matrix

Both activation paths below require dictation to be enabled in the QA build. **Pending** means neither hold nor double-tap was exercised in the integrated Scribe app, so insertion success is not claimed.

| Target | Hold right Command | Double-tap right Command | Expected path from feasibility spike |
| --- | --- | --- | --- |
| TextEdit | Pending | Pending | Direct AX insertion, caret indicator |
| Notes | Pending | Pending | Direct AX insertion, caret indicator |
| Mail compose | Pending | Pending | Paste, element/window indicator |
| Safari textarea | Pending | Pending | Paste after AX no-op, caret indicator |
| Safari contenteditable | Pending | Pending | Paste after AX no-op, caret indicator |
| Chrome textarea | Pending | Pending | Paste after AX no-op, caret indicator |
| Chrome contenteditable | Pending | Pending | Paste, element indicator |
| Slack composer | Pending | Pending | Paste, element indicator; Electron AX tree may need manual accessibility |
| Cursor (VS Code substitute) | Pending | Pending | Paste, caret/window indicator |
| Xcode editor | Pending | Pending | Direct AX insertion, caret indicator |
| Terminal | Pending | Pending | Paste, element/window indicator |
| Java GUI app | Unavailable | Unavailable | No Java GUI app found in the feasibility pass |

## Edge-case checks still requiring a live session

| Case | Code path or automated evidence | Integrated result |
| --- | --- | --- |
| Secure Keyboard Entry | Trigger monitor polls `IsSecureEventInputEnabled`; status appears in menu and Dictation settings and clears when secure input ends. | Pending Terminal secure-input exercise |
| Remapped right Command | First observed keycode 54 event is persisted; settings explains a missing event. | Pending physical key/remap exercise |
| Focus moves between press and release | Inserter resolves the focused field at insertion; coordinator compares the starting and current AX element and labels the indicator with the destination app if focus moved. | Pending live field-switch exercise |
| Model unavailable | Settings enable toggle stays off until the model is installed; the menu action opens Dictation settings with a loading-model error. | Pending live toggle/trigger exercise |
| Maximum duration | Synthetic trigger test verifies cancellation at the cap; coordinator shows an error. | Pending live cap exercise |
| Sleep and device changes | Capture drops an interrupted utterance on sleep and restarts its audio engine after configuration changes; a failed restart shows an error. | Pending sleep/device exercise |
| Dictation during a Scribe recording | Dictation uses its own `AVAudioEngine` and worker, outside the meeting capture and background queue. | Pending simultaneous live capture |
| Memory pressure | Worker unloads on a memory-pressure signal and `dictate()` warms it on the next trigger. | Pending live pressure/reload exercise |

After local QA access is approved, rerun each row with disposable text and confirm the destination field, indicator placement, clipboard restoration, and that meeting audio excludes the dictated utterance. Do not treat the earlier AX spike as a pass for the integrated flow.
