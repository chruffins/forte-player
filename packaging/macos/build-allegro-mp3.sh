#!/usr/bin/env bash
set -euo pipefail

# Build the Allegro PR with callback-based MP3 streaming (PR #1773).
# The result is installed separately so it never overwrites Homebrew Allegro.
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SRC="${TMPDIR:-/tmp}/allegro5-mp3"
BUILD="${TMPDIR:-/tmp}/allegro5-mp3-build"
PREFIX="${ALLEGRO_MP3_PREFIX:-$(brew --prefix)/opt/allegro-mp3}"

rm -rf "$SRC" "$BUILD"
git clone --depth 1 --branch mp3-streaming \
    https://github.com/chruffins/allegro5.git "$SRC"
cmake -S "$SRC" -B "$BUILD" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DSHARED=ON -DWANT_MP3=ON -DWANT_TESTS=OFF \
    -DWANT_EXAMPLES=OFF -DWANT_DOCS=OFF
cmake --build "$BUILD" --parallel
cmake --install "$BUILD"
printf 'Installed MP3-enabled Allegro at %s\n' "$PREFIX"
printf 'Build Forte with: zig build -Dallegro_prefix=%s\n' "$PREFIX"
