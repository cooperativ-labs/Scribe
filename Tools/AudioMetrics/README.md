# audio-metrics

`audio-metrics` measures a processed microphone track against a synthetic fixture and its
`ground-truth.json` sidecar, and prints a machine-readable JSON report whose `gates` block maps
directly onto the [implementation plan](../../IMPLEMENTATION_PLAN.md) section 8 table. It has no
dependencies beyond the Swift standard library and Foundation, and reads 8/16/24/32-bit PCM and
32/64-bit float WAV files.

## Run

```sh
# Baseline: analyze a fixture's own (unprocessed) microphone track.
swift run --package-path Tools/AudioMetrics audio-metrics \
    --fixture Tests/Fixtures/Generated/far-end-only

# Analyze a processed output that carries a 20 ms processing delay.
swift run --package-path Tools/AudioMetrics audio-metrics \
    --fixture Tests/Fixtures/Generated/far-end-only \
    --processed /tmp/far-end-only-aec.wav \
    --processing-delay-ms 20 \
    --output /tmp/far-end-only.json \
    --fail-on-gate
```

The JSON report goes to stdout (or `--output`); a human-readable summary goes to stderr unless
`--quiet` is passed. `--fail-on-gate` exits 1 when an applicable gate fails, so the tool can sit
in a script. `--help` lists every flag, including the gate thresholds, the analysis block length,
the convergence window, and the lag-search width.

To regenerate baseline reports for the whole suite:

```sh
sh Tools/AudioMetrics/report-baselines.sh /tmp/baselines
```

## What it measures

All energy comparisons run at the processed file's own sample rate, on the channel average, after
shifting the processed signal by `--processing-delay-ms`. Reference tracks are resampled to that
rate. Analysis blocks default to 10 ms — the plan's processing-block size.

| Report field | Meaning |
| --- | --- |
| `farEnd` | Whether this fixture's echo path actually reaches the microphone, from the whole-file correlation of `echo.wav` with `microphone.wav`. Every case ships an echo track, but only some mix it in. |
| `regionSeconds` | Seconds classified as `far-end-only`, `near-end-only`, `double-talk`, `silent`, and `gap`. Near-end regions come from the sidecar; far-end activity comes from the echo track; documented gaps are excluded from every measurement. |
| `echoReduction.byRegion` | Per-block `10·log10(microphone energy / processed energy)`, summarized as median, mean, minimum, and 10th percentile. `far-end-only` is the plan's echo gate; `double-talk` is reported separately because suppression there is not the same measurement. |
| `echoReduction.farEndActive` | The same statistics pooled over every block where the far end is active. |
| `nearEnd` | Microphone and output levels over near-end-only blocks and the level change between them, plus the per-block median and worst case. |
| `alignment.{start,end}.timeline` | Lag of the processed output against the microphone in a one-second leading and trailing window, minus the stated processing delay. This is the plan's timeline-correctness gate. |
| `alignment.{start,end}.echoPath` | Measured playback-to-microphone delay against the sidecar's known delay for that window. `reliable` is false — and the gate is skipped — when the echo never reaches the microphone, near-end speech competes in the window, the playback reference is tonal (periodic, so its correlation peak is ambiguous by construction), or correlation is weak. |
| `duration` | Processed duration against the ground-truth duration and against the microphone track. |
| `peaks` | Per channel and overall: sample peak (dBFS), true peak (dBTP, 4x oversampled band-limited reconstruction), clipped sample count, clipped runs, and longest run. |
| `gates` | One entry per gate with `threshold`, `measured`, `applicable`, and `passed`. A gate with `applicable: false` is not scored — the fixture has no region to score it on. `allApplicableGatesPassed` and `failedGates` summarize the block. |

Measurements are skipped for the first `--convergence-seconds` after every reconvergence point:
the start of the file, each delay-segment boundary, and the end of each documented gap.

Fields with no measurement encode as explicit `null` rather than being omitted, so a test can
distinguish "not measurable here" from "the key is missing".

## Baselines

Running the tool with no `--processed` analyzes the fixture's own microphone track, which is the
unprocessed baseline: nothing was cancelled, so every reduction is exactly 0 dB and the output is
exactly aligned with its input.

| Fixture | Baseline result |
| --- | --- |
| `far-end-only` | 0.000 dB median far-end-only reduction over 664 blocks; timeline residual 0 samples at both windows; echo-path delay 1437 and 1440 samples against a known 1440. Only `echoEnergyReductionDb` fails, because nothing processed the file. |
| `double-talk` | 0.000 dB median over 900 far-end-active blocks. The fixture has no far-end-only region, so `echoEnergyReductionDb` is not applicable and every applicable gate passes. |
| `near-end-only` | Echo does not reach the microphone; 0.000 dB near-end level change. |
| `clipping` | 22 811 clipped samples and +0.33 dBTP: the clipping and true-peak gates fail by design. |
| `silence` | No measurable region; duration still matches. |

## Tests

```sh
swift test --package-path Tools/AudioMetrics
```

`SignalTests` check the primitives against constructed signals with answers known in advance: a
full-scale sine sits 3.01 dB below a full-scale square, a 0.1x gain is exactly 20 dB, a 137-sample
delay is recovered exactly, and a full-scale sine sampled between its peaks reads −3.01 dBFS but
0 dBTP. `AnalyzerTests` build fixtures in memory and assert exact answers for a 20 dB suppression,
a 0.5 dB near-end level change, a compensated 20 ms processing delay, gap exclusion, duration
mismatch, and clipping. `GeneratedFixtureBaselineTests` assert the baseline numbers above against
the checked-in fixture suite.
