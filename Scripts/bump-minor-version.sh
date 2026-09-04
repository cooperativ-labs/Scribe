#!/usr/bin/env bash
# Set Scribe's marketing and build versions to 0.YYMMDDHHMM.0 in UTC.
# Usage: Scripts/bump-minor-version.sh
#
# This intentionally mirrors Latch's release-version convention: one reviewed,
# timestamp-derived source version is committed before a release is packaged.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
info_plist="$repo_root/Scribe/App/Info.plist"
timestamp="$(date -u +%y%m%d%H%M)"
next_version="0.${timestamp}.0"

if ! perl -0ne 'exit(!m{<key>CFBundleShortVersionString</key>\s*<string>[0-9]+(?:\.[0-9]+){0,2}</string>})' "$info_plist"; then
  echo "Could not find CFBundleShortVersionString in $info_plist" >&2
  exit 1
fi
if ! perl -0ne 'exit(!m{<key>CFBundleVersion</key>\s*<string>[0-9]+(?:\.[0-9]+){0,2}</string>})' "$info_plist"; then
  echo "Could not find CFBundleVersion in $info_plist" >&2
  exit 1
fi
if grep -Fq "<string>$next_version</string>" "$info_plist"; then
  echo "Refusing to reuse version $next_version; run again after the minute changes." >&2
  exit 1
fi

NEXT_VERSION="$next_version" perl -0pi -e '
  s{(<key>CFBundleShortVersionString</key>\s*<string>)[0-9]+(?:\.[0-9]+){0,2}(</string>)}{$1 . $ENV{NEXT_VERSION} . $2}e;
  s{(<key>CFBundleVersion</key>\s*<string>)[0-9]+(?:\.[0-9]+){0,2}(</string>)}{$1 . $ENV{NEXT_VERSION} . $2}e;
' "$info_plist"

echo "Updated Scribe marketing and build versions to $next_version"
