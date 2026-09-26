# iPhone and iPad meeting recording feasibility

Investigated 2026-09-26 for **coo:1074.pqy6**. This is an architecture and
feasibility investigation, not an implemented mobile app or device benchmark.

## Recommendation

Build a native universal iPhone/iPad app around the existing local transcription
and diarization engine. Start with in-person microphone recording and imported
recordings. Keep macOS as the reliable integration-free capture option for
meetings running in other applications.

**Do not promise universal same-device recording of Meet, Zoom, Teams, or Slack
on iOS/iPadOS.** Public capture APIs do not establish that both call directions
will be available. ReplayKit is worth a small physical-device experiment, but
its results must determine the supported app/OS/audio-route combinations before
the product is scoped around it. A faster chip does not remove audio-session
access restrictions.

Assume A18 Pro-class or better hardware as requested; qualify individual iPads
separately rather than treating A-series and M-series chips as one ordered
capability scale. Recommend iOS/iPadOS 26 as the initial deployment baseline for
the background-processing API, subject to device qualification. No dictation,
cross-device synchronization, or cloud inference is needed in the first release.

## Capture: what can actually be offered

| Workflow | Assessment | Product consequence |
| --- | --- | --- |
| In-person meeting through the device microphone | Normal AVFoundation recording path; needs interruption and lock-screen testing | Suitable first mobile recording mode |
| User imports an audio/video recording | Feasible with supported AVFoundation codecs | Suitable first transcription mode; no service integration required |
| Another app plays ordinary media | System ReplayKit broadcast is a candidate | Verify the actual source; not every kind of media is capturable |
| Meet, Zoom, Teams, Slack Huddles on the same phone/tablet | Both sides of the call are unverified; competing microphone access is a documented obstacle | Experimental only until device tests pass |
| Meeting on another device, audible through its speaker | Mobile mic can record acoustic room audio | Fallback with poorer separation/quality; not system-audio capture and ineffective for remote voices in headphones |
| Meeting on Mac | Existing ScreenCaptureKit-based path | Retain current architecture; transcript/profile sync can follow later |

Apple explicitly documents that activating a `record` or `playAndRecord` audio
session while another app hosts a call fails with insufficient priority.
`mixWithOthers` must not be treated as permission to tap that call. See
[AVAudioSession activation](https://developer.apple.com/documentation/avfaudio/avaudiosession/setactive%3Aerror%3A).

There are two different ReplayKit paths: an app's own recording/capture, and a
user-started system broadcast handled by a Broadcast Upload Extension. The latter
is the relevant cross-app experiment. Apple describes app audio, microphone
audio, and screen video entering the extension separately in
[Live Screen Broadcast with ReplayKit](https://devstreaming-cdn.apple.com/videos/wwdc/2018/601nz4m863hyf0/601/601_live_screen_broadcast_with_replaykit.pdf).
That architecture is not a guarantee of access to protected or call audio.
Receiving callbacks is also not proof: Apple's
[sample-buffer documentation](https://developer.apple.com/documentation/replaykit/rpbroadcastsamplehandler/processsamplebuffer(_:with:))
describes silent audio buffers when input is unavailable. Measure actual signal
and listen to both directions.

A first-person developer report describes loss of ReplayKit mic buffers when
another app uses the microphone, including Meet. It is corroborating evidence
of a failure mode, not an Apple guarantee or a current compatibility matrix:
[broadcast microphone interruption report](https://developer.apple.com/forums/thread/794049).
No physical-device tests of the four meeting apps were performed for this report.

CallKit does not supply a general third-party call-audio tap. Apple's
[Add Audio in Calls](https://developer.apple.com/documentation/avfaudio/adding-synthesized-speech-to-calls)
feature injects synthesized audio into calls; it does not document reading remote
participants' audio. Changing to Catalyst, wrapping the meeting in a web view,
or distributing outside the App Store is not a sound plan for bypassing these
OS restrictions. Hosting calls ourselves or using provider recordings/bots would
change the integration-free requirement.

## Reuse the inference stack, change the host boundaries

The repository pins FluidAudio **0.17.4**, revision
`21493f8dac5a97e65742e6ff26f42f164c2fda0f`, in
`Workers/TranscriptionWorker/Package.swift` and `Package.resolved`.
Its manifest at that exact revision declares iOS 17/macOS 14 support and iOS
device/simulator slices for its NemoTextProcessing binary dependency. Inspection
used `git show` at the pin: the working dependency checkout was at another
revision and must not be used as evidence for the release pin.

Scribe's own packages currently declare macOS 15. Adding an iOS platform line
alone will not port the dependency graph:

| Existing component | Mobile work |
| --- | --- |
| `Scribe/Capture/.../CaptureService.swift` | Replace AppKit/ScreenCaptureKit capture with an AVAudioSession/AVAudioEngine mic adapter; optional separate ReplayKit extension |
| `Modules/Transcription/.../Worker/WorkerProcessTransport.swift` | Replace `Process` transport with an in-process async inference service; retain desktop subprocess isolation |
| `Workers/TranscriptionWorker/Sources/TranscriptionWorkerSupport` | Extract portable inference library; exclude CLI entry points and dictation lifecycle from mobile |
| `Modules/Transcription/.../Import/MediaProbe.swift` and `AudioPreparationService.swift` | Replace ffprobe/ffmpeg executable calls with AVAssetReader/AVAudioFile/AVAudioConverter; explicitly list supported formats |
| `Scribe/App/Sources/ScribeAppCore` | Separate recording contracts/model installation from desktop updater code that invokes codesign, tar, and spctl |
| Transcript models, attribution, grouping, speaker matching, vocabulary | Reuse domain logic and regression fixtures after isolating AppKit UI and desktop filesystem assumptions |
| `Scribe/Storage` | Reuse session/recovery concepts; adapt sandbox paths, file protection, file coordination and backup policy |
| `Native/WebRTCBridge` | Current build hardcodes macos-arm64; needs iOS/simulator native slices if measurements justify reuse |
| `Scribe/UI`, transcript/speaker UI, `Scribe/Platform` | New mobile navigation, recording/import/settings screens; isolate Mac menu bar, Accessibility, Automation and meeting detection |

Proposed dependency direction:

```text
macOS app -> desktop capture + subprocess adapter --+
                                                  +-> shared contracts / pipeline
iPhone/iPad app -> mic/import + in-process adapter -+     -> FluidAudio + Core ML
ReplayKit extension -> bounded local audio chunks -> mobile app job queue
```

Keep extension dependencies small: capture and storage contracts only. Do not
load transcription or diarization models in it. A local-only prototype can
discard video and write timestamped `.audioApp` / `.audioMic` tracks into an App
Group; app review/distribution suitability remains to be established. Use bounded
queues, frequent finalized chunks, atomic manifests and explicit gaps. Do not
depend on the containing app staying alive. Preserve each track's presentation
timestamps and route/sample-rate changes before resampling or mixing.

Start with native lossless PCM/CAF chunks. A mono 16 kHz Float32 analysis copy is
230.4 MB per hour; stereo 48 kHz Int16 capture is 691.2 MB per hour, before file
overhead. Budget each retained track and temporary copy, not just the model.
Reclaim intermediates after durable completion. Prefer platform codecs over a
new FFmpeg mobile distribution unless format requirements justify the cost.
If separate tracks reveal echo duplication, evaluate offline AEC with the remote
track as reference. Do not assume access to the other app's voice-processing
state or use audio-session settings that disrupt the call to obtain it.

## Transcription, diarization, and performance

Use the current Parakeet TDT v3 Core ML ASR and the existing offline
segmentation/WeSpeaker/VBx diarization baseline first. Existing adapters default
to `.cpuAndNeuralEngine`, with FBank on CPU. The staged manifest declares about
505 MB of model files; that is disk size, **not peak resident memory**. Validate
the compiled model assets on iOS and recompile/package from reviewed source
assets if needed. Preserve exact model revisions, integrity checks and notices.

Run final transcription and diarization after recording, sequentially, releasing
models between stages. The current diarizer already uses a disk-backed PCM
source and global clustering. Preserve that design, but measure embeddings,
clustering and reconstruction allocations: disk-backed audio does not bound all
working memory. Arbitrarily splitting into independent diarization jobs would
lose stable speaker identities across chunks unless reconciliation is added.

Reuse word timing reconciliation, overlap handling, unknown-speaker semantics,
turn grouping and manual corrections. Diarization means distinguishing speakers
within a meeting; naming a person requires enrollment or a user assignment.
Do not identify everyone on the remote track as one speaker or assume that the
microphone track contains only the device owner. Persistent profiles should
remain versioned by embedding model and calibrated for mobile/room acoustics.

There is no measured A18 Pro end-to-end result here. Desktop throughput and
upstream headline benchmarks do not establish mobile speed, battery cost, peak
memory or thermal stability. Benchmark release builds with both 15-minute and
60–120-minute meetings, overlap, short replies, noise and supported languages.
Record ASR/diarization/total real-time factor, cold/warm load, peak RSS, scratch
disk, battery delta, thermal state, WER and speaker-attribution error.

If this baseline misses the budget, first compare compute-unit configurations
and peak-memory lifetimes. Then benchmark smaller ASR models or Apple's
[SpeechAnalyzer/SpeechTranscriber](https://developer.apple.com/videos/play/wwdc2025/277/)
behind the same interface. Apple's option supplies on-device transcription;
retain a separate diarization solution and verify language availability, word
timing and vocabulary behavior. WhisperKit/whisper.cpp would introduce another
ASR runtime and would still need diarization; do not switch merely to achieve
mobile packaging. Dependency parity is the starting point, not a reason to
accept materially worse measured performance.

## Background execution and packaging

Ship a signed universal iOS/iPadOS target via normal development/TestFlight/App
Store packaging, with a separate embedded extension only if the capture spike
supports it. Use microphone purpose text and audio background mode for legitimate
mic recording; add App Groups for extension handoff. The Mac self-updater and
bundled command-line workers do not belong in the mobile target.

For processing, iOS/iPadOS 26's
[BGContinuedProcessingTask](https://developer.apple.com/documentation/backgroundtasks/performing-long-running-tasks-on-ios-and-ipados/)
can continue a user-started foreground job. It is not an unlimited daemon or a
guarantee that processing begins immediately. Persist stage progress and support
expiration/cancellation and safe resume. Foreground processing is the baseline;
background acceleration is an additional validated capability.

GPU use requires its entitlement and a runtime supported-resource check; A18 Pro
is not sufficient evidence. Apple also now documents a
[Background Inference entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.background-tasks.continued-processing.inference),
marked **beta when researched**, for background Neural Engine access. Check the
shipping SDK/OS availability and provisioning before relying on it. Do not assume
`.cpuAndNeuralEngine` guarantees background execution. If unsupported, checkpoint
and resume in foreground, or use a separately measured supported CPU path.

Download models once through the existing verified installer design, adapted to
the sandbox; all recording and inference then work offline. Make raw recordings,
analysis files and extension chunks local-only and excluded from device cloud
backup from the first mobile release. Choose file protection compatible with an
already-started locked-screen recording and test it. Later sync should use an
explicit allowlist of transcripts, edits and versioned speaker profiles, with no
audio assets or local audio paths. Playback/reprocessing remains available only
on the device retaining the audio. Sync conflict handling and transport are later
work; this investigation does not implement them.

## Recommended implementation sequence and decision gates

1. **Capture feasibility spike before a broad port.** A tiny native host and
   ReplayKit broadcast extension, no models. Use an A18 Pro phone and a qualifying
   physical iPad. For Meet, Zoom, Teams and Slack separately, record exact OS and
   app versions. Test native clients and supported browser clients as distinct
   cases. Begin capture both before and after joining; exercise local/remote solo
   speech, overlap, mute/unmute, speakerphone, wired/USB audio and Bluetooth,
   screen lock, app switching, route changes, interruptions and meeting screen
   sharing. Inspect each track's signal, timestamps and intelligibility; a short
   repeatable spoken script on each side makes silent/one-sided results obvious.
   Require both voices, no disruption to the call, no unexplained gaps and a
   60-minute stable run. Otherwise reject that combination and retain mic/import
   scope. Simulator capture does not qualify.
2. **Portable engine and performance spike.** Extract shared contracts and
   inference library, build for iPhoneOS and simulator, validate all pinned
   binary/model slices and run identical input through mobile and desktop. Target
   total processing RTF <= 0.25 (a 60-minute meeting within 15 minutes) as a proposed
   acceptance budget, not a measured promise. Require no memory termination,
   bounded scratch growth, repeatable quality and cancellation recovery. Retain
   desktop regression coverage. Choose alternatives based on measured results.
3. **Mobile MVP.** Recording/import, verified model installation, resumable
   processing, transcript review/export and speaker assignment. Qualify 2-hour
   capture, low storage, interruptions, denied permissions, lock/unlock, termination
   recovery, offline relaunch and backup exclusion. Offer ReplayKit only for
   combinations actually qualified in step 1, with clear missing-track reporting.
4. **Later stages.** Transcript/profile sync without audio, then optional live
   preview if justified. Dictation stays out of scope.

These are proposed follow-on implementation slices, not work silently started
by this investigation. No app/device performance or capture compatibility claim
is considered validated until the corresponding gate is run.
