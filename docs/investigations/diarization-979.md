# Meeting diarization investigation — coo:979

Investigated 2026-09-08. **Current decision: retain FluidAudio 0.15.6.** A verified fresh build fixes the original automatic collapse and reaches **91.257% matched-text reference agreement**, versus **94.304% for open-source SpeakerKit** with identical current ASR and host grouping. The earlier purported v0.15.6 collapse measurements are superseded because their executable provenance was not established. See the [combined evaluation and decision](diarization-979-evaluation.md) for corrected measurements, 16 controlled cases, excerpt-review gaps, and licensing/voiceprint assessment. No user meeting artifacts were changed.

**Status:** duration repair, speaker-count controls, the upstream upgrade, diagnostics, and paragraph grouping are shipped. No additional custom clustering change or alternative production integration is recommended from the available evidence. The sections below retain historical investigation details; the combined evaluation is authoritative for current behavior.

## Evidence and measurement limits

Inputs: meeting `817e841cbedcb1d46484bd9eaa4dca44`, run `221DEAC0-22A5-44C1-8B36-D9E5FE37593F`; Overlord attachment `24ab353b-f4d5-4c0f-9c33-b6fbc57f26ee` (MacWhisper speaker/text JSON). The recording is 3,487.171 seconds, mono, originally 48 kHz and prepared at 16 kHz. The supplied original `final.flac` has the same duration as prepared audio. Initial silence is expected, per the user; it is not evidence of lost speech or an offset bug. Experiments retain the full source timeline. Scribe's first recognized word starts at 67.84 seconds; this alone does not establish the first acoustic speech onset.

The saved canonical transcript is revision 29, with later edits. Therefore measurements replay the immutable `words.json` and `diarization.json`, not its edited speaker assignments. The comparison script reproduces `SpeakerTurnBuilder` attribution and `TranscriptDisplayGrouper` display-paragraph defaults, and also reports the older sentence-row grouping for comparison. A separate executable compiled from the actual Swift builder and transcript types confirmed the replay totals for the saved and exact-two runs.

The reference has 260 segments, speaker names and text, **no timestamps or word times**. Normalize both texts to lowercase Unicode word tokens, align with Python `SequenceMatcher(autojunk=False)`, and score only exact matched tokens. There are 9,285 matched tokens out of 9,650 Scribe tokens and 9,543 reference tokens (96.2% and 97.3% coverage). Choose the globally best one-to-one speaker-label mapping; unknown labels remain disagreements. This measures **reference agreement, not audio-annotated DER or WDER**, and excludes unmatched words. Repeated phrases can align imperfectly. MacWhisper is a useful comparison, not infallible ground truth: its first block itself combines the greeting exchange under one speaker. Names in edited Scribe output are not used to select the label mapping.

| Replay | Correct reference speaker | Wrong speaker | Unknown | Segments | Single-word segments |
|---|---:|---:|---:|---:|---:|
| Saved automatic run | 51.06% | 40.79% | 8.15% | 1,447 | 577 |
| Fresh automatic control | 51.06% | 40.79% | 8.15% | 1,447 | 577 |
| Fresh exact-two run | **89.66%** | **1.95%** | 8.39% | 1,464 | 586 |
| Exact-two + diagnostic 320 ms attribution window | 92.00% | 2.04% | 5.97% | 1,160 | 383 |

The 320 ms experiment limits only the interval used for assigning a speaker, retaining original output word times. It is an intentionally crude sensitivity check, **not a proposed duration correction or a validated production threshold**. It reduces unknowns but slightly increases wrong-speaker assignments. Count fixing alone does not improve grouping.

Aggregate, transcript-free data: [saved run](diarization-979/saved-run-metrics.json), [automatic control](diarization-979/automatic-control-metrics.json), [exact two](diarization-979/exact-two-metrics.json).

## 1. Automatic clustering collapses the two voices

The saved and fresh automatic outputs both contain 582 intervals: 577 for one cluster (2,684.736 summed seconds) and five for the other (7.046 seconds). These are summed interval durations, not exclusive speaking-time measurements. The dominant cluster contains thousands of reference words from **each** person. This is a diarization failure before transcript assembly or identity matching.

Fresh local benchmark logs provide a narrower diagnosis:

- Automatic AHC warm start: 10 clusters, with 5,103 of 5,232 embeddings in one cluster.
- VBx largest mixture weight: 0.97819. Reconstruction uses three centroids with embedding assignment counts 5,098, 121 and 13, then emits only two speaker labels in speech intervals.
- Exact-two run: same 5,232 embeddings; log explicitly reports re-clustering from 10 to two, with balanced assignments 2,608 and 2,624. Final intervals: 321 and 269; summed durations 1,261.155 and 1,419.116 seconds.
- Wall time: 72.24 seconds automatic, 76.09 seconds exact-two, using the existing local benchmark executable, installed model bundles and pinned manifest. These are single-run measurements, not performance guarantees.

The original investigation used FluidAudio 0.12.4 defaults and `withSpeakers(exactly:)`. In that version, `VBxClustering.refineWithConstraints` first runs VBx, then invokes **K-means on the original speaker embeddings** when its reported cluster count violates the constraint. `OfflineDiarizerManager.computeCentroids` takes those K-means centroids directly. Thus the experiment changes the effective clustering path; it does not prove a small change to VBx's speaker-count estimate alone would fix this.

A further investigation target: extraction reports 3,832 fallback masks out of 5,232, and training selection filters nonfinite vectors only. `OfflineEmbeddingExtractor` falls back from clean nonoverlapping speech to the base mask when clean support is short; it does not reject all short-support embeddings. Audit whether low-support/overlap-contaminated embeddings dominate clustering. This is a hypothesis, not a proven cause. The successful K-means run demonstrates useful voice separation remains in these embeddings.

Relevant source: `Workers/TranscriptionWorker/Sources/TranscriptionWorkerSupport/OfflineDiarizationAdapter.swift`; pinned FluidAudio `Diarizer/Offline/Core/OfflineDiarizerManager.swift`, `Clustering/VBxClustering.swift`, `Extraction/OfflineEmbeddingExtractor.swift`.

### Superseded v0.15.6 audit — historical, not current-engine evidence

**Correction from objective pmft:** the following audit used artifacts without executable provenance and is invalidated as a claim about the current pin. A verified 0.15.6 rebuild produces 606 intervals split 331/275, 1,834 embeddings with zero fallback masks, and 91.257% current matched-text agreement in both automatic and exact-two modes. See the [replacement evaluation](diarization-979-evaluation.md). The old collapse-based recommendations below are preserved only as investigation history; the representation-versioning rationale still applies.

The upgraded v0.15.6 stack reproduces the automatic failure on the same source: 582 intervals, split 577/5 and 2,684.736/7.046 summed seconds. The run took 75.61 seconds wall clock. The segmentation/extraction log is also unchanged at the level relevant to the earlier hypothesis: 5,232 embeddings and 3,832 fallback masks (73.24%). v0.15.6 already rejects a clean mask with less than 20% frame support before choosing between the clean and base masks; nevertheless all 5,232 masks survive here. That supported low-support filter therefore does not fix this recording, and the public result does not expose enough mask support detail to validate a stronger threshold without modifying FluidAudio. Aggregate evidence: [v0.15.6 automatic](diarization-979/v0.15.6-automatic-metrics.json).

More importantly, the old exact-two fallback result does **not** carry forward. On v0.15.6, exact-two produces 581 intervals split 576/5 and 2,683.021/8.761 seconds. Against the same matched-text proxy it reaches 51.15% agreement, 40.70% wrong speaker and 8.15% unknown — essentially the collapsed automatic result, not v0.12.4's 89.66%. The v0.15.6 log shows why: after the same 10-cluster AHC warm start and 0.9782 dominant VBx mixture, its deterministic best-of-ten K-means adjustment assigns 5,096/136 embeddings. The older implementation used a single random initialization and happened to yield the balanced 2,608/2,624 control. Choosing an old lucky seed or vendoring a private clustering implementation would not be a supported general fix. Aggregate evidence: [v0.15.6 exact two](diarization-979/v0.15.6-exact-two-metrics.json).

The audit also found that v0.15.6 changed the AHC threshold from a cosine-similarity conversion to a direct Euclidean dendrogram cut, added constrained co-chunk assignment for unconstrained runs, fixed the embedding mask-matrix transpose, and added the 20% clean-support rejection above. Those are material algorithm changes. A threshold/profile tweak cannot be accepted from one two-person reference, especially after the constrained K-means control regressed; the same values could split one speaker or erase a low-occupancy third/fourth speaker elsewhere.

Validation coverage is limited explicitly:

- One real two-person meeting has the timestamp-free MacWhisper proxy used above.
- Three other real recordings are available locally, but they have no human speaker-count or speaker-turn annotations; they can exercise runtime/occupancy reporting, not speaker accuracy.
- No annotated real three- or four-person recording is available. The existing generated four-voice fixture remains a pipeline contract only and is not substituted for human accuracy evidence.

Accordingly, production retains FluidAudio automatic clustering unchanged. New run artifacts record the exact FluidAudio and diarization-model revisions, applied AHC/VBx/extraction configuration, cluster occupancy from supported public chunk assignments, interval occupancy and overlap count. `dominant-occupancy-v1` flags only when at least two clusters exist, one owns at least 95% of chunk embeddings and at least 98% of summed interval time. This is a review signal, never an inferred speaker count: genuine monologues can be imbalanced. Canonical transcripts preserve the diagnostics and surface a warning that offers label review or a new known-count reprocessing run instead of silently assuming two speakers. With v0.15.6, manual review is the only demonstrated fallback for this meeting until a supported clustering fix is validated on annotated multi-party recordings.

The embedding compatibility tuple is now `fluidaudio-offline-fbank-16khz-mono-v0.15.6`. Keeping `v0.12.4` would be false compatibility because the transpose and support-filter changes alter vector semantics despite unchanged WeSpeaker weights. Existing enrolled vectors remain stored but are intentionally excluded from automatic comparison until re-enrolled with the current extractor.

## 2. ASR loses durations and hides pauses — **fixed**

Confirmed source chain in the previously pinned FluidAudio v0.12.4:

1. `ASR/ChunkProcessor.swift` merges token, timestamp and confidence, then calls `processTranscriptionResult` **without token durations**.
2. `ASR/AsrTranscription.swift` defaults durations to an empty array. `createTokenTimings` then uses the next token's start as the current token's end.
3. Scribe's `ParakeetAdapter` preserves these times. `TokenTimingReconciler.joinWords` also absorbs punctuation-token timing into the preceding word.
4. `SpeakerTurnBuilder` requires at least 50 ms and 50% of the entire word interval to overlap a speaker. A trailing pause inflates that denominator, causing otherwise recognizable words to become unknown. Its one-second pause-split rule has little useful input when pauses have already been swallowed.

Observed: 440 words exceed one second; a `you.` spans 81.12–97.76 seconds (16.64 s); **zero adjacent word gaps reach one second** across the meeting. The original replay assigns 833 words to unknown. These are structurally valid times, so `words.json` has no timing warnings. Syntactic timestamp validity is insufficient to establish acoustic accuracy.

The defect is in fact broader than step 1 states. `TdtHypothesis.tokenDurations` was appended to in only one place, `TdtDecoderV3.updateHypothesis`, which **has no callers** in v0.12.4; the two live emission sites never appended. Durations were therefore empty on the short-file path as well, and the chunk merge is only where that becomes visible in long recordings.

### What shipped

The pin moved to **FluidAudio v0.12.5** (`2d2979486bd7125558fe783741ef9a2757b3c1bb`), which carries upstream `289833a5`: durations are appended at both live emission sites and carried through `ChunkProcessor`'s `TokenWindow` tuple, overlap matching, deduplication, midpoint fallback and merge. This is a verified upstream fix on an exact pin, not a patched build checkout. The offline diarization tree is byte-identical between the two tags apart from a removed deprecated alias, so this changes nothing about section 1, and enrolled voiceprints and `preprocessingVersion` stay valid.

Separately, `TokenTimingReconciler` now treats punctuation as text with no acoustic extent. That is an independent host-side defect: the decoder settles a terminal mark wherever it likes, and absorbing its timing stretched sentence-final words across the following pause.

Re-running the same prepared audio produced the **same 15,369 tokens with the same ids and the same start times**; only token ends changed.

| Metric | Original | Punctuation fix only | Both fixes |
|---|---:|---:|---:|
| Longest word | 16,640 ms | 5,280 ms | **1,920 ms** |
| Words over 1 s | 440 | 313 | **32** |
| Adjacent word gaps ≥ 1 s | 0 | 36 | **169** |
| Unknown words | 833 | 787 | **661** |
| Segments | 1,447 | 1,396 | **1,287** |
| Single-word segments | 577 | 528 | **477** |
| Exact-two reference agreement | 89.66% | 90.10% | **91.35%** |

The `you.` that spanned 16.64 s is now 160 ms. Aggregate, transcript-free data: [repaired, automatic](diarization-979/repaired-durations-automatic-metrics.json), [repaired, exact two](diarization-979/repaired-durations-exact-two-metrics.json), [punctuation fix only, exact two](diarization-979/punctuation-only-exact-two-metrics.json).

Under **automatic** clustering the agreement stays at 51.79% and wrong-speaker assignments rise slightly, from 40.79% to 41.80%. That is the expected result, not a regression from this work: sharper word bounds land more confidently inside the collapsed dominant cluster of section 1. Timing repair cannot fix clustering.

The diagnostic 320 ms attribution window was **not** shipped, and the repaired data shows why: the longest remaining words are genuine long words such as `overpromising` (1,920 ms) and `subcontractors` (1,520 ms), which a global cap would truncate.

### Remaining decoder-timing limitations

Decoder durations are quantized to the TDT duration bins — 15,363 of 15,369 tokens land on 80, 160, 240 or 320 ms — and are **not forced alignment**:

- 266 token pairs overlap, by up to one 320 ms bin, because a duration can run past the next token's start. Attribution takes the strongest overlap per speaker, so this is tolerated rather than corrected.
- The last-chunk finalization branch can emit an unusually long duration; this recording produced two, 1.52 s and 1.60 s, inside otherwise ordinary words.

Neither is worth a global clip. Establishing true acoustic word bounds needs either manual review of excerpts or a VAD/forced-alignment pass; that is not claimed here. Objective `pmft` should annotate representative excerpts before treating these boundaries as ground truth.

Relevant Scribe files: `ParakeetAdapter.swift`, `TokenTimingReconciler.swift`, `SpeakerTurnBuilder.swift`; regressions in `Modules/Transcription/Tests/TranscriptionTests/TokenDurationPauseRegressionTests.swift`.

## 3. Presentation segmentation differs independently — **shipped**

Scribe previously emitted a new canonical segment after every final `.?!`, every speaker/unknown transition, a one-second gap, or 30 seconds of elapsed segment time. The saved replay has median **three words** per segment and 577 single-word fragments. MacWhisper has 260 blocks and can include several sentences in a same-speaker block. Its export does not reveal the exact grouping algorithm or boundary times.

Display grouping is now a separate pass from word-speaker attribution, and subtitle cues remain a later independent pass over the canonical paragraphs (`SubtitleCueBuilder`). Attribution still writes per-word `wordAssignments`. Canonical `segments` are readable same-speaker paragraphs:

- Hard splits: speaker change, known↔unknown, a pause of at least 1 s, 30 s or 80 words.
- Known-speaker punctuation is a preferred break after 12 s or 40 words, not a mandatory new row.
- Unknown sentence boundaries stay split: `nil == nil` is not evidence that two unknown sentences were the same person. Contiguous unknown fragments inside a sentence may still group.
- Short acknowledgments from another speaker, overlap flags, word timings, split/merge editing, and TXT/SRT export contracts are unchanged. A long paragraph still becomes several subtitle cues.

Measured by replaying the original saved `words.json` / `diarization.json` (duration-loss timings, automatic clustering, not revision-29 edits). Aggregate: [display grouping](diarization-979/display-grouping-metrics.json).

| Replay | Segments | Single-word | Median words | Known-speaker segments | Known median words |
|---|---:|---:|---:|---:|---:|
| Original sentence rows | 1,447 | 577 | 3 | 832 | 9 |
| Display paragraphs | **1,136** | 498 | 2 | **521** | **13** |
| MacWhisper blocks (diagnostic) | 260 | — | — | — | — |

The overall median falls because 833 duration-loss unknown words stay fragmented on purpose (615 unknown rows, 485 of them one word). On attributed speech the change is the intended one: known-speaker rows drop from 832 to 521, single-word known rows from 92 to 13, and median words per known paragraph from 9 to 13. That is not MacWhisper's 260 blocks, and it is not supposed to be: this replay still swallows pauses and collapses clustering. Pause-aware grouping will do more work on duration-repaired words (169 adjacent gaps ≥ 1 s in the repaired exact-two metrics). The user's saved meeting is untouched at revision 29, 1,447 segments.

Relevant files: `TranscriptDisplayGrouper.swift`, `SpeakerTurnBuilder.swift`, `SubtitleCueBuilder.swift`; regressions in `TranscriptDisplayGroupingTests.swift`. `compare.py` now reports both display paragraphs and legacy sentence rows.

## Recommended execution order

1. ~~**Expose the already-supported known speaker count**~~ — done, in import/reprocess controls and carry it into recorder handoff preferences. This run used `speakerCount: automatic`; the request/worker plumbing already supports a known count, but source search found no UI control setting it. Offer re-diarization with two for this meeting in a **new run**, preserving revision-29 edits. Do not infer a guaranteed count from calendar invitees or force two globally.
2. ~~**Repair long-file token durations**~~ — done. The pin moved to FluidAudio v0.12.5 for upstream `289833a5`, and punctuation no longer contributes acoustic extent. All five regression cases are covered; source offsets and the expected opening silence are unchanged (first word still starts at 67.84 s).
3. **Current upstream upgrade validated; earlier collapse audit superseded.** A fresh verified v0.15.6 build separates both voices. Retain the pinned algorithm, diagnostics, and warning. Further accuracy work needs annotated real multi-party coverage, not a custom threshold based on invalidated artifacts.
4. ~~**Improve paragraph grouping**~~ — done. Display paragraphs are grouped independently of attribution and of subtitle cues. Known-speaker rows on the original replay fall from 832 to 521 (median 9 to 13 words) without merging across unknown sentence boundaries. MacWhisper's 260 blocks remain a diagnostic baseline, not a duplicated algorithm.
5. **Alternative benchmark complete.** Open-source SpeakerKit was compared on identical audio/ASR/host grouping; see the [decision](diarization-979-evaluation.md). Retain FluidAudio now. SpeakerKit's development-recording advantage is a candidate for future reviewed integration, not evidence that it is the exact MacWhisper engine or that current enrolled voiceprints are compatible.

Primary external references, checked 2026-09-08: [Argmax SpeakerKit](https://www.argmaxinc.com/blog/speakerkit), [Argmax model catalog](https://app.argmaxinc.com/docs/models), [FluidAudio source](https://github.com/FluidInference/FluidAudio/tree/v0.12.4). Exact behavior above was inspected in the local pinned checkout, rather than inferred from current upstream documentation.

## FluidAudio 0.15.6 compatibility audit

The worker now pins the official [FluidAudio v0.15.6 release](https://github.com/FluidInference/FluidAudio/releases/tag/v0.15.6), revision `4dbf4f9f9a5ff3a53ade848d7ba4e3df13db859b`. The release retains the staged Parakeet v3 and offline diarization model filenames, the exact-speaker-count configuration, overlap-preserving post-processing, and the `OfflineDiarizerManager.process(audioSource:audioLoadingSeconds:)` path used here.

The ASR adapter was migrated to v0.15.6's actor-based API: it calls `loadModels`, creates a `TdtDecoderState`, and passes that state to `transcribe(_:decoderState:)`. The diarization adapter uses v0.15.6's `AudioSourceFactory` replacement for `StreamingAudioSourceFactory`; model initialization and the offline diarizer configuration remain compatible. Runtime downloads and telemetry remain disabled.

Compatibility was checked by building the worker against the official v0.15.6 source and binary artifact, then running the focused worker contracts for the pinned handshake, local-only manifest, ASR token timing, and offline diarization. The earlier compatibility note was too weak: v0.15.6's mask transpose and support-selection changes mean the embedding representation must be versioned even though model weights are unchanged. Existing v0.12.4 voiceprints are retained but deliberately do not match v0.15.6 vectors; re-enrollment is required before automatic identity matching resumes for those profiles.

## Reproduction

**Use the [current reproduction instructions](../../Tools/DiarizationAnalysis/README.md).** The commands below are historical examples. Always rebuild an isolated executable and record its hash; an existing default build-folder executable can predate the current package pin.

Run locally; raw audio, transcripts and voice embeddings are not committed:

```sh
python3 Tools/DiarizationAnalysis/compare.py /path/to/run /path/to/macwhisper.json
Workers/TranscriptionWorker/.build/out/Products/Debug/DiarizationBenchmark \
  --audio /path/to/run/prepared.wav \
  --manifest Workers/TranscriptionWorker/model_manifest.json \
  --models "$HOME/Library/Application Support/Scribe/Models" \
  --known-speaker-count 2 > /tmp/exact-two.json
python3 Tools/DiarizationAnalysis/compare.py /path/to/run /path/to/macwhisper.json \
  --diarization /tmp/exact-two.json
```

Omit `--known-speaker-count 2` for the automatic control. Core ML and macOS temporary-file access are needed.

The benchmark also accepts `--clustering-threshold`, `--embedding-exclude-overlap`, `--minimum-embedding-duration`, and `--segmentation-step-ratio`. Its JSON includes the applied values and the same structured occupancy diagnostics written by the production worker, so candidate configurations can be reproduced without editing a dependency checkout.

To re-measure ASR timing after the v0.15.6 pin, produce a fresh worker transcript and replay the host reconciler over it:

```sh
Workers/TranscriptionWorker/.build/debug/ASRBenchmark \
  --audio /path/to/run/prepared.wav \
  --manifest Workers/TranscriptionWorker/model_manifest.json \
  --models "$HOME/Library/Application Support/Scribe/Models" \
  --compute-units cpuAndNeuralEngine \
  --tokens-json /tmp/transcript.json
```

`--tokens-json` writes the same shape a run's `transcript.json` holds, and the benchmark's `tokenDurationMs` summary reports median/maximum token duration and the count of gaps over a second — the fastest check that durations survived. Reconciling it into a `words.json` for `compare.py` uses `TokenTimingReconciler` directly; that replay harness is scratch tooling and is not committed. The comparison script expects this worker's complete word timings and a small speaker set; it is an investigation utility, not a general diarization benchmark. Actual Swift replay confirmed 1,447/833/577 segments/unknown words/single-word segments for automatic and 1,464/859/586 for exact-two. Both inference runs completed successfully and the automatic control reproduced the saved aggregate metrics. The original investigation contained no production fix; the timing fix recorded under section 2 was made afterwards, and its measurements use the same replay method and the same reference-agreement caveats. No formal human-annotated accuracy claim is made anywhere in this document.
