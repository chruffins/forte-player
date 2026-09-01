# GUI framework plan

The GUI should look intentional without recreating the C++ retained drawable tree.
The existing `State -> ui_view.CmdList -> frontend renderer` pipeline remains the
contract. The framework is a small retained *application model* with an
immediate, typed draw pass.

## Visual direction

- **Typography:** IBM Plex Sans Light for navigation/body copy, Kanit for large
  headings and transport labels, Courier Prime for metadata and time readouts.
  The copied C++ icon set and logo are also packaged; icons fall back to glyphs
  when unavailable.
- **Layout:** dark graphite background, elevated panels, one blue accent, muted
  secondary text, and consistent 8px spacing units.
- **Now Playing:** large cover panel, title/artist hierarchy, progress scrubber,
  transport controls, and a low-contrast spectrum backdrop.
- **Browse views:** dense but breathable rows, clear selection/focus treatment,
  sortable headers, and no layout changes when artwork loads.
- **Motion:** only short state transitions and meter smoothing; never animate
  filesystem or network work on the frontend thread.

## Ownership boundaries

```text
App / worker results
        |
        v
GuiModel (owned data + transient focus)
        |
        v
pure layout -> typed DrawCmd stream -> Allegro renderer
        ^                         |
        |                         v
pure hit-test <- Allegro events
```

- `ui_state.zig` owns semantic state and reducer actions.
- `gui_layout.zig` owns responsive rectangles, shell regions, and hit regions.
  It does not import Allegro.
- `gui_framework.zig` provides pure UV geometry, text inputs, sliders,
  scroll models, alignment, and deterministic event routing. It replaces the
  useful behavior of the C++ drawable framework without retaining widget
  objects or callbacks.
- `ui_view.zig` emits typed commands, not widget objects or callbacks.
- `gui_render.zig` owns font/bitmap resources and converts commands to pixels.
- `gui_input.zig` maps coordinates and key events to semantic actions.
- `gui_jobs.zig` owns worker lifetimes; workers never mutate UI state directly.

## Font/resource layer

1. Load fonts once at GUI startup and keep them in a `FontSet`.
2. Resolve assets from the installed `share/forte-player/fonts` directory, then
   fall back to `assets/fonts` for development runs.
3. Keep font metrics in a pure `Metrics` value so layout tests do not need a
   display. The renderer receives the selected font handles separately.
4. Use explicit fallback order: Kanit/IBM Plex Sans for proportional text,
   Courier Prime for fixed-width metadata, builtin Allegro font only as a final
   fallback.
5. Install the font files through the build system, including their OFL texts.

## Implementation phases

1. **Foundation:** complete — `FontSet`, asset-path resolution, palette values,
   and pure responsive geometry live in `gui_fonts.zig` and `gui_layout.zig`.
2. **Shell:** complete — sidebar navigation, window-safe content bounds, active
   states, hover states, and narrow-window breakpoints are rendered by
   `gui_render.zig`.
3. **Now Playing:** complete — decoded cover bitmaps with a color-grid
   fallback, hierarchy, scrubber, persistent transport panel, and spectrum
   composition are available through the shared view and GUI shell.
4. **Browse:** complete — shared list/detail/queue screens use clipped command
   rows and stable geometry.
5. **Interaction:** mostly complete — keyboard character input, Unicode
   editing, field focus, mouse selection, sidebar clicks, wheel scrolling,
   scrollbar page/drag behavior, seeking, transport controls, and hover
   feedback are implemented; focus rings/context menus remain polish items.
6. **Polish:** in progress — loading/empty/error states exist in the shared
   view; transitions and command batching should be added only after visual
   profiling.

## Performance rules

- No allocation during layout, command emission, or rasterization.
- Cache font metrics and artwork textures; bound every cache. The current
  artwork resource is replaced and destroyed whenever the current song changes.
- Rebuild list snapshots only when their database/queue generation changes.
- Keep command buffers fixed-capacity or explicitly bounded.
- Measure text once per changed label, not once per frame.
- Test layout and hit testing with synthetic sizes before testing Allegro.
- Clip the command stream to the content viewport so long labels cannot bleed
  into the sidebar or transport surface.

## Acceptance checks

- Every screen remains renderable with no display and no assets.
- Resizing does not change semantic selection or queue state.
- A missing font/artwork asset produces a visible fallback, not a startup error.
- Worker completion only changes model state at a main-thread poll point.
- `zig build test`, `zig build`, and `git diff --check` stay green.
