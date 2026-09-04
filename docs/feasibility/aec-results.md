# Offline AEC feasibility results

Measured on 2026-09-03 with the checked-in deterministic fixture suite. These
results are a feasibility result for Apple Silicon and the pinned WebRTC Audio
Processing Module 2.1 / WebRTC M131 bridge; they are not a claim about real
rooms or supported capture devices.

## Configuration

- 48 kHz, 480-frame (10 ms) `render,capture` schedule; stereo render (mono
  references are duplicated) and mono capture.
- AEC3 and its capture high-pass filter enabled; automatic gain control and
  noise suppression disabled.
- A one-second, bounded normalized cross-correlation estimate searches 0–120
  ms. It accepts only active windows with correlation at least 0.65 and a
  non-neighbouring peak margin of at least 0.10.
- An absent or uncertain estimate does **not** guess zero delay: the harness
  emits `uncertain-delay-bypass`, preserving the microphone and reporting that
  the result is not a cleaned AEC success.
- A fresh estimate is considered once per second. A confident movement of one
  10 ms block resets AEC3, updates the stream delay, and starts a new
  convergence interval. Reconstructed-timeline discontinuities can also be
  supplied explicitly with repeatable `--discontinuity-samples` flags.

The far-end-only calibration selected 1,437 samples (29.94 ms), which rounds
to the bridge's 30 ms / 1,440-sample API value. Its correlation was 0.874 and
the strongest independent competing peak was 0.350. This is deliberately
recorded as an estimate rather than treating AEC3's own windowed delay metric
as ground truth.

## Synthetic-fixture run

The following commands produced the harness output and section 8 metrics:

```sh
swift run --package-path Tools/AECHarness aec-harness \
  --reference Tests/Fixtures/Generated/far-end-only/playback.wav \
  --microphone Tests/Fixtures/Generated/far-end-only/microphone.wav \
  --output /tmp/far-end-only.cleaned.wav --report /tmp/far-end-only.aec.json
swift run --package-path Tools/AudioMetrics audio-metrics \
  --fixture Tests/Fixtures/Generated/far-end-only \
  --processed /tmp/far-end-only.cleaned.wav
```

| Fixture | Delay policy/result | Section 8 measurement |
| --- | --- | --- |
| far-end-only | Correlated estimate; processed | 62.82 dB median far-end echo-energy reduction after convergence |
| delay-change-mid-file | Initial 1,437-sample estimate; reset at 288,000 samples after a confident 2,878-sample estimate | 54.32 dB median far-end echo-energy reduction after the new convergence interval |
| sample-rate-drift | Ambiguous periodic correlation; safe bypass | 0.00 dB reduction; requires timeline drift correction before AEC |
| near-end-only | Weak correlation; safe bypass | −0.00003 dB near-end level change |
| double-talk | Weak correlation; safe bypass | 0.00001 dB microphone energy change; local speech is preserved by policy |
| clipping | Weak correlation; safe bypass | −0.00013 dB near-end level change; expected clipping gate remains failed on the source input |
| silence | Rejected as silence; safe bypass | No applicable speech/echo gate |
| documented-gaps | Weak correlation; safe bypass | 0.00007 dB double-talk energy change; source true-peak gate remains failed |
| asymmetric-stereo | Not run: the current bridge intentionally accepts mono capture only | Needs the timeline/downmix policy before this fixture can be processed |
| microphone-44k1, microphone-16k | Not run: harness requires the reconstructed 48 kHz timeline | Needs the upstream streaming resampler/timeline stage before processing |

For the three far-end-only fixtures that have a valid far-end-only measurement
(`far-end-only`, `delay-change-mid-file`, and `sample-rate-drift`), the median
echo-energy reduction is **54.32 dB** after convergence. This exceeds the 20 dB
section 8 gate, although the drift fixture is a conservative bypass rather
than an AEC success. Near-end-only change is effectively 0 dB, meeting the
less-than-1 dB gate. The double-talk fixture is likewise pass-through because
the estimator cannot prove a safe far-end-only calibration region; that is the
chosen preservation policy, not evidence that AEC3 has been validated under
double-talk suppression.

AudioMetrics also reports an end-window alignment failure on the two processed
fixtures despite their duration and echo-path-delay measurements being within
the gate. Its processed-versus-input correlation becomes weak after successful
suppression, so that particular residual-lag metric is not currently a useful
pass/fail signal for a cleaned far-end-only output. The raw timeline is not
moved by this harness; resolving this requires an alignment metric based on
the retained metadata/reference rather than matching a suppressed waveform.

## Real recordings and recommendation

No paired system-reference/microphone recordings from the capture-feasibility
work were present when this run was performed, so real-room validation,
listening checks, and device-specific claims remain deferred.

Recommended next configuration change: add the planned streaming timeline
normalizer (sample-rate conversion, mono downmix policy, drift correction, and
capture-gap metadata) before AEC. Then rerun the same metrics and real-room
recordings. Until a confident correlation window exists, retain the originals
and publish a clearly failed/uncertain processing state rather than a raw
doubled mix labelled as cleaned.

## Application pipeline results (2026-09-04)

The run above was the feasibility harness reading two WAVs. What follows is the
application path: `TimelineBuilder` reconstructs a capture archive, then
`Scribe/Processing`'s `EchoCanceller` and `MixdownService` cancel, mix and publish
`final.flac`. Reproduce with:

```sh
sh Tools/TimelineHarness/run-mixdown-gates.sh
```

### What changed since the harness run

**The pinned module delays the capture path by 430 frames (8.96 ms).** AEC3 is
usually described as time-aligned, and the harness assumed as much. Probing the
linked build — silence on render, a band-limited broadband probe on capture —
puts the correlation peak at lag 430 at 0.946, against −0.0005 at lag 0, with the
output level unchanged at −0.4 dB. It is a pure delay, and it is real. The
wrapper measures it at construction and removes exactly that many frames, which
is the only shift ever applied to the microphone. `ProcessingTests` pins the
figure so an upstream bump has to be looked at rather than silently moving the
user's speech 9 ms late against the system track it is mixed with.

**Delay estimation now uses the whole session, not a rolling window.** The
harness could only see one second at a time, which is why it bypassed
`double-talk`, `asymmetric-stereo` and `sample-rate-drift`. Offline, several
*disjoint* windows landing on the same lag is evidence no single window can
supply: local speech is uncorrelated with playback, so it cannot pull independent
windows onto one shared lag. A window that meets the harness's own bar
(correlation ≥ 0.65, peak margin ≥ 0.10) is still accepted on its own; otherwise
a cluster needs at least three non-overlapping windows and must be the session's
dominant answer. All eleven synthetic cases now reach a decision.

**Uncertainty splits three ways, not two.** A silent reference and a reference
that reaches nothing both pass the microphone through and publish normally — the
headphone case is not a failure. Only evident echo with an unestablished delay
fails the job, retains the originals and publishes nothing.

**A correlation peak needs a physically possible lag.** The synthetic
`near-end-only` fixture is defective for the local-speech gate: its "independent"
local speech is **0.590 correlated with the playback at lag 0**, because
`speechLikeSignal` builds both from the same deterministic 530 Hz and 1460 Hz
formant sinusoids with the same phrase envelope, and only the pitch differs. Any
competent canceller removes part of that, and an earlier revision of this
pipeline removed 9.3 dB of it. No acoustic path produces zero delay, so a peak
below a 2 ms floor is not an echo path; combined with requiring echo evidence in
more than one window, the fixture is now correctly read as having none. The
tonal-playback fixtures do not share this defect: `double-talk` measures −0.002.

### Synthetic suite

Echo reduction is measured on the cleaned microphone before mix gain; peak and
duration on the published `final.flac`.

| Fixture | Decision | Delay | Echo reduction | Near-end change | Mix true peak |
| --- | --- | --- | --- | --- | --- |
| far-end-only | cancel, single-window-confident | 1440 | **62.66 dB** | — | −6.82 dBTP |
| delay-change-mid-file | cancel, 2 segments | 1439 → | **55.48 dB** | — | −6.73 dBTP |
| sample-rate-drift | cancel, multi-window-agreement | 1293 | **34.88 dB** | — | −7.60 dBTP |
| near-end-only | no echo path detected | — | — | **0.0000 dB** | −1.56 dBTP |
| silence | no reference activity | — | — | — | — |
| double-talk | cancel, multi-window-agreement | 1294 | — | — | −2.91 dBTP |
| asymmetric-stereo | cancel, multi-window-agreement | 1294 | — | — | −3.50 dBTP |
| clipping | cancel, single-window-confident | 1441 | — | 3.09 dB | −1.00 dBTP |
| documented-gaps | cancel, multi-window-agreement | 1442 | — | 16.27 dB | −1.80 dBTP |
| microphone-44k1 | cancel, single-window-confident | 1443 | — | 3.75 dB | −3.05 dBTP |
| microphone-16k | cancel, single-window-confident | 1442 | — | 11.34 dB | −2.06 dBTP |

Median echo-energy reduction across the far-end-reaching cases is **55.48 dB**
against the 20 dB gate. `sample-rate-drift` is now a genuine cancellation rather
than the bypass recorded above, because the timeline stage removes the 500 ppm
clock mismatch before AEC sees it. Every published mix decodes, carries no
clipped samples, sits at or under −1 dBTP, and matches the reconstructed
timeline's duration exactly.

The near-end numbers in the last four rows are **not** gated, and should not be
read as speech damage. Section 8 places the 1 dB bound on *near-end-only*
fixtures; those four carry echo and local speech together, which makes them
double-talk cases that section 8 covers with listening checks. Their local speech
is also the 0.59-correlated signal described above, so a share of what is removed
is genuinely part of the reference. How large a share cannot be separated on
these fixtures, which is the strongest argument for the real-room takes below.

### Real-room recordings

MacBook Pro built-in speakers at system volume 63 and the built-in microphone,
macOS 27.0 (26A5425a), from [`Tests/Fixtures/real`](../../Tests/Fixtures/real).
Each exported WAV starts at its own stream's first sample, so the harness rebuilds
the archive at the offsets `fixture.json` journaled — the microphone was 125–131 ms
behind the system stream in these takes, which is more than the whole 120 ms delay
search. Placing both at the origin instead finds nothing, and did, until the
offsets were restored.

| Take | Decision | Delay | Microphone | Cleaned | Change | Reference correlation |
| --- | --- | --- | --- | --- | --- | --- |
| builtin-far-end-only | cancel, single-window-confident | 50.75 ms | −29.72 dBFS | −58.63 dBFS | **−28.91 dB** | +0.3931 → **+0.0118** |
| builtin-near-end-only | no reference activity | — | −39.04 dBFS | −39.04 dBFS | **0.00 dB** | — |
| builtin-double-talk | cancel, multi-window-agreement | 48.67 ms | −28.63 dBFS | −32.65 dBFS | −4.02 dB | +0.2885 → **+0.0013** |

The microphone in `builtin-far-end-only` contains echo and room noise only, so
its 28.91 dB drop is 28.91 dB of real-room echo reduction on built-in speakers —
over the 20 dB gate on real hardware, not only in synthesis. The two cancelling
takes were recorded on the same machine minutes apart and independently measured
delays 2 ms from each other, which is the corroboration a single number cannot
give. The real echo path is 50 ms, not the 30 ms of the synthetic fixtures.

`builtin-near-end-only` was recorded with the speakers idle, so its system track
is exact digital silence, the decision is "no reference activity", and the
microphone is returned untouched: **0.00 dB**, the local-speech gate met on a real
recording of real speech.

### Double-talk listening check

**Status: the listening itself has not been performed. It is a human step.** The
artefacts are written by the gate script; the last run left them at
`<work>/builtin-double-talk-cleaned-microphone.wav` and
`<work>/builtin-double-talk-final-mix.wav`. What is asked of a listener is
section 8's question: are any words lost where the operator spoke over the
playback?

What can be measured without ears, and was:

- Correlation with the system reference falls from **+0.2885 to +0.0013**, a
  factor of 222. Essentially no reference-correlated content survives, so the
  echo is gone rather than merely quieter.
- The cleaned track still sits at **−32.65 dBFS**, which is *louder* than the
  −39.04 dBFS of `builtin-near-end-only` — a take of the same operator speaking
  the same way into the same microphone with nothing playing. Removing all the
  reference-correlated content left more energy than a speech-only recording
  carries, so the near-end was not removed with it.
- Per-block: 456 of 1074 active 10 ms blocks are attenuated by more than 12 dB,
  the longest consecutive run being 800 ms. This number needs care and is *not*
  evidence of speech loss on its own. The playback was loud — the system track
  peaks at −4.2 dBFS and the echo alone reaches −13.4 dBFS in the far-end-only
  take, against −11.0 dBFS for the double-talk microphone — so the microphone is
  echo-dominated and most active blocks are echo the canceller is supposed to
  remove. An 800 ms run is consistent with the operator pausing between phrases.
  Separating "removed the echo" from "removed the speech" needs near-end ground
  truth this take does not have, which is exactly why section 8 asks for a
  listening check here rather than a threshold.

### Still outstanding

- The listening check above, by a person.
- A recording where the operator speaks *over* playback at a comparable level;
  the existing double-talk take is echo-dominated, which limits what it can show
  about speech preservation under a fair contest.
- USB microphone, wired headphones and Bluetooth takes. No USB microphone was
  available on the machine.
- A long capture. Every number here comes from takes of 15 seconds or less.
