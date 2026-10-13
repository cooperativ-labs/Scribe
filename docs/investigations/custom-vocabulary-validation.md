# Custom vocabulary validation — 2026-10-13

Objective: `coo:1140.d95c`. Desktop implementation, built locally; this report
does not claim a signed release or production rollout.

## Result

Batch and dictation use the pinned local CTC assets and preserve vocabulary
snapshots. Real worker integration passed with **all network access denied**.
The two-hour fixture produced **1,103 audio-backed replacements**, all of which
were applied to canonical timed words, including spans beyond one hour. Missing
optional assets returned normal transcription and a vocabulary-unavailable warning.

## Environment and fixtures

- Apple Silicon arm64, macOS 27.0.1 (`26A434`), Xcode beta toolchain.
- FluidAudio 0.17.4, revision `21493f8dac5a97e65742e6ff26f42f164c2fda0f`.
- Debug workers, `cpuAndNeuralEngine`; local SHA-256-verified model files.
- CTC revision `accdafd8cf8a2ff1cabe3c11e54416b405d409aa`.
- Local Samantha speech: “We prescribe Liv mar lee for the patient. The company
  is Cooperativ. Please deploy on Kubernetes with Jake and Neah.”
- Three-second dictation crop and two-hour repetition of the 6.527-second clip.
- Snapshot: `Livmarli` with mishearing aliases, `Cooperativ`, and `Neah`.
  No private meeting recording was used.

Each inference process ran under this Seatbelt policy:

```scheme
(version 1)
(allow default)
(deny network*)
```

The CTC loader and tokenizer were also checked in the pinned source: explicit
local file APIs are used throughout; no model-hub/download recovery path is called.

## Checks

| Check | Result |
| --- | --- |
| Actual macOS app build | Passed, code signing disabled for compilation |
| Full host transcription suite | 377 tests, 0 failures, 2 reference-recording tests skipped because their data is absent |
| Current real worker integration suite | 5 tests passed; includes offline batch, 3-second dictation, empty vocabulary, non-hit, missing CTC assets, and two-hour canonical spans |
| Final focused canonical/export/job tests | 21 passed |
| Final worker suite | 25 passed |
| Vocabulary store/revision suite | 21 passed |
| Platform/installer suite | 48 passed |
| Focused dictation engine suite | 7 passed |
| Optional model file hash/size verification | Passed |
| Shell syntax and `git diff --check` | Passed |

The export integration checks `words.json`, canonical validation, review, TXT,
SRT, JSON and Knowledgebase JSON. Raw token text remains unchanged. Snapshot
tests cover aliases, enabled packs, edits after enqueue, retry, recovery, speaker
reprocessing and fresh retranscription.

A real audio test exposed an upstream proposal to replace “clear comply works”
with “Clear Comply.” The additional neighbor guard rejects it and retains
“works.” Exact spelling changes require independently aligned CTC detections;
a term with insufficient evidence remains unchanged. Unit tests cover punctuation,
multiword output, repeated phrases, overlap rejection and this guard.

## Two-hour memory measurement

Machine-readable observations are in
[custom-vocabulary-memory.json](custom-vocabulary-memory.json).

| Run | Duration | Peak RSS | Wall time | Replacements |
| --- | --- | --- | --- | --- |
| Empty vocabulary, TDT only | 7,200 s | 627,785,728 bytes (598.7 MiB) | 74.88 s | 0 |
| TDT + bounded CTC vocabulary | 7,200 s | 594,231,296 bytes (566.7 MiB) | 610.76 s | 1,103 |

Both runs used disk-backed TDT chunking and returned 41,118 timed tokens.
The vocabulary run had no unavailable warning. The first correction starts at
0.56 seconds; the last starts at 7,193.52 seconds, demonstrating source-relative
spans across chunk boundaries. The host applied every `Livmarli` replacement.
A preceding measurement of the same bounded acoustic path peaked at 612,614,144
bytes (584.2 MiB).

These are single Debug runs, with model compilation/cache and mapped-file RSS
variation and other validation activity on the machine. The lower measured RSS
with CTC does **not** establish that CTC saves memory. Elapsed time is diagnostic,
not a controlled throughput comparison. Log probabilities are bounded in code
to a 30-second core plus three seconds of context per side. The long measurements
cover the acoustic/alias path; exact-spelling formatting is separately tested.
This is evidence of a working bounded local path, not a broad accuracy claim.

## Existing failure left outside this objective

The full dictation suite has three assertions failing in
`DictationTextInserterTests.testInaccessibleComposerUsesUnverifiedPasteAndKeepsTranscript`
(`discarded` versus `unverifiedPaste`, and missing paste/clipboard outcomes).
The same three assertions reproduce from an untouched `HEAD` archive in a
separate temporary checkout. Insertion and generic cleanup were left unchanged,
as required by the objective. The vocabulary-related engine tests pass.

## Reproduce

Stage the models through the explicit installer, then run:

```sh
Scripts/package-transcription-models.sh
Scripts/validate-vocabulary-offline.sh --long
```

The validation script generates local speech, builds the pinned worker, denies
network access to inference processes, runs real integration tests, and retains
its synthetic artifacts and `/usr/bin/time -l` logs in the printed temporary
directory. It requires the local Samantha voice, FFmpeg, Swift/Xcode and staged
model assets. Omit `--long` for short batch/dictation validation only.

Existing app installations need **Settings → Transcription model → Install
Vocabulary Boosting** after updating. The regular model remains usable while
that optional group is absent. Developer model files are staged in the repository;
they are not automatically copied to the user's configured Models folder.
