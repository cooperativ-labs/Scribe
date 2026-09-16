# Short-turn retention — coo:1016.x1nn

This experiment separates final output retention from embedding extraction using
the **public API of pinned FluidAudio 0.15.7**, revision
`41540ea237350afe5117a082b5c28eda642d0612`. No dependency upgrade, SDK patch,
production transcription change or default promotion is made.

## Source audit and adapter

Paths below are relative to `Sources/FluidAudio` at the pinned revision:

- `Diarizer/Offline/Core/OfflineDiarizerTypes.swift`: the compatibility property
  `minSegmentDuration` aliases `embedding.minSegmentDurationSeconds`. The
  `PostProcessing` type has gap/exclusivity controls but no output duration.
- `Diarizer/Offline/Extraction/OfflineEmbeddingExtractor.swift:385`: required
  nominal embedding support is `ceil(minSegmentDuration / frameDuration)`, at
  least one frame. At lines 518–534, a separate **20% clean-mask support gate**
  first rejects weak masks; the duration threshold then selects the clean mask
  versus fallback base mask. Lowering it can change that selection, rather than
  simply accepting every shorter span. For full default 10 s windows, the 20%
  gate implies roughly 2 s of support and dominates both 1 s and 0.5 s. This
  explains why those settings can produce identical embeddings here. These are
  heuristic support rules, not proof that every longer embedding is reliable.
- `Diarizer/Offline/Utils/OfflineReconstruction.swift:483`: after merging,
  `sanitize` filters at the maximum of embedding and segmentation-on duration.
  Exclusive trimming also applies the embedding floor. Lowering
  `segmentation.minDurationOn` alone cannot bypass the default 1 s floor.
- `Diarizer/Offline/Core/OfflineDiarizerManager.swift:201` and `:335`: public
  `prepare(audioSource:)` returns a reusable `PreparedDiarization`, and another
  initialized manager may call `cluster(_:)` using its own configuration.
  Clustering uses cached embeddings and does not consult the duration floor.
  Optional zero-vote re-embedding would consult the new configuration; it must
  stay disabled for this experiment.

The smallest viable adapter is therefore two managers sharing models: prepare at
1 s, then cluster/reconstruct with the requested output floor. The implementation
is [ShortTurnExperiment.swift](../../Workers/TranscriptionWorker/Sources/TranscriptionWorkerSupport/ShortTurnExperiment.swift),
exercised only by the explicit `ShortTurnBenchmark` executable. All output-only
variants reuse one prepared object. Serialized chunk embeddings, PLDA vectors,
indices and assignments must be byte-identical across floors, or execution fails.
Re-clustering is repeated because the public SDK does not expose cached final
assignments to reconstruction; this has no model inference cost, but is not a
claim of free post-processing.

No upstream change is required for these measurements. A cleaner future API
would add an optional `PostProcessing.minSegmentDurationSeconds`, default nil
to preserve the historical embedding-floor fallback, and use it in both
`sanitize` and `excludeOverlaps`. It must leave extraction's support threshold
untouched. An API exposing reconstruction from cached assignments would also
avoid repeated clustering. Neither change is needed or shipped here.

The benchmark rejects nonfinite/negative floors, exclusive reconstruction,
nonzero segmentation-on floors and enabled zero-vote re-embedding. Gap stays
0.1 s, clustering threshold 0.6, overlap exclusion during extraction true,
segmentation step ratio 0.2, and speaker count automatic. Real concurrent
intervals remain nonexclusive and are passed through the production adapter.
Retained short turns use existing cluster centroids; they are not independently
verified short-span speaker embeddings. Zero-vote tie-breaking remains a known
source of uncertainty in the pinned reconstruction.

## Reproduction and provenance

Run the [documented recipe](../../Tools/DiarizationAnalysis/README.md#independent-short-turn-retention-objective-3).
The durable private bundle is
`~/Library/Application Support/Scribe/QualityEvaluation/short-turn-retention-v1`.
It contains worker/analysis source snapshots, a newly compiled executable, SDK
checkout, model hashes, complete inference artifacts and unannotated review
packs. The [aggregate evidence](transcript-quality-short-turns-v1.json) records
source, SDK, model, configuration and binary hashes without transcript text or
embedding vectors.

The immutable `scribe-quality-v1` executable supplies all host behavior, using
exact saved words. Apostrophe reconstruction and later grouping/phrase/gap
candidates are disabled. Both latest Jake <> Neah and CAB are explored
development/sensitivity recordings; validation membership remains empty.
MacWhisper exports are machine references. Whole-second and zero-duration
reference rows make lexical agreement the primary score, with timestamp
agreement only a sensitivity check. No human listening adjudication is claimed.

Fresh baseline clusters map to historical clusters by shared interval duration.
Output-only variants reuse raw cluster identity even when first appearance
renumbers exported IDs. The separately prepared coupled candidate maps to the
fresh control through embedding cosine similarity. These mappings use no
reference speaker labels. Full correspondence strengths and competing matches
are included in the aggregate report.

Only serial inference is run. Each recording has one 1 s preparation and one
0.5 s preparation; cached models/system state are uncontrolled and there is no
repetition-based latency or peak-memory claim. Per-stage timings in private
artifacts are diagnostic and shared preparation times must not be summed across
output-floor variants.

## Results and decision

**Keep the 1 s production default.** All lower output floors recover reference-
agreeing assignments, but also introduce new disagreements. Retain the adapter
and all configurations for the mission's interaction and validation objectives.
There is no supported production winner yet.

Both fresh 1 s controls reproduce the immutable baseline's intervals **and full
host replay exactly**. On both recordings the separately prepared coupled 0.5 s
candidate has identical chunk vectors, assignments and intervals to output-only
0.5 s. Thus, in this corpus, its measured effect is entirely output retention.
This does not establish that lowering the preparation floor is harmless on other
audio/configurations: its code path still changes the clean/base mask threshold.

All rows below use a **1 s preparation floor**, except the explicitly coupled
rows. C/E are canonical/effective disagreeing and unknown aligned tokens.
New/corrected counts refer to effective disagreements against the frozen baseline.

| Recording | Output floor | C wrong / unknown | E wrong / unknown | Saved rows | Reading rows / one-word | New / corrected wrong |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Latest | 1.0 baseline | 53 / 375 | 76 / 112 | 610 | 240 / 62 | 0 / 0 |
| Latest | 0.75 | 55 / 335 | 76 / 64 | 603 | 217 / 54 | 2 / 2 |
| Latest | 0.5 | 64 / 296 | 81 / 22 | 592 | 197 / 33 | 12 / 7 |
| Latest | 0.25 | 72 / 269 | 80 / 8 | 592 | 215 / 33 | 23 / 19 |
| Latest | 0 | 74 / 266 | 84 / 9 | 589 | 231 / 41 | 28 / 18 |
| Latest | coupled 0.5 | 64 / 296 | 81 / 22 | 592 | 197 / 33 | 12 / 7 |
| CAB | 1.0 baseline | 78 / 703 | 87 / 236 | 1329 | 630 / 94 | 0 / 0 |
| CAB | 0.75 | 88 / 637 | 100 / 160 | 1327 | 605 / 89 | 13 / 0 |
| CAB | 0.5 | 94 / 570 | 106 / 79 | 1314 | 562 / 67 | 19 / 0 |
| CAB | 0.25 | 100 / 535 | 109 / 47 | 1302 | 561 / 62 | 25 / 3 |
| CAB | 0 | 102 / 533 | 111 / 49 | 1301 | 581 / 71 | 28 / 3 |
| CAB | coupled 0.5 | 94 / 570 | 106 / 79 | 1314 | 562 / 67 | 19 / 0 |

At output 0.5 s, latest unknowns fall by 90, but effective disagreements rise by
five. CAB unknowns fall by 157, with 19 additional disagreements and no corrected
wrong tokens. Canonical disagreements rise by 11/16 respectively, with no
canonical corrections. Even latest's unchanged disagreement total at 0.75 s
hides two newly wrong tokens offset by two corrections. At output zero, some
baseline wrong tokens become unknown; `new - corrected` alone therefore does
not always equal the net wrong change. The JSON preserves the full transition
matrix, confusion counts, rates and timestamp sensitivity for every row.

All variants retain exactly **5,268 latest / 19,853 CAB saved words**, identical
text and timing, with all source IDs conserved across main rows plus asides.
Latest alignment remains 5,104 tokens (96.887% hypothesis / 97.053% reference),
and CAB 18,963 (95.517% / 95.865%). CAB's 200 aligned null-speaker tokens stay
unscoreable, leaving 18,763 attribution-scored tokens. Coverage changes do not
explain the effects.

At 0.5 s, latest retains 76 additional intervals / 54.380 s, including 18 added
overlapping intervals; CAB retains 125 / 90.056 s, including 22 overlaps. No
baseline interval is removed or changes cluster, timing or quality. The retained
intervals do alter which other intervals are marked as overlapping, as expected.
Private evidence includes 1,046 latest and 3,774 CAB chunk records. All output-only
floors have identical chunk-evidence hashes, and cluster correspondence is
unambiguous here (coupled centroid cosines approximately 1; maximum competing
cosine below 0.485). Exported centroids may have tiny averaging roundoff changes
as retained segment counts change; this is not a newly extracted embedding.

Reading improvements are not monotonically related to floor size. Output 0.5 s
creates two latest one-word asides and one CAB aside; output 0/0.25 creates
13 latest and three CAB asides. They remain separate and conserved. Latest
exact paragraph-boundary matches fall from 99/239 to 89/198 at 0.5 s: precision
rises 41.42%→44.95%, but recall falls 52.11%→46.84%. CAB changes 217/629→215/562:
precision 34.50%→38.26%, recall 49.32%→48.86%. Unaligned starts change 17→14 and
66→61. Full ±1/±3-token, unmatched-boundary, saved-boundary-cause, and one-/three-
word metrics are in the evidence. Fewer rows do not prove better boundaries.

## Changed-assignment review and regression coverage

Text/timing inspection of the 0.5 s review packs shows short acknowledgments,
overlapping responses, fillers, and multiword turn openings among the newly
disagreeing assignments. Latest has **four previously correct→wrong** and
**eight unknown→wrong** effective tokens; CAB has **five and fourteen**.
Latest cases near 97.92 s and 1096.08 s cover a recovered acknowledgment and a
repeated short response. CAB includes a six-token span near 5096.8 s, showing
that this setting can affect a phrase, not just a single backchannel. These are
machine-reference disagreements requiring listening, not adjudicated mistakes.
Neither private transcript excerpts nor speaker names are copied into this report.

The private `latest-short-turn-regressions.json` and
`cab-short-turn-regressions.json` preserve all 181/296 changed canonical/effective
case records at 0.5 s, including padded original-audio clip offsets and null
human annotation fields. Each other floor also retains its complete review pack.
No model confidence or text-only inspection is presented as human verification.

**Seven focused Swift tests pass**, including actual pinned reconstruction at
an exact 0.5 s overlap and a 0.4 s response, configuration isolation/guards,
existing adapter contracts, and real latest-recording overlap geometry at
43.005–43.667 s (synthetic vectors, no private transcript content). **Twenty-nine
Python tests pass**, covering cluster renumbering by recovered first appearance,
acoustic correspondence, overlap evidence, and detection of changed assignments.
Both release worker builds succeeded. Original saved runs/references and the
immutable baseline remain unchanged. No schema migration or human setup is needed.
