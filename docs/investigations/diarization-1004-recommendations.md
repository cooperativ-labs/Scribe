# Diarization and paragraph-grouping improvement recommendations — coo:1004

Reviewed 2026-09-11. This is an analysis of the shipped pipeline plus a survey of
comparable open-source stacks. No production code was changed. It builds on the
[coo:979 investigation](diarization-979.md) and its
[combined evaluation](diarization-979-evaluation.md), which remain the
authoritative measurements (FluidAudio 0.15.6: 91.257% matched-text agreement,
7.796% unknown, 0.948% wrong; SpeakerKit: 94.304% / 4.932% / 0.765%).

## How the pipeline works today

| Stage | Component | Behaviour |
|---|---|---|
| Diarize | `OfflineDiarizationAdapter` (FluidAudio 0.15.6) | pyannote segmentation → WeSpeaker embeddings → AHC warm start → VBx. Overlapping intervals preserved. Community defaults: threshold 0.6, step ratio 0.2, min embedding 1.0 s. Occupancy diagnostics only. |
| Word timing | `TokenTimingReconciler` | Parakeet TDT tokens; durations are quantized to 80/160/240/320 ms bins; punctuation carries no acoustic extent. Not forced alignment. |
| Attribute | `SpeakerTurnBuilder.attribute` | **Each word decided independently.** Strongest per-cluster overlap must be ≥ 50 ms **and** ≥ 50% of the word, and beat the runner-up by > 1 ms; otherwise the word is unknown. No neighbour context, no nearest-interval fallback. |
| Canonical rows | `TranscriptDisplayGrouper` (inside the builder) | Split on speaker/unknown change, pause ≥ 1 s, 30 s or 80 words; sentence end is a preferred break after 12 s / 40 words. Unknown sentence ends always split. |
| Repair | `UnknownFragmentReconciler` | Only an unknown fragment of ≤ 3 words / ≤ 1 s sandwiched between two rows of the **same** speaker, with diarization coverage or a ≤ 1.5 s hole. Writes `speakerInference`, never rewrites `speakerID`. |
| Display | `TranscriptParagraphGrouper` (view model) | Merges canonical rows of one speaker: sentence end + pause ≥ 1.5 s, any gap ≥ 2.5 s, first sentence end after 40 words, hard cap 110 words / 60 s. Overlap transitions split. |

Two facts shape everything below:

1. **Unknowns dominate the remaining error.** On the reference meeting the
   wrong-speaker rate is already under 1%; unknown words are 7.8% (813 words,
   401 single-word paragraphs). SpeakerKit's whole advantage was 266 of those
   words moving out of unknown. Unknowns are mostly produced by the attribution
   rule meeting approximate word bounds at diarization boundaries, not by
   clustering.
2. **`speakerConfidence` is in the schema but never populated.** The UI,
   paragraph grouper and review filter all support a graded confidence, yet
   attribution only emits known/unknown. Every recommendation in section 2
   becomes safer once the margin behind a decision is recorded.

## 1. What comparable stacks do differently

| Stack | Attribution | Relevance |
|---|---|---|
| [OpenWhispr](https://openwhispr.com/blog/local-speaker-diarization) (sherpa-onnx: Silero VAD → pyannote-seg-3.0 → CAM++ → AHC at cosine 0.5) | Diarization segment matched to the **transcript segment** with maximum overlap. Microphone input is labelled "you" by source, not by voice, "reducing workload by ~50%". Short (< 0.8 s) segments are dropped and recovered by **label propagation** from neighbours. Profile matching tiers: ≥ 0.70 auto, 0.55–0.70 suggest, < 0.55 anonymous; running-mean profile update. | Source-based "you" labelling and label propagation are both directly applicable. |
| [WhisperX `assign_word_speakers`](https://github.com/m-bain/whisperX/blob/main/whisperx/diarize.py) | Sum overlap per speaker over the **whole sentence segment** first, then per word; `fill_nearest` assigns a word with no overlap to the diarization interval whose midpoint is closest. Interval tree for lookup. | Segment-first attribution plus nearest fallback is the standard answer to boundary unknowns. |
| [pyannote community-1](https://huggingface.co/pyannote/speaker-diarization-community-1) | Emits an additional **exclusive speaker diarization** timeline "to simplify reconciliation between fine-grained diarization timestamps and (sometimes not so precise) transcription timestamps". | Scribe should derive its own exclusive timeline for attribution while keeping overlaps for flags. |
| [DiarizationLM](https://arxiv.org/abs/2401.03506) | LLM post-processing of word/speaker text; 44–55% relative WDER reduction with a fine-tuned PaLM 2-S. | Interesting later; not local-first today. |
| [NaturalTurn](https://www.nature.com/articles/s41598-025-24381-1) | Separates backchannels ("mhm", "yeah") and brief interjections from the turn they interrupt. | The main reason Scribe shows 3 rows where a reader expects 1. |
| FluidAudio [0.15.7](https://github.com/FluidInference/FluidAudio/releases) (10 Sep) | Offline diarizer cancellation propagation, speaker-cap enforcement, ASR final-window re-decode. Sortformer/LS-EEND are streaming only (4 / 10 speakers). | Small pin bump to evaluate; no engine change warranted. |

## 2. Attribution recommendations (highest value)

### 2.1 Attribute at phrase level first, then refine per word

Replace the independent per-word decision with a two-pass rule, keeping
per-word `wordAssignments`:

1. Group words into phrases (no gap ≥ pause threshold, same enclosing ASR span).
2. For each phrase, sum overlap per speaker across all its words (the WhisperX
   rule). The dominant speaker becomes the phrase default.
3. A word keeps the phrase speaker unless its *own* overlap gives a **different**
   speaker a clear lead (both the existing ≥ 50 ms / ≥ 50% test and a margin).
   Words at the phrase edge with weak or no overlap inherit the phrase speaker.

Expected effect: most of the 813 unknowns are edge words of a phrase whose
interior is unambiguous. Wrong-speaker risk rises only where a genuine speaker
change happens mid-phrase without a pause, which step 3 still catches.

### 2.2 Add a bounded nearest-interval fallback

For a word with no adequate overlap, assign the interval whose nearest edge is
within a tolerance (start at 250 ms, about three TDT bins) and record
`attributionSource = .inferred` with a new evidence case such as
`.nearestInterval(distanceMs:)`. Do not fall back across a competing speaker's
interval. The coo:979 320 ms window experiment (+2.3 pp agreement, +0.1 pp
wrong) is the closest existing measurement of this effect.

### 2.3 Build an exclusive attribution timeline

`preserveOverlappingIntervals` must stay true for the canonical record, but
attribution should run on a derived exclusive timeline: where two intervals of
different speakers overlap, keep the speaker whose interval extends further
on each side (or the one with higher `qualityScore`) as owner of the overlap
region, and set the `overlap` flag on affected words as now. Today a word inside
an overlap with equal shares becomes unknown because `minimumLeadMs` is 1.

### 2.4 Populate `speakerConfidence`

Emit `(strongest − runnerUp) / wordDuration` clamped to 0…1 per word, and the
minimum over a segment. Threshold `lowSpeakerConfidence` already exists, so
"Needs review" immediately becomes graded instead of binary, and later smoothing
passes can be gated on it.

### 2.5 Widen `UnknownFragmentReconciler` cases

Once 2.1–2.4 exist, most fragments vanish; the remaining useful extensions are:

- a fragment at the **start or end** of a same-speaker run (one neighbour) when
  diarization coverage names that neighbour;
- a fragment **between two different speakers** resolved by the exclusive
  timeline or nearest interval, with confidence from the hole size;
- raise `maximumWordCount` from 3 to about 6 when coverage evidence is unique.

## 3. Diarizer recommendations

### 3.1 Use the microphone track as a "you" prior

The recorder keeps separate microphone and system tracks before mixdown
(`MixdownService`, `UnprocessedFLACExporter`). Per-window energy ratio between
the two tracks gives an almost free, voice-independent label for when the local
user is speaking. Use it as:

- a **prior for one cluster** (the cluster most co-occurring with mic-dominant
  windows is labelled with the library's owner profile, or "Me");
- a **constraint** feeding `withSpeakers(exactly:)`-style controls (known count
  minus one remote participants);
- evidence for `UnknownFragmentReconciler` and confidence scoring.

Keep the plan's caution: the mic track is not assumed to contain one voice
(in-room meetings), so make it an opt-in setting per recording source and
never override cluster identity when mic and system energy are both high.
OpenWhispr reports this alone removes about half the labelling work.

### 3.2 Bump to FluidAudio 0.15.7 with the existing benchmark protocol

Rebuild in an isolated scratch path, hash the executable, rerun
`Tools/DiarizationAnalysis/benchmark.py` on the four local recordings, and
confirm `preprocessingVersion` does not need a bump (the mask pipeline is
documented as unchanged in the release notes, but verify the diff). The
cancellation fix is worth having on its own for long files.

### 3.3 Tune post-processing before touching clustering

`OfflineDiarizerConfig.postProcessing` minimum gap/duration are still upstream
defaults; the reference meeting yields 606 intervals for two speakers. Fewer,
longer intervals mean fewer boundary words. Sweep minimum gap (0.25–0.75 s) and
minimum interval duration with the benchmark tool and the WDER harness in 5.1.
Do not change `clusteringThreshold` on the current evidence (coo:979 decision).

### 3.4 Expose a speaker-count *ceiling*, not just an exact count

Exact count is fragile on short recordings (both engines emit one voice on the
7.8 s recording even when two are requested). Verify whether the pinned
`OfflineDiarizerConfig` accepts a maximum and expose "up to N" in the
reprocess sheet; otherwise post-merge the smallest cluster when N is exceeded
and record it in diagnostics.

### 3.5 Add Silero VAD as a diagnostics input (medium value)

FluidAudio ships Silero VAD. A VAD timeline would (a) give true acoustic
pauses to both groupers instead of decoder-bin gaps, (b) make
`untranscribedSpeech` warnings acoustic rather than inferred, and (c) let 2.2
refuse a fallback across a real silence. Not required for 2.1–2.4.

### 3.6 Keep SpeakerKit as the opt-in candidate

Nothing new changes the coo:979 decision. Revisit only after 2.x lands, since
its measured advantage was almost entirely coverage of unknowns, which 2.1–2.3
target directly at zero licensing cost.

## 4. Paragraph-grouping recommendations

### 4.1 Backchannel-aware display grouping

The single biggest reader-visible improvement. A short interjection by speaker
B inside A's continuous turn currently yields rows A / B / A. Add a display-only
classification in `TranscriptParagraphGrouper`:

- candidate: ≤ 3 words, ≤ 1.2 s, text in a small lexicon (yeah, right, okay,
  mm-hmm, uh-huh, sure, got it, exactly…) or flagged `overlap`;
- A's rows on both sides are within `hardPauseMs` of each other;
- render A as one paragraph and B's backchannel as an inline aside or a
  compact sub-row, with source segment IDs preserved.

Canonical segments, exports and subtitles are unchanged; this is presentation.
NaturalTurn describes the same split.

### 4.2 Make pause thresholds evidence-aware

The display grouper treats a 1.5 s decoder gap as a sentence pause. Once VAD
(3.5) exists, take the pause from the VAD timeline and let decoder gaps only
break at ≥ `hardPauseMs`. Until then, keep values but expose them in
`processingOptions` as the canonical grouper already does, so replays are
reproducible.

### 4.3 Let the display grouper bridge inferred fragments explicitly

`effectiveSpeakerID` already merges reconciled fragments. Extend the same
courtesy to 2.2 nearest-interval inferences, and surface
`containsInferredAttribution` as a subtle marker rather than a full
"needs review" state once confidence (2.4) is available.

### 4.4 Minor

- Preferred breaks could also honour a long clause boundary (comma or
  semicolon) after `maximumWordCount − 20` words to avoid ugly hard cuts.
- `TranscriptParagraphGrouper().paragraphs(from:)` runs on every segment edit
  in the view model; memoise by transcript revision for long meetings.

## 5. Evaluation, the real blocker

Every previous objective stopped at "no annotated multi-party data". Two cheap
sources exist already:

### 5.1 Use manual edits as ground truth

Edited transcripts carry `attributionSource == .manual` per segment (the
reference meeting is at revision 29). A `wder.py` in
`Tools/DiarizationAnalysis` can replay the immutable `words.json` +
`diarization.json` through the Swift host harness (`replay.py` already
compiles the production types) and score word-level agreement against the
manually corrected canonical transcript, excluding unedited segments. This
gives WDER-style numbers on real meetings with zero extra labelling and turns
2.1–2.5 and 3.3 into measurable changes.

### 5.2 Hold out at least two recordings

Keep the 155 s and 37 s local recordings untouched by tuning; add one three-plus
speaker meeting when available. Record every run's executable hash as the
README requires.

## Suggested execution order

1. **5.1 WDER harness** from manual edits (unblocks everything else).
2. **2.4 confidence + 2.1 phrase-level attribution + 2.2 bounded nearest
   fallback + 2.3 exclusive timeline**, measured together on the harness.
3. **4.1 backchannel-aware display grouping** (independent of 2).
4. **3.2 FluidAudio 0.15.7 bump** and **3.3 post-processing sweep**.
5. **3.1 microphone-track prior** (opt-in, largest identity win for remote
   meetings).
6. 3.5 VAD, 4.2, 2.5, 3.4 as follow-ups; 3.6 only if the harness still shows a
   coverage gap.

Sources checked 2026-09-11: OpenWhispr blog, WhisperX `diarize.py`, pyannote
community-1 model card, FluidAudio releases and diarization docs, DiarizationLM
(arXiv 2401.03506), NaturalTurn (Sci. Rep. 2025), local coo:979 documents and
the Scribe sources named above.
