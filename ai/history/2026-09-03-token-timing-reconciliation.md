# Token-to-word timing reconciliation (coo:906.zm16)

Picked up the blocked ASR reconciliation work after `docs/feasibility/asr-timing.md` landed.

## What changed

Host-side `TokenTimingReconciler` reconstructs source-relative `RecognizedWord`s from recorded worker token JSON:

- SentencePiece `▁` / leading-space word boundaries, subword join, and punctuation attachment (no empty word cues)
- Working-file seconds mapped through `AudioTimeMapping`
- Optional chunk-relative offsets restored; proven seam duplicates (matching text/id + time within half the 2.0 s overlap) dropped
- Invalid or out-of-bounds times kept as `segment_only` text inside the recognized span
- Worker-output fixtures covering punctuation, subwords, two-boundary 40.603 s chunks, relative offsets, Unicode, no speech, invalid timing, and past-one-hour

## Tests

`swift test` in `Modules/Transcription`: 29 tests, 0 failures. Reconciler coverage includes no duplicated/lost unique words across chunk-boundary fixtures and all word times within source duration.
