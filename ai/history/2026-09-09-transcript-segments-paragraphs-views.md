# Segments and Paragraphs transcript views

Date: 2026-09-09
Mission: coo:992
Objective: coo:992.x38g

## What changed

The review window now has two layouts:

- **Segments** — each canonical turn, for precise review, split, merge, and word edits
- **Paragraphs** — reading view derived from those turns without rewriting the saved transcript

Paragraphs group consecutive same-speaker canonical segments using the existing `TranscriptDisplayGrouper` limits (1s pause, preferred 12s / 40 words, hard 30s / 80 words). Speaker changes, unknown spans, overlap flags, and interruptions stay visible. Unknown turns are not treated as one speaker: a sentence boundary still splits them.

Playback position, the selected canonical segment, and source mappings are kept when switching views (⌘1 / ⌘2).

## Reference run baseline

Run: `/Users/jake/Meeting Transcripts/meeting--12cc48aa2c740dc50eb637b4b25a274f/runs/767535C4-424D-48BF-A178-E36435C01F12` (canonical revision 3)

| Measure | Value |
| --- | --- |
| Canonical segments | 1033 |
| Presentation paragraphs | 1033 (1:1 under current limits) |
| Grouped paragraphs (2+ sources) | 0 |
| Unknown paragraphs | 548 |
| Unknown stored words | 814 / 9656 |
| Adjacent same-known-speaker paragraph pairs | 70 |
| Adjacent unknown-unknown paragraph pairs | 153 |
| Overlap segments still marked | 8 |

This run was already grouped at assembly time with the same limits, so Paragraphs does not yet join additional turns. Remaining fragmentation is mostly unknown interruptions (next objective) and pauses / preferred length caps (later boundary tuning).

## Representative timestamps

- `00:01:07.760` Unknown `Hello.`
- `00:01:09.840` Unknown `hey.` — not merged with the previous unknown sentence
- `00:01:11.600` Jason Garcia `I need two minutes to kick start something and then I will`
- `00:01:16.160` Unknown `Okay.` — short interruption, not absorbed
- `00:01:37.680` Unknown `Yeah,`
- `00:01:38.080` Jason Garcia `we have these marketing partnerships that you'`
- `00:01:41.680` Unknown `ll` — split contraction remains unresolved
- `00:16:02.400` Jason Garcia, 71 words — longest known paragraph on this run

## Manual test procedure

1. Open the reference meeting in Scribe and select the completed transcript.
2. Confirm the header shows **1033 turns · 1033 paragraphs**.
3. In **Segments**, find `00:01:07` (`Hello.` / `hey.`) and `00:01:16` (`Okay.` interrupting Jason).
4. Play from Jason’s `00:01:11.600` turn, pause mid-turn, then switch to **Paragraphs** (⌘2). Play head, selection, and speaker readout must stay put.
5. In **Paragraphs**, confirm `Hello.` and `hey.` stay two unknown rows, `Okay.` stays its own span, and the `you'` / `ll` split near `00:01:38` is still two rows.
6. Press ⌥↓ / ⌥↑ and confirm navigation walks paragraphs, not hidden internals.
7. Switch back to **Segments** (⌘1). Split, combine, and edit words still operate on canonical turns. Export TXT/JSON/SRT still matches saved segments, not a rewritten transcript.

## Tests

`swift test --filter 'TranscriptViewModelTests|TranscriptDisplayGroupingTests|TranscriptEditingTests|TranscriptParagraphGroupingTests'` in `Modules/Transcription`: 63 tests passed, including the on-disk reference run.

The macOS window itself was not launched in this session; visual layout of the segmented control still needs a look in the app.
