# Reading-oriented paragraph boundaries

Date: 2026-09-09
Mission: coo:992
Objective: coo:992.crzj

## What changed

`TranscriptParagraphGrouper` no longer borrows `TranscriptDisplayGrouper.Configuration`.
Paragraph boundaries are now a reading decision with their own settings; canonical
segmentation and subtitle timing still belong to `TranscriptDisplayGrouper`, which is
untouched.

Boundary rules inside one continuous turn, in preference order:

1. **Sentence ending.** A break may only land on a sentence ending, unless a hard cap forces it.
2. **Meaningful pause.** A gap of 1.5 s or more at a sentence ending closes the paragraph.
   A gap inside a sentence reads as hesitation and only breaks at 2.5 s.
3. **Length.** A sentence ending under 40 words is not a break, so short connected
   sentences stay together. Past 40 words the next sentence ending closes the paragraph.
   110 words or 60 s is a hard cap that may split mid-sentence.

Unchanged and re-checked: a speaker change (including known/unknown) always splits;
an unresolved span keeps the tighter 1 s pause limit and never joins across a sentence
ending, so two unknown sentences are never merged on the strength of both lacking an ID.
New in this step: an **overlap transition also splits**, so overlapping speech is no
longer absorbed into a clean paragraph where the marker would lose meaning.

Text, word timings, source-segment mappings, and chronological order are unchanged —
paragraphs still concatenate segment text verbatim and map back to every source ID.

## Chosen settings

| Knob | Value | Why |
| --- | --- | --- |
| `sentencePauseMs` | 1 500 | Low end of the 1.5–2 s candidate band; 2 000 merged only 2 more paragraphs. |
| `hardPauseMs` | 2 500 | Cuts same-speaker mid-sentence breaks from 32 to 1; 3 000 was identical. |
| `unknownPauseMs` | 1 000 | Unchanged from the baseline. Unknown spans stay conservative. |
| `minimumWordCount` | 40 | Best of 40/50/60. See the sweep below. |
| `maximumWordCount` | 110 | Headroom to reach a sentence ending instead of splitting mid-sentence. |
| `maximumDurationMs` | 60 000 | Hard cap only; the old 12 s *preferred* duration rule is gone. |

### Sweep on the reference run (reconciled segments)

| sentencePause | hardPause | minWords | paragraphs | p95 words | >80 w | mid-sentence breaks |
| --- | --- | --- | --- | --- | --- | --- |
| 1500 | 2500 | **40** | **917** | **55** | **2** | **1** |
| 1500 | 2500 | 50 | 901 | 62 | 9 | 2 |
| 1500 | 2500 | 60 | 898 | 66 | 10 | 2 |
| 2000 | 2500 | 40 | 915 | 55 | 2 | 1 |
| 1500 | 2000 | 40 | 920 | 54 | 2 | 4 |

50 and 60 buy ~16 fewer paragraphs but push nine or ten paragraphs past 80 words, outside
the readable band the objective asked for. 40 was chosen.

## Reference run, before and after

Run: `/Users/jake/Meeting Transcripts/meeting--12cc48aa2c740dc50eb637b4b25a274f/runs/767535C4-424D-48BF-A178-E36435C01F12` (revision 3, not rewritten on disk).

| Measure | coo:992.d06z | This step |
| --- | --- | --- |
| Canonical segments | 1033 | 1033 (unchanged) |
| Paragraphs (reconciled) | 959 | 917 |
| Paragraphs (raw, no reconciliation) | 1033 | 994 |
| Grouped paragraphs (2+ sources) | 35 | 62 |
| Adjacent same-known-speaker pairs | 74 | 32 |
| Same-speaker **mid-sentence** breaks | 34 | 1 |
| Known-speaker paragraphs in the 40–80 word band | 52 | 67 |
| Known paragraphs under 10 words | 115 | 101 |
| p95 / max words per known paragraph | 47 / 71 | 55 / 96 |
| Unknown paragraphs | 509 | 509 (unchanged) |
| Adjacent unknown pairs | 153 | 153 (unchanged) |
| Total words | 9656 | 9656 (unchanged) |
| Speaker changes between paragraphs | 809 | 809 (unchanged) |

The single remaining same-speaker mid-sentence break is at `29:12.880` after a 4.72 s
silence — a justified break, and the regression test now requires every mid-sentence
break to be backed by a gap of at least `hardPauseMs`.

Example of a repaired long explanation, `21:04.560`, now one 96-word paragraph from eight
segments instead of eight rows:

> I feel like one of the nice things about being trying to start a company is y it forces
> you to do that to do that in so many domains at once. Whereas I think if you are an
> employee, particularly one in like a very defined job is you know you're you're
> constrained to that area of the learning. …

Preserved structure in the first two minutes (unchanged from the previous step):

- `01:07.760` `Hello.` / `01:09.840` `hey.` — separate unresolved paragraphs.
- `01:16.160` `Okay.` — still splits Jason's sentence into two paragraphs; the interruption survives.
- `01:37.680` `Yeah,` and the `you'` / `ll` split near `01:38` — still separate rows.

## Known remaining issues

- Median known-paragraph length is still 16 words. Boundary tuning cannot fix this: only
  32 adjacent same-known-speaker pairs remain, so most short paragraphs are separated by a
  real speaker change or an unresolved span, not by a boundary choice.
- Two paragraphs exceed 80 words (82 and 96). A paragraph can only break at a canonical
  segment boundary, and those segments contain sentence endings internally. Breaking inside
  a segment would need a sub-segment mapping, which is out of scope for a presentation pass.
- The overlap-transition split adds breaks wherever the overlap flag toggles inside one
  speaker's turn. That is deliberate (the marker keeps its meaning) but it does fragment
  overlapping stretches.

## Manual test procedure

1. Open the reference meeting's completed transcript. The header should read
   **1033 turns · 917 paragraphs**.
2. Switch to Paragraphs and go to `21:04`. Jacob's explanation should read as one paragraph,
   not eight rows.
3. Go to `29:08`. The break at `29:12.880` is mid-sentence — confirm there is a long silence
   there in playback; it is the only one of its kind in the run.
4. Go to `01:16`. Jason's sentence is still split by the unknown `Okay.` interruption.
5. Go to `01:38`. `you'` and `ll` are still two rows and `ll` is still unknown.
6. Switch to Segments and back: 1033 rows, play head and selection unchanged.
7. Export TXT/JSON/SRT and confirm the output is identical to before this change.

## Tests

`swift test --package-path Modules/Transcription` — 282 passed. New focused cases in
`TranscriptParagraphGroupingTests`: short connected sentences stay together, a meaningful
pause at a sentence ending splits, a mid-sentence pause only splits at the hard limit, a
long passage breaks at the first sentence ending past the minimum, the hard word cap splits
mid-sentence, overlapping speech is not absorbed, and unknown fragments keep the tighter
pause limit. The reference-run test now also asserts the mid-sentence-break and word-cap
bounds. `xcodebuild -scheme Scribe` succeeds.
