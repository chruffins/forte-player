# forte-player

Working name for a music player, being rewritten in Zig from
`audio-visualizer-cpp` as a real-world exercise for the
[allegro5-zig](https://github.com/your-org/allegro5-zig) wrapper.

Currently ported:
- `core/allegro_init.zig` — Allegro/addon/input init (port of `allegro_init.cpp`)
- `core/music_engine.zig` — audio engine, generic over a duck-typed driver
- `core/driver.zig` — `AllegroDriver` (real) + `FakeDriver` (headless tests)
- `core/bootstrap.zig` — display + event loop scaffold (no UI yet)
- `ui/` — the redesigned UI layer (seed only; see `ui/DESIGN.md`)

## Build / run / test

```sh
zig build            # compile the app
zig build run        # run it (audio + optional display; headless-safe)
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
    music_engine_test.zig   # transport tests via FakeDriver
    sample_capture.zig      # FFT-free wave capture ring buffer
  ui/                       # redesigned UI layer (see ui/DESIGN.md)
```

**Test placement:** Zig convention is to keep unit tests *co-located* with
their source as `test` blocks inside the same `.zig` file; `zig build test`
discovers them automatically. `src/tests.zig` is just an aggregator so every
module's tests run in one pass (and so modules that need `allegro` linked are
pulled in). Larger integration tests (real display + input) will live in a
top-level `test/` dir as executables importing this project as a module.
