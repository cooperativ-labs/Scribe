#!/bin/bash
# Builds capture-integration and wraps it in an ad-hoc signed application bundle.
#
# The bundle is not a convenience. A bare Mach-O executable cannot be granted
# Screen & System Audio Recording by any route -- CGRequestScreenCaptureAccess
# returns false without prompting, the System Settings "+" picker only accepts
# application bundles, and tccutil cannot address a client that has no
# LaunchServices bundle identity. See docs/feasibility/capture-permissions.md.
#
# The ad-hoc signature's designated requirement is the cdhash, so every rebuild
# is a new identity to TCC and silently invalidates a grant made minutes earlier.
# Re-run `permissions` after every build rather than trusting an earlier approval.
set -euo pipefail

PACKAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${1:-release}"
INFO_PLIST="$PACKAGE_DIR/Resources/Info.plist"
ENTITLEMENTS="$PACKAGE_DIR/Resources/CaptureIntegration.entitlements"
IDENTIFIER="io.cooperativ.scribe.captureintegration"

cd "$PACKAGE_DIR"
swift build -c "$CONFIGURATION" \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$INFO_PLIST"

BINARY="$(swift build -c "$CONFIGURATION" --show-bin-path)/capture-integration"

APP="$PACKAGE_DIR/bin/CaptureIntegration.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$INFO_PLIST" "$APP/Contents/Info.plist"
cp "$BINARY" "$APP/Contents/MacOS/capture-integration"
codesign --force --sign - \
  --identifier "$IDENTIFIER" \
  --entitlements "$ENTITLEMENTS" \
  --timestamp=none \
  "$APP"

codesign --display --verbose=2 --entitlements - "$APP" 2>&1 | sed 's/^/  /'
echo
echo "Signed bundle: $APP"
echo "  \"$APP/Contents/MacOS/capture-integration\" permissions --request"
echo "  \"$APP/Contents/MacOS/capture-integration\" record --bundle-id <id> --seconds 600"
