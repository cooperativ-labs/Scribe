# Frozen transcript quality baseline — coo:1016.3jsj

The **scribe-quality-v1** baseline reproduces both saved recordings exactly for
segment text, word timings, canonical identities, nearest/fragment inference
records, and overlap. Reconstructing from the original raw ASR tokens also
produces exactly the saved word objects and builder segments. No production
code or default changed.

The [aggregate evidence and hash lock](transcript-quality-baseline-v1.json),
[corpus manifest](../../Tools/DiarizationAnalysis/experiments/corpus-v1.json),
[experiment registry](../../Tools/DiarizationAnalysis/experiments/registry.json),
and [commands and scoring contract](../../Tools/DiarizationAnalysis/README.md#immutable-quality-baseline-and-independent-experiments-coo1016)
are the starting point for subsequent objectives.

## Measured baseline

These are **machine-reference agreement** measurements, not human accuracy.
Text alignment is primary. Both exports of each recording have the same
normalized lexical sequence; grouping differs. The latest timestamped reference
has 41 zero-duration rows, and CAB has 60. Whole-second reference timing is a
sensitivity check only.

| Measure | Latest | CAB |
| --- | ---: | ---: |
| Saved words / normalized hypothesis tokens | 5,268 | 19,853 |
| Matched lexical tokens | 5,104 | 18,963 |
| Hypothesis coverage | 96.887% | 95.517% |
| Reference coverage | 97.053% | 95.865% |
| Speaker-scoreable matched tokens | 5,104 | 18,763 |
| Canonical wrong / unknown | 53 / 375 | 78 / 703 |
| Effective wrong / unknown | 76 / 112 | 87 / 236 |
| Saved rows / one-word rows | 610 / 301 | 1,329 / 559 |
| Reading rows / one-word rows | 240 / 62 | 630 / 94 |
| Asides / aside words | 0 / 0 | 0 / 0 |
| Reference reading rows | 191 | 441 |
| Nearest-evidence-only saved boundaries | 359 / 609 | 647 / 1,328 |
| Same-speaker inferred distance changes | 30 | 44 |
| Exact reading-boundary matches | 99 / 239 | 217 / 629 |
| Exact boundary precision / recall | 41.42% / 52.11% | 34.50% / 49.32% |
| Unaligned reading starts | 17 | 66 |

CAB's 200 aligned tokens in null-speaker reference rows contribute to coverage
but not speaker scoring. This is why matched-token totals differ from historical
reports that removed those rows before alignment. The scoreable 18,763-token
subset reproduces the historical lexical result. Timestamp sensitivity also
reproduces CAB's previous 98/690 canonical and 111/237 effective wrong/unknown
counts. Latest timestamp sensitivity yields 107/379 and 131/116, respectively;
it uses a different alignment and denominator and is not pooled with lexical
scores.

Reference one-word counts in the JSON use normalized lexical units (latest 29,
CAB 4), whereas the prior investigation's whitespace counts were 31 and 5.
Scribe row sizes count actual saved word objects. This distinction matters for
contractions; neither definition is silently treated as the other.

The boundary report includes exact, ±1-token, and ±3-token matches. Unaligned
starts stay ambiguous rather than snapping across missing words. A row-count
reduction alone is not acceptance evidence. The pinned-v3 boundary explanation
is diagnostic reconstruction only; the transcript itself comes from Swift.

## Preservation and provenance

Private immutable bundle:
`~/Library/Application Support/Scribe/QualityEvaluation/scribe-quality-v1`.
It contains the exact source snapshot, executable, installed-model file hashes,
saved input JSON, replay outputs, fixed speaker maps and unreviewed listening
packs. It survives temporary-directory cleanup and is excluded from tracked
source by location. The bundle refuses overwrite, its files are read-only, and
all frozen file hashes are verified against a manifest whose hash is locked in
the public evidence.

- Manifest SHA-256: `7bd63d637472785145e841c67325d952e0c0f398eba4e703ad5dbc57c7ede75e`.
- Swift replay SHA-256: `fd72291b489fe64be4d7d79223d01726ae21d726e39e0e9fd1766e6249a68bbf`.
- Source-tree digest: `741daafd7fc778893026a0c38b027c3ceb24a51325bb39591f528244586273c8`.
- Installed-model tree digest: `73c32918305057f80c3b53e82f5ad055980005bf0392f666fc140213ba93f1e2` (35 files).

The evidence hashes every saved artifact, original recording, prepared audio,
reference, configuration, and compiled source. Latest records FluidAudio 0.15.7;
CAB's saved artifact records 0.15.6. This objective replays those saved outputs
and does not claim fresh model inference. Installed-model hashes describe the
current assets; historical loaded-model bytes cannot be retroactively attested.
No runtime or memory improvement is claimed.

## Verification and limits

All 23 Python analysis tests pass, including 10 new fixtures for contraction
alignment, fixed mappings, new-versus-corrected mistakes at equal totals,
null-speaker/zero-duration rows, aside conservation and corruption, boundary
ambiguity/tolerance, repeated tokens, and frozen-file tampering. Both real runs
pass exact saved/raw reproduction and source-word, content/timing, and
main-plus-aside conservation. The independently selected saved and raw controls
are compared to the same frozen baseline, with no remapped speaker optimization.

Both recordings have already influenced tuning and belong to the development /
sensitivity set. The validation set is empty. Sparse manual edits elsewhere
are not full-meeting validation. Local review packs supply context and listening
offsets; human annotation fields remain empty because no adjudication occurred.

**Decision:** accept this harness and baseline as the control for later
experiments. No quality candidate is promoted by this objective. Retain the
private bundle and original recordings through the remaining mission objectives.
