#!/usr/bin/env bash
# Build, assemble, sign, notarize, and archive a direct-distribution Scribe app.
#
# This script deliberately accepts only local, explicit release inputs. It never
# fetches code, binaries, models, or licenses. See release-inputs.example.env.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"

usage() {
  cat <<'EOF'
Usage: Scripts/package-app.sh [--inputs PATH] [--notary-profile NAME] [--output PATH]

--inputs PATH  Source a local release-input environment file before validation.
--notary-profile NAME  Override the notarytool keychain profile from inputs.
--output PATH  Write the notarized Scribe.zip archive to PATH.

Required environment:
  DEVELOPER_ID_APPLICATION  Developer ID Application signing identity.
  DEVELOPER_TEAM_ID         Apple Developer team identifier.
  NOTARYTOOL_PROFILE        Keychain profile configured for notarytool
                            (or pass --notary-profile).
  SCRIBE_FFMPEG_PATH        Reviewed, pinned local ffmpeg executable.
  SCRIBE_FFPROBE_PATH       Reviewed, pinned local ffprobe executable.
  SCRIBE_NOTICE_WEBRTC, SCRIBE_NOTICE_FLUIDAUDIO, SCRIBE_NOTICE_PARAKEET,
  SCRIBE_NOTICE_DIARIZATION, SCRIBE_NOTICE_FFMPEG

Optional environment:
  SCRIBE_TRANSCRIPTION_WORKER_PATH  A prebuilt helper. Otherwise it is built
                                     from Workers/TranscriptionWorker.
  SCRIBE_RUNTIME_PAYLOADS_DIR        Local frameworks/dylibs needed by helpers.
  SCRIBE_LIBFLAC_BUNDLED=1           Requires SCRIBE_NOTICE_LIBFLAC.
  SCRIBE_MODEL_CATALOG_FILE          Local catalog bundled as a signed resource.
  SCRIBE_RELEASE_ROOT                Scratch output root (default build/release).
EOF
}

die() { echo "error: $*" >&2; exit 1; }
require_command() { command -v "$1" >/dev/null || die "required command not found: $1"; }
require_file() { [[ -f "$1" ]] || die "required file is missing: $1"; }
require_executable() { [[ -f "$1" && -x "$1" ]] || die "required executable is missing or not executable: $1"; }
require_value() { [[ -n "${!1:-}" ]] || die "$1 is required; see Scripts/release-inputs.example.env"; }

copy_notice() {
  local name="$1"
  local source="$2"
  require_file "$source"
  cp "$source" "$notices_dir/$name"
  [[ -s "$notices_dir/$name" ]] || die "copied notice is empty: $name"
}

while (($#)); do
  case "$1" in
    --inputs)
      (($# >= 2)) || die "--inputs requires a path"
      if [[ ! -f "$2" ]]; then
        die "required file is missing: $2
Copy Scripts/release-inputs.example.env to Scripts/release-inputs.local.env and replace every placeholder with a reviewed local path."
      fi
      # This is an operator-maintained local configuration file, not downloaded input.
      # shellcheck disable=SC1090
      source "$2"
      shift 2
      ;;
    --notary-profile)
      (($# >= 2)) || die "--notary-profile requires a name"
      notarytool_profile_override="$2"
      shift 2
      ;;
    --output)
      (($# >= 2)) || die "--output requires a path"
      output_archive="$2"
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

# Resolve paths after loading --inputs so that SCRIBE_RELEASE_ROOT in a local
# release configuration takes effect.
release_root="${SCRIBE_RELEASE_ROOT:-$repo_root/build/release}"
archive_path="$release_root/Scribe.xcarchive"
app_path="$archive_path/Products/Applications/Scribe.app"
distribution_dir="$release_root/distribution"
notarization_archive="$distribution_dir/Scribe-notarization.zip"
notices_dir="$app_path/Contents/Resources/ThirdPartyNotices"
helpers_dir="$app_path/Contents/Library/Helpers"
frameworks_dir="$app_path/Contents/Frameworks"
notarytool_profile="${notarytool_profile_override:-${NOTARYTOOL_PROFILE:-}}"

for command in xcodebuild swift codesign xcrun ditto find file grep spctl; do require_command "$command"; done
for variable in DEVELOPER_ID_APPLICATION DEVELOPER_TEAM_ID SCRIBE_FFMPEG_PATH SCRIBE_FFPROBE_PATH; do require_value "$variable"; done
[[ -n "$notarytool_profile" ]] || die "NOTARYTOOL_PROFILE is required; see Scripts/release-inputs.example.env"
for variable in SCRIBE_NOTICE_WEBRTC SCRIBE_NOTICE_FLUIDAUDIO SCRIBE_NOTICE_PARAKEET SCRIBE_NOTICE_DIARIZATION SCRIBE_NOTICE_FFMPEG; do require_value "$variable"; done

require_executable "$SCRIBE_FFMPEG_PATH"
require_executable "$SCRIBE_FFPROBE_PATH"
if [[ "${SCRIBE_LIBFLAC_BUNDLED:-0}" == "1" ]]; then
  require_value SCRIBE_NOTICE_LIBFLAC
fi
if [[ -n "${SCRIBE_RUNTIME_PAYLOADS_DIR:-}" ]]; then
  [[ -d "$SCRIBE_RUNTIME_PAYLOADS_DIR" ]] || die "SCRIBE_RUNTIME_PAYLOADS_DIR is not a directory: $SCRIBE_RUNTIME_PAYLOADS_DIR"
fi
if [[ -n "${SCRIBE_MODEL_CATALOG_FILE:-}" ]]; then
  require_file "$SCRIBE_MODEL_CATALOG_FILE"
fi

mkdir -p "$release_root" "$distribution_dir"
rm -rf "$archive_path"

echo "Building signed Release archive…"
xcodebuild \
  -project "$repo_root/Scribe.xcodeproj" \
  -scheme Scribe \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$archive_path" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$DEVELOPER_ID_APPLICATION" \
  DEVELOPMENT_TEAM="$DEVELOPER_TEAM_ID" \
  archive

[[ -d "$app_path" ]] || die "Xcode archive did not contain Scribe.app"
mkdir -p "$helpers_dir" "$frameworks_dir" "$notices_dir"

if [[ -n "${SCRIBE_TRANSCRIPTION_WORKER_PATH:-}" ]]; then
  require_executable "$SCRIBE_TRANSCRIPTION_WORKER_PATH"
  worker_path="$SCRIBE_TRANSCRIPTION_WORKER_PATH"
else
  echo "Building the transcription helper from its local Swift package…"
  worker_build_root="$release_root/swiftpm/TranscriptionWorker"
  swift build --package-path "$repo_root/Workers/TranscriptionWorker" --scratch-path "$worker_build_root" --configuration release --arch arm64
  # Ask SwiftPM where it put the binary rather than constructing the path. The
  # layout is a toolchain detail and has already changed once: a build that
  # succeeds and then cannot be found is indistinguishable from one that failed.
  worker_bin_dir="$(swift build --package-path "$repo_root/Workers/TranscriptionWorker" --scratch-path "$worker_build_root" --configuration release --arch arm64 --show-bin-path)"
  worker_path="$worker_bin_dir/TranscriptionWorker"
  require_executable "$worker_path"
fi
ditto "$worker_path" "$helpers_dir/TranscriptionWorker"
ditto "$SCRIBE_FFMPEG_PATH" "$helpers_dir/ffmpeg"
ditto "$SCRIBE_FFPROBE_PATH" "$helpers_dir/ffprobe"

if [[ -n "${SCRIBE_RUNTIME_PAYLOADS_DIR:-}" ]]; then
  echo "Embedding local helper runtime payloads…"
  ditto "$SCRIBE_RUNTIME_PAYLOADS_DIR" "$frameworks_dir"
fi

if [[ -n "${SCRIBE_MODEL_CATALOG_FILE:-}" ]]; then
  # Model payloads are mutable user data, not signed executable contents. The
  # catalog is signed with the app and must name checksum-verified local installs.
  ditto "$SCRIBE_MODEL_CATALOG_FILE" "$app_path/Contents/Resources/ModelCatalog.json"
fi

copy_notice 'WebRTC.txt' "$SCRIBE_NOTICE_WEBRTC"
copy_notice 'FluidAudio.txt' "$SCRIBE_NOTICE_FLUIDAUDIO"
copy_notice 'Parakeet-CC-BY-4.0.txt' "$SCRIBE_NOTICE_PARAKEET"
copy_notice 'Diarization-Models.txt' "$SCRIBE_NOTICE_DIARIZATION"
copy_notice 'FFmpeg.txt' "$SCRIBE_NOTICE_FFMPEG"
if [[ "${SCRIBE_LIBFLAC_BUNDLED:-0}" == "1" ]]; then
  copy_notice 'libFLAC.txt' "$SCRIBE_NOTICE_LIBFLAC"
fi

cat > "$notices_dir/README.txt" <<'EOF'
Scribe Third-Party Notices

This directory contains the notices and license terms for every third-party
component included in this release. Runtime model files are installed as user
data and are verified against the signed model catalog before use.
EOF

echo "Signing nested Mach-O code with the hardened runtime…"
# Sign leaf code first. The application bundle itself is signed last below.
while IFS= read -r -d '' candidate; do
  case "$candidate" in
    "$app_path/Contents/MacOS/Scribe") continue ;;
  esac
  if file -b "$candidate" | grep -q 'Mach-O'; then
    codesign --force --sign "$DEVELOPER_ID_APPLICATION" --options runtime --timestamp "$candidate"
  fi
done < <(find "$app_path/Contents" -type f -print0)

# Framework bundles carry their own CodeResources seal. Sign them after their
# leaf Mach-O files, from deepest to shallowest, before signing the app bundle.
while IFS= read -r -d '' framework; do
  codesign --force --sign "$DEVELOPER_ID_APPLICATION" --options runtime --timestamp "$framework"
done < <(find "$frameworks_dir" -depth -type d -name '*.framework' -print0)

codesign --force --sign "$DEVELOPER_ID_APPLICATION" --options runtime --timestamp \
  --preserve-metadata=identifier,entitlements,requirements "$app_path"
codesign --verify --deep --strict --verbose=2 "$app_path"

for required_notice in WebRTC.txt FluidAudio.txt Parakeet-CC-BY-4.0.txt Diarization-Models.txt FFmpeg.txt; do
  [[ -s "$notices_dir/$required_notice" ]] || die "required bundled notice missing: $required_notice"
done
if [[ "${SCRIBE_LIBFLAC_BUNDLED:-0}" == "1" ]]; then
  [[ -s "$notices_dir/libFLAC.txt" ]] || die "required bundled notice missing: libFLAC.txt"
fi

output_archive="${output_archive:-$distribution_dir/Scribe.zip}"
mkdir -p "$(dirname "$output_archive")"
rm -f "$notarization_archive" "$output_archive"
echo "Creating notarization archive…"
ditto -c -k --keepParent "$app_path" "$notarization_archive"

echo "Submitting to Apple notarization…"
xcrun notarytool submit "$notarization_archive" --keychain-profile "$notarytool_profile" --wait
xcrun stapler staple "$app_path"
xcrun stapler validate "$app_path"
spctl --assess --type execute --verbose=4 "$app_path"

# The notarization upload predates stapling. Recreate the distributable archive
# from the stapled app so offline installation receives the ticket as well.
ditto -c -k --keepParent "$app_path" "$output_archive"

echo "Notarized archive: $output_archive"
echo "Notarized app: $app_path"
