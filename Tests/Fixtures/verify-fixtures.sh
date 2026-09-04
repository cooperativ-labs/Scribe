#!/bin/sh
set -eu

fixture_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
first=$(mktemp -d)
second=$(mktemp -d)
cleanup() { rm -rf "$first" "$second"; }
trap cleanup EXIT HUP INT TERM

swift run --package-path "$fixture_root" generate-audio-fixtures --output "$first"
swift run --package-path "$fixture_root" generate-audio-fixtures --output "$second"
diff -r "$first" "$second"

expected_cases='asymmetric-stereo
clipping
delay-change-mid-file
documented-gaps
double-talk
far-end-only
microphone-16k
microphone-44k1
near-end-only
sample-rate-drift
silence'
actual_cases=$(find "$first" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | LC_ALL=C sort)
[ "$actual_cases" = "$expected_cases" ]
printf '%s\n' 'Fixture suite is reproducible and contains all required cases.'
