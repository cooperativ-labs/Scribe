#!/usr/bin/env bash
# Builds Workers/ScribeMCP and copies its two executables into the app:
#
#   Contents/Helpers/scribe-mcp           the local MCP server (read-only
#                                         transcript tools over stdio)
#   Contents/Helpers/scribe-mcp-launcher  what plugin manifests run; it finds
#                                         Scribe.app through LaunchServices and
#                                         execs the helper above
#
#   Scripts/embed-mcp-helper.sh <Scribe.app> <scratch-path>
#
# The caller signs them with the rest of the bundle: ad hoc in
# Scripts/build-app.sh, Developer ID with the hardened runtime and notarization
# in Scripts/package-app.sh.
set -euo pipefail

if (($# != 2)); then
  echo "usage: $(basename "$0") <Scribe.app> <scratch-path>" >&2
  exit 2
fi

app_path="$1"
scratch_path="$2"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
package_path="$repo_root/Workers/ScribeMCP"

die() { echo "error: $*" >&2; exit 1; }

[[ -d "$app_path/Contents" ]] || die "not an app bundle: $app_path"

echo "Building the MCP helper and launcher…"
swift build --package-path "$package_path" --scratch-path "$scratch_path" --configuration release --arch arm64 \
  --product scribe-mcp
swift build --package-path "$package_path" --scratch-path "$scratch_path" --configuration release --arch arm64 \
  --product scribe-mcp-launcher
# SwiftPM is asked where it put the binaries; the layout is a toolchain detail.
bin_dir="$(swift build --package-path "$package_path" --scratch-path "$scratch_path" --configuration release --arch arm64 --show-bin-path)"

helpers_dir="$app_path/Contents/Helpers"
mkdir -p "$helpers_dir"
for name in scribe-mcp scribe-mcp-launcher; do
  [[ -x "$bin_dir/$name" ]] || die "the build did not produce $bin_dir/$name"
  ditto "$bin_dir/$name" "$helpers_dir/$name"
done
echo "Embedded scribe-mcp and scribe-mcp-launcher in $helpers_dir"
