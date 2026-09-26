# Local diarization evaluation

`compare.py` reports exact-matched-text **reference agreement**, not DER, WDER, or human ground truth. `summarize.py` compares automatic/exact-two outputs with actual current Swift host replay and emits transcript-free aggregates. `wder.py` adds a WDER-style score against either explicitly manual canonical rows or a supplied local reference transcript. Read [the evaluation](../../docs/investigations/diarization-979-evaluation.md) for measurement limits and the retain decision.

Requirements: macOS, Swift/Xcode, Python 3, installed Scribe models. Excerpt generation also uses `ffmpeg`. Model download/build access is separate from inference: all meeting audio stays local. Keep raw outputs, transcripts, clips and embeddings in a private directory outside tracked source.

## Build and pin before running

Never infer an executable's version from `Package.resolved`. Rebuild the current worker in an isolated scratch path, then record its SHA-256. `benchmark.py` also rejects FluidAudio output that lacks the expected engine revision. The revision field alone still does not replace the build step.

```sh
EVAL=/private/tmp/scribe-diarization-evaluation
mkdir -p "$EVAL"
swift build --package-path Workers/TranscriptionWorker --scratch-path "$EVAL/worker-build" \
  --build-system swiftbuild -c release --product DiarizationBenchmark
swift build --package-path Workers/TranscriptionWorker --scratch-path "$EVAL/worker-build" \
  --build-system swiftbuild -c release --product ASRBenchmark
```

For this Swift build system, executables are under `worker-build/out/Products/Release`. Confirm the actual build output path on your toolchain. The worker pin is FluidAudio `21493f8dac5a97e65742e6ff26f42f164c2fda0f` (0.17.4).

Build the public SpeakerKit SDK in a separate checkout of `https://github.com/argmaxinc/argmax-oss-swift.git`, at commit `ea872ffd35705aa757f33033500b9b0d40bd38df`, with `swift build -c release --product argmax-cli`. Its executable is `.build/release/argmax-cli`.

Download `argmaxinc/speakerkit-coreml` assets at revision `86ec9c929b52208b6656eb6a6361ed0d822a1f78` using a revision-aware Hugging Face downloader, preserving subdirectories. The CLI's `--model-path` is that repository root, containing `speaker_segmenter`, `speaker_embedder`, and `speaker_clusterer`. `--download-model-path` is convenient for initial exploration but follows upstream defaults; verify the downloaded hashes against `evaluation-provenance.json` before calling a rerun identical. No Pro license is required for the tested OSS path. Review redistribution terms before bundling models in a product.

## Fixed ASR and serial diarization

Set `RUN` to the original reference run directory and `REFERENCE` to the timestamp-free attachment JSON. `RUNS` below means explicit paths to all selected run directories, each containing `prepared.wav`, `prepare.json`, `words.json`, and `canonical-transcript.json`.

```sh
"$EVAL/worker-build/out/Products/Release/ASRBenchmark" \
  --audio "$RUN/prepared.wav" --manifest Workers/TranscriptionWorker/model_manifest.json \
  --models "$HOME/Library/Application Support/Scribe/Models" \
  --compute-units cpuAndNeuralEngine --tokens-json "$EVAL/transcript.json" > "$EVAL/asr.log" 2>&1

python3 Tools/DiarizationAnalysis/benchmark.py RUNS \
  --engine fluid --binary "$EVAL/worker-build/out/Products/Release/DiarizationBenchmark" \
  --models "$HOME/Library/Application Support/Scribe/Models" \
  --manifest Workers/TranscriptionWorker/model_manifest.json \
  --revision 21493f8dac5a97e65742e6ff26f42f164c2fda0f --output "$EVAL/results"

python3 Tools/DiarizationAnalysis/benchmark.py RUNS \
  --engine speakerkit --binary /path/to/argmax-cli --models /path/to/speakerkit-coreml \
  --revision ea872ffd35705aa757f33033500b9b0d40bd38df --output "$EVAL/results"
```

Do not run engines concurrently when comparing runtimes. The runner executes automatic followed by requested exact-two per recording. On unannotated recordings this is a sensitivity test, not a known true count. It preserves RTTM overlap and keeps SpeakerKit exclusive reconciliation off. Repeated runs need separate output folders to retain their measurements.

## Post-processing sweep (FluidAudio 0.15.7)

Keep one fixed saved-word or ASR transcript per recording and run inference serially. Include the 0.1 s production default as the control, then 0.25, 0.5 and 0.75 s. Keep `--clustering-threshold 0.6`, automatic speaker count, overlap preservation and the duration default fixed. Each fresh benchmark JSON records the applied configuration. Core ML logs may share stdout: extract the final JSON line before passing it to replay/WDER.

```sh
for GAP in 0.1 0.25 0.5 0.75; do
  "$EVAL/worker-build/out/Products/Release/DiarizationBenchmark" \
    --audio "$RUN/prepared.wav" --manifest Workers/TranscriptionWorker/model_manifest.json \
    --models "$HOME/Library/Application Support/Scribe/Models" \
    --minimum-gap-duration "$GAP" --minimum-segment-duration 0 --clustering-threshold 0.6 \
    > "$EVAL/gap-$GAP.log" 2>&1
  python3 -c 'import json,sys; rows=open(sys.argv[1]).read().splitlines(); d=next(json.loads(x) for x in reversed(rows) if x.startswith("{") and "\"intervals\"" in x); json.dump(d,open(sys.argv[2],"w"))' \
    "$EVAL/gap-$GAP.log" "$EVAL/gap-$GAP.json"
  python3 Tools/DiarizationAnalysis/wder.py "$RUN" --diarization "$EVAL/gap-$GAP.json" \
    --reference "$REFERENCE" --effective-speakers --output "$EVAL/gap-$GAP-wder.json"
done
shasum -a 256 "$EVAL/worker-build/out/Products/Release/DiarizationBenchmark" \
  "$EVAL/worker-build/out/Products/Release/ASRBenchmark"
```

Omit `--reference` only when scoring explicit manual canonical labels. Unannotated recordings can supply replay paragraph/unknown counts but cannot supply WDER. Sparse manual labels measure only their aligned subset, not full-meeting accuracy. Use the repository segment reference for timestamped CAB scoring and the paragraph reference for a separate untimed alignment/readability comparison.

`--maximum-speaker-count N` requests up to N; `--known-speaker-count N` requests exactly N. Do not combine them. The pinned API has no standalone post-processing minimum-duration field: `--minimum-segment-duration` maps to segmentation `minDurationOn`; final reconstruction also applies the embedding-duration floor (1 s by default). Lower values cannot shorten that floor. See the [source compatibility audit](../../docs/feasibility/offline-diarization.md).

## Actual Swift host replay and aggregate

```sh
python3 Tools/DiarizationAnalysis/replay.py "$RUN" "$EVAL/transcript.json" \
  "$EVAL/results/meeting--817e841cbedcb1d46484bd9eaa4dca44-fluid-automatic.json" \
  --output "$EVAL/replay.json" --keep-executable "$EVAL/host-replay"

python3 Tools/DiarizationAnalysis/summarize.py \
  --meetings "$HOME/Meeting Transcripts" --results "$EVAL/results" \
  --host-replay "$EVAL/host-replay" --reference-run 221DEAC0-22A5-44C1-8B36-D9E5FE37593F \
  --reference "$REFERENCE" --transcript "$EVAL/transcript.json" \
  --private-output "$EVAL/replays" --output "$EVAL/aggregate.json"
```

The host harness compiles the production `TokenTimingReconciler`, `SpeakerTurnBuilder`, `TranscriptDisplayGrouper`, transcript types, and the complete production `AudioTimeMapping` type. Only resource-bundle plumbing is supplied for standalone compilation; schema loading is unused. Historical `prepare.json` without mapping uses an identity source-time mapping only after checking equal full-source durations. This fallback is for these untrimmed recordings, not arbitrary edited audio.

The reference run uses fresh fixed ASR. Other runs use fixed historical saved words and are explicitly labeled as such. Python labels are normalized to the Swift first-appearance speaker IDs; all assignments and paragraph word counts must agree or aggregation fails. `compare.py --words /path/to/replay.json` also accepts the reconstructed words for individual investigations.

## WDER-style ground-truth scoring

`wder.py` always gets its hypothesis assignments and paragraph rows from the
production Swift host harness. Its output contains aggregate counts, normalized
speaker IDs, hashes and engine revision only: it deliberately contains neither
transcript text nor original speaker names. WDER here means word speaker error
on the scoreable alignment set (`wrong + unknown`); it is not time-weighted DER.

Use manually approved canonical rows when a reviewer changed their attribution.
Only rows with `attribution_source == "manual"` are scored; automatic and
inferred rows are deliberately excluded.

```sh
python3 Tools/DiarizationAnalysis/wder.py "$RUN" \
  --diarization "$EVAL/results/fluid.json" --transcript "$EVAL/transcript.json" \
  --output "$EVAL/wder-manual.json"
```

Or pass an external transcript of exactly the same audio. Supported formats are
MacWhisper-style JSON `[{"speaker", "text", "start"?, "end"?}]`, SRT/VTT
captions whose text starts with `Speaker:`, and plain text consisting of one
`Speaker: utterance` per line. JSON `start`/`end` are seconds (use
`start_ms`/`end_ms` for milliseconds); caption timestamps are standard SRT/VTT.
Reviewed JSON exports may instead use a `timestamp` range such as
`MM:SS-MM:SS` or `HH:MM:SS-HH:MM:SS`. Rows with a null speaker are retained in
the source benchmark but excluded from speaker scoring.
Timestamped references align replay words by greatest time overlap. Untimed
references align normalized lexical tokens with `SequenceMatcher(autojunk=False)`.
Both report coverage, and the scorer finds a globally optimal one-to-one mapping
between anonymous Scribe and reference speakers before classifying words.

```sh
python3 Tools/DiarizationAnalysis/wder.py "$RUN" \
  --diarization "$EVAL/results/fluid.json" --transcript "$EVAL/transcript.json" \
  --reference "$REFERENCE" --output "$EVAL/wder-reference.json"
```

By default each call compiles/replays via `replay.py` and discards the private
replay JSON. For a batch that already built the same harness, pass
`--host-replay "$EVAL/host-replay"`; its SHA-256 is still recorded. The output
also records the diarization document hash, canonical revision and engine
revision where supplied by the worker artifact.

### Canonical labels versus inferred display labels

Canonical labels remain the default score. Pass `--effective-speakers` to score
`effectiveSpeakerID` after the production `UnknownFragmentReconciler`, including
bounded nearest-interval evidence from `SpeakerTurnBuilder`:

```sh
python3 Tools/DiarizationAnalysis/wder.py "$RUN" --reference "$REFERENCE" \
  --effective-speakers --output "$EVAL/wder-effective.json"
```

The replay now also compiles the production reconciler and paragraph grouper;
small dependency types are extracted from production sources just like the audio
time mapping. `attribution_view` identifies the selected score. `paragraphs`
retains the historical canonical-row count; `display_paragraphs` counts actual
reading paragraphs after reconciliation. Inferred labels remain suggestions:
canonical `speaker_id` stays null and canonical exports retain that uncertainty.
Rebuild old cached host executables before using `--effective-speakers`.

Backchannel asides are presentation-only: `display_paragraphs` counts the main
reading rows and their main-speaker words; `display_asides` reports the separate
aside, word, and source-segment counts. Asides are excluded from the main row's
single-word count, but their canonical words remain in speaker scoring and the
historical `paragraphs` metrics. Rebuild the host to include aside metrics.
The supplied `benchmark-files/BENCHMARK CALL - Paragraphs.json` can also be passed
as `--reference` for untimed text alignment. Its row counts provide a readability
comparison, not a paragraph-boundary precision/recall score.

## Excerpt review and checks

```sh
python3 Tools/DiarizationAnalysis/review_excerpts.py \
  --audio "$RUN/prepared.wav" --replay "$EVAL/replay.json" \
  --fluid "$EVAL/results/meeting--817e841cbedcb1d46484bd9eaa4dca44-fluid-automatic.json" \
  --speakerkit "$EVAL/results/meeting--817e841cbedcb1d46484bd9eaa4dca44-speakerkit-automatic.json" \
  --output "$EVAL/review-clips" --annotations "$EVAL/excerpt-candidates.json"

python3 -m unittest discover -s Tools/DiarizationAnalysis -p 'test_*.py'
swift test --package-path Modules/Transcription \
  --filter 'TranscriptDisplayGroupingTests|TokenDurationPauseRegressionTests|SpeakerTurnBuilderTests'
```

Excerpt selection is tailored to the investigation meeting. It creates signed-16 listening copies and RMS bins; original float audio remains unchanged and is used for all benchmarks. A person must listen and fill `human-review.tsv`; generated candidate fields deliberately remain null. Silence energy, ASR text, and model overlap flags are not human annotations.

## Microphone source prior (phase 6)

The app's **Identify me from my microphone** setting is off by default. It applies
only when a recorder session retains both tracks in its capture journal, or a
previous run already contains `source-energy.json`. New runs and reprocessing
snapshot the setting; existing transcripts are not relabelled by changing it.
Choose **This is me** in the speaker library to use an owner profile; otherwise
a confident local cluster is labelled **Me**. Keep the setting off for in-room
meetings, where the microphone may contain several people.

Generate the exact production timeline without writing into a saved session/run:

```sh
swift build --package-path Tools/TimelineHarness --scratch-path "$EVAL/timeline-build" \
  -c release --product timeline-harness
"$EVAL/timeline-build/out/Products/Release/timeline-harness" source-energy \
  --session "/path/to/retained/recorder/session" --json "$EVAL/source-energy.json"
python3 Tools/DiarizationAnalysis/wder.py "$RUN" --effective-speakers \
  --output "$EVAL/source-off.json"
python3 Tools/DiarizationAnalysis/wder.py "$RUN" --effective-speakers \
  --source-energy "$EVAL/source-energy.json" --output "$EVAL/source-on.json"
```

Use `--reference` for a full reference; without it, only manually labelled
canonical segments are scored. The energy timeline uses 100 ms mean channel
power on the journal-reconstructed recording timeline. Offsets, gaps and drift
come from the same `TimelineBuilder` as mixdown; stereo channels do not cancel.
Missing capture, silence, and windows where both sources exceed -40 dBFS do not
vote. A microphone window needs at least 10 dB dominance and a quiet system
track. Cluster source agreement must exceed **0.95**, with at least 5 s of
microphone evidence, over 60% microphone-window coverage and a 0.20 lead over
another cluster. These are heuristic evidence scores, not probability estimates.

For threshold sensitivity, pass `--source-minimum-agreement 0.85` (or 0.90,
0.95, 0.999) together with `--source-energy`. This is a benchmark override;
the production default is 0.95. Rebuild cached host executables after source
changes. WDER output records the energy SHA-256, threshold, selected anonymous
cluster and its aggregate support. Optimal speaker mapping measures attribution
agreement, **not** the correctness of the visible “Me”/owner name. Raw energy,
replay text and original audio stay outside tracked source. See the phase plan
for the calibration's limited ground-truth coverage.

## Immutable quality baseline and independent experiments (coo:1016)

Use `quality.py` for the controlled optimization series. It uses the actual Swift
host via `replay.py`, with a single lexical alignment method for both canonical
and effective speaker scores. The older `wder.py` remains available for historical
reports; its automatic timestamp selection and omission of unlabelled reference
rows are **not** the new experiment contract.

The named baseline is **scribe-quality-v1**. Its private, read-only bundle is at
`~/Library/Application Support/Scribe/QualityEvaluation/scribe-quality-v1`.
The published lock and aggregate evidence are
[`transcript-quality-baseline-v1.json`](../../docs/investigations/transcript-quality-baseline-v1.json).
It includes source/input/config/binary hashes, installed model tree hash and file
count, engine revisions, corpus membership, mappings and aggregates. Individual
model-file hashes, frozen source copies, raw ASR, saved JSON inputs, replay output
and review packs stay in the private bundle. No model inference is performed;
installed asset hashes do not prove which bytes a historical process loaded.
Original source audio and every saved run file are hashed in place and never
modified. The original audio paths remain the listening sources.

```sh
BASE="$HOME/Library/Application Support/Scribe/QualityEvaluation/scribe-quality-v1"
python3 Tools/DiarizationAnalysis/quality.py verify --bundle "$BASE"

# Self-comparison: each candidate starts from the frozen inputs, never the prior candidate.
python3 Tools/DiarizationAnalysis/quality.py compare --bundle "$BASE" \
  --config Tools/DiarizationAnalysis/experiments/baseline.json \
  --private-output /private/tmp/scribe-quality-self-check \
  --output /private/tmp/scribe-quality-self-check-aggregate.json

# Independently select raw-token word reconstruction with all other behavior fixed.
python3 Tools/DiarizationAnalysis/quality.py compare --bundle "$BASE" \
  --config Tools/DiarizationAnalysis/experiments/raw-reconstruction.json \
  --private-output /private/tmp/scribe-quality-raw-check \
  --output /private/tmp/scribe-quality-raw-check-aggregate.json

python3 -m unittest discover -s Tools/DiarizationAnalysis -p 'test_*.py'
```

Output directories must be new and outside the checkout and frozen bundle.
The baseline is never overwritten. The CLI verifies the manifest against the
published lock, then verifies every frozen file before candidate execution.
To rebuild the **frozen** Swift executable (rather than current production):

```sh
python3 "$BASE/source/Tools/DiarizationAnalysis/replay.py" "$BASE/latest" saved \
  "$BASE/latest/diarization.json" --output /private/tmp/frozen-rebuilt-replay.json \
  --keep-executable /private/tmp/frozen-rebuilt-host
```

Compiler/path differences may change the rebuilt binary hash. Record that new
hash and check semantic outputs against the frozen replay; do not replace the
locked executable. To create a new separately named bundle from the current
sources, the original freeze command was:

```sh
python3 Tools/DiarizationAnalysis/quality.py freeze \
  --corpus Tools/DiarizationAnalysis/experiments/corpus-v1.json \
  --models "$HOME/Library/Application Support/Scribe/Models" \
  --bundle "$BASE" --output docs/investigations/transcript-quality-baseline-v1.json
```

That command intentionally fails now because the bundle already exists. Preserve
it through later objectives; `/private/tmp` trial files are not dependencies.

### Candidate configuration contract

`experiments/baseline.json` and `experiments/raw-reconstruction.json` are executable
controls, not unimplemented feature switches. Each later objective supplies one
JSON configuration with a unique `id`, `baseline: "scribe-quality-v1"`, and
`word_input: "saved"` or `"raw"`. Unknown configuration keys are rejected.
Saved mode enforces byte-equivalent decoded word objects. Raw mode compares common
lexical tokens and reports added/removed alignment units explicitly.

For a host-code candidate, supply `host_replay`, `binary_sha256`, `source_root`
and `source_tree_sha256`. Build the candidate using `replay.py` from its source
root first; this must be the actual Swift implementation or an explicitly labelled
experimental source variant. The source root must contain all relative files in
the baseline's `provenance.source_hashes`. Compute its digest with:

```python
# Run with Tools/DiarizationAnalysis on PYTHONPATH.
from pathlib import Path
from quality import read, digest, sha256
lock = read('docs/investigations/transcript-quality-baseline-v1.json')
root = Path('/path/to/candidate-source-root')
print(digest({p: sha256(root/p) for p in lock['provenance']['source_hashes']}))
```

For an independent diarization candidate, use
`recordings: {"latest": {"diarization": "/private/path/latest.json",
"diarization_sha256": "..."}, "cab": {...}}`. Omitted recordings use their
baseline intervals. Record the worker config, model hashes and worker executable
hash alongside each inference artifact; inference must be serial for meaningful
runtime comparisons. This harness hashes the supplied artifact and performs only
host replay. It does not run or attest to a worker build.

Speaker mappings are fitted **once**, on baseline effective labels, and reused for
canonical, effective, time sensitivity and every candidate. The Swift builder
numbers speakers by first interval appearance. If a candidate changes cluster
identity/order, specify each recording's one-to-one `speaker_correspondence`
(candidate host ID → baseline host ID), justified from acoustic/cluster evidence.
Unmapped extra clusters remain disagreements; do not refit mappings separately to
make a candidate look better. Speaker confusion includes unknown assignments.

### Alignment, boundaries and review

Lexical normalization is Unicode `casefold` plus `\w+` runs, then deterministic
`SequenceMatcher(autojunk=False)`. Apostrophes/punctuation are separators, allowing
`don't` and `don' t` to share two lexical units. This is exact-token reference
agreement, not ASR WER or human accuracy. Repeated phrases can align ambiguously;
coverage is reported and unmatched tokens are never counted correct. Null-speaker
reference rows stay in text alignment but are excluded from attribution scoring.
CAB therefore has 18,963 matched tokens, of which 200 are unscoreable. Time
sensitivity uses saved words, greatest positive overlap, and the same mapping;
zero-duration rows have no positive time overlap. Latest has 41 such reference
rows; CAB has 60. Time and lexical scores have different units/denominators.

Paragraph boundaries are row starts in reference lexical-token coordinates,
excluding the first row, with deterministic, chronological, nearest-available one-to-one matches at
tolerances 0, 1 and 3 tokens (a greedy diagnostic, not global boundary optimization).
An unaligned first token stays ambiguous, even if a nearby later token matches.
Main paragraphs and asides are separate rows. Unmatched hypothesis/reference
boundaries, precision and recall are reported. These are agreement diagnostics,
not proof of desirable segmentation. `saved_boundary_changes` reconstructs the
builder predicates for explanation only; Python does not generate any host
transcript. Historical replays use the pinned v3 predicates; current replays
declare `speaker-turn-grouping-v2`, where changing nearest-interval distance
alone is no longer a boundary.

The current production refinement can be reproduced with
`refinement_experiment.py --bundle <frozen-bundle> --private-output <new-private-dir> --output <aggregate.json>`.
It snapshots/builds the host and checks conservation and new speaker disagreements.
See [coo:1055 evidence](../../docs/investigations/diarization-1055-refinement.md)
for the bounded reconciliation policy, single-word reductions, and limitations.

Conservation checks fail on missing/duplicated source word IDs, changed word
text/timing, or missing/duplicated source segments, including main rows **plus
asides**. A candidate's own conservation and its word sequence versus baseline
are separate checks. `*-review.json` contains changed assignments and all aligned
wrong/unknown cases, context, original audio path, and padded clip offsets.
Canonical and effective cases are separate. `human_speaker`, `human_boundary`,
`reviewer` and `notes` remain null until someone actually listens. No listening or
adjudication has been fabricated, and no private review pack should be committed.

Both latest and CAB are development/sensitivity recordings. Validation membership
is empty. Sparse manual corrections elsewhere do not establish whole-meeting
validation. Future optimization settings stay independently selectable until the
mission's promotion objective; this harness changes no production behavior.

### Isolated apostrophe reconstruction candidate (objective 2)

`TokenTimingReconciler.Configuration.joinIntrawordApostrophes` is default-off.
The standalone host accepts `--intraword-apostrophes`; candidate JSON accepts
`"intraword_apostrophes": true` only with raw words and an explicitly hashed host.
The option joins unmarked ASCII/right-curly apostrophes between letter pieces,
without absorbing punctuation timing or changing hyphens/explicit word markers.

Build one host, snapshot its sources, and evaluate both off/on against the frozen
baseline with a new private destination:

```sh
python3 Tools/DiarizationAnalysis/apostrophe_experiment.py \
  --bundle "$HOME/Library/Application Support/Scribe/QualityEvaluation/scribe-quality-v1" \
  --private-output /private/tmp/scribe-apostrophes-reproduction \
  --output /private/tmp/scribe-apostrophes-reproduction-aggregate.json
```

The recipe emits independently reusable hashed configuration files and private
review packs, requires complete off-control replay parity, and checks character,
lexical-token and merged timing-span conservation. See
[acceptance evidence](../../docs/investigations/transcript-quality-apostrophes-v1.md).
Latest common-suffix splits fall 203→0; CAB introduces one new speaker disagreement.
Keep this candidate opt-in pending the later validation/promotion objectives.

### Independent short-turn retention (objective 3)

`ShortTurnBenchmark` is an explicit experiment executable; production
`OfflineDiarizationAdapter.diarize(fileURL:)` remains unchanged. It prepares at
the baseline 1.0 s embedding floor, then calls the pinned SDK's public
`cluster(_:)` on that same prepared value at output floors 1.0/0.75/0.5/0.25/0 s.
An independent preparation at 0.5 s measures the old **coupled** candidate.
Each output-only variant must retain exactly the same serialized chunk vectors,
PLDA vectors, chunk indices and cluster assignments or the benchmark fails.
Re-embedding, exclusive output and nonzero segmentation duration are rejected
because they invalidate this isolation contract.

```sh
python3 Tools/DiarizationAnalysis/short_turn_experiment.py \
  --bundle "$HOME/Library/Application Support/Scribe/QualityEvaluation/scribe-quality-v1" \
  --private-output /private/tmp/scribe-short-turn-reproduction \
  --models "$HOME/Library/Application Support/Scribe/Models" \
  --output /private/tmp/scribe-short-turn-reproduction-aggregate.json

swift test --package-path Workers/TranscriptionWorker --build-system swiftbuild \
  --filter 'shortTurn|offlineDiarization'
python3 -m unittest discover -s Tools/DiarizationAnalysis -p 'test_*.py'
```

The recipe snapshots worker sources, builds and verifies the exact SDK revision,
hashes models and binary, runs inference serially, then compares every candidate
against the frozen host with **saved words** (apostrophe candidate disabled).
Private per-recording files contain raw cluster correspondence and embeddings.
Aggregate reports contain only hashes, counts and anonymous correspondence
evidence. Fresh baseline cluster IDs map to historical IDs by interval overlap;
output-only variants reuse raw cluster identity, and the coupled preparation maps
by centroid cosine similarity. Reference labels never fit these correspondences.
Inspect weak/ambiguous correspondence evidence before interpreting a score.

The variant wrapper records `preparationEmbeddingFloorSeconds` and
`outputFloorSeconds` separately. Its nested `result.configuration` describes
**preparation**, not the modified reconstruction-manager configuration. The
generated comparison JSON refers to this artifact by hash and preserves both
floor values in the aggregate evidence. Do not pass a reconstruction manager's
configuration off as the configuration used to extract its prepared embeddings.

See [audit and acceptance evidence](../../docs/investigations/transcript-quality-short-turns-v1.md).

### Lossless attribution ranges and sentence/turn display (objective 4)

`TranscriptParagraph.attributionRanges` retains each complete canonical source
segment and its range in the display row's timed words, including exact inference
and uncertainty. It is transient; canonical schema, edit IDs and exports do not
change. Untimed sources have nil word ranges. Asides own separate ranges.

`TranscriptParagraphGrouper.Configuration.sentenceTurns` is an opt-in display
policy. `Replay.swift` / `replay.py` accept `--sentence-turns`; hashed candidate
JSON accepts `"sentence_turns": true` with an explicit host executable. All other
candidate switches remain independent. The app's grouping defaults stay unchanged.

```sh
python3 Tools/DiarizationAnalysis/grouping_experiment.py \
  --bundle "$HOME/Library/Application Support/Scribe/QualityEvaluation/scribe-quality-v1" \
  --private-output /private/tmp/scribe-grouping-reproduction \
  --output /private/tmp/scribe-grouping-reproduction-aggregate.json
```

The recipe requires exact off-control replay equality, unchanged canonical and
reconciled segments/labels, complete source evidence and exact word-range slices.
It emits private unreviewed changed-boundary packs and aggregate-only results.
Latest has 333 candidate display turns versus 610 saved segments and 240 existing
reading paragraphs; CAB 770 versus 1,329 and 630. This is presentation-only:
no saved row or attribution improvement. Boundary precision falls while recall
rises. See [design and acceptance evidence](../../docs/investigations/transcript-quality-grouping-v1.md).
