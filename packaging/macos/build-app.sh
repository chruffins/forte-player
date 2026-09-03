#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
DIST="$ROOT/dist"
APP="$DIST/forte-player.app"
TAGLIB="${TAGLIB_PREFIX:-$(brew --prefix taglib 2>/dev/null || echo /usr/local)}"
ALLEGRO="${ALLEGRO_PREFIX:-$(if [ -d "$(brew --prefix)/opt/allegro-mp3" ]; then echo "$(brew --prefix)/opt/allegro-mp3"; else brew --prefix allegro 2>/dev/null || echo /usr/local; fi)}"
case "$(uname -m)" in
    arm64) DEFAULT_TARGET=aarch64-macos ;;
    x86_64) DEFAULT_TARGET=x86_64-macos ;;
    *) echo "unsupported macOS architecture" >&2; exit 1 ;;
esac

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

ICONSET="$DIST/forte-player.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512 1024; do
    sips -z "$size" "$size" "$ROOT/assets/logo.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    if [ "$size" -le 512 ]; then
        double=$((size * 2))
        sips -z "$double" "$double" "$ROOT/assets/logo.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
    fi
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/forte-player.icns"
rm -rf "$ICONSET"

zig build -Doptimize=ReleaseFast -Dtarget="${ZIG_TARGET:-$DEFAULT_TARGET}" \
    -Dallegro_prefix="$ALLEGRO" -Dtaglib_prefix="$TAGLIB" -Dcxx="${CXX:-clang++}"
install -m755 "$ROOT/zig-out/bin/forte-player" "$APP/Contents/MacOS/"
install -m755 "$ROOT/zig-out/bin/forte-tui" "$APP/Contents/MacOS/"
mkdir -p "$APP/Contents/Resources"
cp -a "$ROOT/zig-out/share/forte-player/." "$APP/Contents/Resources/"
install -m644 "$ROOT/packaging/macos/Info.plist" "$APP/Contents/"

# Homebrew dylibs are not copied automatically. Prefer dylibbundler when
# available; otherwise the bundle remains a development artifact with paths
# resolved through Homebrew's install_name entries.
if command -v dylibbundler >/dev/null 2>&1; then
    dylibbundler -od -b -x "$APP/Contents/MacOS/forte-player" -d "$APP/Contents/Frameworks/"
fi

mkdir -p "$DIST"
if command -v hdiutil >/dev/null 2>&1; then
    hdiutil create -volname forte-player -srcfolder "$APP" -ov -format UDZO "$DIST/forte-player-macos.dmg"
fi
