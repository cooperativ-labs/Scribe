#!/bin/sh
# Runs audio-metrics over every generated fixture using the fixture's own microphone track as the
# processed input, which is the unprocessed baseline. Reports land in the directory given as the
# first argument (default: a temporary directory).
set -eu

tool_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$tool_root/../.." && pwd)
fixtures="$repo_root/Tests/Fixtures/Generated"
output=${1:-$(mktemp -d)}

[ -d "$fixtures" ] || { echo "missing fixture suite: $fixtures" >&2; exit 1; }
mkdir -p "$output"
swift build -c release --package-path "$tool_root" >/dev/null
binary="$(swift build -c release --package-path "$tool_root" --show-bin-path)/audio-metrics"

for directory in "$fixtures"/*/; do
    case_id=$(basename "$directory")
    printf '===== %s\n' "$case_id"
    "$binary" --fixture "$directory" --output "$output/$case_id.json"
done

printf '\nBaseline reports written to %s\n' "$output"
