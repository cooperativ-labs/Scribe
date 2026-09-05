# Scribe

Scribe is a local macOS meeting-audio recorder. This repository currently
contains the host-app scaffold and the complete menu-bar interface: state
display (Idle, Starting, Recording with elapsed time, Stopping, Error),
background-processing progress reported separately from capture, application
and microphone pickers, folder opening, settings, global shortcuts, and the
first-run permission flow. Everything runs against
`MockRecordingCoordinator`, which implements the `RecordingCoordinating`
contract without capturing anything. Capture, processing, and transcription
are deliberately absent; replacing the mock with the capture-backed
coordinator in `Scribe/App/ScribeAppEnvironment.swift` is what lands them.

## Build and test

The host is macOS 15+ and Apple-Silicon-first. With Xcode installed, build and
run the local Debug app with:

```sh
mise run build
open ~/Library/Developer/Xcode/DerivedData/Scribe-*/Build/Products/Debug/Scribe.app
```

Run the unit test target with:

```sh
mise run test
```

Each workstream package also tests on its own, which is faster while working
inside one of them:

```sh
(cd Scribe/Platform && swift test)
(cd Scribe/UI && swift test)
```

### Project commands

Install [mise](https://mise.jdx.dev) once, then use the checked-in command
catalog:

```sh
mise tasks
mise run build
mise run test
mise run test-platform
mise run test-ui
```

Scribe is an Xcode macOS application, so Xcode remains the source of truth for
the Apple SDK and Swift toolchain. `mise` manages the project commands; it does
not replace Xcode with a standalone Swift installation.

Debug builds disable the hardened runtime so the ad-hoc-signed local package
frameworks load; Release keeps it enabled for notarization.

Release builds are configured for direct Developer ID distribution, no App
Sandbox, and the hardened runtime. `Scripts/package-app.sh` builds an archive,
embeds the transcription helper plus FFmpeg/ffprobe and any local runtime
frameworks, aggregates required third-party notices, signs nested Mach-O code,
notarizes, staples, checks Gatekeeper, and creates `build/release/distribution/Scribe.zip`.
It accepts only reviewed local paths—there are no dependency or model download
steps in the release script.

Release versioning follows the same UTC timestamp convention as Latch:

```sh
mise run version
```

Review and commit that version change before releasing. Then copy `.env.example`
to `.env`, add the installed Developer ID identity plus the Apple ID,
app-specific password, and team ID used to create the `notarytool` profile.
Create `Scripts/release-inputs.local.env` from
`Scripts/release-inputs.example.env` and fill in the reviewed artifact and
notice paths. The guarded release command refuses a dirty worktree, configures
the keychain profile, notarizes and validates the archive, then tags, pushes,
and publishes the GitHub release:

```sh
mise run release
```

For a package-only release rehearsal, run
`mise run package`. The release task refuses a dirty worktree; after the version
bump, review and commit the version change before publishing.

### Model storage and offline operation

Models are user data, not executable bundle contents. The product default is
`~/Library/Application Support/Scribe/Models`; settings may select a different
folder. A future model installer must verify the signed catalog's checksums and
terms before use, make downloads an explicit user action, and never fetch a
model while transcription is running. Once installed, the model loader uses
only the selected local directory and works without networking.

For development, retain source models under `~/Development/Models/Scribe` and
pass that path explicitly through release-input configuration. Never ship a
symlink to a developer directory.

Clean-machine release test:

1. On a Mac without Xcode or command-line developer tools, install the
   stapled `Scribe.zip` output and open the app from Finder; Gatekeeper must
   accept it.
2. Perform the one-time, user-initiated model installation while networking is
   available, then disconnect networking completely.
3. With dependency caches empty, verify launch, recording, processing, and
   transcription using only the installed app, helper binaries, and local
   model directory.
4. Repeat with the model folder unavailable and verify a clear setup error,
   never a runtime download attempt.

`Scripts/build-native-dependencies.sh` likewise never downloads code. It
requires pinned, reviewed sources under `Native/Vendor/webrtc` and
`Native/Vendor/flac` before a future objective replaces the stub with the
reproducible native build steps.

## Workstream ownership

Each entry below is an independent local Swift package. Add code and package
metadata inside the owning directory; the Xcode project already references the
package products, so parallel workstreams do not need to edit
`Scribe.xcodeproj`.

| Owner | Directory |
| --- | --- |
| Host integration contracts and app lifecycle | `Scribe/App/` |
| Capture | `Scribe/Capture/` |
| Session storage and recovery | `Scribe/Storage/` |
| Audio processing | `Scribe/Processing/` |
| macOS integration | `Scribe/Platform/` |
| Recorder SwiftUI | `Scribe/UI/` |
| Native AEC and FLAC boundaries | `Native/WebRTCBridge/`, `Native/FLACBridge/` |
| Speaker module | `Modules/Speakers/` (with `Profiles/`, `Enrollment/`, `Matching/`, `UI/`, `Tests/`) |
| Transcription module | `Modules/Transcription/` (with `Contracts/`, `Import/`, `Jobs/`, `Worker/`, `Transcript/`, `Export/`, `UI/`, `Tests/`) |
| Bundled transcription helper | `Workers/TranscriptionWorker/` |
| Standalone processing utility | `Tools/ScribeProcess/` |
| Capture feasibility harness | `Tools/CaptureHarness/` |
| Audio-quality metrics tool | `Tools/AudioMetrics/` |
| Host-app tests and synthetic fixtures | `Tests/`, `Tests/Fixtures/` |
| Native-build and release scripts | `Scripts/` |

The `Native/`, `Modules/`, `Workers/`, and `Tools/` packages start as compileable
placeholders only; their future owners replace the placeholder APIs without
adding feature logic to the host application.

### In-app updates

Scribe checks the latest published GitHub release at launch and from **Check for
Updates…**. Choose **Download Update…** to download and verify the release, then
**Restart and Install** to replace the application in place and reopen it.
Active recordings finish saving before installation; background processing
resumes after relaunch. Quitting normally discards an update that is ready to
install.

Updates require a Developer ID signed release in a writable Applications folder
and the `Scribe-<version>-macos.zip` asset produced by the release script. The
installer checks the bundle identifier, newer version, installed app's signing
identity, nested code signatures, and Gatekeeper assessment. It preserves the
previous app and restores it if replacement or reopening fails. Unsigned debug
builds, translocated apps, and read-only installations show an actionable error.
No additional feed or signing secret is required by the existing release pipeline.

Before shipping updater changes, exercise a signed older-to-newer release update
on macOS, including an active recording, a cancelled/failed download, and an
unwritable installation. Automated tests cover archive selection/extraction,
bundle identity/version rejection, replacement, and rollback; they substitute
code-signing assessment and Launch Services in the transaction fixtures.
