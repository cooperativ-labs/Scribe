# Vocabulary transcription latency — 2026-10-13

Objective: `coo:1158.k526`. Investigation complete; no application or inference
behavior was changed. Diagnostic scripts and measurements accompany this report.

The reported slowdown is reproducible. Vocabulary rescoring waits until after
ordinary speech recognition, loads a second acoustic model, and withholds the
result until its work finishes. The persistent dictation worker retains the TDT
speech model but recreates the CTC vocabulary stack on **every** request. Its
existing warm operation does not prepare CTC.

## Measurements

Release worker, macOS 27.0.1, Apple Silicon arm64, FluidAudio 0.17.4. All inference
processes ran with networking denied. Audio was 6.5271875 seconds of locally
generated Samantha speech, using the three-term synthetic vocabulary from the
existing offline validation. No private recording or personal vocabulary was read.
Raw observations are in [vocabulary-transcription-latency.json](vocabulary-transcription-latency.json).

| Persistent dictation worker | Wall time |
| --- | ---: |
| Explicit TDT/VAD warm, before any dictation | 4.068 s |
| First empty-vocabulary request | 1.206 s |
| First active-vocabulary request | **41.225 s** |
| Five subsequent active-vocabulary requests | **1.675–2.598 s**, median 1.967 s |
| Five subsequent empty-vocabulary controls | **0.209–0.345 s**, median 0.263 s |

Requests alternated empty/active/active/empty vocabulary for three cycles in the
same process. Every request returned 37 raw tokens; active requests produced one
replacement, empty requests none. None returned an unavailable warning. The
steady active median was about 7.5 times the steady empty median, adding about
1.70 seconds on this fixture.

A separate optimized probe recreated the same CTC setup and keyword-spotting
calls, with two predictions on each loaded model instance:

| CTC stage | First iteration | Second | Third |
| --- | ---: | ---: | ---: |
| SHA-256/size validation, 102,803,087 declared bytes | 0.623 s | 0.063 s | 0.054 s |
| `CtcModels.loadDirect` | **45.797 s** | 0.836 s | 0.507 s |
| Both tokenizer loads, encoded terms, context and rescorer construction | 0.0085 s | 0.0076 s | 0.0077 s |
| First keyword-spotting prediction | 0.213 s | 0.206 s | 0.212 s |
| Second prediction, reusing the same model instance | 0.196 s | 0.204 s | 0.217 s |

This isolates the large first-use delay to **model loading**, rather than
tokenizer/vocabulary parsing or acoustic prediction. Faster subsequent loads
are consistent with Core ML preparation/caching; this probe does not distinguish
compilation, accelerator initialization, and other internal Core ML work.
Repeated model loading also remains material after that first-use cost subsides.
The setup probe does not measure candidate comparison or final text replacement,
so its stages should not be summed as a complete dictation measurement.

An earlier preliminary launch, before the speech fixture was valid, spent
42.973 seconds in TDT/VAD warm. It is excluded from the successful dictation
series. The main speech stack therefore also has a separate first-use cost;
the vocabulary experiment explicitly warmed it before comparing requests.

These are local observations, not a latency guarantee. System load and Core ML
caches were not reset or controlled. The first-use event need not repeat on
every launch, but the per-request CTC construction is unconditional whenever
usable vocabulary is present.

## Recurrence after a few minutes idle

The user additionally reports that the long delay returns after a few minutes
without dictation. The host's
[DictationEngine.swift](../../Modules/Dictation/Sources/Dictation/DictationEngine.swift)
only schedules timed unloading when `keepLoaded` is false. Warning memory
pressure unloads in that mode; critical pressure unloads even when keep-loaded
is enabled. Turning dictation off, worker failure, or changing the model folder
can also require a new warm-up.

The two saved `com.scribe.app` preference keys for keep-loaded and idle minutes
were absent when read directly from the plist. Current source therefore selects
**keep-loaded = true**, with an inactive default ten-minute timer. It would be
incorrect to attribute the user's few-minute recurrence to that timer without
further evidence. Independently, CTC is never retained between requests: even
with TDT resident, every dictation depends on Core ML loading the vocabulary
model again. Loss of its preparation/cache benefits could therefore expose the
long loading path without an application-level idle timeout.

A same-process idle experiment was prepared with `--idle-seconds 180`, but its
initial **TDT warm** timed out after 180 seconds before the idle phase began.
An auxiliary 60-second batch baseline with **empty** vocabulary also timed out
after 180 seconds. Neither timeout proves a vocabulary failure.

During those later checks, the startup/data disk reported **100% capacity**
(136 MiB available), and a two-second process sample failed explicitly with
`No space left on device`. Removing only this investigation's 79 MiB temporary
compiler cache left about 206 MiB available. Other files were left intact.
This is a concrete environmental constraint that may interfere with model
preparation; its contribution to the user's original symptom is unproven.
The successful earlier comparison and setup measurements stand, but the idle
recurrence itself was **not reproduced in a valid controlled run**. Restore
disk headroom before drawing further conclusions from cold/idle measurements.

A one-time memory query reported 35% free system memory; it does not rule out
earlier critical pressure. The installed Scribe helper was present and had a
different binary hash from the local Release worker used here, which can reflect
signing/packaging as well as source differences. These measurements concern the
local build, not a direct timing trace of the installed app.

## Call-path evidence

- [WorkerDictationSession.swift](../../Workers/TranscriptionWorker/Sources/TranscriptionWorkerSupport/WorkerDictationSession.swift):
  `warm()` retains TDT/VAD only; `dictate()` awaits vocabulary rescoring after
  TDT, then builds the response and writes `dictation-transcript.json`.
- [OfflineVocabularyRescorer.swift](../../Workers/TranscriptionWorker/Sources/ScribeInference/OfflineVocabularyRescorer.swift):
  each nonempty snapshot loads CTC, a tokenizer, context, spotter and rescorer.
  `VocabularyRescorer.create` loads the tokenizer a second time. Empty vocabulary
  exits before any of these calls. Loading has no application-level time budget.
- [OfflineModelLoader.swift](../../Workers/TranscriptionWorker/Sources/ScribeInference/OfflineModelLoader.swift)
  and [ModelManifest.swift](../../Workers/TranscriptionWorker/Sources/ScribeInference/ModelManifest.swift):
  every CTC load rechecks the optional group's file sizes and SHA-256 hashes.
- [ParakeetAdapter.swift](../../Workers/TranscriptionWorker/Sources/ScribeInference/ParakeetAdapter.swift):
  batch ASR similarly awaits vocabulary work before returning its transcript.
  Its `processingTimeSeconds` measures upstream ASR, excluding the vocabulary
  step, so that field understates end-to-end latency when boosting is enabled.
- Long recordings receive a second acoustic pass in 30-second cores with
  three-second margins. The pinned spotter then splits those windows at its
  15-second model limit with two-second overlaps. Prewarming alone cannot remove
  this ongoing cost. The previous
  [two-hour validation](custom-vocabulary-validation.md#two-hour-memory-measurement)
  already recorded 74.88 seconds without vocabulary versus 610.76 with it in
  single Debug runs; those are supporting observations, not a controlled ratio.

## Recommended implementation

1. Retain a CTC model/tokenizer inside the dictation worker, with lifetime tied
   to its existing idle-unload and memory-pressure policy. Validate the asset
   group once when loading each instance. Bind the instance to the model folder
   and manifest identity; reload after a model installation/change. Keep missing
   or corrupt assets fail-open, and permit recovery after assets are installed.
2. Prepare the optional booster during dictation warm-up when usable vocabulary
   exists, including a representative prediction before reporting it ready.
   Warm-up must receive the vocabulary snapshot; the current warm command does
   not. Cache encoded terms/context by snapshot contents or a verified revision,
   and continue honoring each request's fresh snapshot and alias edits.
3. Add separate timings for ASR, CTC load, acoustic spotting and candidate
   comparison, and expose vocabulary preparation distinctly from speech
   recognition. Log helper launch/unload reasons, PID, and model readiness to
   distinguish idle timers, critical pressure and CTC-only reloads. Re-run the
   same benchmark before/after, including an idle pause, to prove that later
   requests reuse the model and the first delivered dictation avoids cold setup.
4. Measure the remaining acoustic/candidate cost separately for long recordings
   and larger vocabularies before choosing candidate-window optimizations or an
   optional latency budget. Preserve audio-backed corrections, raw tokens,
   source-relative replacement spans, and canonical-word/export consistency.

Moving model preparation earlier and retaining it addresses the measured loading
problem; it does not make vocabulary inference free. No cache, prewarm or
correction-policy changes were implemented in this investigation.

## Reproduce

Build the Release worker first through the existing build/package workflow. The
commands below use its already-built products and checked-out dependencies;
they do not download models or change the installed app. Use a fresh scratch
directory for `probe_dir`:

```sh
probe_dir="$(mktemp -d /private/tmp/scribe-vocabulary-latency.XXXXXX)"
say -v Samantha -o "$probe_dir/terms.aiff" 'We prescribe Liv mar lee for the patient. The company is Cooperativ. Please deploy on Kubernetes with Jake and Neah.'
ffmpeg -hide_banner -loglevel error -i "$probe_dir/terms.aiff" -ar 16000 -ac 1 "$probe_dir/audio.wav"
cat > "$probe_dir/vocabulary.json" <<'JSON'
{"revision":"synthetic-v1","terms":[{"text":"Livmarli","aliases":["Liv Marley","live Marley","live marly","Liv mar lee"]},{"text":"Cooperativ","aliases":["cooperative"]},{"text":"Neah","aliases":["Nia","near"]}]}
JSON
products=build/release/swiftpm/TranscriptionWorker/out/Products/Release
python3 Scripts/benchmark-vocabulary-latency.py \
  --worker "$products/TranscriptionWorker" \
  --manifest Workers/TranscriptionWorker/model_manifest.json \
  --models Workers/TranscriptionWorker/models \
  --audio "$probe_dir/audio.wav" --vocabulary "$probe_dir/vocabulary.json" \
  --output "$probe_dir/dictation.json"
```

Add `--cycles 1 --idle-seconds 180` to compare again after leaving the same
worker alive without requests for three minutes. This deliberately does not
simulate host-triggered worker unloading; it isolates same-process inactivity.

The diagnostic script validates the fixture, warms once, runs twelve requests,
checks for successful speech and unavailable warnings, saves bounded timings and
replacement counts, and unloads the worker. It retains no transcript text in
the report. macOS speech generation and nested `sandbox-exec` require permission
to run outside a restrictive command sandbox.

For the setup-only probe, from the repository root:

```sh
worker_build=build/release/swiftpm/TranscriptionWorker
swiftc -O -parse-as-library \
  -I "$products" \
  -I "$worker_build/checkouts/FluidAudio/Sources/FastClusterWrapper/include" \
  -I "$worker_build/checkouts/FluidAudio/Sources/MachTaskSelfWrapper/include" \
  -I "$worker_build/artifacts/fluidaudio/NemoTextProcessing/NemoTextProcessing.xcframework/macos-arm64_x86_64/Headers/CNemoTextProcessing" \
  -module-cache-path "$probe_dir/module-cache" \
  Scripts/benchmark-vocabulary-setup.swift \
  "$products/FluidAudio.o" "$products/ScribeInference.o" \
  "$products/FastClusterWrapper.o" "$products/MachTaskSelfWrapper.o" \
  -L "$products" -ltext_processing_rs -lc++ -o "$probe_dir/setup-probe"
printf '(version 1)\n(allow default)\n(deny network*)\n' > "$probe_dir/offline.sb"
sandbox-exec -f "$probe_dir/offline.sb" "$probe_dir/setup-probe" "$probe_dir"
```

Validation performed: the real offline dictation comparison, optimized setup
probe, Python syntax/help/invalid-cycle checks, and whitespace validation.
The later idle and one-minute batch attempts timed out as described above.
Application tests were not rerun because no application code changed.

## Fix — retained and prewarmed booster (`coo:1158.4dev`)

The dictation worker now keeps one `VocabularyBooster` for its lifetime
([VocabularyBooster.swift](../../Workers/TranscriptionWorker/Sources/ScribeInference/VocabularyBooster.swift)):

- CTC models and tokenizer are retained per **asset identity**: the standardized
  models folder, the SHA-256 of the manifest bytes, and each declared CTC
  file's size, modification time and inode. A request with an unchanged
  identity does no model load and no weight hashing; a change (installation,
  repair, folder switch) reloads with the full SHA-256 validation.
- Encoded terms, context, spotter and rescorer are reused only while the
  snapshot's usable terms *and aliases* are identical; any edit rebuilds them
  (milliseconds) against the retained model. Revision alone is never trusted.
- A failed load is remembered only for the identity that produced it, so an
  unchanged broken install is not re-hashed per request, and any change to
  the files retries. Missing or corrupt assets keep returning raw text with
  `vocabulary_assets_unavailable`. Empty or unusable vocabulary never reads the
  manifest or loads CTC.
- `warm` accepts an optional inline `vocabulary` snapshot (text, aliases,
  revision; notes are not sent). With usable terms it loads the booster and
  runs one representative two-second prediction before answering, and
  reports `vocabularyBooster.readiness` (`ready`, `not_needed`, `unavailable`)
  with its source (`loaded`, `retained`, `reloaded_after_change`, `recovered`).
- `unload` releases the booster with TDT/VAD, so the host's existing unload,
  disable, idle-timer and memory-pressure policies govern it unchanged.

The host [DictationEngine](../../Modules/Dictation/Sources/Dictation/DictationEngine.swift)
sends the snapshot on every helper warm, and `isReady()` stays false while a
snapshot with terms still needs the booster, so the indicator says
"Loading model…" for that preparation instead of "Transcribing…". Adding the
first term to a resident helper prepares the booster in the same process.
Unavailable assets do not hold readiness.

Every `dictate` response now carries `timings` (VAD, speech recognition,
vocabulary preparation and model load, acoustic spotting, candidate
comparison, total) and `vocabularyBooster`. Logs (`log show --predicate
'subsystem == "com.scribe.TranscriptionWorker"'` and `subsystem ==
"com.scribe.app" AND category == "DictationHelper"`) record helper launches
with reasons (`first_use`, `after_<unload reason>`, `helper_not_running`,
`models_directory_changed`), unloads with reasons (`requested`,
`idle_timer_<n>_minutes`, `memory_pressure_critical`/`_warning`,
`helper_failure`), readiness and per-stage timings. A booster reload inside a
resident process is logged separately from a helper restart. No transcript
text or vocabulary contents are logged.

### Measurements after the fix

Same fixture and offline sandbox, ~10 GiB free disk. Raw rows:
[vocabulary-transcription-latency-fix.json](vocabulary-transcription-latency-fix.json).
Both runs: two cycles, then 180 s idle in the same process, then one more cycle.

| | Before (pre-change Release worker) | After (vocabulary sent on warm) |
| --- | ---: | ---: |
| Warm | 45.087 s (TDT/VAD only) | 4.745 s (incl. CTC load 0.986 s, representative prediction 0.211 s) |
| First vocabulary request | **89.693 s** | **0.437 s** (`retained`) |
| Later vocabulary requests | 1.165–2.379 s | 0.316–0.358 s |
| Empty-vocabulary requests | 0.193–0.754 s | 0.106–0.194 s |
| First vocabulary request after 180 s idle | 1.669 s | 0.637 s (`retained`) |
| Later after-idle vocabulary request | 1.127 s | 0.344 s |

After the fix every vocabulary request reported `source: retained` and a
model-load step under 0.1 ms; there was one CTC load per process. The
remaining vocabulary overhead is the acoustic pass itself: spotting
0.195–0.299 s (0.497 s on the first request after idle) plus ~0.01 s of
candidate comparison on this 6.5 s clip. It scales with audio length and is
**not** removed by prewarming.

A first launch of the packaged helper from a new app path showed a genuine
cold start: warm took 57.0 s (speech 31.0 s, CTC 25.1 s), all reported before
readiness; the first vocabulary dictation then took 0.339 s.

### Idle recurrence

The pre-change worker did **not** reproduce a tens-of-seconds delay after
180 s idle in the same process (1.669 s, consistent with its normal per-request
reload). So same-process inactivity alone does not explain the report. The
pre-change design reloaded CTC through Core ML on every request, so any loss
of Core ML's on-disk/accelerator preparation (the earlier 100%-full disk is
one candidate) would surface as a cold load on an ordinary dictation; with
the model retained in-process that path is gone unless the helper itself
restarts. Genuine restarts (critical memory pressure, helper failure, disable,
model-folder change, app relaunch) still pay a cold start, now during warm and
logged with its reason. The user's original recurrence remains unreproduced
here; the new launch/unload logs are designed to identify it if it recurs.
The separate empty-vocabulary batch timeout in the investigation is not
attributed to CTC.

Reproduce with the commands above, adding `--warm-vocabulary` (and
`--cycles 2 --idle-seconds 180`) to exercise the prewarmed path.
