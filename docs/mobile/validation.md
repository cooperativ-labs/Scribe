# Mobile foundation validation — 2026-09-26

Objective: `coo:1074.3gw2`. Xcode 27.0 beta (`27A5228h`), iOS SDK 27,
iOS/iPadOS deployment target 26.0. The earlier feasibility report remains the
source for unsupported cross-app call capture and future qualification gates.

## Executed checks

| Check | Result |
| --- | --- |
| iPhoneOS app compile | Passed |
| Universal app simulator compile | Passed |
| Signed development app for the existing team | Passed; no signing credentials committed |
| Mobile foundation tests | 8 passed: backup exclusion, recovery, path validation, deletion, text-only export, overlap attribution, incremental audio conversion, checkpoint reuse, model integrity and replacement rollback, and trailing-punctuation attribution |
| Existing worker regression suite | 18 passed after inference extraction and configuration-boundary fix |
| Existing desktop palette/view-model tests | 11 passed after shared design extraction |
| Hosted iPad simulator tests | 2 passed, 0 skipped: startup permission and actual model installation → decoding → ASR → diarization → replacement |
| Physical M5 iPad test launch | Blocked: Xcode reports the device is locked; the waiting run was cancelled |
| Plist/project syntax and whitespace | Passed |

The desktop palette test initially encountered concurrent unfinished changes to
`TranscriptWindow.swift` from another objective. Those changes were left intact;
the final rerun passed once its helper definitions were present.

The physical iPad is paired, has Developer Mode enabled, and is running iPadOS
27.0. The signed test runner was built successfully. The user was asked to unlock
it. Device Hub UI access was separately denied by the computer-use tool, so no
visual walkthrough is claimed. No microphone recording permission was granted
by these automated tests.

Warnings: Xcode reports skipped App Intents metadata extraction because the app
has no App Intents. The worker package has a pre-existing unhandled resource
README warning. AVFoundation logs that non-interleaved file settings are ignored
for the synthetic conversion tests; resulting sample rate/channel/duration
assertions pass.

## Required before treating this as a qualified mobile release

- Run the hosted real-model fixture on the unlocked M5 iPad and iPhone 16 Pro.
  Use `Scripts/test-mobile.sh --models 'id=<UDID>' DEVELOPMENT_TEAM=<team>
  -allowProvisioningUpdates`. Simulator success does not qualify ANE behavior.
- Exercise microphone first-use allow/deny, Settings recovery, and import with
  microphone denied. Verify no unexpected permission prompts.
- Record through lock/unlock, route loss, phone/call interruptions, low storage,
  force termination, relaunch and actual cloud-backup inspection. Verify saved
  audio and truthful interruption notices; qualify two-hour capture.
- Exercise Files import from local and cloud-backed providers, unsupported media,
  cancelled pickers, a corrupt model folder, and offline relaunch.
- Inspect portrait/landscape, iPad multitasking widths, iPhone navigation, VoiceOver,
  large Dynamic Type and light/dark appearance on device. Glass uses native
  surfaces without custom animations.
- Measure 15-, 60- and 120-minute inference, peak memory, thermal state, storage,
  energy and diarization quality on qualifying hardware. No performance claim is
  established by compilation or the short fixture.
- ReplayKit call capture remains a separate feasibility gate. There is no broadcast
  extension or promise of remote-call audio in this v1 foundation.

## Model download and Scribe folder — objective `coo:1074.4cnd`

| Check | Result |
| --- | --- |
| Mobile package tests | 10 passed, including a new download test: a corrupt response is rejected and never published, the pinned `resolve/<revision>` URL is requested, progress reaches completion, a retry reuses verified files, and a non-Hugging Face source is refused before any request |
| Real Hugging Face download (macOS harness running `ModelLibrary.download`) | 504 MB from the pinned revisions, verified and installed in 87–89 s. Cancelling at 150 MB left no partial file; the resumed download completed and verified |
| Hosted iPad simulator tests | 2 passed, 0 skipped, including the folder install through the new staging location and real ASR plus diarization |
| Simulator launch | `Documents/Models` is created on first launch; models planted in the old Application Support location moved there and kept the backup-exclusion attribute |

The first real download showed that the task delegate passed to
`URLSession.download(from:delegate:)` never received write progress, so the bar
jumped from 0 to 446 MB during the encoder. The mobile downloader now uses a
session-level download delegate (475 progress updates during the resumed run).
The desktop `TranscriptionModelDownloader` still uses the old pattern.

Not yet checked: the Settings sheet and Files visibility were not viewed
interactively because the simulator ran headless with no way to tap. A physical
download on the iPad, including backgrounding during the download, is still
outstanding.

## Real-model simulator evidence

The iPad Pro 11-inch (M5) **simulator**, iOS 27.0 build `24A5390f`, processed
an 11.122-second synthetic meeting recording through the actual pinned models.
It produced the expected meeting text and one identified speaker. The cold debug
pipeline took 171.458 seconds; this is simulator execution, not an iPad hardware
benchmark or a release performance claim. The test also verified reinstallation
of the model set and startup without requesting microphone access.

The result exposed a punctuation-only unknown-speaker row at the speech boundary.
Assembly now keeps trailing punctuation with the preceding turn, covered by a
focused regression test. Overlapping spoken words remain conservatively unknown.

Result bundle: `build/mobile-simulator/Logs/Test/Test-ScribeMobile-2026.09.26_10-22-57-+0200.xcresult`.
