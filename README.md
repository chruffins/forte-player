# forte-player

Working name for a music player, being rewritten in Zig from
`audio-visualizer-cpp` as a real-world exercise for the
[allegro5-zig](https://github.com/chruffins/allegro5-zig) wrapper.

> **Toolchain:** pinned to **Zig 0.16.0** (see `.zigversion`), matching the
> allegro5-zig wrapper. The Zig std API churns a lot between versions (0.17-dev
> removed/renamed things like `ArrayList`, `std.fs`, `std.time`, etc.), and
> third-party Zig packages (e.g. `zig-sqlite`) target 0.16 — so pinning keeps
> everything buildable. Use `zigt`/`zvm`/`zigup` (or the official tarball) to
> install 0.16.0 if your `zig` isn't that version.

Currently ported:
- `core/music_engine.zig` — audio engine, generic over a duck-typed driver (+ `FakeDriver` for headless tests)
- `core/config.zig` — persisted INI settings (Allegro config + standard paths)
- `core/bootstrap.zig` — display + event loop scaffold
- `music/play_queue.zig` — queue / repeat / shuffle + end-of-song auto-advance
- `music/database.zig` — SQLite-backed stores (zig-sqlite, pinned git dep in `build.zig.zon`)
- `music/library.zig` — in-memory library loaded from the DB (backs `resolve_song`)
- `dsp/spectrum.zig` — live FFT bar spectrum for the TUI
- `integrations/discord_rpc.zig` — Discord rich presence (local IPC socket),
  `integrations/cover_resolver.zig` — MusicBrainz / Cover Art Archive covers,
  `integrations/lastfm.zig` — Last.fm scrobbling
- `ui/` — the redesigned UI layer (`ui/ui_state.zig` + `ui/ui_view.zig` pure
  core, `ui/tui_render.zig` and `ui/gui_render.zig` frontend renderers,
  `ui/gui_input.zig` pure hit testing; see `ui/DESIGN.md`)
- TUI artist/genre browsers with track detail views and context-aware playback,
  playlist detail editing, queue editing, asynchronous settings rescan/theme controls, and TagLib-backed
  metadata editing

## Build / run / test

```sh
zig build            # compile both frontends
zig build run        # GUI frontend (audio + optional display)
zig build run-tui    # TUI frontend (terminal; press 1-8 for screens, q to quit)
zig build test       # run headless unit tests + compile-checks
zig build test --summary all   # verbose
```

GUI keys: `1`-`8` switch screens, arrows or `j/k` navigate, Enter opens or
plays, double-click activates rows, and click the footer bar to seek. `A` adds
the selected item to the queue; `E` adds it next. On Queue, `X` removes, `C`
clears, and Left/Right reorders. `R` on Settings starts a background rescan
(`Esc` cancels); click a Last.fm field or press `L` to edit it, and `O`/`K` perform asynchronous Last.fm authorization. TUI screen keys: `1` now playing, `2` library, `3` albums, `4` artists,
`5` genres, `6` playlists, `7` queue, `8` settings. Use `/` to search artist,
genre, album, or library lists. `e` edits the selected/current track's metadata;
`R` starts a background library scan (Esc cancels); `t` cycles the theme; `l` edits Last.fm credentials; `o` starts Last.fm authorization and `k` completes it.
Playlist detail supports adding, removing, and reordering tracks. Queue supports moving, removing, clearing with `C`, adding selected songs or
whole detail lists with `a`, and adding the selected item as next with `A`; the
queue, cursor, shuffle, and repeat mode are restored on the next launch.

## Layout & test-organization

```
src/
  main.zig                  # GUI frontend (thin; shares wiring via app.zig)
  tui_main.zig              # TUI frontend (terminal: space/n/p/s/r/+/-/q)
  app.zig                   # shared composition root; GUI uses deferred scan
  tests.zig                 # test aggregator (imports every module's tests)
  core/                     # audio engine + app shell
    allegro_init.zig
    bootstrap.zig           # event loop / display host
    driver.zig              # AllegroDriver / FakeDriver (duck-typed seam)
    music_engine.zig        # generic MusicEngine(Drv) + RealEngine
    music_engine_test.zig   # transport + auto-advance tests via FakeDriver
    sample_capture.zig      # lock-free-ish wave capture ring buffer
    config.zig              # persisted INI settings (Allegro config + paths)
  music/                    # library domain
    entity.zig              # Song/Album/Artist/Genre/Playlist value types
    database.zig            # SQLite-backed stores (zig-sqlite)
    library.zig             # in-memory Library loaded from the DB
    play_queue.zig          # queue / repeat / shuffle (pure, tested)
    scanner.zig             # recursive walk + change detection + upsert
    taglib_meta.zig         # TagLib metadata extraction
    taglib_art.{zig,cpp,h}  # TagLib artwork + metadata writing shim
    metadata_edit.zig       # write tags, then reconcile the database
  dsp/                      # signal processing (for the TUI visualizer)
    fft.zig                 # iterative Cooley–Tukey FFT
    spectrum.zig            # log-spaced band spectrum + AGC smoother
  integrations/             # external-service subsystems
    discord_rpc.zig         # Discord Rich Presence over the local IPC socket
    cover_resolver.zig     # MusicBrainz + Cover Art Archive cover resolution
  ui/                       # redesigned UI layer (see ui/DESIGN.md)
    ui_state.zig            # pure State + action reducer
    ui_view.zig             # pure State -> draw-command list
    tui_render.zig          # terminal framebuffer renderer
    gui_render.zig           # Allegro command-stream renderer
    gui_input.zig            # pure GUI hit testing
    gui_layout.zig           # responsive shell geometry
    gui_framework.zig        # pure widgets, text input, slider, scroll models
    gui_fonts.zig            # installed FontSet + asset fallback
    gui_icons.zig            # optional packaged transport icons
    gui_jobs.zig             # GUI scan/auth workers
    cover_art.zig            # image bytes -> half-block terminal art grid
    GUI_PLAN.md              # GUI visual/framework plan
    theme.zig, render.zig, ui.zig
assets/                       # C++ fonts, licenses, icons, and logo

```

**Test placement:** Zig convention is to keep unit tests *co-located* with
their source as `test` blocks inside the same `.zig` file; `zig build test`
discovers them automatically. `src/tests.zig` is just an aggregator so every
module's tests run in one pass (and so modules that need `allegro` linked are
pulled in). Larger integration tests (real display + input) will live in a
top-level `test/` dir as executables importing this project as a module.
