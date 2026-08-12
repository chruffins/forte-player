# forte-player

Working name for a music player, being rewritten in Zig from
`audio-visualizer-cpp` as a real-world exercise for the
[allegro5-zig](https://github.com/your-org/allegro5-zig) wrapper.

> **Toolchain:** pinned to **Zig 0.16.0** (see `.zigversion`), matching the
> allegro5-zig wrapper. The Zig std API churns a lot between versions (0.17-dev
> removed/renamed things like `ArrayList`, `std.fs`, `std.time`, etc.), and
> third-party Zig packages (e.g. `zig-sqlite`) target 0.16 — so pinning keeps
> everything buildable. Use `zigt`/`zvm`/`zigup` (or the official tarball) to
> install 0.16.0 if your `zig` isn't that version.

Currently ported:
- `core/allegro_init.zig` — Allegro/addon/input init (port of `allegro_init.cpp`)
- `core/music_engine.zig` — audio engine, generic over a duck-typed driver (+ `FakeDriver` for headless tests)
- `core/play_queue.zig` — queue / repeat / shuffle + end-of-song auto-advance
- `core/config.zig` — persisted INI settings (Allegro config + standard paths)
- `core/bootstrap.zig` — display + event loop scaffold (no UI yet)
- `music/database.zig` — SQLite-backed stores (zig-sqlite, pinned git dep in `build.zig.zon`)
- `music/library.zig` — in-memory library loaded from the DB (backs `resolve_song`)
- `ui/` — the redesigned UI layer (`ui/ui.zig` pure layout + `ui/render.zig` Allegro drawing; see `ui/DESIGN.md`)

## Build / run / test

```sh
zig build            # compile both frontends
zig build run        # GUI frontend (audio + optional display)
zig build run-tui    # TUI frontend (terminal: space/n/p/s/r/+/-/q)
zig build test       # run headless unit tests + compile-checks
zig build test --summary all   # verbose
```

## Layout & test-organization

```
src/
  main.zig                  # app entry (wires engine + bootstrap)
  tests.zig                 # test aggregator (imports every module's tests)
  core/                     # audio engine + app shell
    allegro_init.zig
    bootstrap.zig           # event loop / display host
    driver.zig              # AllegroDriver / FakeDriver (duck-typed seam)
    music_engine.zig        # generic MusicEngine(Drv) + RealEngine
    music_engine_test.zig   # transport + auto-advance tests via FakeDriver
    play_queue.zig          # queue / repeat / shuffle (pure, tested)
    sample_capture.zig      # FFT-free wave capture ring buffer
    config.zig              # persisted INI settings (Allegro config + paths)
  ui/                       # redesigned UI layer (see ui/DESIGN.md)
  music/                    # library domain
    entity.zig              # Song/Album/Artist/Genre/Playlist value types
    database.zig            # SQLite-backed stores (zig-sqlite)
    library.zig             # in-memory Library loaded from the DB

```

**Test placement:** Zig convention is to keep unit tests *co-located* with
their source as `test` blocks inside the same `.zig` file; `zig build test`
discovers them automatically. `src/tests.zig` is just an aggregator so every
module's tests run in one pass (and so modules that need `allegro` linked are
pulled in). Larger integration tests (real display + input) will live in a
top-level `test/` dir as executables importing this project as a module.
