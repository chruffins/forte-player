# UI layer design (WIP)

This is a placeholder for the redesign of the music player's UI. Nothing here is
specced yet; the notes below capture the direction so the layout and test
strategy can accommodate it.

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

## Proposed structure (under `src/ui/`)

```
src/ui/
  ui.zig          # module root, re-exports the public surface
  DESIGN.md       # this file
  layout/
    rect.zig      # Rect/inset/contains (started)
    tree.zig      # layout tree / constraints
  state/          # view models / app state (pure)
  input/          # event classification (pure)
  render/         # Allegro draw commands (the only impure part)
```

Everything under `layout/`, `state/`, `input/` should stay dependency-free
(single importable module, co-located `test` blocks). `render/` is the only
place that imports `allegro`.

## Testing

- Pure modules get co-located `test` blocks, aggregated through `src/tests.zig`.
- Future integration tests (a real window + input) go under a top-level
  `test/` dir as separate executables that import `forte-player` as a module.
