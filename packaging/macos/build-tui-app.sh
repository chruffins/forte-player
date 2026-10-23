#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
DIST="$ROOT/dist"
APP="$DIST/forte player.app"
BUILD="${TMPDIR:-/tmp}/forte-player-tui-build"
ALLEGRO="${ALLEGRO_PREFIX:-$(brew --prefix)/opt/allegro-mp3}"
TAGLIB="${TAGLIB_PREFIX:-$(brew --prefix taglib)}"
case "$(uname -m)" in
    arm64) TARGET=aarch64-macos; ARCH=arm64 ;;
    x86_64) TARGET=x86_64-macos; ARCH=x86_64 ;;
    *) echo "unsupported macOS architecture" >&2; exit 1 ;;
esac

rm -rf "$APP" "$BUILD"
mkdir -p "$BUILD" "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
zig build -Dtarget="$TARGET" -Doptimize=ReleaseFast -Dallegro_prefix="$ALLEGRO" -Dtaglib_prefix="$TAGLIB"
cp "$ROOT/zig-out/bin/forte-tui" "$APP/Contents/Resources/forte-tui"
cp "$ROOT/zig-out/bin/forte-mcp" "$APP/Contents/Resources/forte-mcp"
chmod +x "$APP/Contents/Resources/forte-tui" "$APP/Contents/Resources/forte-mcp"
file "$APP/Contents/Resources/forte-tui"
cp -a "$ROOT/zig-out/share/forte-player/." "$APP/Contents/Resources/"
ICONSET="$APP/Contents/Resources/forte-player.iconset"
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

# Finder expects the bundle executable to be a native Mach-O binary. A shell
# script launcher can make Finder offer Rosetta even when the TUI itself is
# arm64, so compile a tiny native launcher that opens Terminal via AppleScript.
LAUNCHER_SRC="$BUILD/forte-player-tui-launcher.c"
cat > "$LAUNCHER_SRC" <<'EOF'
#include <limits.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
int main(int argc, char **argv) {
    (void)argc;
    char path[PATH_MAX], script[PATH_MAX + 128];
    char *slash = strrchr(argv[0], '/');
    if (!slash) return 1;
    size_t n = (size_t)(slash - argv[0]);
    if (n >= sizeof(path) - 32) return 1;
    memcpy(path, argv[0], n);
    path[n] = 0;
    snprintf(path + n, sizeof(path) - n, "/../Resources/forte-tui");
    snprintf(script, sizeof(script), "tell application \"Terminal\" to activate\ntell application \"Terminal\" to do script (quoted form of \"%s\")", path);
    execl("/usr/bin/osascript", "osascript", "-e", script, (char *)0);
    return 1;
}
EOF
clang -arch "$ARCH" -O2 "$LAUNCHER_SRC" -o "$APP/Contents/MacOS/forte-player-tui"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>forte player</string>
<key>CFBundleDisplayName</key><string>forte player</string>
<key>CFBundleIdentifier</key><string>com.forte.player.tui</string>
<key>CFBundleVersion</key><string>0.1.0</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleExecutable</key><string>forte-player-tui</string>
<key>CFBundleIconFile</key><string>forte-player.icns</string>
</dict></plist>
EOF

if command -v dylibbundler >/dev/null 2>&1; then
    dylibbundler -od -b -x "$APP/Contents/Resources/forte-tui" -d "$APP/Contents/Frameworks/"
fi
mkdir -p "$DIST"
printf 'Created %s\n' "$APP"
