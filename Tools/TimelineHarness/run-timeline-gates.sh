#!/bin/sh
# Reconstructs every synthetic fixture through TimelineBuilder and scores the
# implementation-plan section 8 timeline gate with Tools/AudioMetrics.
#
# Usage: sh Tools/TimelineHarness/run-timeline-gates.sh [work-directory]
# Run from the repository root. Exits non-zero if any case misses the gate.
set -e

WORK="${1:-$(mktemp -d)}"
mkdir -p "$WORK"
echo "timeline gate work directory: $WORK"

swift build -c release --package-path Tools/TimelineHarness >/dev/null
swift build -c release --package-path Tools/AudioMetrics >/dev/null

HARNESS="./Tools/TimelineHarness/.build/release/timeline-harness"
METRICS="./Tools/AudioMetrics/.build/release/audio-metrics"

"$HARNESS" fixtures --fixtures Tests/Fixtures/Generated --work "$WORK" --json "$WORK/harness.json"

python3 Tools/TimelineHarness/score-timeline-gates.py "$WORK" "$METRICS"
