# ScreenCaptureKit capture harness — configuration and run report

The harness is `Tools/CaptureHarness`, a standalone Swift package that does not depend on
`Scribe.xcodeproj`. Build and permission steps are in
[capture-permissions.md](capture-permissions.md); the journal contract and CLI reference are in
[the package README](../../Tools/CaptureHarness/README.md). Timing analysis of the journals it
produces lives in [capture-timing.md](capture-timing.md).

## What the stream is configured to do

One `SCStream`, built from an application content filter chosen by bundle identifier, with an
explicit all-system-audio alternative:

| Setting | Value | Why |
| --- | --- | --- |
| `capturesAudio` | `true` | System audio is the far-end reference track. |
| `sampleRate` | `48000` (`--sample-rate`) | Plan section 3: 48 kHz system capture. |
| `channelCount` | `2` (`--channels`) | Stereo system capture. |
| `excludesCurrentProcessAudio` | `true` | Keeps the harness's own output out of the reference. |
| `captureMicrophone` | `true` | The `.microphone` output on the same stream. |
| `microphoneCaptureDeviceID` | `--microphone-uid`, else the system default input | Device selection for the device matrix. |
| `.screen` output | **not registered** by default | Screen frames are never saved. |

The application filter is resolved at start: `--bundle-id` is matched against the live
`SCRunningApplication` list, and the run fails with a source error if nothing matches. It never
falls back to all-system audio, which the plan calls out explicitly. Every matched process is
included, which is what makes browser helper processes worth checking separately.

The microphone's format is **not** governed by `sampleRate`/`channelCount`. The harness records the
full `AudioStreamBasicDescription` of every buffer on both tracks precisely because the microphone
is expected to arrive in the device's native format.

## Answering the audio-only question

`--screen-consumer none` (the default) registers no `.screen` output at all. If no audio buffer has
arrived after `--start-timeout` seconds, the harness stops the stream, restarts it with the smallest
low-frame-rate screen configuration (2x2, 1 fps) whose frames are counted and immediately discarded,
and journals the retry. `--no-screen-fallback` suppresses the retry when the point is to establish
what happens without any screen consumer at all.

`session.json` and the console summary therefore carry one of four explicit verdicts rather than an
inference:

- audio arrived with no `.screen` output registered — audio-only operation works;
- no audio arrived without a screen consumer — rerun with `--screen-consumer minimal` to separate a
  configuration requirement from a permission or source problem;
- audio arrived but a minimal screen output was registered — audio-only is *not* proven by that run;
- no audio arrived even with a minimal screen consumer — not an audio-only result at all.

## Resource accounting

While recording, the harness samples `proc_pid_rusage` every `--cpu-sample-seconds` (default 5) for
itself and, when readable, for the system capture daemon named by `--watch-process` (default
`replayd`). Each sample goes to `events.jsonl`; `session.json` and the console summary report average
percent of one core over the run, peak instantaneous percent, and peak physical footprint.

The harness process figure is not the whole cost of ScreenCaptureKit capture: the system does part of
the work in its own daemon. That is why the daemon is sampled alongside, and why any number quoted
below states which process it belongs to. The plan's capture budget (under 10% of one core, under
200 MB) is a milestone-5 gate measured against the real app, not against this harness.

## Callback discipline

`.audio` and `.microphone` are registered on separate sample-handler queues. A callback copies the
sample buffer's audio into a freshly allocated `AVAudioPCMBuffer`, releases the retained block
buffer before returning, and enqueues the copy on one serial writer queue. No disk write, no
encoding and no analysis happens on a sample-handler thread, and no no-copy pointer outlives its
backing sample buffer. Every buffer record carries the queue label, thread id, main-thread flag and
QoS class of the callback that delivered it.

## Run report

Target from IMPLEMENTATION_PLAN.md section 7, milestone 1: a real system/microphone pair from a
meeting application, at least five minutes, on macOS 15.

| Item | Result |
| --- | --- |
| Recorded run | **pending — see below** |
| OS the harness was exercised on | macOS 27.0, build 26A5425a, Apple Silicon. **Not** macOS 15; the package's deployment target is macOS 15 but the minimum-OS exit criterion is unverified. |
| Stream ran without a screen consumer | **pending measurement** |
| Minimal low-frame-rate screen configuration required | **pending measurement** |
| CPU, harness process | **pending measurement** |
| CPU, capture daemon | **pending measurement** |
| Microphone native format and buffer frames | **pending measurement** |
| System audio delivered format | **pending measurement** |

### What is verified today

- The package builds clean in debug and release with no warnings, and `swift test` passes six tests,
  including a recorder-to-inspector round trip that writes real CAF segments and a journal the
  inspector parses with zero ignored lines.
- Ad-hoc signing works: `Signature=adhoc`, `Identifier=io.cooperativ.scribe.captureharness`, an
  embedded `Info.plist` carrying `NSMicrophoneUsageDescription`, and the
  `com.apple.security.device.audio-input` entitlement.
- Microphone permission was granted to the signed binary and reads back as `authorized`.
- Microphone and display enumeration works; `capture-harness devices` lists bundle identifiers and
  microphone unique IDs.

### What blocks the run

Screen & System Audio Recording has not been granted to the binary on this machine.
`CGPreflightScreenCaptureAccess()` and `CGRequestScreenCaptureAccess()` both return `false`, and
`SCShareableContent` fails with `The user declined TCCs for application, window, display capture`.
This is a human step; the procedure is in [capture-permissions.md](capture-permissions.md).

Once granted, the five-minute exit-criteria run is:

```sh
cd Tools/CaptureHarness
BIN="$(swift build -c release --show-bin-path)/capture-harness"
"$BIN" devices                                   # confirm the meeting app's bundle identifier
"$BIN" record --bundle-id us.zoom.xos --duration 300 --output "$HOME/harness-5min"
"$BIN" inspect "$HOME/harness-5min/timeline.jsonl"
```

with a meeting joined in that application so both far-end audio and the microphone are live. Then
replace every **pending measurement** above with the values from `session.json`, and state plainly
whether the audio-only configuration held.
