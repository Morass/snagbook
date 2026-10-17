#!/usr/bin/env bash
# Assemble Snagbook.app from the SwiftPM build. An .app is a directory with a plist;
# no Xcode project is needed.
#
#   scripts/build-app.sh [release|debug]
#
# Signing: set SNAGBOOK_SIGN_IDENTITY to a code-signing identity to sign with it.
# macOS remembers the Screen Recording permission per signature, so a stable identity
# keeps the permission across rebuilds; the ad-hoc default asks again after each build.
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$ROOT"

# The note editor is a small web bundle built from web/src. It needs Node.js once.
if [ ! -f "$ROOT/Resources/editor/editor.js" ] || [ -n "$(find "$ROOT/web/src" "$ROOT/web/build.mjs" -newer "$ROOT/Resources/editor/editor.js" 2>/dev/null)" ]; then
    command -v node >/dev/null || { echo "Node.js is needed to build the note editor (brew install node)." >&2; exit 1; }
    (cd "$ROOT/web" && { [ -d node_modules ] || npm ci --silent; } && node build.mjs >/dev/null)
fi

SWIFT_ARGS=(-c "$CONFIG" --product Snagbook)
if [ "$CONFIG" = release ]; then
    SWIFT_ARGS+=(-Xswiftc -file-prefix-map -Xswiftc "$ROOT=." -Xswiftc -debug-prefix-map -Xswiftc "$ROOT=.")
fi
swift build "${SWIFT_ARGS[@]}"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
python3 scripts/prepare-resource-accessors.py "$BIN_DIR"
swift build "${SWIFT_ARGS[@]}"
python3 scripts/prepare-resource-accessors.py "$BIN_DIR" --check
BIN="$BIN_DIR/Snagbook"

APP="$ROOT/build/Snagbook.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Snagbook"
cp "$ROOT/Sources/Snagbook/Info.plist" "$APP/Contents/Info.plist"
cp -R "$ROOT/Resources/editor" "$APP/Contents/Resources/editor"
[ -f "$ROOT/Resources/AppIcon.icns" ] && cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
for bundle in "$BIN_DIR"/*.bundle; do
    if [ -d "$bundle" ]; then cp -R "$bundle" "$APP/Contents/Resources/"; fi
done
cp "$ROOT/LICENSE" "$APP/Contents/Resources/LICENSE"
cp "$ROOT/.build/checkouts/KeyboardShortcuts/license" "$APP/Contents/Resources/KeyboardShortcuts-LICENSE"
if [ "$CONFIG" = release ]; then /usr/bin/strip -S "$APP/Contents/MacOS/Snagbook"; fi
printf 'APPL????' > "$APP/Contents/PkgInfo"

IDENTITY="${SNAGBOOK_SIGN_IDENTITY:--}"
if [ "$IDENTITY" = "-" ]; then
    codesign --force --sign - --timestamp=none "$APP" >/dev/null
else
    codesign --force --sign "$IDENTITY" --options runtime --timestamp=none \
        --entitlements "$ROOT/scripts/Snagbook.entitlements" "$APP" >/dev/null
fi
codesign --verify --strict "$APP"
echo "built: $APP"
