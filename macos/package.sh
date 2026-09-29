#!/usr/bin/env bash
# Wrap dist/Followspot.app in a drag-to-Applications disk image.
#
#   macos/build.sh && macos/package.sh     # → dist/Followspot-<version>.dmg
set -euo pipefail

cd "$(dirname "$0")/.."
APP=dist/Followspot.app
[[ -d "$APP" ]] || { echo "$APP not found. Run macos/build.sh first." >&2; exit 1; }
VERSION="$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")"
DMG="dist/Followspot-${VERSION}.dmg"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/Followspot.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname Followspot -srcfolder "$STAGE" -format UDZO -fs HFS+ "$DMG" >/dev/null
echo "Built $DMG ($(du -h "$DMG" | cut -f1))"
