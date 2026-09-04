#!/usr/bin/env bash
# Run the host app's unit-test target on the supported development host.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

xcodebuild \
  -project Scribe.xcodeproj \
  -scheme Scribe \
  -destination 'platform=macOS,arch=arm64' \
  test
