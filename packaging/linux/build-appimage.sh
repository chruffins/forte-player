#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
DIST="$ROOT/dist"
APPDIR="$DIST/forte-player.AppDir"
PREFIX="${ALLEGRO_PREFIX:-}"
TAGLIB="${TAGLIB_PREFIX:-/usr}"

rm -rf "$APPDIR"
mkdir -p "$APPDIR/usr/bin" "$APPDIR/usr/share/applications"

zig build -Doptimize=ReleaseFast -Dallegro_prefix="$PREFIX" -Dtaglib_prefix="$TAGLIB"
install -m755 "$ROOT/zig-out/bin/forte-player" "$APPDIR/usr/bin/"
install -m755 "$ROOT/zig-out/bin/forte-tui" "$APPDIR/usr/bin/"
mkdir -p "$APPDIR/usr/share/forte-player"
cp -a "$ROOT/zig-out/share/forte-player/." "$APPDIR/usr/share/forte-player/"
install -m644 "$ROOT/packaging/linux/forte-player.desktop" "$APPDIR/usr/share/applications/"

if ! command -v linuxdeploy >/dev/null 2>&1; then
    echo "linuxdeploy is required to bundle Allegro/TagLib dependencies" >&2
    exit 1
fi

mkdir -p "$DIST"
linuxdeploy \
    --appdir "$APPDIR" \
    --executable "$APPDIR/usr/bin/forte-player" \
    --desktop-file "$APPDIR/usr/share/applications/forte-player.desktop" \
    --output appimage
