# Scribe for iPad and iPhone — v1 foundation

Open `ScribeMobile.xcodeproj` and select the `ScribeMobile` scheme. The universal
app requires iOS/iPadOS 26. It prioritizes iPad split-view navigation and adapts to
iPhone. Select your development team for device signing; no team or credentials
are committed. The desktop app remains in `Scribe.xcodeproj`.

## Supported workflow

1. Record an in-person meeting through the microphone, or import a supported
   audio/video file from Files. Import uses the first audio track and platform
   codecs; protected or unsupported media produces an error.
2. In Settings, tap **Download Model**, as on the desktop. Scribe fetches the
   pinned Parakeet v3 and speaker-diarization revisions (about 505 MB) from
   Hugging Face into its on-device folder, shown in Files as
   **On My iPad › Scribe › Models** (On My iPhone on iPhone). Every file is
   checked against the bundled manifest's size and SHA-256 before an atomic
   rename publishes it, so cancelling or losing the connection never leaves a
   partial model file. Tapping Download again resumes, reusing files that
   already verify. Keep Scribe open: the screen stays awake during the download,
   and a download that the system suspends in the background asks you to
   resume. Inference itself never touches the network.

   Offline alternative: **Install from a folder in Files…** accepts a folder
   containing `parakeet-tdt-0.6b-v3-coreml` and `speaker-diarization-coreml`,
   such as `Workers/TranscriptionWorker/models`. Choose the folder that contains
   both subfolders, not one on its own. iCloud Drive and other provider files are
   downloaded during installation. Only allowlisted files are copied and
   verified, and a previous installation is kept if verification fails.
3. Select Transcribe. Keep Scribe in the foreground. It decodes incrementally to
   16 kHz mono, runs ASR, releases that model set, then runs global diarization.
   Pause or interruption preserves completed stages; Resume starts from the
   last checkpoint. Relaunch recovers interrupted jobs and recordings.
4. Review the transcript, tap a timestamp to listen, name recording-local
   speakers, or export transcript text through the system share sheet.

This version records **microphone audio**, not audio from other apps' calls.
Meet/Zoom/Teams/Slack capture via ReplayKit is not offered as a supported mode.
Sync, persistent speaker enrollment, dictation, and background inference are
outside this foundation. Processing is deliberately foreground-only; background
recording uses the legitimate audio background mode.

## Architecture

| Boundary | Implementation |
| --- | --- |
| Native UI | `Scribe/Mobile`: observable app coordinator and adaptive SwiftUI views |
| Shared design | `Modules/ScribeDesign`: extracted actual `TranscriptDesign`, speaker palette, flat chips, dots, glass surfaces and containers; the desktop module re-exports it |
| Mobile domain/platform | `Modules/ScribeMobile`: meeting storage, import decoding, microphone lifecycle, trusted model installation, checkpointed processing and conservative speaker attribution |
| Shared inference | `Workers/TranscriptionWorker/Sources/ScribeInference`: the existing Parakeet, offline VBx diarization, manifest and Core ML loaders |
| Desktop compatibility | `TranscriptionWorkerSupport` re-exports shared inference; CLI transport, dictation and desktop workers remain outside the mobile graph |

Both platforms pin FluidAudio 0.17.4 / `21493f8d`. No second ASR runtime, FFmpeg
executable, subprocess, AppKit dependency, or screen-capture entitlement enters
the mobile app. The mobile manifest preserves existing model revisions and
weight hashes and additionally pins every compiled-model metadata file by hash.
It is a committed trust root, never replaced by an imported manifest. Model
notices ship in the app's `Licenses` resource folder.

The design system is shared source, not a mobile copy. Mobile uses its content
measure, line-height ratio, spacing, speaker ordering/colors, unknown-speaker
marks, warning colors, metadata chips and floating glass transport. Native
navigation supplies the adaptive sidebar and toolbar. Transcript body size
scales with Dynamic Type; content remains flat, with glass reserved for controls.

## Permissions and data lifecycle

- `NSMicrophoneUsageDescription` is requested only after Record. Denial exposes
  a Settings action; import never requests microphone or speech permission.
- No camera, contacts, calendar, speech service, accessibility, screen recording,
  App Group, iCloud or background-inference entitlement is requested.
- Only user-selected security-scoped file/folder URLs are opened. Imported media
  is copied to the private container with file coordination before access ends.
- The app's Documents folder is the user-visible **Scribe** folder in Files
  (`UIFileSharingEnabled`, `LSSupportsOpeningDocumentsInPlace`). It holds only
  `Models`, which is excluded from backups; models from earlier builds are moved
  there from Application Support on first launch. The only network requests are
  the user-started model downloads from pinned `huggingface.co` revisions.
- Recordings and checkpoints are below Application Support, not visible in Files,
  and excluded from backups. Audio uses `completeUnlessOpen` protection so an already-open
  recording can continue after lock. Metadata uses protection available after
  first unlock, allowing an interrupted recording's state to be saved.
- Calls/audio interruptions, input disconnection, media-services reset, encoding
  errors and low storage stop capture with a saved-file notice. Recording is
  never silently restarted after an interruption.
- Raw audio, prepared PCM and embedding checkpoint files stay local. Export is
  an explicit text-only allowlist with no audio paths or embeddings. Deletion
  removes the entire meeting directory after confirmation.
- A 64 MiB free-space reserve guards capture; preparation and model installation
  also check estimated space. System I/O failures are surfaced and checkpoints
  remain recoverable. Long-running Core ML calls may finish their current stage
  before cancellation takes effect.

Privacy manifest reason declarations cover app/user-selected file metadata and
user-visible disk-capacity checks. See Apple's [required reason API documentation](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitypereasons),
[microphone permission API](https://developer.apple.com/documentation/avfaudio/avaudioapplication/requestrecordpermission(completionhandler:)),
and [AVAssetReaderTrackOutput](https://developer.apple.com/documentation/avfoundation/avassetreadertrackoutput).

## Build and test

```sh
xcodebuild -project ScribeMobile.xcodeproj -scheme ScribeMobile \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
swift test --package-path Modules/ScribeMobile
swift test --package-path Workers/TranscriptionWorker
swift test --package-path Modules/Transcription --filter Palette
Scripts/test-mobile.sh --models 'id=<iPad UDID>' \
  DEVELOPMENT_TEAM=<team> -allowProvisioningUpdates
```

`--models` stages ignored local model fixtures from the existing verified model
folder. The test bundle contains a synthetic system-voice recording; the shipped
app never contains test audio/models. Without staged models, the real inference
test explicitly skips. The hosted startup test verifies construction does not
request microphone access. Test artifacts are under `build/mobile-device`.

See `validation.md` for executed checks and remaining device qualification gates.
