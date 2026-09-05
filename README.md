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

### Meeting detection

Scribe notices when a call starts in Zoom, Microsoft Teams, Slack, FaceTime,
WhatsApp, Signal, Discord, or an installed Chromium browser (Chrome, Arc, Edge,
Brave, Vivaldi, Opera, Chromium). The signal is macOS's own accounting of
microphone use, read from CoreAudio's process objects: an application that has
the microphone open is on a call, and no window titles or extra permissions are
involved. **Settings → Meeting detection** lists the applications with a
checkbox each; all are on by default, and browsers appear only when installed.

For a browser, a call counts only when a tab is on one of the domains under
**Settings → Meeting websites**. The list starts with `meet.google.com`; add
`teams.microsoft.com`, `zoom.us`, or anything else, and subdomains match. The
tab addresses are read over Apple Events, so the first check of each browser
produces a one-time macOS Automation prompt. If that is declined, a browser
using the microphone is still reported, and Settings says why the domain filter
could not be applied. Leaving the list empty treats browsers like any other
application.

Detection only reports what it sees; it never starts a recording on its own.

### Model storage and offline operation

Open **Settings → Transcription model → Install Model** to install the recommended
Parakeet v3 model directly from Hugging Face. The roughly 505 MB download includes
the speaker detection assets required by the transcription pipeline. No API key,
Python environment, or Git LFS installation is needed.

Models default to `~/Library/Application Support/Scribe/Models`. **Choose Models
Folder…** saves a different location across launches; **Use Default** restores
the default. Changing folders leaves previous downloads in place. A complete
installation in the selected folder is recognized automatically.

The installer uses the exact revisions in the bundled `model_manifest.json`,
checks file sizes and declared SHA-256 hashes, and publishes each verified file
atomically. Progress, cancellation, and retry are available in Settings; retries
reuse verified files, while an interrupted file downloads again. Queued recordings
wait for model setup and start automatically when installation completes. New
jobs use the selected folder without an app restart; active workers retain their
original model directory. Once installed, transcription works offline.

Cloud models and API-key configuration are deferred. The shell installer in
`Scripts/package-transcription-models.sh` remains available for development;
select its output folder in Settings to reuse those files.

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
