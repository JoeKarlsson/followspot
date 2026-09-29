#!/usr/bin/env bash
# Build dist/Followspot.app: the Swift wrapper, the bundled whisper-server,
# and a copy of public/. Signed with your local identity if you made one
# (macos/make-signing-identity.sh), else ad-hoc. Neither is a Developer ID,
# so other Macs need Open Anyway the first time.
#
#   macos/build-whisper.sh   # once, to build the bundled whisper-server
#   macos/build.sh           # → dist/Followspot.app
#   macos/build.sh --install # ...and copy it to /Applications
set -euo pipefail

INSTALL=0
[[ "${1:-}" == "--install" ]] && INSTALL=1

cd "$(dirname "$0")"
ROOT="$(cd .. && pwd)"
APP="$ROOT/dist/Followspot.app"
SERVER=".whisper/whisper-server"

if [[ ! -x "$SERVER" ]]; then
  echo "$SERVER not found. Build it first: macos/build-whisper.sh" >&2
  exit 1
fi

swift build -c release
BIN="$(swift build -c release --show-bin-path)/Followspot"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Followspot"
cp "$SERVER" "$APP/Contents/Helpers/whisper-server"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/Followspot.icns "$APP/Contents/Resources/Followspot.icns"
# Real files only: current.md is the launcher's symlink to your script.
rsync -a --exclude current.md "$ROOT/public/" "$APP/Contents/Resources/public/"

VERSION="$(sed -n 's/^  "version": "\(.*\)",$/\1/p' "$ROOT/package.json")"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"

# A fixed local identity (macos/make-signing-identity.sh) keeps camera, mic,
# and Documents permissions across rebuilds. Ad-hoc (CI, or without one)
# changes the signature every build, so macOS asks again each time.
IDENTITY="-"
SIGNED="ad-hoc"
if security find-certificate -c "Followspot Local Signing" >/dev/null 2>&1; then
  IDENTITY="Followspot Local Signing"
  SIGNED="$IDENTITY"
fi
# Inside out: the helper first, then the app that contains it.
codesign --force --options runtime --sign "$IDENTITY" "$APP/Contents/Helpers/whisper-server"
codesign --force --options runtime --entitlements Resources/Followspot.entitlements --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"

echo "Built dist/Followspot.app ($VERSION, signed: $SIGNED)"

if [[ "$INSTALL" == 1 ]]; then
  # Quit a running copy first; it stops its whisper-server on the way out.
  # It asks first if the control window has unsaved edits.
  if pgrep -xq Followspot; then
    osascript -e 'tell application "Followspot" to quit' 2>/dev/null || true
    for _ in $(seq 1 50); do pgrep -xq Followspot || break; sleep 0.1; done
    if pgrep -xq Followspot; then
      echo "Followspot is still running (unsaved edits?). Quit it, then run this again." >&2
      exit 1
    fi
  fi
  rm -rf /Applications/Followspot.app
  ditto "$APP" /Applications/Followspot.app
  echo "Installed /Applications/Followspot.app"
fi
