#!/bin/bash
# Builds capture-harness with an embedded Info.plist and ad-hoc signs it, so macOS
# can attach Screen & System Audio Recording and Microphone permissions to the binary.
#
# The signature identity is the binary's cdhash, so every rebuild produces a new
# identity and the permission grants must be reviewed again. Re-run this script after
# every source change, then re-check `capture-harness permissions`.
set -euo pipefail

PACKAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${1:-release}"
INFO_PLIST="$PACKAGE_DIR/Resources/Info.plist"
ENTITLEMENTS="$PACKAGE_DIR/Resources/CaptureHarness.entitlements"
IDENTIFIER="io.cooperativ.scribe.captureharness"

cd "$PACKAGE_DIR"
swift build -c "$CONFIGURATION" \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$INFO_PLIST"

BINARY="$(swift build -c "$CONFIGURATION" --show-bin-path)/capture-harness"
codesign --force --sign - \
  --identifier "$IDENTIFIER" \
  --entitlements "$ENTITLEMENTS" \
  --timestamp=none \
  "$BINARY"

# Also install to a non-hidden path. Adding a binary inside .build to System Settings
# requires the Go-to-folder box; this copy can simply be dragged in. The copy carries the
# same signature and cdhash, so it is the same identity to TCC.
INSTALLED="$PACKAGE_DIR/bin/capture-harness"
mkdir -p "$PACKAGE_DIR/bin"
cp "$BINARY" "$INSTALLED"

# And wrap the same executable in a real application bundle.
#
# A bare Mach-O executable cannot be granted Screen & System Audio Recording: the "+"
# picker in System Settings only accepts application bundles, tccutil cannot address a
# client with no LaunchServices bundle identifier, and CGRequestScreenCaptureAccess()
# returns false without presenting a prompt. Inside a bundle the tool has a real bundle
# identity, which is also how the shipping menu-bar app will be evaluated -- so the
# permission behaviour measured here is representative rather than an artefact of
# running from a terminal.
APP="$PACKAGE_DIR/bin/CaptureHarness.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$PACKAGE_DIR/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$BINARY" "$APP/Contents/MacOS/capture-harness"
codesign --force --sign - \
  --identifier "$IDENTIFIER" \
  --entitlements "$ENTITLEMENTS" \
  --timestamp=none \
  "$APP"

codesign --display --verbose=2 --entitlements - "$INSTALLED" 2>&1 | sed 's/^/  /'
echo
echo "Signed binary: $INSTALLED"
echo "Signed bundle: $APP"
echo "  Run the bundled copy for anything needing Screen & System Audio Recording:"
echo "  \"$APP/Contents/MacOS/capture-harness\" permissions --request"
