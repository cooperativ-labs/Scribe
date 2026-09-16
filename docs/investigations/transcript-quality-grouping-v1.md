# Lossless presentation attribution and sentence/turn experiment

Objective coo:1016.7t0t, 2026-09-16. Baseline: **scribe-quality-v1**.

## Decision and scope

Use the existing canonical segments as immutable attribution ranges, and derive
presentation rows from them. No canonical schema change or migration is needed.
`TranscriptParagraph.attributionRanges` now carries each complete source segment
plus its half-open range in the row's timed-word array. This preserves the exact
canonical and effective identities, manual attribution, confidence, unresolved
reason, nearest distance, inference provenance/hole/overlap evidence, text and
timing. Asides carry their own ranges. Missing word timings produce a nil range;
a later timed source still maps to the correct offset in the timed-word array.
The source snapshot retains the untimed text and source bounds.

This is the smallest lossless design because the existing saved boundaries
already delimit the available inference evidence. Keep the builder guard and
first-word attribution logic intact. Removing the guard would discard later
word evidence; adding persisted per-word attribution would require coordinated
codec, validator, editor, export and migration changes without demonstrated
benefit here. Confidence remains the existing source-range minimum, not newly
recovered per-word confidence or a calibrated probability.

The additive range representation also serves existing reading paragraphs.
`Configuration.sentenceTurns` is a separately selectable, experimental display
policy using the same Swift grouper. It breaks at available sentence endings,
1-second pauses, speaker/unknown and overlap transitions, and 80-word/30-second
caps at source boundaries. These bounds reuse the canonical display limits;
they were not fitted to the reference row count. A source segment is atomic:
this policy does not split sentences inside an existing multi-sentence segment,
and an oversized source cannot be made smaller by grouping. Existing bounded
backchannels remain visible as separate-speaker asides. No attribution,
reconciliation, word reconstruction or diarization configuration changes.

The policy is available to callers and the replay harness, **not enabled in the
app UI**. The existing Segments and Paragraphs views keep their grouping.
Accept the evidence representation; retain sentence/turn presentation as an
opt-in experiment. Reject replacing the reading default with this policy on
present evidence: it adds fragmentation and lowers paragraph-boundary precision.
There is no saved-segment reduction and no speaker-accuracy improvement.

## Isolated measurements

Same saved ASR words, diarization, fixed mappings, reconciliation and engine as
the immutable baseline. Both new-host off controls exactly reproduce the entire
frozen replay. Canonical and reconciled source objects are exactly equal even
with the candidate on; all source ranges and range word/timing slices pass exact
comparison. The apostrophe and short-turn candidates are disabled.

| Recording | Saved rows (unchanged) | Existing reading rows | Candidate display turns | Saved one-word rows | Reading one-word rows | Candidate one-word rows |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Latest / Jake <> Neah | 610 | 240 | 333 | 301 | 62 | 95 |
| CAB | 1,329 | 630 | 770 | 559 | 94 | 115 |

Candidate display counts are 277/559 lower than saved counts, but 93/140 higher
than existing reading counts. This is **presentation-only**, not a repaired
canonical transcript. Rows of at most three words: saved 354/652, reading 87/145,
candidate 127/177 (latest/CAB). Both controls and candidates have zero asides on
these fixed inputs; synthetic tests exercise real backchannel geometry and
separate aside identities/evidence. All 5,268/19,853 stored words and every source
ID occur exactly once across main rows plus asides.

The 359 latest evidence-only saved boundaries remain intact. Existing reading
paragraphs already join 339 of them; candidate sentence turns join 275. CAB has
647 evidence-only saved boundaries, with 605 already joined in reading and 550
joined by the candidate. These counts explain why deleting the saved guard would
be both lossy and unnecessary for the existing reading presentation.

| Recording | Aligned lexical tokens | Replay / reference coverage | Canonical wrong / unknown (unchanged) | Effective wrong / unknown (unchanged) |
| --- | ---: | --- | --- | --- |
| Latest | 5,104 | 96.887% / 97.053% | 53 / 375 (1.0384% / 7.3472%) | 76 / 112 (1.4890% / 2.1944%) |
| CAB | 18,963 | 95.517% / 95.865% | 78 / 703 (0.4157% / 3.7467%) | 87 / 236 (0.4637% / 1.2578%) |

CAB has 200 aligned but unscoreable tokens and 18,763 scoreable tokens. Both
canonical/effective views have **zero newly wrong and zero corrected wrong**
tokens; labels, unmatched lexical units and confusion matrices are unchanged.
The JSON report includes rates, fixed mappings, per-speaker confusion and time
sensitivity. The input references are machine exports, not human ground truth;
41 latest reference rows have zero duration from whole-second timestamps.

Paragraph-reference boundary agreement (precision / recall):

| Recording | Tolerance | Existing reading | Candidate turns |
| --- | ---: | --- | --- |
| Latest | 0 tokens | 41.42% / 52.11% | 37.35% / 65.26% |
| Latest | 1 token | 44.77% / 56.32% | 39.16% / 68.42% |
| Latest | 3 tokens | 48.54% / 61.05% | 42.47% / 74.21% |
| CAB | 0 tokens | 34.50% / 49.32% | 29.78% / 52.05% |
| CAB | 1 token | 36.72% / 52.50% | 32.12% / 56.14% |
| CAB | 3 tokens | 39.11% / 55.91% | 34.46% / 60.23% |

At exact tolerance, latest unmatched hypothesis/reference boundaries change
140/91 → 208/66; CAB 412/223 → 540/211. Ambiguous unaligned starts change
17→21 and 66→86. The full JSON contains all tolerance counts. Comparison against
paragraph references favors a different unit than sentence turns; these are
tradeoffs, not evidence of universally better segmentation. Private review
packs contain all 97/150 changed reading-boundary starts and all aligned
wrong/unknown attribution cases. Human annotation fields remain null.

## Compatibility and consumer contract

- No persisted property or schema version changes. Legacy decoding and exports
  still consume canonical segments. TXT/JSON/SRT never export the display row's
  effective label as a confirmed attribution.
- Evidence is a value snapshot tied to the current transcript revision. Rebuild
  after edits or undo; do not cache across revisions or persist as a new segment.
- Source segment IDs remain the editing targets. Display IDs keep the existing
  deterministic `paragraph:` source-ID composition. Range offsets are local
  positions, not new persistent word IDs. Manual unknown assignments override
  stale suggestions. Source-level speaker changes cannot be erased by grouping.
- Existing selection, split/undo, playback, search and aside routes still resolve
  canonical source IDs. Word timings and playback offsets do not move. A caller
  using the opt-in policy must retain this same source-ID routing; a display row
  is not an instruction to merge canonical segments.
- Reading rows still use the existing inferred/review indicators. Full range
  evidence is now available to consumers without collapsing it to the first
  word's inference. No new UI controls or rendering changes are promoted here.

## Reproduce and verify

Durable private output: `~/Library/Application Support/Scribe/QualityEvaluation/sentence-turns-v1`.
It contains source snapshots, host binary, independently reusable off/on configs,
private replay/range evidence and unreviewed boundary/attribution packs. The
aggregate [JSON](transcript-quality-grouping-v1.json) records baseline lock,
source/config/binary/diarization/model hashes, corpus membership and measurements.
Model hashes describe the frozen baseline provenance; this experiment performs
no model inference. No speed or memory claim is made.

```sh
python3 Tools/DiarizationAnalysis/quality.py verify \
  --bundle "$HOME/Library/Application Support/Scribe/QualityEvaluation/scribe-quality-v1"
python3 Tools/DiarizationAnalysis/grouping_experiment.py \
  --bundle "$HOME/Library/Application Support/Scribe/QualityEvaluation/scribe-quality-v1" \
  --private-output /private/tmp/scribe-grouping-reproduction \
  --output /private/tmp/scribe-grouping-reproduction-aggregate.json
python3 -m unittest discover -s Tools/DiarizationAnalysis -p 'test_*.py'
swift test --package-path Modules/Transcription \
  --filter 'TranscriptAttributionRangeTests|TranscriptParagraphGroupingTests|TranscriptEditingTests|TranscriptPlaybackTests|TranscriptExporterTests|CanonicalTranscriptTests'
```

Use a new private destination each time. All 33 Python tests pass. Swift selected
75 tests: 74 passed, one historical on-disk reference fixture skipped because it
is absent. Six new Swift tests cover differing nearest distances, canonical
uncertainty, timed and untimed ranges, manual unknown, sentence/pause/overlap and
speaker changes, backchannels, split source IDs, undo, codec and canonical export
contracts. Existing tests cover legacy decoding, schema validation, editing,
search, playback and exports. The two requested corpus replays pass separately;
the absent historical fixture is not counted as corpus validation.

Final hash verification also confirms all 12 original input hashes per recording
(including original/prepared audio, saved artifacts and repository references)
and every frozen bundle file still match the published baseline lock.

Latest and CAB are explored development/sensitivity recordings. No pristine
holdout, listening adjudication or new UI end-to-end claim is available. Keep
the current defaults pending the mission's combination and promotion objectives.
