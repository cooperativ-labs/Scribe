# Dictation audio callback crash (2026-09-26)

## Report and cause

The installed `0.2609251649.0` binary UUID matches the supplied crash report:
`D40E48A0-83BD-3E3E-97F2-3A25BF3E3463`. Pressing right Command starts the
microphone engine, whose audio callback triggers `EXC_BREAKPOINT / SIGTRAP`
on `RealtimeMessenger.mServiceQueue`. The stack enters Swift's executor
isolation check and `_dispatch_assert_queue_fail` from an AVFAudio tap.

`DictationAudioCapture` is `@MainActor`. Creating the audio tap and its nested
converter input callback inside that isolation scope lets legacy callbacks
inherit a main-actor requirement, despite AVFAudio invoking them on its audio
queue. Callback creation now lives in a `nonisolated` factory. Each tap owns
its converter, and sample storage and level reads still use the locked ring.

## Regression verification

`DictationAudioCaptureTests.testAudioTapConvertsOnBackgroundQueue` creates the
production callback from MainActor and invokes it repeatedly on a separate
serial queue with synthetic 48 kHz stereo PCM. It checks that converted 16 kHz
mono samples and the RMS level reach the ring.

- With the factory still main-actor isolated, the test process exited with
  signal 5. Its crash report shows the same Swift executor/dispatch assertion
  chain, reached through the nested converter input callback.
- After marking the factory `nonisolated`, all 15 Dictation package tests pass.
- The full arm64 Release app build passes with `CODE_SIGNING_ALLOWED=NO`
  (`build/dictation-validation`). This is a compilation check, not a signed
  distribution build; the installed application has not been replaced.

The regression requires no microphone access. Physical right-Command capture,
transcription, and insertion still need a live check with an updated installed
app; this test does not claim end-to-end dictation validation.
