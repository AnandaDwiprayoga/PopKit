#!/usr/bin/env bash
# Builds PopKit.app, the menu bar app.
#
#   ./build.sh             build into build/PopKit.app
#   ./build.sh --install   also copy it to ~/Applications and open it
#
# Signing: set POPKIT_SIGN_IDENTITY to a stable code-signing identity (for
# example a self-signed "PopKit Dev" certificate from Keychain Access) and
# macOS keeps your Accessibility permission across rebuilds. Without it the app
# is signed ad-hoc, and macOS forgets the permission after every rebuild.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/PopKit.app"
INSTALL_DIR="$HOME/Applications"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/PopKit"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/PopKit"
cp Info.plist "$APP/Contents/Info.plist"
if [ -d Resources/Extensions ]; then
  cp -R Resources/Extensions "$APP/Contents/Resources/Extensions"
  find "$APP/Contents/Resources/Extensions" -name .gitkeep -delete
fi

if [ -n "${POPKIT_SIGN_IDENTITY:-}" ]; then
  codesign --force --sign "$POPKIT_SIGN_IDENTITY" "$APP"
  echo "Signed with \"$POPKIT_SIGN_IDENTITY\"."
else
  codesign --force --sign - "$APP"
  echo "Note: signed ad-hoc. macOS will ask for Accessibility access again after each rebuild."
  echo "      Set POPKIT_SIGN_IDENTITY to a stable self-signed certificate to avoid that."
fi
echo "Built $APP"

if [ "${1:-}" = "--install" ]; then
  pkill -x PopKit 2>/dev/null || true
  mkdir -p "$INSTALL_DIR"
  rm -rf "$INSTALL_DIR/PopKit.app"
  ditto "$APP" "$INSTALL_DIR/PopKit.app"
  open "$INSTALL_DIR/PopKit.app"
  echo "Installed to $INSTALL_DIR/PopKit.app. Look for the PopKit icon in the menu bar."
fi
