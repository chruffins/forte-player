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

The GUI deliberately does not mirror the old retained drawable tree. Frontends
share semantic `ui_state` snapshots and reducer operations, not presentation.
The TUI consumes the terminal-cell command stream from `ui_view`; the GUI draws
native pixel-space geometry from `gui_layout`. Its input uses those same bounds,
including the same fractional scroll offset, instead of translating terminal rows.

Allegro events map to semantic actions at the edge, then `ui_state` and the
application adapter execute player operations. No per-widget allocation or
callback ownership is hidden in the layout. Pure `gui_framework` models provide
Unicode editing, image placement, sliders, scrolling, clipped input targets,
pointer capture, and focus traversal. `gui_render` nests clips and only draws
visible list rows. Dialog geometry keeps fields and footer buttons bounded even
in compact windows. See `GUI_PLAN.md` for the native GUI contracts and remaining
polish.

## Structure (under `src/ui/`)

```
src/ui/
  ui.zig          # module root, re-exports the public surface
  DESIGN.md       # this file
  gui_input.zig   # pure pixel-space hit testing
  gui_layout.zig  # responsive gallery/inspector/table/form/dialog geometry
  gui_framework.zig # pure UV, text, slider, scroll, and event models
  gui_render.zig  # native Allegro renderer
  gui_fonts.zig   # font resources and packaged asset fallback
  gui_artwork.zig # bounded thumbnail cache and memory-only decode worker
  gui_visualizer.zig # display-owned single-rectangle GPU renderer
  gui_jobs.zig    # asynchronous scan/auth workers
  ui_state.zig    # shared semantic state and reducer
  ui_view.zig     # terminal-cell typed draw commands
  gui_regression_test.zig # native layout/input regression coverage
  render.zig      # small Allegro primitive helpers
```

`gui_layout.zig`, `gui_framework.zig`, `gui_input.zig`, `ui_state.zig`, and
`ui_view.zig` stay headless-testable. Only `gui_render.zig`, `gui_fonts.zig`,
`gui_artwork.zig`, `gui_visualizer.zig`, and `render.zig` import Allegro directly.

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

This keeps terminal navigation predictable and album browsing cheap to render.

The GUI instead lands in an artwork grid, with stable square image slots and
labels beneath. Art publication never changes card geometry. Album detail has
an artwork/metadata hero and a separate track table. A memory-only worker
produces bounded thumbnails; the frontend uploads them on ticks and the renderer
only looks them up. Short viewports use compact artwork rows rather than clipping
a huge cover across the entire viewport. The collapsible Now Playing inspector
shares playback/queue/lyrics snapshots, not the TUI's presentation.

## Testing

- Pure modules get co-located `test` blocks, aggregated through `src/tests.zig`.
- Future integration tests (a real window + input) go under a top-level
  `test/` dir as separate executables that import `forte-player` as a module.
