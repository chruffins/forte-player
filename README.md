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
- `dsp/spectrum.zig` — shared live FFT spectrum and time-based envelopes
- `ui/gui_visualizer.zig` — shader-generated Mirror/Polar Spectrum modes
- `integrations/discord_rpc.zig` — Discord rich presence (local IPC socket),
  `integrations/cover_resolver.zig` — MusicBrainz / Cover Art Archive covers,
  `integrations/lastfm.zig` — Last.fm scrobbling
- `ui/` — shared semantic `ui_state.zig`, native pixel-space GUI layout/rendering,
  and separate terminal-cell `ui_view.zig`/`tui_render.zig`. GUI rendering and hit
  testing use identical geometry; see `ui/DESIGN.md` and `ui/GUI_PLAN.md`.
- TUI artist/genre browsers with track detail views and context-aware playback,
  playlist detail editing, queue editing, asynchronous settings rescan/theme controls, and TagLib-backed
  metadata editing

## Build / run / test

```sh
zig build            # compile gallery, TUI, and visualizer-world frontends
zig build run        # GUI frontend (audio + optional display)
zig build run-tui    # TUI frontend (terminal; press 1-8 for screens, q to quit)
zig build run-world  # separate 3D firefly-world frontend
zig build test       # run headless unit tests + compile-checks
zig build test --summary all   # verbose
zig build test-gpu   # optional real-OpenGL visualizer test (requires display)
zig build test-world # optional real-GPU world test (no audio/user library)
zig build test-recording # recording helper tests (Python 3; no display/audio)
```

The GUI uses a Windows XP Media Player-inspired blue glass and brushed-metal
skin around its artwork-led gallery. Albums are the landing page: click a cover
to open its detail view, or use its Play / More buttons. Artwork loads lazily
through a bounded background thumbnail cache; missing covers get stable
blue/steel typographic placeholders. Tracks and detail views use quiet tables.

The window is resizable (minimum 360×300). A Now Playing inspector with Queue /
Lyrics tabs appears on larger windows; the player's **Panel** button toggles it
and remembers the choice. Clicking the small player cover opens Listening, with
larger artwork and the GPU visualizer. Short windows switch albums to compact
artwork rows. Lists, gallery, and settings scroll inside their own viewport;
dialogs keep their buttons visible and reveal the focused field.
GUI keys: `1`-`8` switch screens, arrows or `j/k` navigate, Enter opens or
plays, and double-click activates track rows. Album arrows move across the grid;
Up/Down move by a complete row. Album tiles open with a single click. Click/drag player progress to seek and
drag the volume slider. Now Playing includes GPU Mirror/Polar Spectrum modes;
press `Z` or click the visualizer arrows to switch (mode is remembered). The
visualizer hides in compact windows and gracefully disables when shaders are
unavailable. Press `V` or right-click a track row for
play/queue/favorite/playlist actions; press `E` to edit all common tags in one
form. Press `/` to search Library, Albums, Artists, Genres, and Playlists; on
Albums, click the sort button or press `O` to cycle sort order. On Playlists, `N`
creates, `F2` renames, and `Delete` removes the selected playlist. In playlist
detail, `X` removes the selected track and Left/Right reorders it. `A` adds the
selected item to the queue; use the track-actions menu to add it next. On Queue, drag the left handle to
reorder, `W` saves the queue as a playlist, `X` removes, `C` clears, and
Left/Right reorders. `R` on Settings starts a background rescan
(`Esc` cancels); click a Last.fm field or press `L` to edit it, and `O`/`K` perform asynchronous Last.fm authorization. TUI screen keys: `1` now playing, `2` library, `3` albums, `4` artists,
`5` genres, `6` playlists, `7` queue, `8` settings. `j/k` or Up/Down navigate.
Use `/` to search artist, genre, album, or library lists. `e` edits the selected/current track's metadata;
`R` starts a background library scan (Esc cancels); `t` cycles the theme; `l` edits Last.fm credentials; `o` starts Last.fm authorization and `k` completes it.
Playlist detail supports adding, removing, and reordering tracks. Queue supports moving, removing, clearing with `C`, adding selected songs or
whole detail lists with `a`, and adding the selected item as next with `A`; the
queue, cursor, shuffle, and repeat mode are restored on the next launch. Shuffle
uses play history and favorites while reducing consecutive tracks from the same
artist or album; the current track stays first.

## Visualizer-first world

`zig build run-world` launches **forte-world**, a separate app—not a replacement
for the gallery. It wraps the camera/skybox rendering subset from
`~/projects/template` behind `src/world/template.zig`. V1 is a dark checkerboard
field with the same night-ocean skybox and 288 GPU-animated fireflies reacting to
live FFT bands. A separate low-cost singing-presence heuristic accents likely
voiced content on a purple-accented subset of the fireflies (not stem separation;
pitched instruments can also trigger
it). Each emits a moving colored point light onto the checkerboard,
with diffuse falloff, batched on the GPU (no shadows yet). No cubes, dashboard,
physics runtime, or per-firefly CPU updates.

**WASD** walks, **Shift** moves faster, **right-drag / arrows** look around, and
**R** returns home. **Space** pauses, **N/P** changes tracks, **+/-** adjusts volume,
**H** hides the minimal HUD, and **F1** shows controls. **Tab** opens a transient
music picker: type to search, arrows select, Enter/click plays, Esc returns.
Picking a song replaces the old album/playlist queue with library order, so songs
outside a saved queue are playable; next/previous are unaffected by filtering.
Esc outside the picker quits. Movement clears on focus loss; music keeps playing.

It shares the existing music settings/database/queue, but owns its live engine
and keeps independent `[world] width/height` settings. Avoid simultaneous
frontends if saved-state ownership matters; the last exit wins. Set
`FORTE_WORLD_DIAGNOSTICS=1` for once-per-second playback/capture diagnostics.

**Asset caveat:** the template's skybox source license is unverified; its
provenance and warning are retained. Verify permission or replace it before
shipping. **Codec caveat:** the local Allegro backend stopped a 24-bit FLAC test
fixture early in both gallery and world; the 16-bit version worked. That decoder
issue remains separate from this rendering prototype. Reproduction and main-branch
verification steps: [FLAC issue notes](docs/issues/allegro-24bit-flac.md).
See also `src/world/DESIGN.md`.

### Record a track from a saved shot

Compose a view in the world and press **V** to save it. **F2** records the current
track; in the Tab picker, F2 records the selected track. The camera locks, the
HUD disappears, and a per-track MP4 is saved under `recordings/` (then the app
exits). Existing default names get numbered rather than overwritten.

```sh
zig build run-world -- --view my-shot  # compose, then V
zig-out/bin/forte-world record "/music/track.flac" --view my-shot
# Optional: --output /videos/track.mp4 --width 1920 --height 1080 --fps 60
```

Requires Python 3, FFmpeg and desktop OpenGL. Export uses a fixed frame clock and
FFmpeg-decoded track audio—not desktop capture or real-time speaker playback.
Default resolution preserves the saved window framing; default frame rate is
60 fps. Volume/normalization profiles do not affect export. See
[recording workflow and limitations](src/world/RECORDING.md).

## Layout & test-organization

```
src/
  main.zig                  # GUI frontend (thin; shares wiring via app.zig)
  tui_main.zig              # TUI frontend (terminal: space/n/p/s/r/+/-/q)
  world_main.zig            # separate immersive frontend / minimal HUD
  world/                    # camera/HUD model, Zig/C bridge, fixed-clock recorder
  world_smoke.zig           # opt-in GPU world/sky/particle/lifecycle tests
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
  dsp/                      # signal processing (shared TUI / GUI spectrum)
    fft.zig                 # iterative Cooley–Tukey FFT
    spectrum.zig            # log-spaced band spectrum + AGC smoother
  integrations/             # external-service subsystems
    discord_rpc.zig         # Discord Rich Presence over the local IPC socket
    cover_resolver.zig     # MusicBrainz + Cover Art Archive cover resolution
  ui/                       # redesigned UI layer (see ui/DESIGN.md)
    ui_state.zig            # pure State + action reducer
    ui_view.zig             # pure State -> terminal draw-command list
    tui_render.zig          # terminal framebuffer renderer
    gui_render.zig           # native pixel-space Allegro renderer
    gui_input.zig            # pure GUI hit testing
    gui_layout.zig           # shared draw/hit geometry for shell/lists/dialogs
    gui_visualizer.zig       # display-owned shader renderer, one rectangle
    gui_artwork.zig          # bounded LRU thumbnails, memory-only decode worker
    gui_gallery_test.zig     # gallery/inspector/navigation regression tests
    gui_regression_test.zig  # headless native GUI regression coverage
    gui_framework.zig        # pure widgets, text input, slider, scroll models
    gui_fonts.zig            # installed FontSet + asset fallback
    gui_icons.zig            # legacy optional icon loader (transport is vector)
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
