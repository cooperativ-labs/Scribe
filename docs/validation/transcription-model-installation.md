# Parakeet v3 installation validation

Validated on Apple Silicon, macOS 27 / Xcode 27 beta, 2026-09-05.

## Automated checks

- Platform: 32 passing tests, including installation, pinned download URLs,
  checksum rejection, atomic replacement, retry reuse, cancellation, folder
  persistence, and an opt-in live Hugging Face installation.
- ScribeUI: 24 passing tests.
- Transcription: 162 passing tests, including queued jobs waiting for model
  readiness and a fresh worker installation being resolved for each job.
- The Debug macOS app builds with the real Xcode scheme. Its bundled
  `model_manifest.json` matches the worker's source manifest byte for byte.
- The actual SwiftUI Settings view was rendered in an isolated AppKit preview.
  Model selection, destination, and Install Model are visible near the top.
- `git diff --check` passes.

## Live installation and recognition

The production downloader installed all 504,878,061 required bytes from the
manifest's pinned Hugging Face revisions into a fresh temporary Models folder.
Every required file passed the installer and worker validators. Removing one
vocabulary file from this temporary installation and retrying downloaded only
the missing file; the final URLSession download-progress delegate was exercised.

The existing Release `TranscriptionWorker` was then pointed at that folder and
run in normal mode (no deterministic test-mode flag). A local macOS `say`
fixture, 11.681 seconds long, produced this transcript:

> Scribe can now download and install the parakeet transcription model. This
> recording checks that local speech recognition works after installation. The
> model files are stored in a folder selected by the user.

Prepare, transcription, diarization, and embedding stages all completed, with
real token timestamps, diarization intervals, and embedding artifacts. This is
a short synthetic-speech smoke test, not an accuracy benchmark for meetings.

## Reproduction

```sh
swift test --package-path Scribe/Platform
swift test --package-path Scribe/UI
swift test --package-path Modules/Transcription
xcodebuild -project Scribe.xcodeproj -scheme Scribe -configuration Debug \
  -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO build

# Optional: downloads approximately 505 MB when the destination is empty.
SCRIBE_MODEL_INSTALL_SMOKE_DIRECTORY=/tmp/scribe-model-install-check \
  swift test --package-path Scribe/Platform --filter freshHuggingFaceInstallation
```

The live download test is opt-in; ordinary package tests do not require the
network. Cloud providers and API-key setup remain deferred.
