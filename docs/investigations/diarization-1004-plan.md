# Diarization and paragraph-grouping implementation plan — coo:1004

Written 2026-09-11 from the [recommendations](diarization-1004-recommendations.md).
Each phase is one Overlord objective. Phases 2–4 are measured on the phase 1
harness before they merge; nothing in phases 2–6 changes the canonical
transcript schema except where stated.

## Phase 1 — Ground-truth harness

**Goal:** a repeatable word-level speaker-error measurement on real meetings so
every later phase reports a number.

Two ground-truth sources, both scored by one tool (`Tools/DiarizationAnalysis/wder.py`):

1. **Manual edits.** Replay a run's immutable `words.json` + `diarization.json`
   through the Swift host harness (`replay.py` already compiles the production
   `SpeakerTurnBuilder`, groupers and reconciler) and compare word attributions
   against the saved canonical transcript, scoring only words inside segments
   whose `attributionSource == .manual`.
2. **Imported reference transcript.** Accept an external transcript of the same
   audio in any of: MacWhisper/JSON `[{speaker, text, start?, end?}]`, SRT/VTT
   with `Speaker:` prefixes, and plain text `Speaker: utterance` lines. When the
   reference has timestamps, align by time; when it does not, align by text
   (the existing `compare.py` `SequenceMatcher` path), choose the optimal
   one-to-one speaker mapping, and report coverage.

Outputs per run: WDER-style word agreement, unknown rate, wrong rate,
per-speaker confusion, paragraph count, single-word paragraph count, executable
hash, engine revision. Aggregate JSON is transcript-free so it can be committed.

Also: a reference-transcript importer in the app is **not** part of this phase;
the harness is CLI tooling. Phase 7 covers an in-app comparison if wanted.

### Initial baseline (2026-09-12)

The supplied `AK-Jake-reference.json` was scored against the mounted **Jake +
AK_Clearcomply Intros** run (`D2945EA8-415A-4B23-842C-DC92694FB58C`) with its
saved words and diarization artifact replayed through the Swift host. The
timestamp-free reference used text alignment: 13,115 lexical tokens aligned
(96.683% replay coverage; 97.134% reference coverage). The WDER-style error was
**6.535%**: 0.831% wrong speaker (109 words) and 5.703% unknown (748 words),
with 1,089 paragraphs and 412 single-word paragraphs. The complete
transcript-free aggregate, including anonymous confusion counts and executable
(`71d7e06f…`) / FluidAudio (`4dbf4f9f…`) revisions, is
[`diarization-1004-wder-baseline.json`](diarization-1004-wder-baseline.json).

## Phase 2 — Confidence and exclusive attribution timeline

**Files:** `SpeakerTurnBuilder.swift`, `CanonicalTranscript.swift`,
`TranscriptAssemblyStageRunner.swift`, golden fixtures.

- Emit per-word confidence `(strongest − runnerUp) / wordDuration` clamped to
  0…1 and store `speakerConfidence` on segments as the minimum over words.
  `TranscriptSegment.lowSpeakerConfidence` already gates the review filter.
- Derive an exclusive attribution timeline from overlapping diarization
  intervals (owner = interval extending further on each side, tie-break on
  `qualityScore`), used only for attribution. Canonical intervals and the
  `overlap` flag are unchanged.
- Record both in `processingOptions` and bump the attribution provenance.
- Regenerate goldens; run phase 1 harness and record before/after.

### Phase 2 result (2026-09-12)

The same saved words, FluidAudio diarization artifact, and supplied
`AK-Jake-reference.json` were replayed before and after this phase. Across the
same 13,115 aligned lexical tokens, WDER-style error improved from **6.535%**
(109 wrong / 748 unknown) to **6.397%** (118 wrong / 721 unknown). Wrong-speaker
rate rose slightly from 0.831% to 0.900%, while unknown rate fell from 5.703%
to 5.498%. Paragraphs fell from 1,089 to 1,072 and single-word paragraphs from
412 to 404. The phase-2 replay executable SHA-256 was
`b9a94c7d24abc7353890fe886682019322ba3deb93426aba310a1c028312ac21`;
the diarization artifact and FluidAudio revision were unchanged from the
baseline. No serialization golden changed: the existing fixtures are canonical
transcript inputs rather than `SpeakerTurnBuilder` outputs.

### CAB Call benchmark (2026-09-14)

The current phase-3 implementation was evaluated against the supplied 1,493-row
`BENCHMARK CALL.json` for **CAB Call 09-01-2026**. Thirteen rows without a
ground-truth speaker were excluded, leaving 1,480 timestamped speaker segments.
The production replay scored 19,248 of 19,853 words (96.953% time coverage).

Canonical assignments scored **4.094% WDER-style error**: 0.509% wrong speaker
and 3.585% unknown. Effective reading labels scored **1.808%**: 0.577% wrong and
1.231% unknown. All nine benchmark speakers received distinct one-to-one
cluster mappings; a tenth Scribe cluster contributed only three scored words.
An untimed exact-token alignment cross-check produced similar results (4.162%
canonical / 1.721% effective) while matching 94.510% of Scribe lexical tokens
and 95.837% of reference tokens. Those lexical coverage figures are not a
conventional ASR WER. Full transcript-free evidence and hashes are in
[`diarization-1004-wder-cab-2026-09-01.json`](diarization-1004-wder-cab-2026-09-01.json).

## Phase 3 — Phrase-level attribution and bounded nearest fallback

**Files:** `SpeakerTurnBuilder.swift`, `UnknownFragmentReconciler.swift`,
`TranscriptSpeakerInferenceEvidence`.

- Group words into phrases (same enclosing ASR span, no gap ≥ `pauseSplitMs`).
- Sum overlap per speaker across the phrase; the dominant speaker is the phrase
  default. A word overrides only when its own overlap gives a different speaker
  adequate evidence and a clear lead.
- Words with no adequate overlap take the nearest interval edge within 250 ms,
  written as `attributionSource = .inferred` with new evidence
  `.nearestInterval(distanceMs:)`, never across a competing speaker.
- Widen `UnknownFragmentReconciler`: one-neighbour runs, and
  `maximumWordCount` 3 → 6 when coverage is unique.
- Harness target: unknown rate on the reference meeting below 3% with wrong
  rate not rising above 1.5%. If wrong rises more, tighten the override rule
  before merging.

## Phase 4 — Backchannel-aware display grouping

**Files:** `TranscriptParagraph.swift`, `TranscriptViewModel.swift`,
`TranscriptWindow.swift`, exporters untouched.

- In `TranscriptParagraphGrouper`, classify a canonical row as a backchannel
  when it is ≤ 3 words, ≤ 1.2 s, and either its text is in a small lexicon
  (yeah, right, okay, mm-hmm, uh-huh, sure, got it, exactly, …) or it is
  flagged `overlap`, and the surrounding rows belong to one other speaker within
  `hardPauseMs`.
- Bridge the surrounding speaker into one paragraph; attach the backchannel as
  an `aside` on the paragraph (new presentation-only field with source segment
  IDs).
- Render asides in the transcript window as a compact inline marker or
  sub-row; TXT/SRT/JSON exports are unchanged.
- Harness reports paragraph and single-word counts before/after.

### Phase 4 implementation and measurement (2026-09-14)

Implemented presentation-only backchannel asides. The grouper requires a known
(or inferred effective) interjecting speaker and the same other known speaker
on both sides; the row is at most three words and 1,200 ms, with lexicon or
overlap evidence. Adjacent gaps and the returning speaker's gap must remain
below `hardPauseMs`. Bridging suppresses soft sentence boundaries, retaining
hard word/duration caps and main-speaker overlap boundaries. Main text, words,
and edit targets exclude aside sources; each aside retains its own speaker,
timing, confidence, overlap flag and source IDs. Canonical rows are untouched.

The window renders a compact timestamped aside sub-row with playback and
“Show turn” for canonical edits. Search, speaker/review filters and parent-row
selection/playback mapping include asides. The main speaker menu continues to
act only on the main speaker's source turns.

Production-host replay with saved words, measured by `wder.py`:

| Recording / view | Before paragraphs | After paragraphs | Before single-word | After single-word |
| --- | ---: | ---: | ---: | ---: |
| CAB reading paragraphs | 630 | 630 | 94 | 94 |
| CAB canonical rows | 1,329 | 1,329 | 559 | 559 |
| Jake + AK reading paragraphs (saved-word replay) | 518 | 518 | 92 | 92 |
| Supplied CAB paragraph ground truth | 441 | 441 | 5 | 5 |

**No measured count improvement on these recordings:** neither saved-word
replay yields an eligible backchannel bridge under the requested bounds.
The supplied paragraph reference therefore still exposes a 189-paragraph and
89-single-word-paragraph gap; these count differences are not boundary accuracy
scores. The detector was not widened to absorb unknown fragments or substantive
speaker turns to chase the benchmark. Synthetic grouper contracts do exercise
successful bridges, including repeated asides, plus all threshold boundaries.

CAB was scored against both repository benchmark files (timestamp alignment for
segments; text alignment for paragraphs). Before/after canonical segments,
word timings, canonical/effective labels and WDER scores are identical. The
new replay reports aside counts separately so interjection words cannot quietly
disappear from evaluation. Aggregate results, input hashes and executable hashes
are in [phase-4 evidence](diarization-1004-phase4.json). The AK row above uses the
saved-word replay and `wder.py` paragraph metrics only, not the earlier fixed-ASR
reference scoring setup.

Validation: all 299 Transcription tests pass (two unavailable-fixture skips),
including grouper/view-model tests and unchanged TXT/JSON/SRT export goldens;
12 Python analysis tests pass. The Scribe Xcode scheme builds. An isolated
SwiftUI screenshot harness with synthetic data and stub playback verified the
aside sub-row without launching another Scribe instance; an opaque white
background was needed because offscreen capture omits materials.

## Phase 5 — FluidAudio 0.15.7 and post-processing sweep

**Files:** `Workers/TranscriptionWorker/Package.swift`, `model_manifest.json`,
`OfflineDiarizationAdapter.swift`, `docs/feasibility/offline-diarization.md`.

- Bump the exact pin, rebuild in an isolated scratch path, record the hash.
- Diff the offline diarizer and embedding extractor between 0.15.6 and 0.15.7;
  bump `preprocessingVersion` only if vector semantics changed.
- Expose `postProcessing` minimum gap / minimum duration on the adapter and the
  `DiarizationBenchmark` CLI; sweep gap 0.25–0.75 s on the four local
  recordings with the harness; keep `clusteringThreshold` at 0.6.
- Verify whether the pinned config supports a speaker-count ceiling; if so,
  plumb "up to N" through the reprocess sheet.

### Phase 5 implementation and audit (2026-09-15)

The worker and Xcode lockfiles now pin FluidAudio exact **0.15.7**, revision
`41540ea237350afe5117a082b5c28eda642d0612`. Both benchmark products were rebuilt
with `swiftbuild -c release` in `/private/tmp/scribe-coo1004-phase5/worker-build`.
The source audit and recording aggregates are recorded in
[phase-5 evidence](diarization-1004-phase5.json).

The upstream diff changes three of the 16 offline source files: structured
cancellation and an OS advisory in the manager, a speaker-cap fix that checks
both active and assigned VBx clusters, and model-loader comments. Embedding
extraction, masks, filterbank, PLDA transforms and normalization are unchanged.
`preprocessingVersion` remains `fluidaudio-offline-fbank-16khz-mono-v0.15.6`;
existing compatible voiceprints do not need re-enrollment.

The adapter and benchmark expose minimum gap and minimum segment duration.
The pinned `PostProcessing` type has **only** a gap control, so duration maps to
`segmentation.minDurationOn`; reconstruction still applies the maximum of this
value and the 1 s embedding-duration floor. This limitation is documented in the
manifest, CLI instructions and [feasibility audit](../feasibility/offline-diarization.md).

The supported speaker ceiling is now available as **Up to N** in the reprocess
menu and confirmation sheet. It passes through `TranscriptionRequest`, persisted
job encoding, import fingerprinting, worker protocol, FluidAudio config, and
canonical processing options. Exact and ceiling counts are mutually exclusive;
old automatic/exact request encodings remain readable. Canonical intervals keep
overlap, and clustering threshold remains **0.6**.

#### Phase 5 CAB results and tuning decision

Five distinct local recordings were swept serially at 0.1 s (control), 0.25 s,
0.5 s and 0.75 s, using fixed saved ASR words, automatic clustering and threshold
0.6. CAB was scored against both repository references. The timestamped segment
reference aligns **19,248 / 19,853 words (96.953%)** at every gap; effective scores
include the existing inferred speaker suggestions, while canonical scores leave
those suggestions unassigned.

| Gap (s) | Canonical WDER | Effective WDER | Effective wrong | Effective unknown | Reading paragraphs | Single-word reading paragraphs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 0.10 (control) | 4.094% | 1.808% | 0.577% | 1.231% | 630 | 94 |
| 0.25 | 3.897% | 1.709% | 0.561% | 1.148% | 613 | 84 |
| 0.50 | 3.206% | 1.481% | 0.566% | 0.914% | 575 | 66 |
| 0.75 | 2.665% | 1.346% | 0.577% | 0.769% | 552 | 57 |

The 0.15.7 control's intervals are exactly equal to CAB's saved 0.15.6 intervals.
The untimed paragraph-reference alignment also improves, from **1.727% to 1.247%**
effective WDER at 0.75 s. The supplied reading reference remains **441 paragraphs /
5 single-word paragraphs**, so even the best gap leaves a substantial readability
gap. Canonical rows decrease from 1,329/559 single-word rows to 978/350; these are
new benchmark hypotheses, not edits to any saved transcript.

**Retain the production 0.1 s gap and 0 s duration setting for this objective.**
0.75 s is the best CAB candidate and is now reproducible via the benchmark CLI,
but CAB is the only fully annotated recording in the mounted corpus. The two
manual-label subsets are tiny (19 and 17 aligned words), and **both show more
wrong assignments at 0.75 s**: the 19-word subset rises from 5 to 9 wrong words,
and the 17-word subset from 0 to 5. Total WDER falls because unknown labels become
assigned, but some become incorrect. These subsets are too small and selectively
edited to estimate whole-meeting accuracy; they nevertheless prevent treating
CAB's improvement as a safe global win. The 0.25 s setting preserves wrong-word
counts in both subsets and is a more conservative candidate for held-out testing.
Two recordings have no scoreable ground truth, so their unknown/paragraph counts
cannot establish a wrong-speaker regression guard. Validate additional fully
annotated meetings before changing the default. No clustering-threshold change
was made.

The benchmark binaries were rebuilt and hashed; ASR was deliberately not rerun
for this sweep so word recognition/timing stayed fixed. Runtime figures are
recorded as observations only: initial sweeps overlapped compilation, so these
are not controlled speed comparisons. Historical synthetic timings in the model
manifest are explicitly labeled as predating this upgrade.

Verification: all **12 worker tests** passed; the full Transcription suite passed
**303 tests with two fixture skips** before the final three test additions;
**40 focused worker/reprocess tests** and **5 fingerprint/serialization tests**
then passed, including the added ceiling coverage. All **12 analysis tests** pass,
and the real Scribe Xcode scheme builds successfully. No visual screenshot was
captured for the native menu addition. Executable hashes and complete aggregate
measurements are in the phase-5 evidence JSON; private raw outputs remain in
`/private/tmp/scribe-coo1004-phase5`.

## Phase 6 — Microphone-track "you" prior (opt-in)

**Files:** recorder session manifest, `AudioPreparationService`,
`TranscriptionRequest`, `SpeakerTurnBuilder` or a new `SourceEnergyPrior`,
identity matching.

- For recorder sessions with separate microphone and system tracks, compute a
  per-100 ms energy ratio timeline during preparation and commit it as
  `source-energy.json`.
- Label the diarized cluster with the highest agreement to mic-dominant windows
  as the local user (library owner profile if one exists, else "Me"), only when
  agreement exceeds a calibrated threshold and the setting is on.
- Use the timeline as extra evidence for confidence and fragment
  reconciliation; never override cluster identity when both tracks are loud.
- Setting default off; explain the in-room-meeting caveat in the UI.

### Phase 6 implementation and calibration (2026-09-15)

Implemented the default-off **Identify me from my microphone** setting, including
an in-room meeting caveat. Recorder handoffs and folder imports retain the session
location. During preparation, the host streams the recorder's original microphone
and system tracks through the existing journal `TimelineBuilder`, preserving
start offsets, gaps and drift on the final mix's timeline. Mean channel power
avoids stereo phase cancellation. `AudioPreparationService` atomically commits
100 ms windows, powers, microphone ratios and capture availability as
`source-energy.json`; retries and fresh runs retain this source artifact after
recorder files are removed. The current setting is snapshotted for new imports,
reprocess and retranscribe requests, and participates in the configuration hash.
Missing legacy request fields mean off. Final-track checksum matching guards the
host's association of a retained session with the requested audio.

Source identity requires a unique highest-agreement cluster. A source-exclusive
window has one track at or above **-40 dBFS**, the other below that floor, and at
least **10 dB power dominance**. Both-loud windows, missing capture, diarization
overlap and silence abstain. Cluster agreement is microphone-exclusive covered
time divided by microphone- plus system-exclusive covered time. The selected
cluster must exceed **95% agreement**, have at least **5 seconds** microphone
support, cover over **60%** of all microphone-exclusive windows, and beat the
runner-up agreement by **20 percentage points**. Intervals retain their original
cluster IDs and overlap flags.

The speaker library now has an explicit, persistent **This is me** designation.
The prior uses that owner's profile/name, or **Me** when unset. It preserves
existing manual or voiceprint identities and abstains if another cluster already
owns that profile. No owner is guessed from names or profile order.

Confidence receives bounded positive/negative source evidence, with a minimum
across each segment's word ranges. Source-assisted unknown fragments require
90% microphone coverage, the selected local cluster as a consistent neighbor,
the existing short-duration/word/gap bounds, and no competing interval. They
remain suggestions (`speaker_id` stays null), with additive `source_energy`
inference evidence. Manual attributions and known word IDs are unchanged.
Versioned selection, confidence formula, threshold and availability are recorded
in processing options. Both-loud source windows cannot supply identity or
confidence evidence.

#### Remote-call measurements

Saved ASR words and diarization were held fixed; the production Swift replay was
rebuilt and evaluated with `wder.py`. Both recordings retain original journaled
tracks. Full supplied ground truth is unavailable for these retained-track runs,
so these WDER figures cover **only sparse manual edits**, not the whole meeting:

| Recording | Scored words | Wrong, off → on | Unknown, off → on | WDER, off → on | Reading rows | Single-word rows |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Jake + AK | 19 | 5 → 5 | 5 → 5 | 52.632% → 52.632% | 518 → 514 | 92 → 90 |
| Connor Jake | 17 | 0 → 0 | 13 → 13 | 76.471% → 76.471% | 227 → 224 | 52 → 50 |

Those selectively corrected words cover only **0.140% (AK)** and **0.266%
(Connor)** of the replay, and intentionally concentrate difficult cases.
**No whole-meeting WDER improvement or “Me” naming accuracy is established.**
Canonical-label scores and canonical row counts are also unchanged; the new
source inferences improve reading grouping outside the tiny scored subsets.

The selected local cluster has **99.686%** source agreement / **89.711%**
microphone coverage on AK (992.837 s support), and **99.954%** / **92.644%** on
Connor (571.796 s). A production-host sensitivity sweep at 0.85, 0.90 and 0.95
produces the same selections and WDER on both calls. At 0.999, AK abstains and
returns to its baseline paragraph counts; Connor still qualifies. **Choose 0.95**
as the strictest tested cutoff that retains both calls, with the independent
support/coverage/runner-up guards. This is provisional source-evidence calibration,
not validation of a general false-identification rate. The setting remains off
by default. In-room microphones, unusually loud noise or different gain setups
can invalidate source identity assumptions; two remote calls cannot calibrate
those conditions.

Transcript-free scores, energy/executable hashes and the complete threshold sweep
are in [phase-6 evidence](diarization-1004-phase6.json). Production identity tests
cover default-off behavior, Me fallback, owner profiles and preserving existing
identity. Tests also cover double-talk despite a large ratio, missing capture,
overlaps, insufficient support, threshold boundaries, ambiguous clusters,
source-assisted holes, competing intervals, confidence, old requests, journal
alignment, stereo power and source evidence surviving reprocessing.

Validation: the full Transcription suite passed **314 tests with two existing
fixture skips**; **13 final focused attribution/coordinator tests** then passed.
All **32 speaker-library tests**, **12 focused recorder preparation/handoff tests**,
and **13 Python analysis tests** pass. The real Scribe macOS scheme builds with
code signing disabled. The UI additions use standard native toggles; no visual
screenshot was captured. Original recordings and saved transcripts were not
modified by the evaluation.

## Phase 7 — Optional follow-ups

- Silero VAD timeline for acoustic pauses feeding both groupers and the
  `untranscribedSpeech` warning.
- In-app "Compare with reference transcript" import using the phase 1 parsers.
- Re-run SpeakerKit against FluidAudio on the harness; consider opt-in
  integration only if a ≥ 3-point gap remains.
