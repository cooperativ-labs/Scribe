# Custom transcription vocabulary

**Status:** Implemented for desktop batch transcription and dictation on the
pinned FluidAudio **0.17.4** (`21493f8dac5a97e65742e6ff26f42f164c2fda0f`).
Vocabulary boosting requires the optional local CTC assets. It does not change
text insertion or generic dictation cleanup. See
[validation evidence](../investigations/custom-vocabulary-validation.md).

## Product behavior

One personal vocabulary is always active. Enabled named packs are unioned with
it; there is no per-recording picker. Manage terms in **Settings → Vocabulary**
or through `Scripts/vocab.sh`. Packs are currently managed through the CLI.
Aliases describe actual mishearings, not synonyms:

```text
NVIDIA
macOS: Mac OS, Mac O S
Livmarli: Liv Mali, live marly
```

Terms shorter than three characters, or without letters and numbers, remain stored but are excluded from active
snapshots. Upstream stopword, length and acoustic guards still apply. Speaker
names are not automatically injected; speaker identity and spelling remain
separate concerns.

In **Settings → Transcription model**, install **Vocabulary Boosting** separately
from the normal Parakeet/diarization bundle. The optional group is approximately
103 MB. Existing base installations remain valid. If terms exist but CTC assets
are missing, corrupt or unusable, normal transcription completes and shows a
**Vocabulary unavailable** warning. Queued jobs do not wait for optional assets.
This fallback supersedes the earlier proposal to block jobs until CTC installation.
An empty vocabulary skips CTC validation, loading and inference entirely.

## Snapshots and reproducibility

The durable library is
`~/Library/Application Support/Scribe/Vocabulary/library.json`. Settings and
`scribe-vocab` share its locked, atomic read/modify/write path.

At batch enqueue, the coordinator reads one complete `VocabularySnapshot`:
canonical terms, aliases, enabled-pack contents and a content revision. It
stores that snapshot in `job.json` and `vocabulary.json` inside the run directory.
The revision participates in `ImportConfiguration.canonicalDescription`.
The v2 revision includes exact canonical spelling and aliases, independent of
term order. A capitalization change can change output and therefore changes
this revision. Empty vocabulary keeps the historical empty fingerprint.

- Recovery and retry retain the original snapshot and configuration.
- Reprocessing speaker count retains the original snapshot.
- **Transcribe again** captures the current vocabulary and creates a fresh run.
- Historical jobs without snapshots do not acquire today's terms on retry.

Dictation captures a snapshot when each request enters `DictationEngine`, before
waiting for warming or another request. Publication is serialized with inference
so concurrent requests cannot overwrite the snapshot in use. The request's
`vocabulary.json` and `dictation-transcript.json` carry its revision, raw text,
corrected text and replacement evidence. Dictation's existing temporary-run
cleanup still removes these artifacts after the session; batch snapshots remain
available for durable reruns.

## Offline model contract

`Workers/TranscriptionWorker/model_manifest.json` pins every file, byte count and
SHA-256 for **Parakeet CTC 110M** at revision
`accdafd8cf8a2ff1cabe3c11e54416b405d409aa` from
[FluidInference](https://huggingface.co/FluidInference/parakeet-ctc-110m-coreml).
Only the following assets are needed by 0.17.4:

- Complete `MelSpectrogram.mlmodelc` bundle.
- Complete `AudioEncoder.mlmodelc` bundle, including its CTC output.
- `vocab.json`, `tokenizer.json`, `tokenizer_config.json`.

No separate CTC head or TDT decoder is installed for this group. Both the host
installer and `Scripts/install-vocabulary-models.py` verify the pinned files.
`Scripts/package-transcription-models.sh` also stages and verifies this group.

Runtime inference uses `CtcModels.loadDirect(from:variant:)` and explicit local
`CtcTokenizer.load(from:)` paths. It never calls model-hub recovery, download,
or default-cache convenience APIs. Telemetry and runtime downloads must be false
in the manifest. Loading or scoring failures return raw ASR with the structured
`vocabulary_assets_unavailable` warning.

The model card says Apache-2.0, while its repository metadata also labels
CC-BY-4.0. Both notices and attribution ship with the app:
`Licenses/Parakeet-CTC-110M.txt` and `Licenses/Parakeet-CC-BY-4.0.txt`.

## Audio-backed correction

TDT produces raw text and timed tokens. Afterward, the shared
`OfflineVocabularyRescorer` loads CTC only for usable vocabulary and reads the
prepared 16 kHz mono file in 30-second core windows, with up to three seconds
of audio context on either side. Log-probability memory is bounded to one window,
not the duration of a meeting. CTC and TDT leave scope before batch diarization.
Dictation retains its existing resident TDT manager but releases CTC per request.

FluidAudio 0.17.4's public `ctcTokenEvaluateCandidates` API provides original
phrases, canonical terms, source spans, acoustic scores and overlap outcomes.
Scribe accepts candidates which passed acoustic comparison and upstream
arbitration, with additional conservative guards:

- Disable the spotter rescue pass and taper boosts for short token sequences.
- Require an exact whole-phrase alias, or strong similarity and length agreement.
- Never consume neighboring words around an already-present vocabulary phrase.
- Own a candidate by its start in one core window and reject overlapping spans.
- Match the original phrase against the timed words before applying a correction.
- Canonicalize exact spelling/capitalization only with an independent CTC detection
  overlapping that same audio occurrence.

These choices favor precision over recall. Adding a term does not guarantee a
replacement. Aliases still require acoustic evidence; there is no automatic
host-only find-and-replace path.

## Canonical words and exports

The worker emits `rawText`, `text`, `vocabularyRevision`,
`vocabularyReplacements` and an optional warning in `transcript.json`. Token
IDs and token timings remain raw. Replacements include original/replacement
text, source-relative start/end seconds and acoustic scores.

The host reconciles raw tokens, then applies replacements to **canonical timed
words before writing `words.json`**. It preserves punctuation, uses the original
first word's ID and enclosing span, and collapses a multiword replacement into
one real timed slot. It never invents SentencePiece IDs or internal word timings.
Invalid, overlapping, mismatched or ambiguous spans are skipped conservatively.

Review, speaker assembly, TXT, SRT, canonical JSON and Knowledgebase JSON all
consume those corrected words. Canonical processing metadata points to the
snapshot and raw ASR artifact. Existing transcripts and review revisions remain
unchanged until deliberately retranscribed.

## Verification

Focused tests cover snapshots, aliases and enabled packs, changed revisions,
retry/recovery/reprocessing, empty and short vocabulary, missing optional assets,
non-hits, punctuation, multiword output, repeated occurrences, overlap arbitration,
and corrections reaching review and exports.

The opt-in real integration test exercises batch preparation, offline worker
inference, host canonical assembly and three-second dictation. Run it with a
worker wrapped in a deny-network sandbox and the fixture environment documented
in the validation report. Memory measurements use local synthetic speech; they
establish bounded-window behavior, not accuracy on all accents or terminology.
