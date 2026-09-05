#!/usr/bin/env bash
# Regenerate the app's icon artwork from the single source logo.
#
# Assets/scribe-logo.png is the artwork of record. Everything the bundle ships
# is a scaled copy of it, so the catalog is treated as build output that happens
# to be checked in: rerun this after the logo changes rather than editing the
# PNGs under Scribe/App/Resources/Assets.xcassets by hand.
#
#   Scripts/generate-app-icon.sh
#
# The menu-bar imageset is rendered as a template image, so only the logo's
# alpha reaches the menu bar and AppKit tints the silhouette to match the
# menu bar's own appearance in light and dark mode.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source_logo="$repo_root/Assets/scribe-logo.png"
catalog="$repo_root/Scribe/App/Resources/Assets.xcassets"

[[ -f "$source_logo" ]] || { echo "error: missing $source_logo" >&2; exit 1; }

app_icon="$catalog/AppIcon.appiconset"
menu_icon="$catalog/MenuBarIcon.imageset"
mkdir -p "$app_icon" "$menu_icon"

emit() { # emit <destination> <pixel size>
  sips --setProperty format png --resampleHeightWidth "$2" "$2" "$source_logo" \
    --out "$1" >/dev/null
}

for size in 16 32 64 128 256 512 1024; do
  emit "$app_icon/icon_${size}.png" "$size"
done

# 18pt is the conventional menu-bar icon size; 1x and 2x cover every display
# the app supports.
emit "$menu_icon/menubar_18.png" 18
emit "$menu_icon/menubar_36.png" 36

echo "Regenerated $app_icon and $menu_icon from $source_logo"
