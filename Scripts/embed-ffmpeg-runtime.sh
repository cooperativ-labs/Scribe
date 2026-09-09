#!/usr/bin/env bash
# Copies the shared FFmpeg runtime beside Scribe's helpers and makes the copied
# tools relocatable inside an app bundle.  The development FFmpeg prefix uses
# absolute install names, which work from the checkout but cannot be loaded by
# a signed application bundle.
set -euo pipefail

if (($# != 4)); then
  echo "usage: $(basename "$0") <ffmpeg> <ffprobe> <helpers-dir> <frameworks-dir>" >&2
  exit 2
fi

ffmpeg_path="$1"
ffprobe_path="$2"
helpers_dir="$3"
frameworks_dir="$4"

die() { echo "error: $*" >&2; exit 1; }

for tool in "$ffmpeg_path" "$ffprobe_path"; do
  [[ -x "$tool" ]] || die "FFmpeg tool is not executable: $tool"
done

ffmpeg_lib_dir="$(cd "$(dirname "$ffmpeg_path")/../lib" && pwd)"
ffprobe_lib_dir="$(cd "$(dirname "$ffprobe_path")/../lib" && pwd)"
[[ "$ffmpeg_lib_dir" == "$ffprobe_lib_dir" ]] || die "ffmpeg and ffprobe must use the same shared-library directory"
[[ -d "$ffmpeg_lib_dir" ]] || die "FFmpeg shared-library directory is missing: $ffmpeg_lib_dir"

runtime_dir="$frameworks_dir/FFmpeg"
mkdir -p "$helpers_dir" "$frameworks_dir"
ditto "$ffmpeg_path" "$helpers_dir/ffmpeg"
ditto "$ffprobe_path" "$helpers_dir/ffprobe"
rm -rf "$runtime_dir"
mkdir -p "$runtime_dir"
# Do not copy the prefix wholesale: Homebrew-style prefixes can contain
# pkg-config metadata or unrelated libraries, neither of which belongs in an
# app bundle's Frameworks directory. Preserve the FFmpeg dylib alias chain so
# the major-version install names remain resolvable.
while IFS= read -r -d '' entry; do
  ditto "$entry" "$runtime_dir/$(basename "$entry")"
done < <(find "$ffmpeg_lib_dir" -maxdepth 1 -type f -name '*.dylib' -print0)
while IFS= read -r -d '' entry; do
  ln -s "$(readlink "$entry")" "$runtime_dir/$(basename "$entry")"
done < <(find "$ffmpeg_lib_dir" -maxdepth 1 -type l -name '*.dylib' -print0)

# Keep the libraries replaceable (as required by LGPL) while making their
# install names independent of the machine-specific build prefix.  Helpers use
# an rpath relative to Contents/Library/Helpers; each dylib retains @rpath
# references so a compatible replacement can be dropped into this directory.
while IFS= read -r -d '' binary; do
  while IFS= read -r -d '' dependency; do
    case "$dependency" in
      "$ffmpeg_lib_dir"/*)
        install_name_tool -change "$dependency" "@rpath/$(basename "$dependency")" "$binary"
        ;;
    esac
  done < <(otool -L "$binary" | sed '1d' | awk '{print $1}' | tr '\n' '\0')
done < <(find "$runtime_dir" -type f -name '*.dylib' -print0)

while IFS= read -r -d '' library; do
  current_id="$(otool -D "$library" | sed -n '2p')"
  [[ -n "$current_id" ]] || die "could not read install name for $library"
  install_name_tool -id "@rpath/$(basename "$current_id")" "$library"
done < <(find "$runtime_dir" -type f -name '*.dylib' -print0)

for helper in "$helpers_dir/ffmpeg" "$helpers_dir/ffprobe"; do
  while IFS= read -r -d '' dependency; do
    case "$dependency" in
      "$ffmpeg_lib_dir"/*)
        install_name_tool -change "$dependency" "@rpath/$(basename "$dependency")" "$helper"
        ;;
    esac
  done < <(otool -L "$helper" | sed '1d' | awk '{print $1}' | tr '\n' '\0')
  install_name_tool -add_rpath '@loader_path/../../Frameworks/FFmpeg' "$helper"
done
