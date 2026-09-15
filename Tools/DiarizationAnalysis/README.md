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

For this Swift build system, executables are under `worker-build/out/Products/Release`. Confirm the actual build output path on your toolchain. The worker pin is FluidAudio `41540ea237350afe5117a082b5c28eda642d0612` (0.15.7).

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
  --revision 41540ea237350afe5117a082b5c28eda642d0612 --output "$EVAL/results"

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
