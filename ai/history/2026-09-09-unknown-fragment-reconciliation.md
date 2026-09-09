# Conservative unknown-fragment reconciliation

Date: 2026-09-09
Mission: coo:992
Objective: coo:992.d06z

## What changed

A separate pass, `UnknownFragmentReconciler`, now runs after the turn builder. It does not rewrite canonical `speaker_id` values, words, timestamps, or overlap flags.

It only infers identity for a **same-speaker / short unknown / same-speaker** sandwich when diarization timing supports continuity:

- unique adequate overlap with that speaker, or
- a short unoccupied hole between that speaker’s intervals that actually cover the two neighbors

Neighbor identity and wording are not enough. Manual labels are skipped. Unresolved unknowns keep an evidence tag: `no_coverage`, `insufficient_overlap`, or `competing_speakers`.

Paragraphs view can join an inferred fragment with its neighbors. Segments view still shows the original unknown row, now labeled `(inferred)` in orange. TXT/JSON/SRT still export the original unknown speaker.

## Limits used

| Knob | Value |
| --- | --- |
| Max unknown duration | 1000 ms |
| Max neighbor gap | 1500 ms |
| Max diarization hole | 1500 ms |
| Max words | 3 |
| Overlap rule | 50 ms and 50% of the fragment (same as the turn builder) |

Provenance: `unknown-fragment-reconciliation-v1`.

## Reference run vs baseline

Run: `/Users/jake/Meeting Transcripts/meeting--12cc48aa2c740dc50eb637b4b25a274f/runs/767535C4-424D-48BF-A178-E36435C01F12` (canonical revision 3, not rewritten on disk). Review applies the pass in memory; new assemblies persist it.

| Measure | Baseline (coo:992.x38g) | After this pass |
| --- | --- | --- |
| Canonical segments | 1033 | 1033 (original speaker IDs unchanged) |
| Presentation paragraphs | 1033 | 959 |
| Grouped paragraphs (2+ sources) | 0 | 35 |
| Unknown segments | 548 | 509 unresolved, 39 inferred |
| Unknown stored words | 814 / 9656 | 771 remaining (43 inferred) |

## Positive / negative cases

Repaired (boundary-gap examples):

- `03:01.360` `we` between Jason’s “convert,” and “get revenue share”
- `12:30.240` split `s` in “that' / s / going”

Left unresolved on purpose:

- `01:07.760` `Hello.` and `01:09.840` `hey.` — no diarization coverage, not a sandwich
- `01:16.160` `Okay.` — insufficient overlap with Jason (55 ms of 160 ms); treated as a possible interruption
- `01:41.680` `ll` after `you'` — insufficient overlap (52 ms of 320 ms); split contraction remains two rows
- `16:32.560` overlapping `It's` — competing speakers

## Audio check

Clips from `source.m4a`, 16 kHz mono, RMS by thirds:

- `03:01` `we` (repaired): 1087 / 1560 / 1044 — continuous energy with neighbors
- `12:30` split `s` (repaired): 900 / 1867 / 1523 — continuous
- `01:07` Hello/hey: 659 / 556 / 57 — speech then drop, matches no coverage
- `01:16` Okay: 448 / 551 / 75 — short burst, left unresolved
- `01:38` you'/ll: 1080 / 1093 / 1557 — continuous speech **not** repaired (false negative from the overlap rule)
- `16:32` overlap: high energy throughout, left competing

All 39 repaired strings were mid-turn fragments (`we`, `that`, `Um,`, `s`, `there`, `about`, …). None looked like a second-speaker backchannel on the transcript. This is not a full listen of every repair; `ll` is a known miss, not a wrong assignment.

## Manual test procedure

1. Open the reference meeting and the completed transcript. Header should show **1033 turns · 959 paragraphs**.
2. In Segments, `Hello.` / `hey.` stay unknown. `Okay.` at `01:16` stays unknown. `you'` / `ll` near `01:38` stay two rows; `ll` is still unknown.
3. Find `03:01.360` `we`: original speaker is unknown, label is **Jason Garcia (inferred)**. Switch to Paragraphs; it should sit inside Jason’s surrounding sentence with an **Inferred attribution** badge.
4. Play from the previous Jason turn, switch views: play head and selection stay put.
5. Assign `we` to Jacob Chase-Lubitz. Both views update. Undo restores the inferred state. Export TXT still says Unknown speaker until a manual label is saved as the canonical speaker.

## Tests

`swift test --filter 'UnknownFragmentReconcilerTests|TranscriptParagraphGroupingTests|TranscriptDisplayGroupingTests|TranscriptViewModelTests|TranscriptEditingTests|CanonicalTranscriptTests|TranscriptExporterTests|TranscriptSpeakerAssignmentTests|SpeakerTurnBuilderTests|ModuleIntegrationTests|TranscriptionCoordinatorTests'` in `Modules/Transcription`: 134 tests passed.

## Remaining issues (for later objectives)

- 509 unknown segments remain, including the `you'` / `ll` split and opening acknowledgments.
- Same-speaker pauses still split paragraphs at 1 s (boundary work is the next objective).
- A short real interruption that falls in a diarization hole could still be inferred; report it if one shows up in listening.
- Uncertainty review UI (select marker → correct → undo) is not in this step.
