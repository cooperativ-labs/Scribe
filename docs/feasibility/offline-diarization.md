# Offline diarization and speaker-embedding feasibility

The worker uses FluidAudio **v0.17.4**'s `OfflineDiarizerManager` over one complete recording. It manually initializes `OfflineDiarizerModels` from the staged Core ML bundles, so it does not call `prepareModels()` or any download/cache helper. The adapter converts every source through `AudioSourceFactory.makeDiskBackedSource`; decoding produces a temporary 16 kHz mono mmap-backed PCM file rather than retaining a full waveform in the Swift heap. This is the selected two-hour-file memory strategy.

`OfflineDiarizationAdapter.Configuration.knownSpeakerCount` maps to the pinned API's `OfflineDiarizerConfig.withSpeakers(exactly:)`, constraining its one global VBx clustering pass. `maximumSpeakerCount` maps to `clustering.maxSpeakers` and lets the pipeline select fewer speakers. Exact and maximum counts are mutually exclusive. With neither count, the pipeline chooses the count. The adapter sets `postProcessing.exclusiveSegments` to `false` by default. In this pinned build, that preserves concurrent `TimedSpeakerSegment` intervals; setting it to `true` trims later intervals and is therefore not suitable for the canonical transcript.

Raw FluidAudio cluster IDs are mapped to `speaker_1`, `speaker_2`, and so on in timestamp order, making identifiers stable within the produced recording. They are deliberately not reused between recordings. Each result also emits one L2-normalized global vector per local speaker from `DiarizationResult.speakerDatabase`.

## Post-processing controls

The adapter and benchmark expose `minimumGapDurationSeconds` (`--minimum-gap-duration`, default 0.1 s) and `minimumSegmentDurationSeconds` (`--minimum-segment-duration`, default 0 s). The former maps directly to `postProcessing.minGapDurationSeconds`. **There is no separate minimum-duration field in the pinned `PostProcessing` type**: the latter maps to `segmentation.minDurationOn`. Reconstruction takes the maximum of that value and `embedding.minSegmentDurationSeconds` (default 1 s), so values below 1 s do not lower the final segment floor. Both controls reject negative or nonfinite values. Overlapping intervals remain enabled and clustering threshold stays 0.6.

Use `--maximum-speaker-count N` to benchmark the same "up to N" constraint offered in the reprocess menu and confirmation sheet. It is distinct from `--known-speaker-count N`, which requests exactly N. The request persists a ceiling as `{"upTo": N}` while old integer exact counts and `"automatic"` still decode. Fingerprints and canonical processing options distinguish all three modes.

## Embedding compatibility contract

Every exported vector records all values that must match before a future speaker-library matcher compares it:

- `modelID`: `wespeaker-embedding-coreml`
- `modelRevision`: the pinned `wespeaker-embeddings` asset revision from `model_manifest.json`
- `preprocessingVersion`: `fluidaudio-offline-fbank-16khz-mono-v0.15.6`
- `normalizationVersion`: `l2-unit-v1`

`preprocessingVersion` was bumped for v0.15.6 because FluidAudio fixed the
speaker-mask matrix transpose and changed low-support mask selection. Those
operations change the vector representation even though the WeSpeaker model
weights are unchanged. Existing v0.12.4 signatures remain stored but are
incompatible by design and require re-enrollment before automatic matching.

The v0.15.6 (`4dbf4f9f9a5ff3a53ade848d7ba4e3df13db859b`) to v0.15.7 (`41540ea237350afe5117a082b5c28eda642d0612`) source audit found only three changed offline production files: `VBxClustering.swift` fixes speaker constraints by checking both assigned and active cluster counts; `OfflineDiarizerManager.swift` introduces structured task cancellation, factors assignment into a testable helper, and adds an OS advisory; `OfflineDiarizerModels.swift` adds comments. `OfflineEmbeddingExtractor`, segmentation, reconstruction, filterbank, PLDA transforms, model assets, and normalization are unchanged. Scribe's enrollment extractor still runs the same adapter with exactly one speaker. Constrained clustering can change which samples form a centroid, but the vector representation is unchanged: **retain the v0.15.6 preprocessing version**, with no re-enrollment for this upgrade.

The vectors originate from FluidAudio's result speaker database and are normalized again by the worker because the pinned reconstruction averages per-segment centroids without a final L2 normalization. The runner refuses an empty or incompatible exported representation rather than silently emitting a zero vector.

To measure cross-recording consistency, run the same known speaker in at least two disjoint recordings and compare only these compatible normalized vectors with cosine similarity. The expected result is that each same-person pair scores above every different-person pair in the fixture set; otherwise enrollment must extract embeddings from confirmed clean excerpts with this identical conversion/preprocessing stack. `DiarizationBenchmark` emits the exact vector metadata and can be run under `/usr/bin/time -l` for peak RSS:

```sh
swift run DiarizationBenchmark --audio sample.wav --manifest model_manifest.json --models models --known-speaker-count 2
```

## Historical measurements on the validation Mac

These synthetic measurements predate the 0.15.7 upgrade; they were not rerun as part of phase 5. See [phase 5](../investigations/diarization-1004-plan.md#phase-5--fluidaudio-0157-and-post-processing-sweep) for the new recording sweep and executable hashes.

`DiarizationBenchmark` was run with the staged bundle on arm64 Apple Silicon, macOS 27.0. A 51.1255-second alternating two-voice fixture with an exact count of two produced the expected chronological `speaker_1 → speaker_2 → speaker_1 → speaker_2` pattern. Inference took 1.549 seconds after loading and peak RSS was 469,876,736 bytes. A 101.3049-second four-voice synthetic stress fixture with an exact count of four produced seven intervals covering all four local speaker IDs and four versioned embeddings; inference took 2.594 seconds and peak RSS was 469,942,272 bytes. Both runs used disk-backed audio.

Two disjoint local-synthesis recordings of the same two voices were also exported with the same representation metadata. Their cosine scores were 0.880 and 0.928 for the same voice, versus 0.267 and 0.230 for cross-voice comparisons. This confirms that the exported normalized representation is usable for a compatibility-gated speaker-library matcher, but it is not an identity-calibration result; consented, held-out human speech remains required before setting an automatic-match threshold.

A 7,200-second 16 kHz mono Float32 looped-speech source was staged as 451,122,376 bytes of disk-backed PCM. The pinned pipeline completed conversion and model initialization but did not finish inside the available validation run, so no two-hour peak-RSS number is claimed. Keep the disk-backed source path mandatory and repeat this profile with consented long-form speech under a dedicated process monitor before release.

## FluidAudio 0.17.4 upgrade

The offline VBx implementation and embedding extractor are source-identical to
v0.15.7. Keep the v0.15.6 preprocessing identifier and existing voiceprints.
The frozen CAB recording produces identical diarization intervals and ASR token
records. See [upgrade validation](../investigations/fluidaudio-017-upgrade.md)
for the exact revision, offline checks, and validation limits.
