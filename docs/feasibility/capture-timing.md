# ScreenCaptureKit capture timing feasibility

Status: measured on 2026-09-03 across ten real `SCStream` runs. The capture harness
(`capture-harness record`), the device-matrix probes (`capture-harness probe-filter`,
`capture-harness probe-interruptions`) and the real-fixture recorder (`capture-harness fixture`) all
exist and have been run against live audio. Results below are stated as **measured** where a real
capture produced them and **pending measurement** where no capture has been run; nothing is inferred
and presented as fact.

**Machine and scope of validity.** Apple Silicon Mac, macOS 27.0 (build 26A5425a), built-in speakers
and built-in microphone, system volume 63. The plan targets macOS 15 or later. Everything here is
*above* that floor, so **no result on this page is evidence about macOS 15 behaviour**; the screen-lock
and sleep rows in particular must be repeated on the baseline before they can be relied on.

## Recommended timeline mapping rule

Use every buffer's `CMSampleBuffer` presentation timestamp, not callback arrival time. Serialize it losslessly as `CMTime.value` and `CMTime.timescale`, retain each track's first PTS relative to one session origin, and map to the 48 kHz processing timeline with rational arithmetic. For a sample block, expected duration is `frameCount / nativeSampleRate`.

Do not concatenate across a positive timestamp gap: insert the matching silence on the processing copy and journal it. Retain overlaps for explicit resolution instead of silently trimming. Preserve native CAF originals unchanged. Compare timestamp span with delivered sample duration over the full run; only when that measured difference warrants it should the processing copy be gradually resampled. Compensate resampler latency explicitly.

A `CMTime` contains a number and time scale, not a serialised `CMClock` identity. The harness must write `clockDomain: "SCStream.presentationTimeStamp"` for both `.audio` and `.microphone` records if they were obtained from the single `SCStream` presentation timeline. The inspector reports missing or conflicting declarations as unproven / requiring conversion; it must not infer clock equality from callback order.

## Producing a journal

`Tools/CaptureHarness` records the journal and then reads it back:

```sh
cd Tools/CaptureHarness
./Scripts/build-signed.sh
BIN="$PWD/bin/CaptureHarness.app/Contents/MacOS/capture-harness"   # bundled build; a bare executable cannot hold the grant
"$BIN" record --bundle-id <meeting-app-bundle-id> --duration 1800 --output "$HOME/capture-30min-builtin"
"$BIN" inspect "$HOME/capture-30min-builtin/timeline.jsonl"
"$BIN" inspect "$HOME/capture-30min-builtin/timeline.jsonl" --json > timing-report.json
```

The recorder writes `clockDomain: "SCStream.presentationTimeStamp"` on both tracks, so the inspector
reports a common timeline rather than an unproven one. Permission steps are in
[capture-permissions.md](capture-permissions.md).

## Inspector

It reports each track's initial and final PTS, frames, timestamp-versus-sample-duration drift in seconds and ppm, gaps, overlaps, full-format changes, ignored journal lines, and the evidential status of clock alignment. A discontinuity greater than one sample is reported. Its JSONL contract is in [the harness README](../../Tools/CaptureHarness/README.md).

## Producing the device matrix

```sh
cd Tools/CaptureHarness
BIN=./bin/CaptureHarness.app/Contents/MacOS/capture-harness

# Which processes exist, and which of them a content filter can name.
"$BIN" probe-filter --targets zoom,safari,chrome,teams --enumerate-only

# Then, with the application in a call and making sound, compare filters.
"$BIN" probe-filter --targets chrome --seconds 20

# Interruptions, with the operator performing each scenario the tool prints.
"$BIN" probe-interruptions --bundle-id us.zoom.xos --duration 900
```

`probe-filter --enumerate-only` works without the screen-recording grant, because NSWorkspace and the
process table do; it then reports ScreenCaptureKit visibility as *unknown* rather than false. The
capturing modes fail loudly without the grant instead of producing a filter result that means nothing.

## Measurement matrix

| Scenario | System format | Microphone format / buffer frames | Drift (`audio` / `microphone`) | Gaps / overlaps / format changes | Result |
| --- | --- | --- | --- | --- | --- |
| Built-in speakers + built-in microphone, 40 s | lpcm 48 kHz, 2 ch, float32, **non-interleaved**, 960 frames/buffer (20 ms) | lpcm 48 kHz, **1 ch**, float32, **interleaved**, mono layout tag, **512 frames/buffer** (10.67 ms) | −0.000 ppm / +0.000 ppm | 0 / 0 / 0 | **Measured.** 2015 `.audio` and 3750 `.microphone` buffers |
| Built-in speakers + built-in microphone, 15 s × 3 (the committed fixtures) | as above | as above | −0.000 ppm / −0.000 ppm | 0 / 0 / 0 | **Measured.** See `Tests/Fixtures/real/*/fixture.json` |
| Built-in speakers + built-in microphone, ≥30 min | | | | | **Pending measurement.** Longest run so far is 90 s; the two-hour reliability gate and long-run drift are untested |
| USB or Bluetooth microphone, any duration | | | | | **Pending measurement.** No USB or Bluetooth microphone was available on the machine |

The microphone format is the headline: the stream was configured for **48 kHz stereo**, and the
microphone still arrived as **48 kHz mono, interleaved**, with a different buffer size from the system
track. This confirms the SDK's documented behaviour that microphone buffers use the device's native
format independently of the system-audio configuration. It also means these measurements did **not**
exercise sample-rate conversion, because this particular microphone happens to run at 48 kHz; a
44.1 kHz or 16 kHz device would, and remains untested.

### Track start offset — measured, and larger than expected

Across all ten runs the `.microphone` track's first presentation timestamp was **always later** than
the `.audio` track's, never equal and never earlier:

| Run | `.audio` first PTS (s) | `.microphone` first PTS (s) | Offset |
| --- | --- | --- | --- |
| 40 s all-system-audio | 207492.667875 | 207492.998875 | +0.331000 |
| Finder control | 207637.576748 | 207640.170292 | **+2.593544** |
| Zoom exit/relaunch probe | 207783.316894 | 207783.463729 | +0.146836 |
| Safari exit/relaunch probe | 207864.713835 | 207864.836521 | +0.122686 |
| Output-route probe | 207992.692663 | 207992.829104 | +0.136441 |
| Input-route probe (loopback) | 208197.638813 | 208197.834583 | +0.195770 |
| Input-route probe (real devices) | 208272.215541 | 208272.340938 | +0.125396 |
| Fixture: far-end-only | 208100.919895 | 208101.047354 | +0.127459 |
| Fixture: near-end-only | 208493.255465 | 208493.381125 | +0.125660 |
| Fixture: double-talk | 208547.482293 | 208547.613396 | +0.131103 |

Range **+0.123 s to +2.594 s**, a spread of 2.47 s. The consequence for the timeline builder is
direct: **there is always a leading interval containing system audio and no microphone audio, its
length varies per run by more than two seconds, and it cannot be predicted or assumed.** Use each
track's own first PTS against one session origin and represent that interval as leading silence on
the microphone track. Never align the two tracks by their first sample, and never subtract a
constant.

Both tracks' timestamps are on the same numeric scale (roughly 207 500 s here, tracking system
uptime), consistent with one host-time-based `SCStream` presentation clock, and the harness declares
`clockDomain: "SCStream.presentationTimeStamp"` on both. The inspector therefore reports a common
timeline. **No conversion between clock domains was needed.**

### Resource use — measured

| Metric | Measured | Plan budget (section 8) |
| --- | --- | --- |
| Harness CPU, average | **0.09 % of one core** | below 10 % of one core |
| Harness CPU, peak | 5.18 % of one core (at stream start) | — |
| Harness memory, peak footprint | **15.2 MB** | below 200 MB |
| `replayd` (the capture daemon) CPU | 0.13–0.14 % of one core | — |

Comfortably inside budget, in a release build, with no screen output registered. Note this is the
harness, not the shipping app, and it does no encoding or processing.

### Audio-only operation — measured, and it works

`.audio` and `.microphone` both delivered continuously with **no `.screen` output registered at all**,
on every one of the ten runs. The automatic minimal-screen retry never had to fire.
**Audio-only operation does not require a screen consumer on this configuration**, which answers the
milestone-1 question directly and removes the low-frame-rate-screen fallback from the MVP design.

### Callback threading — measured

`.audio` and `.microphone` were registered on separate serial dispatch queues and were delivered on
those queues, never on the main thread, at QoS class 25 (`QOS_CLASS_USER_INITIATED`) — the QoS the
harness requested. Each queue was serviced by several worker threads over a run (five to six distinct
thread ids per queue in a 40–55 s capture), which is ordinary dispatch behaviour and not a
concurrency hazard for a serial queue. The sample handlers copy buffer data out of the
`CMSampleBuffer` and enqueue; all file and journal work happens on one separate writer queue.

## Application-filter matrix — measured

Each capture ran with the application producing real audio and no other application making sound.

| Application | Filterable identifier | SCK-visible helpers | Non-filterable processes | Audio via main-only filter | Verdict |
| --- | --- | --- | --- | --- | --- |
| Google Chrome | `com.google.Chrome` | none | 9 (`Google Chrome Helper`, `… (Renderer)` ×4, crashpad) | **yes, peak −8.6 dBFS** | **Measured.** Tab audio captured naming only the main identifier |
| Safari | `com.apple.Safari` | none | 7 (`Safari Graphics and Media` = `com.apple.WebKit.GPU`, `Safari Web Content` ×2, `Safari Networking`, SandboxBroker, 2 extensions) | **yes, peak −8.6 dBFS** | **Measured.** Confirmed with Chrome fully quit |
| Zoom | `us.zoom.xos` | none | 8 (`ZoomCefHelper` ×5 incl. GPU and Renderer, `us.zoom.CptHost`, `us.zoom.aomhost`, `us.zoom.caphost`) | **yes, peak −2.9 dBFS** | **Measured** with Zoom's speaker-test tone in a live test meeting |
| Microsoft Teams | — | — | — | — | **Untestable here.** Teams is not installed on the machine; only its `MSLoopbackDriverDevice` audio driver remains. Teams in a browser is covered by the Chrome and Safari rows |

Zoom is the useful third data point: it is a native application that *embeds* Chromium
(`ZoomCefHelper`), so it exercises both models at once, and its own `us.zoom.*` helpers have real
bundle identifiers yet still never appear to ScreenCaptureKit. Its audio came from Zoom's
speaker-test tone inside a live test meeting.

Audio source for the browser rows was a looping `<audio>` element playing the deterministic
`Tests/Fixtures/Generated/far-end-only/playback.wav`, not a live WebRTC session. For the question
*"does a filter naming the browser receive its tab audio"* that is equivalent, because the audio takes
the same process path. It is **not** equivalent for anything specific to WebRTC's audio stack, which
remains untested.

### The helper-process question is answered: helpers never need naming

This was the main risk the plan flagged, and it is a non-issue.

**Chrome.** Nine helper processes were running, including the renderers that produce audio. Every one
of them has **no bundle identifier at all** and none appears in `SCShareableContent.applications`.
Only `com.google.Chrome` (the browser process) is nameable in a content filter. A filter naming only
that identifier nonetheless captured the tab audio.

**Safari.** Structurally different and it still does not matter. WebKit's helpers are XPC services with
**parent process 1 (launchd)** — they are not children of Safari, unlike Chrome's — and they are
visible to `NSWorkspace` but *not* to `SCShareableContent`. A filter naming only `com.apple.Safari`
captured the audio being produced by `com.apple.WebKit.GPU`.

So **ScreenCaptureKit attributes helper-process audio to the owning application** under both the
Chromium child-process model and the WebKit launchd-XPC model. The UI can honestly describe selecting
a browser as recording that browser's audio. It still cannot promise isolation of a single tab —
that limitation is unchanged, and is a property of application-level filtering, not of helpers.

### The filter really is selective — control measurement

A filter naming `com.apple.finder` (an application producing no audio), run while Chrome was audibly
playing, delivered **627 buffers containing 1 203 840 samples that were every one exactly zero**,
while the `.microphone` track on the same stream carried real room audio at −25.4 dBFS. This rules
out the alternative explanation that the browser results were system-wide audio leaking through.

It also establishes the behaviour the rest of this document depends on: **a filter matching a silent
application delivers a continuous stream of silence-filled buffers, not an absence of buffers.**
Buffer delivery therefore says nothing about whether the intended source is being captured.

### Shared helper identifiers are not per-application

Measured by enumeration. `com.apple.WebKit.GPU`, `com.apple.WebKit.WebContent`,
`com.apple.WebKit.Networking` and `com.apple.SafariPlatformSupport.Helper` are shared process classes.
On this machine they were running on behalf of Mail, Raycast, Google Drive, MacWhisper, Spotify,
Notion, Bear, Arc, Cursor and iTerm2 — 30+ processes across those identifiers, at a moment when Safari
was not running at all. macOS names each instance after its host (`Mail Graphics and Media`,
`Safari Web Content`).

Since the measurements above show helpers never need naming, this is now a **guard rail rather than a
problem**: nothing should ever add a `com.apple.WebKit.*` identifier to a content filter, because
doing so would capture other applications' media. `ApplicationCatalog` attributes a shared helper to a
family only when macOS named the process after that application, and `probe-filter` prints the caveat.

### Resolving the application to its current process — measured, and it matters

`SCContentFilter` is built from `SCRunningApplication` values taken from one `SCShareableContent`
snapshot. The exit/relaunch measurement below proves the consequence directly: a filter built at start
does **not** pick up a relaunched process, and gives no indication that it has stopped capturing
anything. Resolving at start, and failing loudly when the application is not running, is therefore
required — as is watching for its exit.

## Interruption matrix — measured

| Scenario | `.audio` | `.microphone` | Stream delegate | PTS discontinuity | Format change |
| --- | --- | --- | --- | --- | --- |
| Output route changed (speakers → LG display → back) | continued | continued | no error, no stop | **none** | **none** — stayed 48 kHz stereo even when routed to a 1-channel device |
| Output route changed, content effect | **≈1 s of exact digital silence on one of three switches** | unaffected | — | none | — |
| Default input device changed (two real devices) | continued | **continued unchanged** — same level, format and 512-frame buffers | no error, no stop | none | none |
| Default input changed to a virtual loopback driver | continued | continued unchanged | no error, no stop | none | none |
| Selected application quits (audio was flowing) | **exact digital silence from that instant onward, forever** | continued normally | **no error, no stop** | **none** | none |
| Selected application relaunches (new pid) | **still exact digital silence — never recovers** | continued normally | no error, no stop | none | none |
| Screen locked | **continued at full level** | continued | no error, no stop | none | none |
| Screen unlocked | continued | continued | no error, no stop | none | none |
| **System sleep** | **stream stopped with an error** | **stopped** | **`Failed to find any displays or windows to capture`** | — | — |
| Wake from sleep | stream is already gone | — | — | — | — |
| Microphone physically disconnected | | | | | **Pending measurement.** No USB microphone available |

### The most important result: application exit is silent in every sense

With Safari's audio flowing at a steady −8.7 dBFS, Safari was quit 18 s into a 55 s capture and
relaunched at 39 s. Per-second peak level of the `.audio` track:

```text
 0–17 s   −8.6 … −9.0 dBFS   (Safari playing)
18–55 s   exact digital silence, every sample zero — including after the relaunch
```

The stream did not error. It did not stop. It reported no timestamp discontinuity and no format
change. It simply delivered silence for the remaining 37 seconds, and the relaunched Safari under a
new pid was never picked up.

**A capture whose source has died is byte-for-byte indistinguishable from a silent meeting.** This is
the exact trap section 3 warns about, in its most dangerous form: the plan says not to mistake silence
for failure, and the corollary measured here is that you equally cannot use silence to *detect*
failure. Neither buffer delivery, nor timestamps, nor levels can tell these apart. Only process
liveness can. Watching `NSWorkspace.didTerminateApplicationNotification` for the selected application
is therefore **required for correctness**, not a nicety, and it is the only signal available.

### Output-route changes are safe for the timeline, but not for the content

Three programmatic default-output changes were made mid-capture. In every case the stream continued
and the system-audio format stayed 48 kHz stereo float32 — ScreenCaptureKit taps the application's
audio upstream of the device mix, so even routing to a 1-channel device changed nothing about the
delivered format. No timestamp gap appeared at any of them.

One of the three, however, produced **about one second in which every delivered sample was exactly
zero**, with no timestamp discontinuity. So a route change can punch a real hole in the audio content
while leaving the timeline perfectly continuous. The timeline builder will not see it; the AEC will.
Journal route changes and mark them as reconvergence points, and do not assume continuity of
timestamps implies continuity of content.

### Screen lock: capture continues — but check what you are measuring

The first screen-lock run appeared to show system audio dying at the lock: `.audio` went to exact
digital silence from the lock onward while `.microphone` continued normally. That reading was wrong.

The source in that run was Safari playing an `<audio>` element, and **Safari pauses its own media when
the screen locks**. Repeating the measurement with `afplay` as the source — a process with no UI to
suspend — showed system audio continuing at full level straight through the lock, with no silence at
all, no timestamp discontinuity, and no stream error. The lock and unlock notifications both fired and
both tracks continued.

**ScreenCaptureKit capture is unaffected by screen lock.** What changes is what the captured
applications choose to do. A meeting application in a live call will not pause itself, but this is
worth remembering: an apparent capture failure can be the source application's behaviour rather than
the capture's.

This also means the earlier control was essential. Without it the recommended policy would have been
written around a behaviour that does not exist.

### Sleep: the stream dies, but with warning first

Measured deterministically by issuing `pmset sleepnow` 15 s into a capture:

```text
15.1 s  NSWorkspaceWillSleepNotification
15.1 s  stream error: "Failed to find any displays or windows to capture"
        stop reason: streamError
```

On sleep the displays go away, and because **a content filter always requires a display — even for
audio-only capture** — the filter's display disappears and ScreenCaptureKit tears the stream down.
Sleep is an unrecoverable stream error, not a pause, and the stream does not survive to wake.

The useful detail is the ordering: `NSWorkspace.willSleepNotification` arrives *before* the error.
The app can therefore finalise cleanly on that notification rather than discovering the failure
afterwards as an error of unknown cause. That ordering is what makes a clean stop-and-finalise
possible.

### Two caveats that limit the interruption results

- **Detection is not reliable.** Only two of three output-route changes posted a Core Audio
  default-device notification, and changes involving the `Microsoft Teams Audio` **virtual loopback
  driver** posted none at all — neither for output nor input. Switching between two real devices
  always notified. Route-change detection must not depend solely on
  `kAudioHardwarePropertyDefaultOutputDevice` / `…DefaultInputDevice` notifications, and virtual
  audio drivers are the case that breaks it.
- **The microphone binds at start.** Changing the system default input device mid-capture did not
  change the `.microphone` track: identical level envelope, identical mono 48 kHz format, identical
  512-frame buffers throughout. Strong evidence that `.microphone` resolves its device once at stream
  start and does not follow the system default. Not conclusive, because the substitute device was a
  Continuity iPhone microphone in the same room whose audio may not have been active; the definitive
  test is unplugging a USB microphone, which is **pending measurement**. Either way, the user-visible
  risk is real: a person changing microphone mid-meeting may keep recording the old device with no
  indication.

## Recommended MVP interruption policy

Every row is now backed by a measurement on macOS 27.0, except the two marked otherwise. Where a
measurement changed the recommendation from what the plan's reasoning alone would suggest, that is
called out.

| Event | Policy | Measured basis |
| --- | --- | --- |
| Output-route change | **Continue.** Journal the event with the new device and mark an AEC reconvergence point. Also journal it as a possible short content gap. | Stream continued, format unchanged even to a 1-channel device, no timestamp discontinuity. But one of three switches produced ~1 s of exact digital silence, so the audio content can have a hole the timeline does not show. |
| Input-device change | **Continue, and warn the user.** Journal it. Do not expect the recording to follow the new device. | `.microphone` kept the original device's level, format and 512-frame buffers across a default-input change. The recording silently keeps the old device, which is a user-visible correctness problem worth surfacing in the UI. |
| Microphone format change | Continue, rotate to a new segment, journal both formats. | Not observed — this microphone never changed format. The recorder's rotation path is exercised only by tests. **Pending measurement** with a device that changes rate. |
| Microphone disconnected | **Stop and finalise** as a clearly marked partial recording. | **Pending measurement** — no USB microphone was available. Policy follows section 8 and the input-change result, which showed the stream will *not* fail loudly on its own. |
| Selected application exits | **Stop and finalise**, driven by `NSWorkspace.didTerminateApplicationNotification`. | **Required, not preferred.** The stream does not error, does not stop, reports no discontinuity, and delivers exact digital silence indefinitely. Process liveness is the only available signal. |
| Selected application relaunches | Do not auto-resume. A new recording is a new session. | The existing filter never picked up the relaunched process; audio never returned. Reconnection would require rebuilding the filter, which is deferred until the reliability gates pass. |
| Screen lock / unlock | **Continue.** Journal both. | Capture is unaffected: both tracks continued at full level with no discontinuity through lock and unlock. The plan's requirement to measure this per-OS still stands — this is macOS 27, not the macOS 15 baseline. |
| Sleep | **Stop and finalise on `NSWorkspace.willSleepNotification`**, before the stream fails. | The notification arrives first, then the stream dies with `Failed to find any displays or windows to capture`. Finalising on the notification turns an unrecoverable error into a clean partial recording. |
| Wake | Do not auto-resume. | The stream is already gone; there is nothing to resume. |
| Unrecoverable stream error | Stop and finalise, surface the error. | `stream(_:didStopWithError:)` fires and the harness settles the session as `streamError`, as seen on sleep. |

Three rules apply across all of them.

1. **Never diagnose capture health from audio level.** Measured twice over: a filter matching a silent
   application delivers a continuous stream of exactly-zero buffers, and a filter whose application has
   *died* delivers exactly the same thing. Silence is valid input and silence is also what total
   failure looks like. Use capture state, process liveness, and timestamp continuity — as section 3
   requires. The harness records peak and RMS per buffer to *describe* a capture, never to judge it.
2. **Timestamp continuity does not imply content continuity.** Both the route-change dropout and the
   whole post-exit silence period were perfectly continuous in presentation timestamps. The timeline
   builder will reconstruct them without complaint.
3. **"Recording stopped" and "Final recording ready" stay separate events**, including on every
   interruption path. A partial recording still drains queues, closes files and commits its manifest
   before it is offered to the user.

### What the app must observe, minimally

Nothing in ScreenCaptureKit reports any of the conditions above except sleep. The MVP therefore needs:

- `NSWorkspace.didTerminateApplicationNotification`, filtered to the selected application — the only
  way to detect that the capture has become silent-forever.
- `NSWorkspace.willSleepNotification` — to finalise before the stream error.
- Core Audio default-device listeners for route changes, **plus** a periodic reconciliation, because
  virtual audio drivers were measured not to post these notifications.
- `SCStreamDelegate.stream(_:didStopWithError:)` for the genuine error path.

## Findings and surprises

- **Measured drift: none.** −0.000 ppm on `.audio` and +0.000 ppm on `.microphone` over a 40 s
  capture, and zero on all three 15 s fixtures. Timestamp progression matched delivered sample counts
  exactly. **Caveat: the longest run was 90 s.** Drift over 30 minutes or two hours is still
  **pending measurement**, and a 90-second result cannot be extrapolated to a two-hour gate.
- **Clock relationship: one common timeline, no conversion needed.** Both tracks' presentation
  timestamps are on the same host-time-based scale from the single `SCStream`, and the harness
  declares `clockDomain` on both so the inspector reports a common timeline rather than assuming one.
- **Microphone native format:** 48 kHz **mono, interleaved**, mono channel layout tag, **512 frames per
  buffer**, while system audio was 48 kHz **stereo, non-interleaved, 960 frames per buffer**. The
  microphone ignored the stream's 48 kHz *stereo* configuration, exactly as the SDK documents. Because
  this device happens to run at 48 kHz, **the sample-rate conversion path was never exercised.**
- **Surprise: the microphone track always starts late, by a variable amount.** Never simultaneous,
  never early, +0.123 s to +2.594 s across ten runs. Any code that aligns the two tracks by their
  first sample, or subtracts a constant offset, will be wrong by up to 2.5 seconds.
- **Surprise: a dead capture is byte-identical to a silent meeting.** Quitting the captured
  application produced no error, no stop, no timestamp discontinuity — just exact digital silence
  forever, including after relaunch. This is the inverse of the trap section 3 warns about, and it is
  the single most important result here: it makes process-liveness observation a correctness
  requirement.
- **Surprise: browser helper processes turned out to be a non-issue.** The plan flagged this as a risk
  to verify. ScreenCaptureKit attributes helper audio to the owning application under both the
  Chromium child-process model (Chrome, and Zoom's embedded `ZoomCefHelper`) and the WebKit
  launchd-XPC model (Safari). No helper is SCK-visible, and none needs to be named.
- **Surprise: a bare executable cannot hold Screen & System Audio Recording at all** — not by request,
  not by the System Settings **+** picker, not via `tccutil`. Wrapping the identical binary in an
  application bundle granted it immediately. See [capture-permissions.md](capture-permissions.md).
- **Surprise: virtual audio drivers post no route-change notification.** Selecting the
  `Microsoft Teams Audio` loopback device as default output or input notified nothing, while switching
  between two real devices always did.
- **Nearly a wrong conclusion:** the first screen-lock run looked like system-audio capture dying at
  lock. It was Safari pausing its own `<audio>` playback. A control with `afplay` showed capture is
  entirely unaffected by screen lock. Recorded here because the plan's own guidance — diagnose from
  capture state rather than audio level — is exactly what caught it.
- **Audio-only screen configuration: confirmed unnecessary.** All ten captures ran with no `.screen`
  output registered at all. The minimal low-frame-rate fallback the plan allows for was never needed
  and never fired. A content filter still requires a *display* to exist, which is why sleep kills the
  stream.
- **Resource use:** 0.09 % of one core average and 15.2 MB peak footprint, against budgets of 10 % and
  200 MB. Measured on the harness in a release build, which does no encoding or processing.
- **Real fixtures:** three recorded on built-in hardware, in
  [Tests/Fixtures/real/](../../Tests/Fixtures/real/README.md). The USB microphone half of the matrix
  is **not** recorded — no USB microphone was available — which also means no committed real fixture
  exercises a non-48 kHz microphone.

## Completion checklist

Done:

1. ✅ Screen & System Audio Recording obtained, via the application-bundle build.
2. ✅ Application-filter matrix for Chrome, Safari and Zoom, with a silent-application control.
3. ✅ Interruption matrix for output route, input device, application exit and relaunch, screen lock
   and unlock, and sleep.
4. ✅ MVP interruption policy rewritten against measurement.
5. ✅ Three real fixtures on built-in hardware.

Outstanding, in priority order:

1. **A ≥30-minute capture, and a two-hour one for the reliability gate.** Every drift number here comes
   from runs of 90 seconds or less. This is the largest remaining gap and it blocks the timeline
   builder's resampling decision.
2. **A USB or Bluetooth microphone.** It would supply the three missing fixtures, the definitive
   microphone-disconnect measurement, and — if it runs at 44.1 or 16 kHz — the first real exercise of
   the sample-rate-conversion path.
3. **Repeat screen lock and sleep on the macOS 15 baseline.** These results are from macOS 27; the plan
   requires screen-lock behaviour to be measured on each supported OS.
4. **A live WebRTC meeting**, rather than tab playback, for Google Meet in Chrome and Safari. Zoom
   was measured with a real meeting; the browser rows were not.
5. **Teams**, if it is ever installed on a test machine. Not installed here; Teams in a browser is
   already covered by the Chrome and Safari rows.
6. **A microphone that changes format mid-capture**, to exercise the recorder's segment-rotation path
   outside of tests.
