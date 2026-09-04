#!/usr/bin/env bash
# Build the local, ad-hoc-signed Debug app for the supported development host.
#
# The app is built the way Xcode builds it, then given the same
# Contents/Library/Helpers payload that Scripts/package-app.sh gives a release:
# the transcription helper, ffmpeg, and ffprobe. Without them a development
# build resolves none of the three through WorkerLocator and MediaToolLocator,
# so folder import refuses, every transcription job fails at its first stage,
# and the only way to exercise either is to remember four environment
# variables. Populating the bundle instead means a development run takes the
# same lookup path as the shipped one, rather than a special case that only
# developers hit.
#
#   Scripts/build-app.sh                 # build, and populate the helpers
#   Scripts/build-app.sh --no-helpers    # build only; the first worker build is slow
#
# The environment overrides remain for pointing at a deliberately different
# helper or media toolchain:
#
#   SCRIBE_TRANSCRIPTION_WORKER_PATH   pre-built helper, instead of building one
#   SCRIBE_FFMPEG_PATH / SCRIBE_FFPROBE_PATH
#                                      the reviewed, pinned media binaries
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

populate_helpers=1
case "${1:-}" in
  --no-helpers) populate_helpers=0 ;;
  "") ;;
  *) echo "usage: $(basename "$0") [--no-helpers]" >&2; exit 2 ;;
esac

die() { echo "error: $*" >&2; exit 1; }

xcodebuild \
  -project Scribe.xcodeproj \
  -scheme Scribe \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  build

((populate_helpers)) || exit 0

# Ask the build for its own product directory rather than guessing at a
# DerivedData path, which is neither stable nor the same on two machines.
products_dir="$(xcodebuild -project Scribe.xcodeproj -scheme Scribe -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/ BUILT_PRODUCTS_DIR = /{print $2; exit}')"
[[ -n "$products_dir" && -d "$products_dir" ]] || die "could not resolve BUILT_PRODUCTS_DIR from the build settings"
app_path="$products_dir/Scribe.app"
[[ -d "$app_path" ]] || die "the build did not produce $app_path"
helpers_dir="$app_path/Contents/Library/Helpers"
mkdir -p "$helpers_dir"

# ffmpeg and ffprobe. A release requires the reviewed, pinned builds; a
# development build falls back to whatever is on PATH and says so, because a
# decoder difference is exactly the kind of thing that makes a local result
# disagree with a release one.
resolve_media_tool() {
  local name="$1" override="$2" resolved
  if [[ -n "$override" ]]; then
    [[ -x "$override" ]] || die "$name override is not executable: $override"
    printf '%s' "$override"
    return
  fi
  resolved="$(command -v "$name" 2>/dev/null || true)"
  [[ -n "$resolved" ]] || die "$name not found. Install the pinned toolchain with Scripts/build-ffmpeg.sh, or set SCRIBE_${name^^}_PATH."
  printf '%s' "$resolved"
}

ffmpeg_path="$(resolve_media_tool ffmpeg "${SCRIBE_FFMPEG_PATH:-}")"
ffprobe_path="$(resolve_media_tool ffprobe "${SCRIBE_FFPROBE_PATH:-}")"
if [[ -z "${SCRIBE_FFMPEG_PATH:-}" || -z "${SCRIBE_FFPROBE_PATH:-}" ]]; then
  echo "note: using ffmpeg/ffprobe from PATH; these are not the reviewed pinned builds a release ships."
fi

# The transcription helper.
if [[ -n "${SCRIBE_TRANSCRIPTION_WORKER_PATH:-}" ]]; then
  [[ -x "$SCRIBE_TRANSCRIPTION_WORKER_PATH" ]] || die "SCRIBE_TRANSCRIPTION_WORKER_PATH is not executable"
  worker_path="$SCRIBE_TRANSCRIPTION_WORKER_PATH"
else
  echo "Building the transcription helper (first build is slow; --no-helpers skips it)…"
  worker_scratch="$repo_root/build/dev/TranscriptionWorker"
  swift build --package-path "$repo_root/Workers/TranscriptionWorker" \
    --scratch-path "$worker_scratch" --configuration release --arch arm64
  # SwiftPM is asked where it put the binary; the layout is a toolchain detail.
  worker_bin_dir="$(swift build --package-path "$repo_root/Workers/TranscriptionWorker" \
    --scratch-path "$worker_scratch" --configuration release --arch arm64 --show-bin-path)"
  worker_path="$worker_bin_dir/TranscriptionWorker"
  [[ -x "$worker_path" ]] || die "the helper build did not produce $worker_path"
fi

ditto "$worker_path" "$helpers_dir/TranscriptionWorker"
ditto "$ffmpeg_path" "$helpers_dir/ffmpeg"
ditto "$ffprobe_path" "$helpers_dir/ffprobe"

# Xcode has already signed the bundle, and adding files to Contents invalidates
# that seal. Re-sign ad hoc, leaves first, preserving the identifier and
# entitlements so the app keeps its identity.
for helper in TranscriptionWorker ffmpeg ffprobe; do
  codesign --force --sign - "$helpers_dir/$helper"
done
codesign --force --sign - --preserve-metadata=identifier,entitlements "$app_path"
codesign --verify --deep --strict "$app_path"

cat <<EOF

Built $app_path
  helper:  $(basename "$worker_path")  <- $worker_path
  ffmpeg:  $ffmpeg_path
  ffprobe: $ffprobe_path

Re-signing changed the bundle's cdhash, so any Screen & System Audio Recording
grant made for an earlier build no longer applies. Re-approve it in System
Settings before recording; see docs/feasibility/capture-permissions.md.

Model files are user data and are not bundled. Transcription stages that need
them still require SCRIBE_TRANSCRIPTION_MODELS_DIRECTORY, or an installed model
set, exactly as a release does.
EOF
