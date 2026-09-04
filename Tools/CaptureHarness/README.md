# CaptureHarness

A standalone Swift package, independent of `Scribe.xcodeproj`, that answers the milestone-1
capture questions in [IMPLEMENTATION_PLAN.md](../../IMPLEMENTATION_PLAN.md) sections 1, 3 and 7:
can one ScreenCaptureKit `SCStream` deliver system audio and microphone audio together, with no
screen consumer, at an acceptable CPU cost, and how do the two timestamp domains relate?

```sh
cd Tools/CaptureHarness
./Scripts/build-signed.sh              # release build + embedded Info.plist + ad-hoc sign + .app bundle
BIN=./bin/CaptureHarness.app/Contents/MacOS/capture-harness
"$BIN" permissions --request           # then grant Screen Recording in System Settings
"$BIN" devices                         # bundle identifiers and microphone uids
"$BIN" record --bundle-id us.zoom.xos --duration 300
"$BIN" inspect "captures/<session>/timeline.jsonl"
```

## Subcommands

| Command | Purpose |
| --- | --- |
| `record` | Runs the capture. Writes `timeline.jsonl`, `events.jsonl`, `session.json`, and per-track CAF segments. |
| `inspect` | Reads a `timeline.jsonl` and reports PTS origins, clock evidence, drift, gaps, overlaps, and format changes. |
| `probe-filter` | Enumerates each application family's processes, reports which a content filter can name, and captures the same moment through a main-only and a main-plus-helpers filter. |
| `probe-interruptions` | Records while watching output/input route changes, device-list changes, screen lock, sleep/wake and selected-application exit, then reports what the stream did at each event. |
| `fixture` | Records one labelled real system/microphone pair into `Tests/Fixtures/real/<id>/` with a sidecar describing devices, formats and timing. |
| `devices` | Lists displays, running applications with bundle identifiers, and microphone unique IDs. |
| `permissions` | Reports and optionally requests Screen & System Audio Recording and Microphone access. |

## What `record` configures

- One `SCStream`. `.audio` and `.microphone` outputs are registered on **separate** sample-handler
  queues so the journal shows each track's real callback thread.
- `capturesAudio = true`, `sampleRate = 48000`, `channelCount = 2`, `excludesCurrentProcessAudio = true`,
  `captureMicrophone = true`, and `microphoneCaptureDeviceID` when `--microphone-uid` is given.
  The microphone arrives in the device's **native** format regardless of these system-audio settings.
- **No screen frames are ever saved.** With `--screen-consumer none` (the default) no `.screen`
  output is registered at all. If no audio buffer arrives within `--start-timeout` seconds, the
  harness stops, restarts with the smallest low-frame-rate screen configuration (2x2, 1 fps) whose
  frames are counted and discarded, and says so in the report. `--no-screen-fallback` disables that
  retry so the audio-only question can be answered without a second attempt.
- `--bundle-id` resolves the identifier to every currently running `SCRunningApplication` process at
  start, as the plan requires. If nothing matches it fails; it never silently broadens to all audio.
  `--all-system-audio` is the explicit alternative.

`record` exits non-zero if the stream stopped with an error.

## Session directory

```text
captures/2026-09-03 15-30-12/
  timeline.jsonl      one JSON object per delivered audio buffer (the inspector reads this)
  events.jsonl        stream start/stop, retries, segment rotations, resource samples, errors
  session.json        run manifest: stop reason, screen-consumer verdict, per-track totals, CPU
  system-0001.caf     native system-audio PCM
  microphone-0001.caf native microphone PCM
```

Segments rotate on a format change, and additionally on `--segment-seconds` when given. Rotation is
journalled to `events.jsonl` with the reason and both formats.

CAF cannot store non-interleaved linear PCM, so a stream delivered as non-interleaved float32 is
archived as interleaved float32 at the same rate and channel count. The sample values are unchanged;
only the channel layout on disk differs. Each segment event records the delivered format and the
on-disk `fileFormat` so nothing has to be inferred later.

## Device-matrix probes

```sh
"$BIN" probe-filter --enumerate-only                    # works without the screen-recording grant
"$BIN" probe-filter --targets chrome,teams --seconds 20 # needs the grant, and the app making sound
"$BIN" probe-interruptions --bundle-id us.zoom.xos --duration 900
```

`probe-filter` merges three views of the process table — `SCShareableContent`, `NSWorkspace`, and the
BSD process list — because they disagree in exactly the interesting case: a helper that renders audio
but that no content filter can name. It then captures through `main-only` and `main-plus-helpers`
filters and compares them, so "selecting Chrome captures a Meet tab" becomes a measurement rather
than a guess.

Some helper bundle identifiers are shared system-wide. `com.apple.WebKit.GPU` and
`com.apple.SafariPlatformSupport.Helper` run on behalf of every WebKit host on the machine, not just
Safari, so the catalog attributes them to a family only when macOS named the process after that
application, and the probe prints the caveat. Naming such an identifier in a filter would capture
other applications' media.

`probe-interruptions` prints the scenario script the operator has to perform, journals each system
event on the host clock, and afterwards reports per track whether the stream continued, continued
after a presentation-timestamp gap of N seconds, changed format, or stopped. The host clock is used
only to locate an event in the stream; the audio timeline still comes from presentation timestamps.

## Real fixtures

```sh
"$BIN" fixture --scenario double-talk --id usb-double-talk \
  --devices "MacBook Pro built-in speakers, Shure MV7 USB" \
  --all-system-audio --seconds 15
```

`--devices` is required: a recording whose hardware is unknown cannot be interpreted later. The
committed pair is 16-bit WAV; the float32 CAF originals and the full journal stay in the capture
directory that `fixture.json` names. See [Tests/Fixtures/real/README.md](../../Tests/Fixtures/real/README.md).

## Buffer journal contract

One JSON object per line in `timeline.jsonl`:

```json
{"record":"buffer","outputType":"audio","sequence":1,
 "presentationTimestamp":{"value":123456,"timescale":48000},
 "presentationTimestampSeconds":2.5719,"frameCount":480,"sampleRate":48000,
 "clockDomain":"SCStream.presentationTimeStamp",
 "formatDescription":{"mSampleRate":48000,"mFormatID":1819304813,"mFormatIDString":"lpcm",
   "mFormatFlags":41,"mFormatFlagNames":["Float","Packed","NonInterleaved"],
   "mBytesPerPacket":4,"mFramesPerPacket":1,"mBytesPerFrame":4,
   "mChannelsPerFrame":2,"mBitsPerChannel":32},
 "peak":0.42,"rms":0.11,
 "file":"system-0001.caf","fileFrameOffset":480,
 "callbackThread":"queue=... tid=... main=false qos=33","callbackHostSeconds":123456.789}
```

`peak` and `rms` are the buffer's linear amplitude. They are diagnostics: silence is valid input and
a silent meeting must never be mistaken for a capture failure, but a filter that delivers
silence-filled buffers is a different result from one that delivers no buffers, and only the level
distinguishes them.

`presentationTimestamp` is the `CMSampleBuffer` presentation timestamp serialised losslessly as
value and timescale. `callbackHostSeconds` and `callbackThread` are **diagnostics only** and must
never be used as a timing source. `formatDescription` carries only format fields, so a per-buffer
value cannot masquerade as a format change. `clockDomain` is written because a `CMTime` on its own
records a number and a timescale, not an auditable `CMClock` identity; the inspector treats a
missing declaration as unproven rather than assuming the two tracks share a clock.

Non-buffer records go to `events.jsonl` so `timeline.jsonl` stays free of lines the inspector would
count as ignored.

## Permissions

**Use `bin/CaptureHarness.app/Contents/MacOS/capture-harness`, not `bin/capture-harness`.** A bare
executable cannot be granted Screen & System Audio Recording at all: the request presents no dialog,
the System Settings **+** picker accepts only application bundles, and `tccutil` cannot address a
client with no LaunchServices bundle identifier. `Scripts/build-signed.sh` emits both; the bundle
carries the same executable, signature and identifier, and is what the grant attaches to. It is also
closer to the shipping app, so permission behaviour measured through it is representative.

See [docs/feasibility/capture-permissions.md](../../docs/feasibility/capture-permissions.md) for the
steps a person must perform, and the code-signing behaviour that makes them necessary after every
rebuild.

## Tests

```sh
swift test
```

The suite covers the inspector's drift/gap/overlap/format detection, the recorder-to-inspector
journal round trip (including a real CAF write and a microphone track at its own native rate),
format-change segment rotation, argument parsing, the full format-description record, the
audio-only verdict wording, level measurement and digital-silence detection, application-family
helper attribution, the filter variants the probe compares, interruption correlation
(continued / gap / stopped / format changed) with markers round-tripped through the journal, and
the fixture export's segment concatenation and native-rate preservation. It does not and cannot cover the parts that need TCC-granted hardware
capture; those results come from real runs and are recorded in
[docs/feasibility/capture-timing.md](../../docs/feasibility/capture-timing.md), which now holds a
measured application-filter matrix, a measured interruption matrix, and the MVP interruption policy
derived from them.
