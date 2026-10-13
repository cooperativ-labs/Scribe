#!/usr/bin/env bash
# Uses local synthetic speech, pinned local assets and a deny-network worker.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"
long=0
case "${1:-}" in
  --long) long=1 ;;
  "") ;;
  *) echo 'Usage: Scripts/validate-vocabulary-offline.sh [--long]' >&2; exit 64 ;;
esac
ffmpeg_path="${SCRIBE_FFMPEG_PATH:-$(command -v ffmpeg)}"
validation_dir="$(mktemp -d "${TMPDIR:-/tmp}/scribe-vocabulary-validation.XXXXXX")"
worker="$repo_root/build/release/swiftpm/TranscriptionWorker/debug/TranscriptionWorker"
benchmark="$repo_root/build/release/swiftpm/TranscriptionWorker/debug/ASRBenchmark"
manifest="$repo_root/Workers/TranscriptionWorker/model_manifest.json"
models="$repo_root/Workers/TranscriptionWorker/models"

swift build --package-path Workers/TranscriptionWorker --scratch-path build/release/swiftpm/TranscriptionWorker --disable-automatic-resolution
python3 Scripts/install-vocabulary-models.py --models-dir "$models" --verify-only
say -v Samantha -o "$validation_dir/terms.aiff" 'We prescribe Liv mar lee for the patient. The company is Cooperativ. Please deploy on Kubernetes with Jake and Neah.'
"$ffmpeg_path" -hide_banner -loglevel error -y -i "$validation_dir/terms.aiff" -ar 16000 -ac 1 "$validation_dir/terms.wav"
"$ffmpeg_path" -hide_banner -loglevel error -y -i "$validation_dir/terms.wav" -t 3 "$validation_dir/dictation.wav"
cat > "$validation_dir/vocabulary.json" <<'JSON'
{"revision":"offline-fixture-v1","terms":[{"text":"Livmarli","aliases":["Liv Marley","live Marley","live marly","Liv mar lee"]},{"text":"Cooperativ","aliases":["cooperative"]},{"text":"Neah","aliases":["Nia","near"]}]}
JSON
cat > "$validation_dir/offline.sb" <<'SB'
(version 1)
(allow default)
(deny network*)
SB
printf '#!/bin/bash\nexec /usr/bin/sandbox-exec -f %q %q "$@"\n' "$validation_dir/offline.sb" "$worker" > "$validation_dir/worker-offline"
chmod +x "$validation_dir/worker-offline"
SCRIBE_TRANSCRIPTION_WORKER_PATH="$validation_dir/worker-offline" \
SCRIBE_VOCABULARY_TEST_AUDIO="$validation_dir/terms.wav" \
SCRIBE_VOCABULARY_TEST_DICTATION="$validation_dir/dictation.wav" \
SCRIBE_VOCABULARY_TEST_SNAPSHOT="$validation_dir/vocabulary.json" \
swift test --package-path Modules/Transcription --filter WorkerIntegrationTests.testRealOfflineVocabularyBatchAndShortDictation

if ((long)); then
  "$ffmpeg_path" -hide_banner -loglevel error -y -stream_loop -1 -i "$validation_dir/terms.wav" -t 7200 "$validation_dir/two-hours.wav"
  /usr/bin/time -l sandbox-exec -f "$validation_dir/offline.sb" "$benchmark" \
    --audio "$validation_dir/two-hours.wav" --manifest "$manifest" --models "$models" --compute-units cpuAndNeuralEngine \
    --vocabulary-json "$validation_dir/vocabulary.json" --tokens-json "$validation_dir/long-transcript.json" \
    > "$validation_dir/long-result.json" 2> "$validation_dir/long-metrics.log"
  /usr/bin/time -l sandbox-exec -f "$validation_dir/offline.sb" "$benchmark" \
    --audio "$validation_dir/two-hours.wav" --manifest "$manifest" --models "$models" --compute-units cpuAndNeuralEngine \
    > "$validation_dir/baseline-result.json" 2> "$validation_dir/baseline-metrics.log"
  SCRIBE_VOCABULARY_TEST_LONG_TRANSCRIPT="$validation_dir/long-transcript.json" \
    swift test --package-path Modules/Transcription --filter WorkerIntegrationTests.testLongVocabularyEvidenceUsesSourceRelativeCanonicalWords
fi
printf 'Offline vocabulary validation artifacts: %s\n' "$validation_dir"
