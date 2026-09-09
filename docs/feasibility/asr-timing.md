# Parakeet v3 timing feasibility

Validated against the exact `FluidAudio` v0.15.6 source pinned by
`Workers/TranscriptionWorker/Package.resolved` (commit
`4dbf4f9f9a5ff3a53ade848d7ba4e3df13db859b`). The worker only uses local Core
ML bundles through `OfflineModelLoader`; it never calls FluidAudio download or
cache APIs.

The historical token-duration fix landed in v0.12.5. The production pin is now
v0.15.6, which retains that fix and adds long-form seam-gap repair, final-window
alignment, and merged token-order preservation. See [Token ends and
pauses](#token-ends-and-pauses) below and `docs/investigations/diarization-979.md`.

## Timing contract

`ASRResult.tokenTimings` contains `TokenTiming` records with `startTime` and
`endTime` in **source-media seconds**. Internally the TDT decoder first reports
encoder frame indices; `ASRConstants.samplesPerEncoderFrame` is 1,280 samples,
or 80 ms at the required 16 kHz. FluidAudio converts a frame index with
`TimeInterval(frameIndex) * 0.08` before exposing `TokenTiming`.

The adapter serializes those seconds unchanged. It rejects non-finite,
negative, reversed, or out-of-range timings rather than inventing replacement
times: a `startTime` past the end of the recording is the signature of a
chunk-rebasing bug and fails loudly. An `endTime` a frame or two past the end is
different — it is an ordinary consequence of `start + duration` on the last
tokens of a file — and is clamped to the source duration instead. A non-empty
transcript without token timings is likewise a structured adapter failure. This
leaves token-to-word reconciliation to the host-side stage with the original
evidence intact.

## Token ends and pauses

A token's `endTime` is `startTime + tokenDuration`, where the TDT decoder's
duration is a frame count from its duration bins (80 ms per frame, minimum one
frame). Durations are quantized: on a 58-minute two-person meeting, 15,363 of
15,369 tokens landed on 80, 160, 240 or 320 ms.

**This did not work in v0.12.4.** `TdtHypothesis.tokenDurations` was appended to
in exactly one place, `TdtDecoderV3.updateHypothesis`, which had no callers; the
two live emission sites never appended. Durations were therefore always empty —
on the short-file path as well as the chunked one — and `createTokenTimings`
fell through to its documented fallback of using *the next token's start* as the
current token's end. Every silence was consequently charged to the word that
preceded it. Upstream commit `289833a5` (v0.12.5) appends durations at both live
emission sites and carries a duration field through `ChunkProcessor`'s
`TokenWindow` tuple, its overlap matching, deduplication, midpoint fallback and
merge, into `processTranscriptionResult`.

The two releases decode identically. Re-running the investigated meeting on the
same prepared audio produced the same 15,369 tokens with the same ids and the
same start times; only the ends changed. The effect on host output:

| Metric | v0.12.4 | v0.12.5 |
| --- | ---: | ---: |
| Longest word | 16,640 ms | 1,920 ms |
| Words over 1 s | 440 | 32 |
| Adjacent word gaps ≥ 1 s | 0 | 169 |
| Words attributed to the unknown speaker | 833 | 661 |

Two residual limitations. Decoder durations are not forced alignment: 266 token
pairs overlap by up to one 320 ms bin, because a duration can run past the next
token's start. Attribution takes the strongest overlap per speaker so this is
tolerated, but it is not a guarantee of acoustic word bounds, and confirming
boundaries against reviewed excerpts or a VAD/alignment pass is still the only
way to make that claim. Second, the last-chunk finalization branch can emit an
unusually long duration; on the meeting above it produced two tokens of 1.52 s
and 1.60 s inside otherwise ordinary words. Both are bounded and neither is
worth a blanket clip: the longest words in that recording are genuine long words
such as "overpromising" and "subcontractors", which any global cap would
truncate.

## Tokens and punctuation

The pinned API exposes timed decoded vocabulary tokens, not words. Its
`normalizedTimingToken` normalizes tokenizer artifacts for display, but the
adapter does not join or drop token records. Punctuation can arrive as a timed
stand-alone token (for example `","` or `"!"`); host reconciliation must attach
it to the preceding lexical word without creating an empty word cue. The
adapter's test covers this preservation explicitly.

Punctuation contributes text and no acoustic extent. The decoder settles a
terminal mark at whatever frame it chooses, routinely after the speech it
closes, so `TokenTimingReconciler` takes a word's span from its lexical tokens
alone. Absorbing the mark's timing stretched sentence-final words across the
following pause; on the investigated meeting that single host-side change cut
the longest word from 16,640 ms to 5,280 ms even before the dependency moved.

## Long-file chunks and offsets

For a file above 240,000 samples (15 s), `AsrManager.transcribe(URL)` selects
the disk-backed `ChunkProcessor`. In this build it uses a frame-aligned 14.88 s
actual-audio window, 2.0 s overlap, and 80 ms left mel/encoder context on every
chunk after the first. The decoder receives `globalFrameOffset = chunkStart /
1280`; its emitted timestamps are therefore already absolute when chunks are
merged. Boundary tokens are merged only after matching token text plus timing,
with a midpoint fallback. The adapter does not add a second offset.

## Chosen runtime settings

The selected deployment setting is `cpuAndNeuralEngine`. The preprocessor is
CPU-bound in the pinned FluidAudio implementation; Parakeet encoder, decoder,
and joint models load as CPU+ANE. The manifest also records
`allowLowPrecisionAccumulationOnGPU: true`, although this has no effect for the
chosen non-GPU path. The library's batch API does not expose alternate
chunk-window or overlap sizes in v0.15.6, so the pinned, source-verified values
above are the supported settings to benchmark.

## Apple Silicon benchmark and stability check

The following local offline feasibility runs were performed on the available
arm64 Apple Silicon Mac running macOS 27.0. Fixtures were generated with local
macOS voices, converted to 16 kHz mono Float32 WAV, and are not committed.
`ASRBenchmark` was run under `/usr/bin/time -l`; RTFx uses FluidAudio's ASR
processing time, while peak RSS includes model load and Core ML runtime.

| Setting | Fixture | Audio | ASR time | RTFx | Peak RSS |
| --- | --- | ---: | ---: | ---: | ---: |
| CPU + ANE, low-GPU-precision flag on | English | 12.454 s | 0.279 s | 44.64x | 465.0 MB |
| CPU + ANE, low-GPU-precision flag on | German | 13.109 s | 0.303 s | 43.25x | 465.5 MB |
| CPU + ANE, fixed 14.88 s / 2.0 s-overlap chunks | English with leading context | 40.603 s | 0.732 s | 55.45x | 466.5 MB |
| CPU + GPU, low-GPU-precision flag on | English | 12.454 s | 0.918 s | 13.57x | 2.397 GB |

`cpuAndNeuralEngine` is selected: it was roughly 3.3x faster on the English
fixture and used about 1.9 GB less peak RSS than CPU+GPU. The low-precision
flag remains recorded for repeatability, but it has no effect on this selected
non-GPU path. FluidAudio v0.15.6 does not make model window or overlap public
configuration, so those values were verified and benchmarked as fixed pinned
runtime behavior rather than falsely presenting an unimplemented knob.

The English and German samples both produced non-empty timed token sequences;
all adapter-validated timings were finite, non-negative, ordered, and bounded
by source duration. The 40.603 s leading-context fixture crossed two chunk
boundaries. Its target suffix matched the no-context English transcription,
with 218 total tokens and no duplicate target passage, confirming that the
pinned absolute-offset and merge behavior is stable for this feasibility case.
