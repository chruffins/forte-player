# Packaging

Release artifacts are built on native runners because Allegro, TagLib, and the
C++ album-art shim need native platform libraries.

## Linux AppImage

Install Zig 0.16, Allegro 5, TagLib, and `linuxdeploy`/`appimagetool`, then run:

```sh
packaging/linux/build-appimage.sh
```

The resulting AppImage contains both `forte-player` (GUI) and `forte-tui`.
Set `ALLEGRO_PREFIX` and `TAGLIB_PREFIX` when using non-system installs.

## macOS

Install TagLib with Homebrew. For MP3 support, first build the Allegro branch
with vendored minimp3:

```sh
packaging/macos/build-allegro-mp3.sh
```

Build the GUI app and DMG with:

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

Build on a native Windows runner with Zig, Allegro, TagLib, and a C++ compiler
available on `PATH`:

```powershell
packaging\windows\build.ps1
```

This creates a portable ZIP. Windows dependency DLLs must be copied beside the
executables; the script accepts `ALLEGRO_PREFIX` and `TAGLIB_PREFIX` pointing to
those installations.
