# Secure Input handling (2026-10-13)

## Evidence and cause

The inspected interval in the local Scribe debug history (`~/Library/Application Support/Scribe/Debugging/messages.json`) contains four Secure Keyboard Entry on/off pairs between 08:01:49 and 08:44:24 UTC on 2026-10-13. All eight observations record `frontmost=com.apple.loginwindow`. The first on transition follows an `Inserted` state; the later three follow `Idle`. Each on transition produces two identical pause errors, with a synthetic blocked-activation event and a cancellation between them.

The source explains that sequence: `refreshSecureInput()` called the coordinator's transition callback, which unconditionally cancelled and set an error, then emitted a blocked-activation event even without a key attempt. The coordinator cancelled and set the error again. Thus the log's old “Activation blocked” entries do not establish that anyone pressed a trigger.

`IsSecureEventInputEnabled()` establishes system-wide availability at the observation time. The separately sampled frontmost bundle identifier is context, not the Secure Input owner. This evidence does not identify which process requested Secure Input, why it did so, whether the screen was locked, or any causal connection to computer use. Scribe does not collect owner/process attribution here. Apple's [Secure Event Input technical note](https://developer.apple.com/library/archive/technotes/tn2150/_index.html) describes the system-wide restriction, including when the enabling process is in the background.

## Resulting behavior

- Idle transitions only update availability in the existing menu/settings and record transition diagnostics. They do not create an indicator error, synthetic blocked attempt, or cancellation.
- An on transition cancels active dictation or Voice Assistant capture, session model loading, transcription, or an assistant request. Router cancellation still resets hold/double-tap tracking. Repeated transition notifications and the router's cancellation cannot cancel twice or overwrite a blocked-attempt notice.
- An observed blocked trigger names its intent and shows one warning: “Secure Keyboard Entry is on. Leave the password field or protected app, then try again.” Repeated attempts during the same displayed block do not republish the notice or duplicate its debug messages. The indicator shows it even when listening visuals are set to Off.
- The notice stays visible until Secure Input ends (or the feature/monitor is stopped); the off callback clears it to Idle. No capture or insertion is automatically retried. Unrelated errors and background model warm-up are not replaced by passive transitions.
- macOS can withhold global keyboard events, including a trigger attempt. Scribe cannot report an attempt it never receives. In that case the existing availability text in the menu and both settings tabs explains the block. Scribe neither disables Secure Input nor bypasses keyboard monitoring restrictions.
- Secure AX roles/subroles still reject insertion. Unverified paste into an inaccessible composer still requires Secure Input to be off and the destination application to remain the same. Generated answers may fall back to copy-only; they are not posted into the secure destination.

## Automated validation

`swift test --package-path Modules/Dictation` covers idle and repeated transitions, both intents and hold/double-tap capture cancellation with fake audio, blocked attempts without microphone/model access, duplicate-event publication and debug-history persistence, clearing and a later block, post-release transcription cancellation, monitor stop/reset, secure roles/subroles, and rejection of unsafe unverified paste. Existing trigger, insertion, audio, engine, and source-collection tests run with these checks. The real audio capture remains the production default; fake capture and Secure Input providers are internal test seams.

Final results: **77 Dictation tests passed, zero failures**; the unsigned Debug Scribe scheme build passed; `git diff --check` passed. The build emitted the existing AppIntents metadata-extraction warning (no AppIntents framework dependency). The app build checks the new state across the actual app and indicator. This is local verification, not an installed or published release.

## Live checks not exercised automatically

Synthetic tests do not establish which physical modifier callbacks macOS delivers under Secure Input on this host. They also do not exercise actual microphone capture, lock/unlock, password-field transitions, or visual indicator positioning. On an unlocked Mac with Scribe's normal permissions, use disposable text to verify:

1. Enter and leave a real secure field while idle: no dictation indicator error; availability clears after the owning app releases Secure Input.
2. While protected input is active, try each assigned trigger. If macOS delivers a modifier callback, one readable notice appears; repeats do not flicker or restart it. With indicator position Off, that notice appears at the screen bottom. If no callback arrives, check the passive menu/settings availability instead.
3. Enter protected input during hold and double-tap capture in each mode, and during an in-flight assistant request: work stops and no result is inserted. After the block ends, a fresh trigger starts normally.
4. Confirm the notice disappears when protection ends and that secure fields receive no AX write or posted paste. Do not weaken or disable Secure Input to make Scribe capture a blocked event.

The checks above remain manual verification limits; no physical end-to-end pass is claimed.
