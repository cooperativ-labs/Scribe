# Capture harness permissions

The capture harness is a command-line tool, not an application bundle. macOS still gates it with
TCC, so a person must grant two permissions before it can record anything. This page lists the exact
steps and the signing behaviour that makes them necessary.

## 1. Build and ad-hoc sign

```sh
cd Tools/CaptureHarness
./Scripts/build-signed.sh
BIN="$PWD/bin/capture-harness"   # the non-hidden copy the script installs; same signature
echo "$BIN"
```

The script signs the binary inside `.build` and installs an identical copy at `bin/capture-harness`.
Use the `bin/` path everywhere: it carries the same cdhash, so it is the same identity to TCC, and it
can be dragged into System Settings without the Go-to-folder box.

`Scripts/build-signed.sh` does two things a plain `swift build` does not:

1. Embeds `Resources/Info.plist` into the executable's `__TEXT,__info_plist` section with
   `-sectcreate`. Without it, `NSMicrophoneUsageDescription` is missing and the microphone request
   terminates the process instead of prompting.
2. Ad-hoc signs (`codesign --sign -`) with the stable identifier
   `io.cooperativ.scribe.captureharness` and `Resources/CaptureHarness.entitlements`
   (`com.apple.security.device.audio-input`). An unsigned binary has no stable identity for TCC to
   attach a decision to.

Verify with `codesign --display --verbose=2 --entitlements - "$BIN"`; expect `Signature=adhoc`,
`Identifier=io.cooperativ.scribe.captureharness`, and a non-zero `Info.plist entries` count.

## 2. Microphone

```sh
"$BIN" permissions --request
```

Reports the current state and requests anything undetermined.

## 3. Screen & System Audio Recording — use the application bundle

**A bare command-line executable cannot be granted this permission at all.** This was established the
hard way on 2026-09-03; all three routes fail:

- `CGRequestScreenCaptureAccess()` returns `false` immediately and presents no dialog.
- The **+** button in System Settings opens a file picker that accepts **application bundles**, so a
  bare Mach-O executable cannot be selected. There is nothing to add.
- `tccutil reset ScreenCapture io.cooperativ.scribe.captureharness` fails with
  `No such bundle identifier`, because the executable has no LaunchServices bundle identity for TCC
  to address.

Responsible-process inheritance does not rescue it either. Measured: `screencapture` run from the same
shell succeeded and returned real pixels, so the terminal (iTerm) *does* hold the permission — but an
Apple-signed system binary inherits the responsible process's grant, while a third-party ad-hoc-signed
binary is evaluated on its own identity and denied.

`Scripts/build-signed.sh` therefore also produces **`bin/CaptureHarness.app`**, the same executable
inside a real application bundle carrying `Resources/Info.plist` and the same ad-hoc signature and
identifier. Use it for anything that touches ScreenCaptureKit:

```sh
BIN="$PWD/bin/CaptureHarness.app/Contents/MacOS/capture-harness"
"$BIN" permissions --request
```

1. Open **System Settings → Privacy & Security → Screen & System Audio Recording**.
2. If `CaptureHarness` is not already listed, click **+** and select `bin/CaptureHarness.app`.
3. Enable its switch.
4. Re-run `"$BIN" permissions`. It must print `granted` before `record`, `devices` or the probes work.

This is not merely a workaround. The shipping product is a `MenuBarExtra` application bundle, so
measuring permissions through a bundle makes the feasibility results *representative* rather than an
artefact of running a CLI from a terminal.

Without the grant, `SCShareableContent` fails with
`The user declined TCCs for application, window, display capture`, which the harness surfaces as a
permission error rather than an empty capture.

## The rebuild caveat

TCC keys a decision to the binary's code signature. An ad-hoc signature has no team identity, so its
designated requirement is the **cdhash**, which changes on every rebuild. Practical consequences:

- Re-run `./Scripts/build-signed.sh` after any source change, then re-check `permissions`.
- **A rebuild silently invalidates a grant that was made minutes earlier.** This happened during the
  device-matrix work on 2026-09-03: the binary was re-signed to fix two compiler warnings after the
  grant was made, the cdhash changed, and `permissions` went back to reporting `not granted` with no
  error anywhere to explain it. Freeze the binary before asking anyone to approve it, and re-check
  `permissions` immediately after any rebuild rather than trusting an earlier approval.
- If the grant stops applying, remove the stale `capture-harness` row in System Settings with **−**
  and add the new binary again.
- Copying or moving the binary changes the recorded path, and the System Settings entry may need to
  be re-added.
- A Developer ID signature would make the identity stable across rebuilds. That is a milestone-5
  concern; the harness deliberately stays ad-hoc so it needs no certificate.

## Launch the bundle with `open`, not by running the executable inside it

Measured on 2026-09-03 while bringing up `Tools/CaptureIntegration`. Screen & System
Audio Recording had been granted to `CaptureIntegration.app` in System Settings, and
the switch was on, yet:

```sh
./bin/CaptureIntegration.app/Contents/MacOS/capture-integration permissions
# Screen & System Audio Recording: denied

open -n --stdout /tmp/out.log ./bin/CaptureIntegration.app --args permissions
# Screen & System Audio Recording: granted
```

Same bundle, same cdhash, same grant, opposite answers. Invoking the executable
by path from a shell makes the **terminal** the responsible process, and TCC
evaluates the request against that identity rather than the bundle's. Launching
through `open` gives the bundle its own responsible process, and the grant applies.

This costs a long time to diagnose, because the failure is indistinguishable from a
grant that was never made: `CGPreflightScreenCaptureAccess()` simply returns false.
If a grant looks like it "isn't taking", re-run through `open` before touching
System Settings. Use `--stdout`/`--stderr` to capture the output, since `open`
returns immediately and the app's output does not come back to the shell.

The shipping menu-bar app is launched normally by the person using it, so this
affects tooling and automated gates rather than the product.

## Measured on this machine

macOS 27.0 (build 26A5425a), Apple Silicon, 2026-09-03:

- **Microphone:** granted to the ad-hoc signed binary through `permissions --request` with no visible
  prompt, and `AVCaptureDevice.authorizationStatus(for: .audio)` then reported `authorized`. The
  request is attributed to the responsible process of the launching terminal session, so a person
  running the harness from a terminal that already holds microphone access may never see a dialog.
  Do not read this as evidence that a standalone launch behaves the same way.
- **Screen & System Audio Recording:** denied to the bare executable by every available route (see
  above), and **granted to the identical executable inside `CaptureHarness.app`**, after which ten
  real `SCStream` captures ran. The bundle is what made the difference.
- **Responsible process:** the session ran under iTerm (`com.googlecode.iterm2`), which was measured
  to hold Screen & System Audio Recording itself. Apple-signed tools such as `screencapture` inherit
  that; the third-party harness did not. Microphone access appearing instantly with no dialog is
  most likely the same inheritance, so **do not read the instant microphone grant as evidence that a
  standalone launch behaves the same way.**
