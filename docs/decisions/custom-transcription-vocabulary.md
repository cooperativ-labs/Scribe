# Custom transcription vocabulary

**Decision:** Ship one always-on personal vocabulary that is merged into every
transcription. Use FluidAudio 0.12.4's existing CTC rescoring path (already
pinned) to correct domain terms against the audio, then apply those
replacements to Scribe's word stream — not only to the worker's `text` field.
Optional named packs can exist later; they are merged automatically and are
never a per-meeting picker.

## Why this, not a prompt or a find-replace

Scribe transcribes with **Parakeet TDT 0.6B v3** through `ParakeetAdapter` →
`AsrManager.transcribe(_:source:)`. That decoder has no Whisper-style initial
prompt. Naive string replacement on the finished transcript would also be the
wrong primary path: it has no acoustic evidence, it rewrites common short
words, and Scribe does not treat `transcript.json`'s `text` as canonical.

Canonical words come from `TokenTimingReconciler`, which reconstructs
source-relative words from timed SentencePiece tokens. FluidAudio's
`ASRResult.withRescoring` updates `text` and `ctcAppliedTerms` but **leaves
`tokenTimings` unchanged**. If Scribe only enabled
`AsrManager.configureVocabularyBoosting` and kept the current assembly path,
the review window, SRT, and JSON export would still show the uncorrected
tokens.

The pinned library already implements the correct engine:

- TDT (Parakeet v3, already installed) produces the transcript and timings.
- CTC (Parakeet CTC 110M, not installed today) scores custom terms against
  per-frame log-probabilities (NeMo CTC word spotter, arXiv:2406.07096).
- `VocabularyRescorer` replaces a TDT word or short span only when the
  vocabulary term has stronger CTC evidence and passes similarity / stopword /
  length guards.

That API was already in FluidAudio **v0.12.4** (`9830ce83`), so this decision
required no library bump. The pin later moved to **v0.12.5**
(`2d297948`) for the token-duration fix and now to **v0.15.6**
(`4dbf4f9f`) for the current worker release. The vocabulary and CTC rescoring
sources remain outside the upgraded adapter path, and every 0.12.4 statement
below is historical design context rather than the current dependency pin.

## Product model: one list, packs as an escape hatch

Transcription crosses topics, but the default should match "one vocabulary for
all of my work":

| Surface | Behaviour |
| --- | --- |
| **Personal vocabulary** | Always on. Names, companies, product spellings, jargon used across meetings. This is the list a person actually maintains. |
| **Named packs** (optional, later) | Extra lists (for example a client glossary) that can be switched on in Settings. At job time they are **unioned** with the personal list. No per-recording picker. |
| **Speaker names** | Display names from the speaker library are injected as terms automatically. They are already the proper nouns ASR most often mangles. |

Do not ask which list to use when a recording starts or a file is imported.
A forgotten picker is worse than a slightly larger always-on list. FluidAudio
documents 1–50 terms as the typical case and has tested up to ~230; a combined
work vocabulary of names plus jargon fits.

Empty vocabulary is a first-class state: skip CTC load and rescoring entirely
so people who never add terms pay nothing at runtime.

## Data model and storage

Mirror the speaker library: a local store under Application Support, a
content-addressed revision, no network.

```
~/Library/Application Support/Scribe/Vocabulary/
  library.json          # lists, terms, aliases, revision
```

Suggested records:

- `VocabularyTerm`: `id`, `text` (canonical spelling written into the
  transcript), `aliases[]` (common ASR mishearings), optional `notes`.
- `VocabularyList`: `id`, `name`, `kind` (`personal` | `pack`), `enabled`.
  Exactly one `personal` list; it cannot be disabled.
- `VocabularyLibrary.revision`: SHA-256 of a canonical, key-sorted rendering
  of every **enabled** term (text + sorted aliases). Same pattern as
  `speakerLibraryRevision`.

Text import matches FluidAudio's simple format so a glossary file can be
pasted in:

```
NVIDIA
macOS: Mac OS, Mac O S, Macos
Livmarli: Liv Mali, Liv-Marli
```

Lines starting with `#` are comments. Skip terms shorter than three characters
after sanitization (FluidAudio's default `minTermLength`); show that skip in
the editor rather than failing the save.

Do not store this in `UserDefaults`. A glossary will grow past preference-size
comfort, and the speaker library already established Application Support as
the place for durable personal data.

## Pipeline

```
Settings / speaker names
        │
        ▼
  VocabularyLibrary.snapshot()  ── revision hashed into ImportConfiguration
        │
        ▼
  Host writes vocabulary.json into the run directory
        │
        ▼
  Worker transcribe stage
        │  TDT as today
        │  if snapshot.terms is non-empty and CTC assets validate:
        │     CtcModels.loadDirect (never downloadAndLoad)
        │     configureVocabularyBoosting
        │     persist replacements with time spans
        │  release CTC + TDT before diarize
        │
        ▼
  Host TokenTimingReconciler  →  words.json
        │
        ▼
  Host applies vocabulary replacements onto words.json by time span
        │
        ▼
  SpeakerTurnBuilder / canonical-transcript.json / exports
```

### Worker contract

Keep the 1 MiB stdin envelope small. Snapshot the active terms as
`vocabulary.json` in the run directory (same pattern as every other large
artifact) and pass only `vocabularyPath: "vocabulary.json"` on the `run`
payload, analogous to `sourcePath` / `runDirectory`.

Extend `ParakeetAdapter.Transcript` / `WorkerASRTranscript` with an optional
replacements array. Each applied replacement must include:

- `original` / `replacement` text
- `startSeconds` / `endSeconds` of the TDT span that was rewritten
- scores FluidAudio already computes (optional, for diagnostics)

FluidAudio's public `RescoringResult` currently carries original and
replacement words but **not** the span times. The worker should record span
times from `VocabularyRescorer`'s word timings (those exist internally as
`spanStartTime` / `spanEndTime`) or re-derive them by aligning
`original` against the reconciled word list. Prefer capturing span times in
the worker so assembly does not guess.

`AsrManager.configureVocabularyBoosting` must be pointed at the **staged** CTC
directory. The library default is
`~/Library/Application Support/FluidAudio/Models/parakeet-ctc-110m-coreml`,
which would either miss files or trigger FluidAudio's download helpers. Scribe
already refuses those helpers in `OfflineModelLoader`.

Load CTC with `CtcModels.loadDirect(from:variant:)`, not `load` /
`downloadAndLoad`. Tokenizer files must sit in that same directory:
`tokenizer.json` and `tokenizer_config.json`.

If terms are present but CTC assets are missing, **still transcribe**. Surface
a structured warning (`vocabulary_assets_missing`) and skip boosting. Do not
block a finished recording on an optional glossary.

### Word-stream application (required)

After `TokenTimingReconciler` commits `words.json`, a small host stage walks
replacements in descending span length and, for each, replaces the word(s)
whose times overlap the recorded span:

- One TDT word → one vocabulary word: replace `text`, keep `startMs` / `endMs`.
- Several TDT words → one vocabulary phrase: join into the first word's slot,
  mark the rest empty or drop them, keep the enclosing start/end.
- Never retokenize into fake SentencePiece IDs. Downstream assembly and
  exporters already consume words, not token IDs.

Existing transcripts do not change until someone reruns them. Edits a person
makes in the review window stay ordinary transcript revisions; they do not
mutate the vocabulary unless a later "Add to vocabulary" action is built.

### Fingerprinting

Add `vocabularyRevision` to `ImportConfiguration.canonicalDescription` so a
glossary edit is a new processing configuration. Empty library → empty
revision string, which matches today's fingerprints and does not invalidate
every stored run.

`speakerLibraryRevision` already exists for the same reason. Keep the two
hashes separate: changing who is remembered is not the same as changing how
words are spelled.

## Model assets

Pin **Parakeet CTC 110M** from
`https://huggingface.co/FluidInference/parakeet-ctc-110m-coreml` in
`model_manifest.json` using the same SHA-256 / byte / revision installer as
Parakeet v3. Files FluidAudio 0.12.4 actually loads:

| Path | Role | Approx. size (current `main`) |
| --- | --- | --- |
| `MelSpectrogram.mlmodelc/weights/weight.bin` | Mel features | 0.54 MB |
| `AudioEncoder.mlmodelc/weights/weight.bin` | CTC encoder | 96.1 MB |
| `vocab.json` | CTC token map | 16 KB |
| `tokenizer.json` | BPE | 0.35 MB |
| `tokenizer_config.json` | Tokenizer settings | 1 KB |

Total on the order of **~100 MB**, not another 500 MB TDT bundle. Do not
stage `CtcHead`, TDT decoder, or joint networks from that repo; the 0.12.4
spotter only uses MelSpectrogram + AudioEncoder.

License on that Hugging Face conversion is Apache-2.0 (NVIDIA Parakeet CTC).
Add the notice beside the existing Parakeet CC-BY-4.0 and WeSpeaker notices.

Installation policy:

1. Keep today's "Install Model" as the TDT + diarization bundle so existing
   installs remain valid.
2. Treat CTC as a second, named asset group in the same installer ("Vocabulary
   boosting"). Settings copy: terms you add are applied only after this
   download finishes.
3. Queued jobs with a non-empty vocabulary wait for CTC the same way they
   already wait for Parakeet v3.

Worker peak memory: FluidAudio measures TDT+CTC at roughly double TDT-only on
iPhone (~66 MB vs ~130 MB for the encoder working set; Scribe's process RSS
is already ~465 MB with TDT loaded). Load CTC only inside the transcribe
stage and drop it before VBx, matching the current ASR/diarization split.

Long files: the CTC spotter chunks at 15 s with 2 s overlap and concatenates
log-probs `[T, 1024]`. A two-hour file is on the order of hundreds of
megabytes of log-probs. That is acceptable for Scribe's helper process if we
keep TDT and CTC from overlapping diarization, but the first implementation
should measure RSS on a long consented recording before calling the feature
done. If it is too large, run spotting per TDT chunk using the already
prepared 16 kHz file rather than holding the full matrix.

## Settings UI

Add a **Vocabulary** section to the existing grouped Settings form (same
window as the model installer). A separate Speakers-style window is
unnecessary for a term list.

First version:

- A multiline editor or a list of terms with add/remove.
- Placeholder explaining aliases (`Canonical: mishearing, other`).
- Count of active terms and whether CTC assets are installed.
- "Import from file…" for a `.txt` glossary.
- Footnote: applied to every future transcription; existing transcripts are
  unchanged until rerun.

Packs, if built later, are a disclosure under the personal list: named groups
with an on/off switch, still merged at job time.

Do not put vocabulary on the meeting chip or the import drop target.

## What this is not

| Alternative | Why not |
| --- | --- |
| Whisper / prompt biasing | Would replace Parakeet, timings, and the pinned worker. |
| Fine-tune Parakeet on personal terms | GPU training, breaks the offline pin, overkill for a glossary. |
| Decode-time TDT token boosting (`CustomVocabularyTerm.tokenIds`) | Present on the term struct in 0.12.4; the working path is CTC rescoring. Do not depend on an unused decoder hook. |
| Host-only find-and-replace after assembly | Cheap, but no acoustic check; will corrupt short function words. Keep it out of the automatic path. |
| Per-meeting vocabulary picker | Conflicts with "one list for all of my work"; easy to forget; the merge model covers topic-specific packs without that friction. |
| Mutating saved transcripts when the glossary changes | Canonical runs are immutable; `vocabularyRevision` already forces a new run on rerun. |

## Risks

- **Text vs tokens:** If replacements are applied only to `text`, the feature
  will look like it works in logs and fail in the window. Treat word-span
  application as part of the first ship, not a polish item.
- **False positives:** Short or common terms (`or` → `VR`) are why FluidAudio
  has length, stopword, and similarity guards. The editor should discourage
  terms under four characters and stopwords.
- **Alias quality:** Aliases should be *mishearings*, not synonyms. Adding
  "meeting" as an alias for a product name will over-match.
- **CTC download vs offline contract:** Any load path that calls
  `DownloadUtils` / `downloadAndLoad` is a defect. Follow `OfflineModelLoader`.
- **Long-file memory:** Measure before claiming two-hour meetings are fine.
- **Library bump later:** Newer FluidAudio docs mention a 1 MB standalone CTC
  head on TDT-CTC-110M. That is not in the pinned 0.12.4 TDT v3 bundle. Stay
  on the separate 110M encoder until a deliberate, re-benchmarked bump.

## Implementation sequence

1. **Store + Settings editor + `vocabularyRevision` on `ImportConfiguration`.**
   No ASR change yet; adding a term does not affect transcripts.
2. **Pin CTC 110M in the manifest, `OfflineModelLoader.loadCTC`, installer
   UX.** Transcription still ignores the glossary.
3. **Worker boosting + `vocabulary.json` snapshot + replacement spans in
   `transcript.json`.**
4. **Host word-span application between reconciliation and assembly, plus a
   fixture that proves `words.json` changed, not only `text`.**
5. **Optional later:** named packs, "Add this spelling to vocabulary" from a
   transcript edit, speaker-name injection.

Steps 1–4 are the feature. Step 5 is only needed if one personal list proves
unwieldy in real use.

## Shipped: step 1 (store, Settings editor, command line, fingerprint)

Steps 2–4 — the CTC model pin, worker boosting, and word-span application —
are unchanged and still to do. Adding a term today changes nothing about a
transcript; it changes what a future run will be *given*.

### Where things live

| Piece | Path |
| --- | --- |
| Model, store, text format, editor | `Modules/Vocabulary` (an independent module, like `Modules/Speakers`) |
| Library file | `~/Library/Application Support/Scribe/Vocabulary/library.json` |
| Settings section | `VocabularySettingsSection`, hosted by `ScribeSettingsView` |
| Command line | `Tools/ScribeVocabulary` → `scribe-vocab`, run through `Scripts/vocab.sh` or `mise run vocab` |
| Run configuration | `ImportConfiguration.vocabularyRevision`, filled by `TranscriptionCoordinator` at enqueue time |

### Decisions made while building it

**One file, two writers.** The Settings editor and `scribe-vocab` open the
same document, so every read-modify-write takes an advisory `flock` on a
sidecar lock file and writes atomically. The settings window also watches the
directory, so a term an agent adds while the window is open appears in it. This
is why the editor holds no unsaved in-memory copy: an editor buffer would make
one of the two writers lose.

**Short terms are kept, not refused.** A term under three characters is stored,
marked in the list and in `scribe-vocab list`, and excluded from `activeTerms`.
Refusing the save would lose the fact that someone tried; applying it would let
the word spotter rewrite ordinary speech. Common English words are flagged the
same way.

**Adding merges.** `add` on a term that is already present unions its
mishearings into the existing row rather than creating a second one, which is
what makes the command safe for an agent to run more than once.

**`vocabularyRevision` is read at enqueue, not carried on the request.** A job
arrives three ways — the recorder handoff, a folder import, and a dropped file
— and only the coordinator sees all three. A request that names its own
revision keeps it; otherwise the coordinator asks the store. An empty
vocabulary contributes no field at all to `canonicalDescription`, so every run
recorded before this feature keeps the fingerprint it was stored under.

**The transcript window routes rather than edits.** Its toolbar has a
Vocabulary button that opens Settings and marks the section. The list is not a
property of the transcript being read, and a change to it does not alter that
transcript, so editing it in place would misrepresent what the edit does.

### Not built yet

Packs exist in the model, the store, and `scribe-vocab` (`pack add`,
`enable`, `disable`, `remove`) because the merge semantics had to be settled
before the file format was written. They have no Settings UI: one personal list
is the product until it proves unwieldy.
