# Local diarization evaluation

`compare.py` reports exact-matched-text **reference agreement**, not DER, WDER, or human ground truth. `summarize.py` compares automatic/exact-two outputs with actual current Swift host replay and emits transcript-free aggregates. Read [the evaluation](../../docs/investigations/diarization-979-evaluation.md) for measurement limits and the retain decision.

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

For this Swift build system, executables are under `worker-build/out/Products/Release`. Confirm the actual build output path on your toolchain. The worker pin is FluidAudio `4dbf4f9f9a5ff3a53ade848d7ba4e3df13db859b` (0.15.6).

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
  --revision 4dbf4f9f9a5ff3a53ade848d7ba4e3df13db859b --output "$EVAL/results"

python3 Tools/DiarizationAnalysis/benchmark.py RUNS \
  --engine speakerkit --binary /path/to/argmax-cli --models /path/to/speakerkit-coreml \
  --revision ea872ffd35705aa757f33033500b9b0d40bd38df --output "$EVAL/results"
```

Do not run engines concurrently when comparing runtimes. The runner executes automatic followed by requested exact-two per recording. On unannotated recordings this is a sensitivity test, not a known true count. It preserves RTTM overlap and keeps SpeakerKit exclusive reconciliation off. Repeated runs need separate output folders to retain their measurements.

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
