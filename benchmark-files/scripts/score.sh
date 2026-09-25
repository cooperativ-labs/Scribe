#!/bin/zsh
# Score one diarization hypothesis against a benchmark recording's timestamped
# reference, with canonical and effective (reconciled) labels.
#
#   benchmark-files/scripts/score.sh cab                          # saved VBx baseline
#   benchmark-files/scripts/score.sh cab path/to/diarization.json # candidate engine
#
# ASR words stay fixed (the snapshot's transcript.json), so only the diarizer
# changes. Outputs are transcript-free JSON under benchmark-files/<rec>/results/.
set -euo pipefail

ROOT=${0:A:h:h:h}
RECORDING=${1:?usage: score.sh <recording-id> [diarization.json]}
case $RECORDING in
  cab)
    RUN="$ROOT/benchmark-files/CAB/meeting--cecb678e89d2e0bc89c9687e1c980d5b/runs/C465C5EC-6EFF-4C43-A472-2EB2367BFA78"
    REF="$ROOT/benchmark-files/CAB/BENCHMARK CALL - Transcrpt segments.json"
    OUT="$ROOT/benchmark-files/CAB/results" ;;
  *) print -u2 "Unknown recording: $RECORDING"; exit 2 ;;
esac
[[ -f $RUN/prepared.wav ]] || { print -u2 "Snapshot missing: $RUN (see benchmark-files/README.md)"; exit 1; }
DIARIZATION=${2:-$RUN/diarization.json}
LABEL=${3:-${${DIARIZATION:t}:r}}

mkdir -p "$OUT"
for MODE in canonical effective; do
  python3 "$ROOT/Tools/DiarizationAnalysis/wder.py" "$RUN" \
    --diarization "$DIARIZATION" --transcript "$RUN/transcript.json" --reference "$REF" \
    ${${MODE:#canonical}:+--effective-speakers} --output "$OUT/$LABEL-$MODE.json" >"$OUT/$LABEL-$MODE.log" 2>&1 \
    || { print -u2 "wder.py failed; see $OUT/$LABEL-$MODE.log"; exit 1; }
  python3 -c 'import json,sys; a=json.load(open(sys.argv[1]))["agreement"]
print("%9s: WDER %.3f%%  wrong %.3f%%  unknown %.3f%%  (%d words)" % (sys.argv[2], a["wder_pct"], a["wrong_pct"], a["unknown_pct"], a["scored_words"]))' \
    "$OUT/$LABEL-$MODE.json" $MODE
done
