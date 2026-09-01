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

Install Allegro 5 and TagLib with Homebrew. `allegro_main` is required by
Allegro's macOS entry-point glue and is linked by the build. Run:

```sh
TAGLIB_PREFIX="$(brew --prefix taglib)" \
ALLEGRO_PREFIX="$(brew --prefix allegro)" \
packaging/macos/build-app.sh
```

This creates `dist/forte-player.app` and, when `hdiutil` is available, a DMG.
The app bundle currently contains both frontends; the TUI executable remains
available at `Contents/MacOS/forte-tui`.

## Windows

Build on a native Windows runner with Zig, Allegro, TagLib, and a C++ compiler
available on `PATH`:

```powershell
packaging\windows\build.ps1
```

This creates a portable ZIP. Windows dependency DLLs must be copied beside the
executables; the script accepts `ALLEGRO_PREFIX` and `TAGLIB_PREFIX` pointing to
those installations.
