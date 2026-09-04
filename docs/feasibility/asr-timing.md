# Parakeet v3 timing feasibility

Validated against the exact `FluidAudio` v0.12.4 source pinned by
`Workers/TranscriptionWorker/Package.resolved` (commit
`9830ce835881c0d0d40f90aabfaae3a6da5bebfb`). The worker only uses local Core
ML bundles through `OfflineModelLoader`; it never calls FluidAudio download or
cache APIs.

## Timing contract

`ASRResult.tokenTimings` contains `TokenTiming` records with `startTime` and
`endTime` in **source-media seconds**. Internally the TDT decoder first reports
encoder frame indices; `ASRConstants.samplesPerEncoderFrame` is 1,280 samples,
or 80 ms at the required 16 kHz. FluidAudio converts a frame index with
`TimeInterval(frameIndex) * 0.08` before exposing `TokenTiming`.

The adapter serializes those seconds unchanged. It rejects non-finite,
negative, reversed, or source-duration-exceeding timings rather than inventing
replacement times. A non-empty transcript without token timings is likewise a
structured adapter failure. This leaves token-to-word reconciliation to the
host-side stage with the original evidence intact.

## Tokens and punctuation

The pinned API exposes timed decoded vocabulary tokens, not words. Its
`normalizedTimingToken` normalizes tokenizer artifacts for display, but the
adapter does not join or drop token records. Punctuation can arrive as a timed
stand-alone token (for example `","` or `"!"`); host reconciliation must attach
it to the preceding lexical word without creating an empty word cue. The
adapter's test covers this preservation explicitly.

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
chunk-window or overlap sizes in v0.12.4, so the pinned, source-verified values
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
non-GPU path. FluidAudio v0.12.4 does not make model window or overlap public
configuration, so those values were verified and benchmarked as fixed pinned
runtime behavior rather than falsely presenting an unimplemented knob.

The English and German samples both produced non-empty timed token sequences;
all adapter-validated timings were finite, non-negative, ordered, and bounded
by source duration. The 40.603 s leading-context fixture crossed two chunk
boundaries. Its target suffix matched the no-context English transcription,
with 218 total tokens and no duplicate target passage, confirming that the
pinned absolute-offset and merge behavior is stable for this feasibility case.
