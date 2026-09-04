# Recorder release validation

Validation date: 2026-09-04  
Objective: `coo:913.jp33`  
Source revision: `3ea4e82` plus the working-tree route-monitor fix described below  
Overall result: **FAIL — not release ready**

The deterministic recorder, timeline, AEC, file-publication, and recovery suites pass. The required live release run could not start because Screen & System Audio Recording is not granted and microphone access is denied for the available integration executables. Consequently the two-hour/resource gate and the required application, hardware, and physical-interruption matrix remain release blockers. A failed row below means that the release requirement is not yet demonstrated; it does not necessarily mean a product assertion failed.

## Test environment

| Item | Value |
| --- | --- |
| Machine | MacBook Pro `MacBookPro18,3`, Apple M1 Pro, 8 cores, 32 GB RAM |
| OS | macOS 27.0 (`26A5425a`) |
| Release artifact | Unsigned arm64 `Scribe.app`; executable 19,597,304 bytes; final rebuild passed after the fix |
| Installed meeting apps | Zoom 7.1.5 (84650), Google Chrome 149.0.7827.201, Safari 27.0 |
| Missing meeting app | Microsoft Teams |
| Storage at final check | 11 GiB available on the system volume |
| Capture authorization | Screen & System Audio Recording not granted; microphone denied |

## Section 8 release gates

| Gate | Result | Measurement and evidence |
| --- | --- | --- |
| Two-hour normal capture; no missing frames or growing memory | **FAIL** | No two-hour release capture was possible under the current TCC grants. The longest prior live harness artifact is 90 seconds, which does not satisfy this release gate. No two-hour buffer-loss or memory-growth measurement exists. |
| Fifty start/stop cycles | **FAIL** | The deterministic coordinator test completed 50 starts, 50 stops, and 50 finalized sessions with no failure. Fifty cycles through the real release capture stack were not possible, so the release gate remains failed. |
| Timeline start/end alignment within one 10 ms block and no cumulative drift | **PASS** | All 11 TimelineHarness cases passed. Every ordinary signal case measured 0.000 ms start error, end error, and cumulative error. The 500.001 ppm sample-rate-drift case was corrected to a 0.021 ms duration residual. |
| Echo reduction at least 20 dB median after convergence | **PASS** | Synthetic median echo reduction was 55.48 dB: far-end-only 62.657 dB, delay-change 55.482 dB, and clock-drift 34.877 dB. Prior built-in-speaker fixture measured 28.91 dB reduction. The required human listening checks remain failed separately below. |
| Local speech changes by less than 1 dB in near-end-only regions | **PASS** | Near-end-only level change was 0.0000 dB in the automated fixture and 0.00 dB in the prior built-in fixture. |
| No lost words or severe pumping during double-talk | **FAIL** | Objective metrics passed: the prior built-in double-talk correlation changed from +0.2885 to +0.0013 without changing near-end-only level. No human listener reviewed the generated cleaned microphone and final mix, so intelligibility and pumping are unverified. |
| Intermediate and final files decode; correct channels, rates, and duration | **PASS** | Fixture reproduction passed. FLACBridge's 11 tests (including its 12-format round-trip parameter matrix) passed; Processing's 67 tests and AudioMetrics' 30 tests passed. Published mixes were 48 kHz stereo 24-bit, all measured at or below -1 dBTP, with zero clips and 0.0 ms duration delta. |
| Originals are never modified; checksums remain valid | **PASS** | Processing verified source archives remain unchanged across successful, failed, and repeated processing. FLAC publication tests verified the published SHA-256 and preservation of an existing final file after a failed rerun. |
| Release capture averages below 10% of one CPU core | **FAIL** | Release build succeeded, but live capture could not start. No CPU average was collected. |
| Release capture memory remains below 200 MB | **FAIL** | Live capture could not start. No resident-memory series or peak was collected. |
| Processing runs at least 2x real time | **FAIL** | Functional processing tests passed, but this run did not produce an end-to-end release processing wall-time measurement. |
| Fully local operation with the network disabled | **FAIL** | A source scan of App, Capture, Processing, Platform, Storage, and Native found no runtime `URLSession`, Network.framework, CFNetwork, WebSocket, or `URLRequest` usage. The release app was not exercised with every interface disabled, so runtime proof is absent. |
| Recovery after forced termination during capture | **PASS** | Fault injection appended an uncheckpointed crash tail; recovery truncated it to the last checkpoint, preserved the completed segment, decoded the recovered active CAF as 480 frames, removed active metadata, and marked the session interrupted. Relaunch recovery also passed. |
| Recovery after forced termination during FLAC encoding | **PASS** | A truncated temporary FLAC failed verification, published no final file, and left no temporary file. Cancelled and abandoned encoders also left no partial output. |
| Atomic manifest/final-output replacement | **PASS** | A failed rerun left the previously published final file and checksum untouched; processing did not expose an unverified replacement. Manifest contract and recovery tests passed. |

## Required live matrix

These rows are release requirements in addition to the quantitative Section 8 gates.

### Meeting applications

| Configuration | Result | Evidence/blocker |
| --- | --- | --- |
| Zoom | **FAIL** | Installed, but no authorized live release capture was possible. |
| Google Meet in Safari | **FAIL** | Safari installed; no authorized live release capture was possible. |
| Google Meet in Chrome | **FAIL** | Chrome installed; no authorized live release capture was possible. |
| Microsoft Teams | **FAIL** | Teams is not installed on the test machine. |

### Audio hardware and route changes

| Configuration | Result | Evidence/blocker |
| --- | --- | --- |
| Built-in speakers and built-in microphone | **FAIL** | Prior fixtures support the AEC result, but no two-hour/current release run was possible. |
| Wired output/input | **FAIL** | No wired device was attached and exercised. |
| USB microphone | **FAIL** | No USB microphone was available and exercised. |
| Bluetooth output/input | **FAIL** | No Bluetooth route was paired and exercised. |
| Route changes while recording | **FAIL** | The new default-output monitor and durable journal/AEC reconvergence tests pass, but a physical route swap was not exercised. |

### Application and system conditions

| Condition | Result | Evidence/blocker |
| --- | --- | --- |
| Meeting app minimized | **FAIL** | Requires authorized live capture. |
| Multiple displays | **FAIL** | No multi-display live release run was performed. |
| Relaunch after interrupted recording | **FAIL** | Incomplete-session discovery, checkpoint repair, interrupted state, and recovery notice tests passed, but the release app was not killed and relaunched around a live capture. |
| Rapid record-shortcut presses | **FAIL** | Coordinator serialization/state tests passed without duplicate active sessions; the release UI did not receive a human rapid-input pass. |
| Permission denial/revocation | **FAIL** | Current denied permissions produced the intended actionable capture failure, and resolver/permission-state tests passed. Mid-session revocation and regrant were not exercised live. |
| Missing application/input | **FAIL** | Source resolution rejects absent/terminated targets with actionable recovery text, and silent application audio archives normally. A live target exit and physical microphone removal were not exercised. |
| Low disk space | **FAIL** | Injected free space below the configured floor requested one clean stop before writing and returned a storage error. The release app was not run against an actually constrained volume. |
| Screen lock | **FAIL** | A prior harness run reported uninterrupted capture while locked, but this release artifact was not exercised. |
| Sleep and wake | **FAIL** | The deterministic sleep path drained and marked the session interrupted, and the prior harness observed the stream fail after sleep. No physical sleep/wake/relaunch pass was completed with this release artifact. |

## Defect found and fixed

The shipping `LiveRecordingCoordinator` did not observe Core Audio's default-output-device property. `RecordingCoordinator` and `SessionStore` could persist a route change, but nothing in the product called that path when wired or Bluetooth output changed. This could prevent the AEC from reconverging at the acoustic-path boundary.

The fix adds `OutputDeviceMonitor`, coalesces duplicate Core Audio notifications by device identity, records previous/current output identities, and forwards changes to the active recording engine. Two tests cover a normal route change, duplicate notification suppression, and a route appearing after no initial device. The Capture package now passes 40 tests, and the patched shipping app rebuilds successfully in Release.

## Verification inventory

| Check | Result |
| --- | --- |
| Release app build after route-monitor fix | **PASS** |
| Fixture reproducibility script | **PASS** |
| TimelineHarness, 11 scenarios | **PASS** |
| Synthetic and prior built-in AEC/mixdown metrics | **PASS** for numeric gates |
| Capture package, 40 tests | **PASS** |
| Processing package, 67 tests | **PASS** |
| AudioMetrics, 30 tests | **PASS** |
| App, UI, Storage, Speakers, Transcription, FLACBridge, WebRTCBridge, CaptureHarness, AECHarness, and Platform test suites | **PASS** |

## Human-at-machine steps still required

1. Use a signed, frozen Release build; grant it Screen & System Audio Recording and microphone access in System Settings, then quit and relaunch it. Confirm the permission prompt, denial, grant, and mid-session revocation/regrant flows.
2. Run a consented two-hour call recording. Log RSS and `%CPU` at least once per minute, compute average CPU and peak plus start/end memory, and record buffer counts, dropped/rejected buffers, journal gaps, file durations, processing wall time, and checksums.
3. Perform 50 real start/stop cycles through the menu-bar shortcut and UI, including intentionally rapid presses. Confirm exactly 50 finalized, independently decodable sessions and no orphan active session.
4. Exercise Zoom, Google Meet in Safari, Google Meet in Chrome, and Microsoft Teams. Install Teams first. For each app, verify isolated system and microphone tracks, final mix, correct target-app filtering, minimized behavior, and continuity across app relaunch.
5. Repeat representative calls with built-in speakers/microphone, wired audio, a USB microphone, and Bluetooth. Change output routes during speech and verify an `output-route-change` journal record plus AEC reconvergence.
6. Attach a second display and repeat capture while moving/minimizing meeting windows. Lock the screen during capture, then sleep and wake the Mac; verify the documented continuation or clean interrupted/recovery behavior and listen to audio around every boundary.
7. Listen to the cleaned-microphone and final-mix double-talk artifacts in `.build/validation/mixdown`, checking for lost syllables, pumping, metallic speech, or audible echo. Record the listener, headphones, and verdict.
8. Disable Wi-Fi, unplug Ethernet, disable any remaining network interfaces, and launch, record, stop, process, play, and export without reconnecting. Confirm no resource download or network-dependent error occurs.
9. On a disposable APFS volume or quota-limited test account, reduce free space through the configured threshold during capture. Verify one clean stop, intact last checkpoint, actionable UI, and successful recovery after space is restored.

Until these steps are completed and the failed rows are replaced with measured passes, this build should not be promoted as recorder-release ready.
