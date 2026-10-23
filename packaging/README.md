# Packaging

Release artifacts are built on native runners because Allegro, TagLib, and the
C++ album-art shim need native platform libraries.

## Linux AppImage

Install Zig 0.17.0, Allegro 5, TagLib, and `linuxdeploy`/`appimagetool`, then run:

```sh
packaging/linux/build-appimage.sh
```

The resulting AppImage contains `forte-player` (GUI), `forte-tui`, and the
`forte-mcp` stdio bridge.
Set `ALLEGRO_PREFIX` and `TAGLIB_PREFIX` when using non-system installs.

## macOS

Install TagLib with Homebrew. For MP3 support, first build the Allegro branch
with vendored minimp3:

```sh
packaging/macos/build-allegro-mp3.sh
```

Build the GUI app and DMG (including `forte-mcp`) with:

```sh
packaging/macos/build-app.sh
```

To create an Applications-friendly TUI app (it opens a Terminal window):

```sh
packaging/macos/build-tui-app.sh
open dist/forte player.app
```

Use `ALLEGRO_PREFIX` and `TAGLIB_PREFIX` to override dependency locations.

## Windows

Build on a native Windows runner with Zig 0.17.0 and the MSYS2 MinGW-w64
Allegro, TagLib, and GCC toolchain installed (including `g++` and `objdump` on
`PATH`). For MP3 playback, build/install the project's MP3-enabled Allegro
branch into `%LOCALAPPDATA%\forte-player\allegro-mp3`; the build script will
prefer it automatically. Otherwise, it falls back to the MSYS2 Allegro build,
which may not include an MP3 decoder. Set `ALLEGRO_PREFIX` to override this
selection. The script supplies MinGW's C++ runtime archives and bundles the
transitive non-system DLL dependencies:

```powershell
packaging\windows\build.ps1 -RunSmokeTest
```

This creates a portable ZIP with the GUI, TUI, `forte-mcp`, assets, and required runtime DLLs. Configure your MCP client to run `forte-mcp.exe`; the GUI or TUI must already be open.
Set `ALLEGRO_PREFIX` and `TAGLIB_PREFIX` to override the MSYS2 installation
prefixes.
