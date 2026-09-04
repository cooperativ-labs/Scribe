# capture-integration

The real-Mac gate for the recorder's capture core. It drives the shipping
`PermissionService`, `CaptureService` and `SessionStore` — not a copy of them —
and checks the exit criteria for IMPLEMENTATION_PLAN.md section 3:

- both tracks delivered audio,
- no buffer was dropped,
- a system and a microphone CAF segment were written into the session store,
- and a missing or revoked permission surfaces as an actionable error instead of
  an empty recording.

`Tools/CaptureHarness` is the separate feasibility instrument that produced
[docs/feasibility/capture-timing.md](../../docs/feasibility/capture-timing.md).
This tool exercises the product code those findings were fed into.

## It must run from the application bundle

A bare Mach-O executable cannot be granted Screen & System Audio Recording by any
route: `CGRequestScreenCaptureAccess()` returns false with no prompt, the System
Settings **+** picker only accepts application bundles, and `tccutil` cannot
address a client that has no LaunchServices bundle identity. See
[docs/feasibility/capture-permissions.md](../../docs/feasibility/capture-permissions.md).

```sh
cd Tools/CaptureIntegration
./Scripts/build-signed.sh
BIN="$PWD/bin/CaptureIntegration.app/Contents/MacOS/capture-integration"

"$BIN" permissions --request
```

Then, in **System Settings → Privacy & Security → Screen & System Audio
Recording**, add `bin/CaptureIntegration.app` with **+** and enable its switch.

The ad-hoc signature's designated requirement is the binary's cdhash, so **every
rebuild is a new identity to TCC and silently invalidates a grant made minutes
earlier**. Re-check `permissions` after every build rather than trusting an
earlier approval; if the grant stops applying, remove the stale row with **−** and
add the rebuilt bundle again.

## Running the gate

```sh
# Ten minutes against a running application that is producing audio.
"$BIN" record --bundle-id com.apple.Safari --seconds 600

# Somewhere other than the temporary directory.
"$BIN" record --bundle-id us.zoom.xos --seconds 600 --output "$HOME/scribe-gate"

# A specific input device rather than the system default.
"$BIN" record --bundle-id com.google.Chrome --microphone <device-uid>
```

It exits `0` on **PASS** and `1` on **FAIL**, printing the reason. Progress prints
every 60 s with per-track buffer counts, dropped buffers and peak queued bytes.

## The menu-bar flow gate

`flow` is the real-Mac gate for IMPLEMENTATION_PLAN.md section 6 and milestone 4.
It drives the **shipping** menu-bar path — `LiveRecordingCoordinator`,
`ProcessingQueue`, `FinalRecordingHandoff` and `TranscriptionRequestOutbox`, wired
the way `ScribeAppEnvironment` wires them — by submitting the same
`RecordingCommand` values the menu buttons and the global shortcuts submit. It is
not a reimplementation of the app's behaviour, so a pass here is a pass for the
menu.

```sh
# A short capture of a foregrounded meeting application, through to handoff.
"$BIN" flow --bundle-id us.zoom.xos --seconds 30 --output "$HOME/scribe-gate"

# Cleanup on a long meeting takes longer than the default five-minute wait.
"$BIN" flow --bundle-id com.apple.Safari --seconds 600 --processing-timeout 1800
```

It checks the whole chain in order:

- Start is accepted and the menu observes a `Recording` state.
- Stop drains and returns the recorder to `Idle` — the same property quitting
  during capture depends on.
- Background processing runs *after* capture has closed and reports a terminal
  outcome, so the recorder is startable again while it works.
- Open Recordings Folder resolves to the configured folder.
- `final.flac` passes the handoff gate — recognized schema version, processing
  state `complete`, file present, checksum matching the manifest — and becomes a
  `TranscriptionRequest` whose provenance names the session that was just
  recorded.

It prints the menu states and queue events it saw, so a failure names the step
that broke. It exits `0` on **PASS** and `1` on **FAIL**.

Without the Screen & System Audio Recording grant it stops at the first step with
the actionable permission error rather than recording silence — which is itself
the behaviour section 6 asks for, but it is not a pass.

## What it deliberately does not check

Audio level. A filter matching a silent application delivers a continuous stream
of exactly-zero samples, and so does a filter whose application has *died* — the
two are byte-identical. The gate therefore judges buffer delivery, timestamps and
files, never loudness. Watching process liveness is the coordinator's job.

## If the grant "isn't taking"

Run the bundle through `open`, not by invoking the executable inside it:

```sh
open -n --stdout /tmp/out.log --stderr /tmp/err.log \
  ./bin/CaptureIntegration.app --args record --bundle-id us.zoom.xos --seconds 600
```

Invoking `bin/CaptureIntegration.app/Contents/MacOS/capture-integration` directly
from a shell makes the *terminal* the responsible process, so TCC evaluates the
request against the terminal's identity and reports `denied` even when the bundle
holds the grant. `open` gives the bundle its own responsible process. `open`
returns immediately, so use `--stdout`/`--stderr` to capture the output.
