# Bounded gap reconciliation and inferred-segment grouping — coo:1055

Implemented 2026-09-25. The production host now groups adjacent inferred words
with the same speaker despite different nearest-interval distances, and repairs
short unfinished unknown fragments between acoustically supported neighbors.
The diarization model, clustering, ASR, word timing, and canonical word labels
are unchanged. Existing saved runs are not rewritten.

## Behavior and limits

- `SpeakerTurnBuilder` continues to separate confirmed and inferred words. Within
  an inferred segment, `nearest_interval.distance_ms` is now the **maximum** word
  distance, still bounded by 250 ms. It retains minimum word confidence, exact
  timed words, overlap metadata, speaker transitions, pause and length caps.
  Grouping provenance is `speaker-turn-grouping-v2`; attribution remains v3.
- `UnknownFragmentReconciler` v3 accepts original v3 nearest-interval inferences
  as neighbor anchors. It does not propagate its own gap/coverage suggestions.
  A no-coverage hole still needs two agreeing neighbors, two high-quality acoustic
  anchors, at most three words, a fragment no longer than 1 s, and an unoccupied
  diarization hole no longer than 1.5 s. Missing, competing, low-quality, or
  distant evidence cannot establish identity. Manual unknowns remain untouched.
- If either anchor is inferred, sentence-final unknown fragments stay unknown:
  a completed short reply may belong to another speaker. This is a veto, not a
  text-based speaker classifier. Acoustic evidence remains mandatory.
- Reconciliation improves effective/readable attribution; original canonical
  unknown labels remain unknown. New grouping takes effect on import/reprocess;
  existing runs can benefit from in-memory reconciliation when opened.

## Fixed-input comparison

The read-only `scribe-quality-v1` bundle and published manifest were verified.
The pre-change host reproduced **both complete frozen replay documents exactly**.
The candidate was built from a separate source snapshot and compared using
unchanged saved words, intervals, lexical alignment, and frozen speaker mappings.
All words, timestamps, canonical speaker labels, and main-plus-aside source
coverage were conserved. No audio/model inference was rerun.

| Frozen recording | Canonical rows | Single-word canonical rows | Reading rows | Single-word reading rows | Effective unknown tokens | Wrong tokens |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| latest | 610 → 582 | 301 → 248 | 240 → 238 | 62 → 61 | 112 → 111 | 76 → 76 |
| CAB | 1,329 → 1,292 | 559 → 486 | 630 → 617 | 94 → 90 | 236 → 225 | 87 → 87 |

Single-word canonical rows fall **860 → 734 (14.7%)**. Twelve unknown lexical
tokens become reference-correct, with **zero newly wrong tokens**, including
per-token transition checks. Canonical attribution is identical. Timestamp
sensitivity also reduces unknowns (latest 116 → 115; CAB 237 → 227) with unchanged
wrong counts (131 and 111 respectively).

Reading-boundary agreement is mixed: CAB exact-boundary precision rises
34.50% → 35.23% with recall unchanged at 49.32%; latest precision is effectively
flat (41.42% → 41.35%) and recall drops 52.11% → 51.58% (one matched boundary).
Fewer rows are not a claim of uniformly better paragraph boundaries.

The initial, broader gap candidate assigned two completed short replies to the
wrong speaker in latest. It was rejected. The sentence-final safeguard removes
those new disagreements. This tuning used development references, not a pristine
validation set.

Full aggregate evidence and source/binary/input hashes:
[frozen-corpus report](diarization-1055-refinement.json).

## Fresh CAB snapshot sensitivity

Also replayed the September 24 CAB re-import snapshot with its fixed raw
`transcript.json` and timestamped segment reference, through pre-change and
candidate hosts. This is the same call with a newer saved ASR/diarization run,
not an independent recording or holdout. All four runs select the same speaker
mapping and score 19,488 words.

| Metric | Before | After |
| --- | ---: | ---: |
| Canonical rows | 1,471 | 1,415 |
| Single-word canonical rows | 658 | 548 |
| Reading rows | 643 | 625 |
| Single-word reading rows | 97 | 89 |
| Canonical WDER-style error | 4.685% | 4.685% |
| Effective WDER-style error | 1.888% | 1.837% |
| Effective unknown words | 254 | 244 |
| Effective wrong-speaker words | 114 | 114 |

Single-word canonical rows fall **16.7%**, while effective unknowns fall by ten.
This timestamp score uses a different alignment/denominator from the frozen
lexical score and should not be pooled with it. Evidence:
[fresh CAB before/after](diarization-1055-cab-fresh.json).

## Reproduce and verify

```sh
python3 Tools/DiarizationAnalysis/refinement_experiment.py \
  --bundle "$HOME/Library/Application Support/Scribe/QualityEvaluation/scribe-quality-v1" \
  --private-output /private/tmp/scribe-refinement-reproduction \
  --output /private/tmp/scribe-refinement-reproduction.json

python3 -m unittest discover -s Tools/DiarizationAnalysis -p 'test_*.py'
swift test --package-path Modules/Transcription \
  --filter 'UnknownFragmentReconcilerTests|SpeakerTurnBuilderTests|TranscriptParagraphGroupingTests|TranscriptAttributionRangeTests|CanonicalTranscriptTests|TranscriptionCoordinatorTests|TranscriptExporterTests'
```

The private destination must be new. The recipe snapshots sources, builds the
actual Swift host, runs `quality.py compare`, and rejects changed canonical
word labels/timings or new lexical speaker disagreements. It retains private
review packs with null human annotations. Public output is aggregate-only.
`quality.py` versions boundary diagnostics from replay grouping provenance;
historical replays retain their original v3 predicate interpretation.

For the fresh snapshot, run `wder.py` with the snapshot directory,
`--transcript <snapshot>/transcript.json`,
`--reference 'benchmark-files/CAB/BENCHMARK CALL - Transcrpt segments.json'`,
and `--host-replay <private-output>/host-replay`, separately with and without
`--effective-speakers`. The report records the binary and input hashes.

Validation: **95 Swift tests, zero failures, two skips** for an unavailable
historical local recording; **34 Python tests passed**. New regressions cover
distance aggregation in both directions, confirmed/inferred separation, speaker
changes, pause and length caps, acoustic gap repair, competing/missing/low-quality
evidence, completed replies, manual anchors, provenance, and non-cascading
inference. Both controlled replay corpora pass conservation checks.

These are two previously explored recordings and machine-generated references.
There is no new human listening adjudication or independent holdout, and the
remaining unknowns and genuine short turns are deliberately preserved.
