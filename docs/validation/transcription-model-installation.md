# Parakeet v3 installation validation

See the [assembled offline release validation](offline-release-2026-11-19.md)
for the combined FluidAudio 0.18.3 and FFmpeg 9.0.2 signed build.

## Corrected encoder

Profile `parakeet-v3-offline-diarization-v2` selects FluidInference's
`Encoder_v2.mlmodelc` with per-channel int8-linear weights, from revision
`7dd20fe6b1797d35f5e3307e8b1732d9a178edfe`. The
[release manifest](../../Workers/TranscriptionWorker/model_manifest.json)
pins all four encoder files by size and SHA-256. The encoder bundle is
595,214,702 bytes. The required install is 653,942,388 bytes and the full
pack with optional vocabulary boosting is 756,745,475 bytes.

On Apple Silicon (macOS 27.2.1, Xcode 27.2), the production downloader
installed the complete pack from a clean folder. The upgrade smoke test reused
the existing companions, interrupted the encoder weight transfer, and corrupted
one of the verified encoder files without changing its size. Retrying fetched
only the corrupted file and the missing weights. Both app manifests validated
their respective assets after the retry. The development staging command and
its read-only verifier also passed.

With networking denied, the Release helper ran prepare, batch transcription,
diarization, and embedding, then warmed, ran, and unloaded resident dictation.
Both recognition paths emitted 48 tokens with positive, ordered time ranges
within the 7.746-second synthetic fixture. This check establishes compatibility
with FluidAudio 0.17.4 and the existing companions. Comparative accuracy and
latency measurements await the new reference sample.

The local Release app contains the exact source manifest. The packaging guard
accepts the current helper and rejects a helper built before the encoder update.
Developer ID signing and notarization of the assembled release follow the
remaining pipeline upgrades.

### Rollback pairing

Use Scribe `0.2611101145.0` with the `parakeet-v3-offline-diarization-v1`
model pack and its original `Encoder.mlmodelc`. The verified pair is staged
locally at `build/rollback/Scribe-0.2611101145.0` as `Scribe.app` and
`Models`. The previous helper validated the retained pack and warmed dictation
with networking denied. The previous app's signed manifest has SHA-256
`55c9f6a21b86e4c8864f6d32f2e3f34bbe50ea9772f7bf39fb4c36af214a3d5b`.
Select the paired `Models` folder in the previous app if the original encoder
is absent from the normal install directory.

## Original encoder

Validated on Apple Silicon, macOS 27 / Xcode 27 beta, 2026-09-05.

### Automated checks

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

### Live installation and recognition

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

# Optional: downloads the current full model pack (~757 MB when empty).
SCRIBE_MODEL_INSTALL_SMOKE_DIRECTORY=/tmp/scribe-model-install-check \
  swift test --package-path Scribe/Platform --filter freshHuggingFaceInstallation

# Optional: verify upgrade, interruption, corruption and rollback pairing.
SCRIBE_MODEL_UPGRADE_SMOKE_ROLLBACK="$PWD/build/rollback/Scribe-0.2611101145.0" \
SCRIBE_MODEL_UPGRADE_SMOKE_STAGED="$PWD/Workers/TranscriptionWorker/models" \
  swift test --package-path Scribe/Platform --filter correctedEncoderUpgradeResumesAndPreservesRollback
```

The live download test is opt-in; ordinary package tests do not require the
network. Cloud providers and API-key setup remain deferred.
