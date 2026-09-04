#!/bin/sh
# Runs EchoCanceller and MixdownService over every fixture and scores the
# implementation-plan section 8 echo-reduction and local-speech gates.
#
# Usage: sh Tools/TimelineHarness/run-mixdown-gates.sh [work-directory]
# Run from the repository root. Exits non-zero if any case misses its gate.
set -e

WORK="${1:-$(mktemp -d)}"
mkdir -p "$WORK"
echo "mixdown gate work directory: $WORK"

swift build -c release --package-path Tools/TimelineHarness >/dev/null
swift build -c release --package-path Tools/AudioMetrics >/dev/null

HARNESS="./Tools/TimelineHarness/.build/release/timeline-harness"
METRICS="./Tools/AudioMetrics/.build/release/audio-metrics"

"$HARNESS" mixdown --fixtures Tests/Fixtures/Generated --work "$WORK" --json "$WORK/mixdown.json"
# The real-room takes are run separately because they carry no ground-truth
# sidecar; the scorer measures them directly instead of through audio-metrics.
"$HARNESS" mixdown --fixtures /nonexistent --real Tests/Fixtures/real --work "$WORK" --json "$WORK/real.json"

python3 Tools/TimelineHarness/score-mixdown-gates.py "$WORK" "$METRICS"
