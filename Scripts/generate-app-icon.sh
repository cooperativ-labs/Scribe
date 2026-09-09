#!/usr/bin/env bash
# Regenerate the app and menu-bar icons from their source artwork.
#
# Assets/scribe-logo.png supplies the dark-background app icon.
# Assets/scribe-menubar.png supplies the transparent monochrome menu-bar mark.
# Rerun this after either source changes rather than editing catalog PNGs.
# Assets/scribe-transparent.png is retained for other branding uses.
#
#   Scripts/generate-app-icon.sh
#
# The menu-bar imageset is rendered as a template image, so only the mark's
# alpha reaches the menu bar and AppKit tints the silhouette to match the
# menu bar's own appearance in light and dark mode.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source_logo="$repo_root/Assets/scribe-logo.png"
source_menu="$repo_root/Assets/scribe-menubar.png"
catalog="$repo_root/Scribe/App/Resources/Assets.xcassets"

[[ -f "$source_logo" ]] || { echo "error: missing $source_logo" >&2; exit 1; }
[[ -f "$source_menu" ]] || { echo "error: missing $source_menu" >&2; exit 1; }

app_icon="$catalog/AppIcon.appiconset"
menu_icon="$catalog/MenuBarIcon.imageset"
mkdir -p "$app_icon" "$menu_icon"

emit() { # emit <destination> <pixel size> <source>
  sips --setProperty format png --resampleHeightWidth "$2" "$2" "$3" \
    --out "$1" >/dev/null
}

for size in 16 32 64 128 256 512 1024; do
  emit "$app_icon/icon_${size}.png" "$size" "$source_logo"
done

# 18pt is the conventional menu-bar icon size; 1x and 2x cover every display
# the app supports.
emit "$menu_icon/menubar_18.png" 18 "$source_menu"
emit "$menu_icon/menubar_36.png" 36 "$source_menu"

echo "Regenerated $app_icon from $source_logo and $menu_icon from $source_menu"
