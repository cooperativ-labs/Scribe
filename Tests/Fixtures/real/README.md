# Real-room capture fixtures

Real system/microphone pairs recorded with `capture-harness fixture`, on real hardware, in a real
room. They exist because IMPLEMENTATION_PLAN.md section 8 says the deterministic suite under
[`../Generated`](../Generated) is not sufficient on its own: "Pair these tests with real-room
recordings; synthetic success alone is insufficient."

The two suites answer different questions. `Generated/` has exact ground truth — a known delay, a
known drift ratio, a known echo path — so it can assert numeric bounds. The fixtures here have no
ground truth beyond what a person observed while recording them, so they are for listening checks,
convergence behaviour, and for confronting the processing chain with real microphone formats,
real room acoustics, and real speaker paths.

## Status

Three built-in-hardware fixtures are recorded, on macOS 27.0 (build 26A5425a), 2026-09-03. The USB
microphone rows are not, because no USB microphone was available on the machine.

| Directory | Scenario | System track | Microphone track |
| --- | --- | --- | --- |
| `builtin-far-end-only` | far-end-only | far-end speech, peak −4.1 dBFS | acoustic echo only, peak −13.4 dBFS |
| `builtin-near-end-only` | near-end-only | exact digital silence | speech only, peak −20.1 dBFS |
| `builtin-double-talk` | double-talk | far-end speech, peak −4.2 dBFS | speech over echo, peak −11.0 dBFS |

All three are 15 s, captured through one `SCStream` with `--all-system-audio`, with no gaps, no
overlaps and no format changes. The far-end signal in `builtin-far-end-only` and
`builtin-double-talk` is `../Generated/far-end-only/playback.wav` played through `afplay`, so the
far-end waveform is *exactly known* even though the echo path and the near-end speech are real. That
makes these two more useful than a fully uncontrolled recording: the reference signal can be
correlated against the microphone track to estimate the true acoustic delay.

Recording any of these needs the Screen & System Audio Recording grant, which is a human action and
requires the **application-bundle** build of the harness — a bare executable cannot be granted it at
all. See [capture-permissions.md](../../docs/feasibility/capture-permissions.md).

## Recording one

```sh
cd Tools/CaptureHarness
./Scripts/build-signed.sh
BIN=./bin/CaptureHarness.app/Contents/MacOS/capture-harness   # the bundled build; see permissions doc
"$BIN" devices                       # microphone uids and running bundle identifiers

"$BIN" fixture \
  --scenario far-end-only \
  --id builtin-far-end-only \
  --devices "MacBook Pro built-in speakers, built-in microphone" \
  --all-system-audio \
  --seconds 15 \
  --fixtures-dir ../../Tests/Fixtures/real
```

The tool prints the scenario script, counts down `--lead-in` seconds, records `--seconds`, and then
writes the fixture directory. It never invents a device description: `--devices` is required,
because a recording whose hardware is unknown cannot be interpreted later.

## Scenarios

| `--scenario` | What the operator does | What the pair should contain |
| --- | --- | --- |
| `far-end-only` | Play far-end speech through the speakers under test; say nothing. | System track: far-end speech. Microphone track: its acoustic echo and room noise only. |
| `near-end-only` | Nothing playing; speak into the microphone under test. | System track: silent. Microphone track: near-end speech only. Used to check AEC does not attenuate local speech. |
| `double-talk` | Play far-end speech and talk over it, overlapping at least twice. | Both tracks active simultaneously for part of the take. |

## Device configurations

The plan's device matrix asks for built-in speakers/microphone and a USB microphone at minimum.
Record each scenario on each configuration and name the directory `<device>-<scenario>`:

| Directory | Playback | Microphone |
| --- | --- | --- |
| `builtin-far-end-only` | Built-in speakers | Built-in microphone |
| `builtin-near-end-only` | Built-in speakers | Built-in microphone |
| `builtin-double-talk` | Built-in speakers | Built-in microphone |
| `usb-far-end-only` | Built-in speakers | USB microphone — **not recorded, no USB microphone available** |
| `usb-near-end-only` | Built-in speakers | USB microphone — **not recorded, no USB microphone available** |
| `usb-double-talk` | Built-in speakers | USB microphone — **not recorded, no USB microphone available** |

The USB rows matter for more than coverage: the built-in microphone delivered 48 kHz mono, which is
the same rate as the system track, so these three fixtures do **not** exercise the rate-conversion
path. A USB microphone running at 44.1 kHz or 16 kHz would, and until one is recorded that path is
covered only by the synthetic `microphone-44k1` and `microphone-16k` cases.

## Layout of one fixture directory

```text
Tests/Fixtures/real/builtin-double-talk/
  system.wav        system audio as captured, 48 kHz stereo, 16-bit
  microphone.wav    microphone audio at its own native rate and channel count, 16-bit
  fixture.json      scenario, expectation, devices, resolved filter, formats, timing
```

`microphone.wav` deliberately keeps the device's native sample rate. ScreenCaptureKit delivers the
microphone in the device format regardless of the system-audio configuration, and a fixture that
quietly resampled it would hide exactly the case the timeline builder has to handle.

`fixture.json` carries the `capture-harness inspect` timing report for the take: each track's initial
presentation timestamp, delivered frames, timestamp-versus-sample drift, gaps, overlaps, and format
changes. `formatChangedMidTake` is true if the capture rotated segments because the format changed
partway through, which usually means the take should be redone.

## Size, and what is not committed

Committed files are 16-bit PCM WAV to match the synthetic suite and to stay readable without a codec.
At the default 15 seconds a fixture is 2.8 MB of stereo system audio plus 1.4 MB of mono microphone
audio — measured, not estimated. The three committed fixtures total about 12.6 MB; the full
six-directory matrix would be about 25 MB.

Three things are deliberately **not** committed:

- The float32 CAF originals and the full `timeline.jsonl` (hundreds of thousands of lines for a long
  take). They stay in the capture directory that `fixture.json` records as `rawCaptureDirectory`.
- Takes longer than about 20 seconds. Record those to an external location and reference them from a
  new row in this README rather than adding them here.
- Any recording containing a real meeting participant who has not agreed to it. These fixtures are
  recorded deliberately, by the person operating the machine, with material they are free to keep.

## Verifying a fixture

```sh
afinfo Tests/Fixtures/real/<id>/system.wav
python3 -c 'import json;d=json.load(open("Tests/Fixtures/real/<id>/fixture.json"));print(d["devices"], d["timing"]["tracks"])'
```

The `timing` block should show no gaps and no format changes for a usable fixture. A take with a gap
is still worth keeping if it is the only recording of that condition — but say so in this README.
