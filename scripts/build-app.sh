#!/usr/bin/env bash
# Assemble Snagbook.app from the SwiftPM build. An .app is a directory with a plist;
# no Xcode project is needed.
#
#   Scripts/build-app.sh [release|debug]
#
# Signing: set SNAGBOOK_SIGN_IDENTITY to a code-signing identity to sign with it.
# macOS remembers the Screen Recording permission per signature, so a stable identity
# keeps the permission across rebuilds; the ad-hoc default asks again after each build.
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# The note editor is a small web bundle built from web/src. It needs Node.js once.
if [ ! -f "$ROOT/Resources/editor/editor.js" ] || [ -n "$(find "$ROOT/web/src" "$ROOT/web/build.mjs" -newer "$ROOT/Resources/editor/editor.js" 2>/dev/null)" ]; then
    command -v node >/dev/null || { echo "Node.js is needed to build the note editor (brew install node)." >&2; exit 1; }
    (cd "$ROOT/web" && { [ -d node_modules ] || npm ci --silent; } && node build.mjs >/dev/null)
fi

swift build -c "$CONFIG" --product Snagbook
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Snagbook"

APP="$ROOT/build/Snagbook.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Snagbook"
cp "$ROOT/Sources/Snagbook/Info.plist" "$APP/Contents/Info.plist"
cp -R "$ROOT/Resources/editor" "$APP/Contents/Resources/editor"
[ -f "$ROOT/Resources/AppIcon.icns" ] && cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

IDENTITY="${SNAGBOOK_SIGN_IDENTITY:--}"
if [ "$IDENTITY" = "-" ]; then
    codesign --force --sign - --timestamp=none "$APP" >/dev/null
else
    codesign --force --sign "$IDENTITY" --options runtime --timestamp=none \
        --entitlements "$ROOT/Scripts/Snagbook.entitlements" "$APP" >/dev/null
fi
echo "built: $APP"
