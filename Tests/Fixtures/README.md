# Synthetic audio fixtures

`FixtureGenerator` creates deterministic WAV fixture directories for the audio-processing
tests. It uses only the Swift standard library/Foundation and writes 16-bit PCM WAV, so no
audio codec or package download is needed.

## Regenerate

From the repository root:

```sh
swift run --package-path Tests/Fixtures generate-audio-fixtures --output Tests/Fixtures/Generated
```

The default seed is `0x5C71BE5ED`; it is recorded in every `ground-truth.json` sidecar. The
generator accepts `--seed UINT64` (decimal or `0x` hexadecimal) and `--duration 10...60` for an
alternative deterministic suite. The checked-in/default suite is ten seconds per track, within
the validation plan's 10–60 second fixture limit.

For a byte-for-byte reproducibility check, run:

```sh
sh Tests/Fixtures/verify-fixtures.sh
```

The verification script regenerates the suite twice in temporary directories, compares every
output byte, and checks the case directory list. It deliberately does not compare a pre-existing
`Generated/` directory, allowing a clean checkout to run the check.

## Layout and ground truth

Every case directory contains:

- `playback.wav`: the known 48 kHz mono reference (speech-like or tonal)
- `echo.wav`: 48 kHz mono playback after the delayed/reverberant simulated path
- `local-speech.wav`: an independent 48 kHz mono local-speech source
- `microphone.wav`: the combined microphone signal. It is 48 kHz except for the explicitly
  named 44.1 kHz and 16 kHz cases; asymmetric stereo has two microphone channels.
- `ground-truth.json`: sample rates, delay (including delay-change segments), drift ratio,
  documented capture gaps, and near-end regions.

The suite implements the fixture paragraph in implementation-plan section 8: far-end only,
near-end only, double-talk, silence, mid-file delay change, sample-rate drift, clipping,
asymmetric stereo, 44.1 kHz microphone, 16 kHz microphone, and documented gaps. The source
signals are seeded but synthetic; they complement, rather than replace, the real-room recordings
called for by the plan.

## Measuring a processed output

[`Tools/AudioMetrics`](../../Tools/AudioMetrics/README.md) reads these fixtures and their
sidecars and reports the implementation-plan section 8 gates as JSON:

```sh
swift run --package-path Tools/AudioMetrics audio-metrics --fixture Tests/Fixtures/Generated/far-end-only
```

With no `--processed` file it analyzes the fixture's own microphone track, which is the
unprocessed baseline: zero echo reduction, zero near-end level change, and exact alignment.
