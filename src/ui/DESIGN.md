# UI layer design

The redesign replaces the old drawable tree with a pure state/view pipeline and
an Allegro edge. The shared screens are now functional; this document records
the contracts that keep the GUI framework maintainable.

## Goals

- Replace the C++ `graphics/` (drawable tree + UV layout + event dispatcher)
  with a cleaner, purpose-built design.
- Keep the UI **headless-testable**: the geometry/layout and the *logic* of a
  widget should be pure Zig with no Allegro dependency, so `zig build test` can
  exercise them without a display. Only the final rasterization talks to
  `allegro/graphics`.
- Strong separation of concerns, unlike the C++ monolith:
  - **state/logic** (pure) — what the UI shows / does
  - **layout** (pure) — where things go
  - **input** (pure mapping of raw events -> semantic actions)
  - **render** (Allegro) — draw the layout

The GUI deliberately does not mirror the old retained drawable tree. A frame is
an immutable command stream: `ui_view` emits it, and each frontend interprets
it. Allegro events are mapped to semantic actions at the edge, then reduced by
`ui_state` and executed by the application adapter. This avoids per-widget
allocations, virtual drawables, UV objects, and callback lifetime graphs. The
Allegro edge also performs bounded coordinate hit testing for list rows and the
progress bar, including pointer capture for seek and scrollbar dragging,
while local cover art is decoded once per song change into the same `Art`
snapshot consumed by the TUI. Reusable behavior corresponding to the C++
buttons, textboxes, sliders, scroll frames, alignment, and UV geometry lives in
pure `gui_framework.zig` rather than callback-owning drawable objects.

## Structure (under `src/ui/`)

```
src/ui/
  ui.zig          # module root, re-exports the public surface
  DESIGN.md       # this file
  gui_input.zig   # pure pixel/cell hit testing
  gui_layout.zig  # responsive shell geometry
  gui_framework.zig # pure UV, text, slider, scroll, and event models
  gui_render.zig  # Allegro command-stream interpreter
  gui_fonts.zig   # font resources and packaged asset fallback
  gui_jobs.zig    # asynchronous scan/auth workers
  ui_state.zig    # shared semantic state and reducer
  ui_view.zig     # shared typed draw commands
  render.zig      # small Allegro primitive helpers
```

`gui_layout.zig`, `gui_framework.zig`, `gui_input.zig`, `ui_state.zig`, and
`ui_view.zig` stay headless-testable. Only `gui_render.zig`, `gui_fonts.zig`,
and `render.zig` import Allegro directly.

## Album view contract

The TUI treats album browsing as two distinct screens rather than one layout
whose geometry changes when cover art arrives:

- **Albums** is a stable, keyboard-first list. It shows title, artist, year, and
  track count; the cover indicator is metadata only and does not trigger image
  loading.
- **Album detail** is a full-width track list. Song rows are truncated at the
  terminal edge rather than wrapped or competing with cover art. Album cover
  art is not rendered in either album screen; it remains a Now Playing feature.
- Cover state is explicit (`none`, `loading`, `ready`, `unavailable`) for Now
  Playing only.

This keeps navigation predictable, avoids asynchronous art changing album
geometry, and leaves album browsing cheap to render.

## Testing

- Pure modules get co-located `test` blocks, aggregated through `src/tests.zig`.
- Future integration tests (a real window + input) go under a top-level
  `test/` dir as separate executables that import `forte-player` as a module.
