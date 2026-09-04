# timeline-harness

`timeline-harness` exercises [`TimelineBuilder`](../../Scribe/Processing/Sources/Processing/TimelineBuilder.swift)
against inputs whose correct reconstruction is known in advance, and produces the
evidence for the [implementation plan](../../IMPLEMENTATION_PLAN.md) section 8
timeline-correctness gate:

> At most one 10 ms processing block of residual alignment error in calibrated
> fixtures at start and end; no cumulative drift beyond that bound.

It has no dependencies beyond `Scribe/Processing` and Foundation.

## Run the gate

From the repository root:

```sh
sh Tools/TimelineHarness/run-timeline-gates.sh [work-directory]
```

That builds the harness and `Tools/AudioMetrics` in release, reconstructs every
case in `Tests/Fixtures/Generated`, scores each one, and exits non-zero if any
case misses the gate.

## What the synthesized sessions look like

A fixture is a set of WAV files, not a recording, so the harness writes a real
capture archive around it — CAF segments and a `capture/timeline.jsonl` journal in
exactly the shape `SessionStore` produces — and then asks the builder to
reconstruct it. The archive is deliberately shaped like the measurements in
[`docs/feasibility/capture-timing.md`](../../docs/feasibility/capture-timing.md)
rather than like an idealized recording:

| Property | Value | Why |
| --- | --- | --- |
| Session origin | 207 492.667875 s | Presentation timestamps sit on a host-uptime scale, where a `Double` has about 30 ns of resolution left. A builder that accumulated float error would show it here and not near zero. |
| System buffers | 960 frames, 48 kHz stereo | The measured `.audio` buffer size. |
| Microphone buffers | 512 frames, the fixture's own rate | The measured `.microphone` buffer size, which differs from the system track's. |
| Microphone start offset | one of the ten measured offsets, 0.123 s to 2.594 s | The microphone track was **always** late, never by the same amount. Code that aligned the two tracks by first sample, or subtracted a constant, would be wrong by up to 2.5 s. |
| Gaps | the sidecar's `gapIntervals`, with the samples removed from the archive | A gap is only a gap if it is journaled and the frames are genuinely absent. The builder is what puts the silence back. |
| Drift | the sidecar's `driftRatio`, injected into the archive | The archive is written with the drifted number of samples while the journal keeps true time — the shape a drifting capture device produces. |

## How each case is scored

Two outputs are written per case. `<case>-reconstructed-microphone.wav` is the
track exactly as the pipeline produces it, on the session grid with its leading
silence intact. `<case>-aligned-microphone.wav` is the same audio with that lead
removed.

The lead is checked *exactly*, as a frame count against the offset the session was
written with — a stronger check than a correlation, and one that does not depend on
finding a 2.6-second lead through silence. The alignment gate is then measured by
`audio-metrics` on the aligned copy, where the fixture's own time base applies.

Duration is scored as well, because a duration that no longer matches the source
track is exactly what uncorrected cumulative drift looks like. A silent fixture has
no signal to correlate, so its alignment windows come back `n/a` and the duration
check is what holds it to the gate.

## Current results

Every case reconstructs with **0.000 ms** of residual alignment error at both the
start and the end window, no growth between them, and an exactly preserved
microphone lead. The `sample-rate-drift` case is the informative one: 500 ppm of
capture-clock drift is injected, the builder measures 500.001 ppm by comparing
timestamp progression against sample counts, and gradual resampling of the
processing copy brings the 5 ms that would otherwise accumulate over ten seconds
down to 0.021 ms.

## Reconstructing a real session

```sh
swift run --package-path Tools/TimelineHarness timeline-harness session \
    --session "~/Meeting Recordings/2026-09-03 15-30-12" \
    --output /tmp/reconstructed
```

This prints the plan as JSON — origin, per-track first timestamps and leading
silence, runs, journaled gaps, measured drift with the reason it was or was not
corrected, and any diagnostics — and optionally writes each reconstructed track as
32-bit float WAV at 48 kHz.

## Scoring the echo and mixdown gates

The same harness drives `EchoCanceller` and `MixdownService` over every fixture and
scores the section 8 echo-reduction and local-speech gates:

```sh
sh Tools/TimelineHarness/run-mixdown-gates.sh
```

This runs `timeline-harness mixdown` over the synthetic suite and over the
real-room takes in `Tests/Fixtures/real`, then scores with `Tools/AudioMetrics`
and, for the real takes, by direct measurement. It writes the cleaned microphone
(before mix gain, which is where section 8 defines both gates) and the decoded
`final.flac` for every case, so the double-talk listening check has artefacts to
listen to. It exits non-zero if a case misses its gate.

Two things about the archives this command synthesizes are deliberate and worth
knowing before reading a result:

- The synthetic microphone starts at the session origin rather than behind it by
  one of the measured stream offsets. A fixture's `microphone.wav` *is* the echo
  of its `playback.wav` on a shared time base, so delaying its content would model
  a microphone that missed the opening of the meeting. Preserving a real per-track
  lead is the timeline gate's subject, and is measured there.
- The real-room microphone is placed at the offset `fixture.json` journaled,
  because those exported WAVs each start at their own stream's first sample and
  the real lead of 125–131 ms is wider than the whole delay search.

Current results are written up in
[`docs/feasibility/aec-results.md`](../../docs/feasibility/aec-results.md).
