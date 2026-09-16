# Intraword apostrophe experiment — coo:1016.rjyd

2026-09-16. **Accept the reconstruction repair as an independently selectable
candidate; do not promote it to the production default yet.** It repairs all 203
latest common-suffix splits while conserving characters and lexical tokens. CAB
introduces one new machine-reference speaker disagreement, and neither recording
is independent validation. The full aggregate report is
[transcript-quality-apostrophes-v1.json](transcript-quality-apostrophes-v1.json).

## Implementation and isolation

`TokenTimingReconciler.Configuration.joinIntrawordApostrophes` defaults to false.
When enabled, a standalone ASCII apostrophe or right curly apostrophe joins the
surrounding letter pieces only when neither the apostrophe nor the next piece
has an explicit SentencePiece/space word boundary. The preceding character must
be a letter and not follow another punctuation token. Opening/closing quotes,
plural possessive endings, punctuation sequences and explicit boundaries retain
legacy behavior. Ambiguous unmarked letter/apostrophe/letter sequences follow
the tokenizer's continuation evidence; this is not semantic quote recognition.

Apostrophes and terminal punctuation contribute **text only**. The combined
word's timing covers the lexical stem and suffix; decoder punctuation times
cannot stretch it. Vocabulary fallback, chunk merging, source mapping, export
code and saved transcript decoding are unchanged. Existing words/IDs and manual
edits are never rewritten. A newly reconstructed candidate has fewer word units
and therefore newly enumerated IDs, as expected for a fresh reconstruction.

Hyphens are deliberately unchanged and tested against the legacy path. They can
represent compound words, interrupted speech or dashes; this experiment provides
no evidence for applying the apostrophe rule to them. No hyphen candidate is
claimed or promoted.

Both off/on configurations use the **same newly compiled Swift host binary**, raw
ASR tokens, diarization, mapping, source inputs and all other baseline settings.
The off control reproduces the entire frozen replay JSON exactly for both
recordings, including inference evidence, timing, canonical/effective labels,
grouping and asides. Each on comparison starts independently from the immutable
**scribe-quality-v1**, not from a preceding candidate. No model inference ran.

## Isolated effect sizes

All arrows are frozen baseline → apostrophe-only candidate.

| Metric | Latest | CAB |
| --- | ---: | ---: |
| Split common-suffix forms | 203 → 0 | 862 → 0 |
| Broad letter-apostrophe-space-letter forms | 206 → 2 | 865 → 2 |
| Reconstructed word units | 5,268 → 5,064 | 19,853 → 18,990 |
| Merged words | 204 | 863 |
| Canonical disagreements | 53 → 53 | 78 → 79 |
| Canonical unknown tokens | 375 → 375 | 703 → 694 |
| Effective disagreements | 76 → 76 | 87 → 88 |
| Effective unknown tokens | 112 → 110 | 236 → 235 |
| Newly wrong / corrected wrong, canonical | 0 / 0 | 1 / 0 |
| Newly wrong / corrected wrong, effective | 0 / 0 | 1 / 0 |
| Saved rows | 610 → 594 | 1,329 → 1,299 |
| Saved one-word / up-to-three-word rows | 301 / 354 → 291 / 349 | 559 / 652 → 542 / 637 |
| Reading rows | 240 → 234 | 630 → 615 |
| Reading one-word / up-to-three-word rows | 62 / 87 → 60 / 88 | 94 / 145 → 97 / 148 |
| Aside rows / words | 0 / 0 → 0 / 0 | 0 / 0 → 0 / 0 |
| Nearest-evidence-only saved boundaries | 359 → 345 | 647 → 619 |

The original 203 observation uses `\w'\s+(?:s|t|m|re|ve|ll|d)\b` on joined word
text. The broader `\w['’]\s+\w` also counts other letter continuations and quotes;
it is not a count of proven errors. The two remaining forms per recording have
an explicit space marker on the apostrophe token and are intentionally preserved.
Raw ASR full text contains zero broad forms in both recordings.

Latest alignment is unchanged: **5,104** common aligned tokens, 96.887% hypothesis
and 97.053% reference coverage; 5,104 are scoreable. CAB remains **18,963** aligned,
95.517% hypothesis and 95.865% reference coverage; 18,763 are scoreable and 200
have null reference labels. There are zero baseline-only/candidate-only aligned
reference tokens. All 5,268 latest and 19,853 CAB normalized lexical tokens are
conserved in order; no lexical units are added or removed.

Latest canonical wrong/unknown rates remain 1.0384% / 7.3472%. Effective wrong
stays 1.4890%; unknown decreases 2.1944% → 2.1552%. CAB canonical wrong/unknown
rates change 0.4157% / 3.7467% → 0.4210% / 3.6988%; effective rates change
0.4637% / 1.2578% → 0.4690% / 1.2525%. Per-speaker confusion and fixed baseline
speaker mappings are included in the JSON.

Equal totals hide transitions: latest canonical has ten correct→unknown and ten
unknown→correct; effective has two unknown→correct. CAB canonical has nine
correct→unknown, eighteen unknown→correct and one correct→wrong. CAB effective
has one unknown→correct and one correct→wrong. No baseline wrong token becomes
correct. This is agreement with machine references, not adjudicated accuracy.

The new CAB disagreement concerns a suffix incorporated into a word spanning
**3,603.360–3,603.600 seconds**. Its assignment changes from `speaker_7` to
`speaker_1` in both views. The private CAB review pack includes a padded
3,601.360–3,605.600-second listening window, reference context and empty reviewer
fields. No listening adjudication was performed. A focused synthetic test pins
this mechanism: a suffix across a turn boundary joins its stem, and attribution
uses the whole word's acoustic span rather than treating the suffix as a turn.

## Boundary diagnostics and conservation

Reference paragraph starts are compared in the common lexical coordinate system.
Below: matched / unmatched hypothesis / unmatched reference, with baseline →
candidate. Tolerances are lexical tokens, and matching remains one-to-one.

| Recording | Tolerance 0 | Tolerance 1 | Tolerance 3 |
| --- | --- | --- | --- |
| Latest | 99/140/91 → 96/137/94 | 107/132/83 → 104/129/86 | 116/123/74 → 115/118/75 |
| CAB | 217/412/223 → 214/400/226 | 231/398/209 → 226/388/214 | 246/383/194 → 243/371/197 |

Ambiguous unaligned starts: latest 17 → 17; CAB 66 → 65. Precision/recall at
0/1/3 tokens are in the JSON. Fewer reading rows do **not** establish better
boundaries: exact matched boundaries and recall decrease in both recordings.
CAB one-word reading rows increase by three despite fewer total rows.

Every candidate word occurs exactly once across saved segments and main reading
rows plus asides, with identical text and timing. Source segments are neither
lost nor duplicated. Removing only whitespace from all words yields the exact
same character sequence before/after, preserving punctuation and vocabulary.
Every merged span equals its component lexical span; every unmerged word retains
its original timing. The evidence script fails if these checks fail.

Whole-second reference timestamps include 41 latest and 60 CAB zero-duration
rows. Time-overlap sensitivity is included but uses reconstructed word units,
whose counts change; those counts are not comparable lexical denominators and
are not acceptance evidence. No speed or memory improvement is claimed.

## Reproduction and acceptance

Private source snapshot, executable, off/on hashed JSON configurations, raw replay
outputs and unannotated review packs:
`~/Library/Application Support/Scribe/QualityEvaluation/intraword-apostrophes-v1`.
The baseline bundle remains separately hash-locked. Public JSON includes source,
binary, configuration, diarization, recipe and test hashes, the baseline manifest
lock, installed-model digest and corpus membership. Frozen baseline provenance
supplies original input hashes; the candidate uses those exact frozen inputs.

```sh
BASE="$HOME/Library/Application Support/Scribe/QualityEvaluation/scribe-quality-v1"
python3 Tools/DiarizationAnalysis/quality.py verify --bundle "$BASE"
# Use a NEW private output directory; existing evidence is never overwritten.
python3 Tools/DiarizationAnalysis/apostrophe_experiment.py --bundle "$BASE" \
  --private-output /private/tmp/scribe-apostrophes-reproduction \
  --output /private/tmp/scribe-apostrophes-reproduction-aggregate.json
python3 -m unittest discover -s Tools/DiarizationAnalysis -p 'test_*.py'
swift test --package-path Modules/Transcription \
  --filter 'TokenTimingReconcilerTests|TokenDurationPauseRegressionTests|SpeakerTurnBuilderTests|TranscriptExporterTests'
```

**71 focused Swift tests and 25 Python tests pass.** Coverage includes ASCII/curly
contractions, possessives, names, repeated apostrophes, quotes, explicit spaces
and SentencePiece markers, vocabulary lookup, invalid/late punctuation timing,
suffixes crossing speaker boundaries, pause retention, attribution and existing
TXT/JSON/SRT export contracts. Character loss and stretched timing are rejected
by evidence tests. Swift tests required access to the Xcode build service outside
the shell sandbox; initial sandbox runs could not write its build manifest.

Reconstruction acceptance gates pass: all targeted forms repaired, no lexical or
punctuation loss, timing preserved, exact off-control parity, existing exports
pass. Promotion gates remain unmet: one new CAB disagreement, reduced boundary
recall, no untouched validation recording or human review. Keep the candidate
available for the mission's later combination/validation and promotion objectives.
Production behavior remains unchanged; no schema migration or user action is
required. Original recordings, saved runs and benchmark references were read-only.
