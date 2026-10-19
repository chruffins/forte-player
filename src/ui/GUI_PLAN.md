# Native GUI architecture

## Why the layout changed

The GUI previously interpreted the TUI's terminal-cell command stream. Rendering
subtracted header rows while input and scrolling used different offsets. Artwork,
transport labels, forms, and modal controls competed for the same grid. This
architecture was replaced, not patched with more coordinate adjustments.

The frontends now share **semantic state and application operations**, not layout.
`ui_view.zig` and `tui_render.zig` remain the terminal presentation. The GUI uses
pixel-space rectangles from `gui_layout.zig` and draws them in `gui_render.zig`.

## Ownership

- `ui_state.zig`: playback/library snapshots and reducer actions, shared by both
  frontends. Borrowed strings must point to frontend-owned storage.
- `gui_layout.zig`: screen-aware shell, album grid / compact artwork rows,
  detail hero, tables, inspector, transport, dialogs, and scrollbars. Pure and
  allocation-free; `Frame.forScreen` is the frontend geometry contract.
- `gui_framework.zig`: Unicode text storage, image fitting, sliders, scrolling,
  clipped widget targets, pointer capture, and focus traversal. No Allegro.
- `gui_input.zig`: semantic hit tests using the same layout as rendering.
- `gui_render.zig`: Windows XP Media Player-inspired blue glass/chrome skin over
  the album gallery, track tables, Queue/Lyrics inspector, Listening, settings,
  and modal forms. Fixed-size text fitting cache;
  nested clipping; only visible rows / cards draw.
- `gui_artwork.zig`: 48-entry LRU, thumbnails at most 512×512, compressed sources
  limited to 16 MiB before database allocation. One memory-bitmap decode worker
  at a time; GPU conversion/publication happens on the frontend tick, never
  during drawing. Failed/missing artwork is cached too. Rescans invalidate it.
  Join the worker and destroy thumbnails before destroying the display.
- `gui_visualizer.zig`: display-owned OpenGL shader, initialized once, released
  before display destruction. Twelve vec4 uniforms carry the 48 FFT bands;
  the shader generates geometry/glow/antialiasing in one rectangle draw.
- `gui_fonts.zig`: startup-owned body, heading, small-form, compact-navigation,
  and monospace fonts with packaged/development asset fallback.
- `main.zig`: resource/snapshot ownership, text focus and drag state, input-to-app
  operations. `gui_jobs.zig` retains the scan/auth worker boundary.

## Layout contract

- Full-width persistent player below the content and sidebar, with no overlap.
- Compact navigation at widths below 800px or heights below 500px.
- Separate header, search/action toolbar, and clipped body viewport.
- Fixed 48px list rows; album cards use a responsive column count and pixel
  pitch. Below 180px of body height, square thumbnails sit beside album labels.
  `offsetFromAnchor` / `anchorFromOffset` adapt reducer item indices to GUI grid
  rows. Keyboard Up/Down moves by columns; reveal/clamping uses the same cards.
- GUI starts in Albums; the TUI's initial screen and layout are unchanged.
  Single-click album opening; separate Play / More hit targets on covers.
  Detail heroes offer Play album, followed by column-based track rows.
- Inspector appears at ≥1080×560, and can be toggled with the player's Panel
  button. The `[gallery] inspector` setting remembers the choice. Queue and
  Lyrics tabs reuse shared snapshots; queue clicks play the visible queue entry.
- Drawing, row selection, queue dragging, and scrollbar movement use the same
  rectangles and offset. Blank space and inter-button gaps are not targets.
- Now Playing artwork is fitted into a stable square, with text/lyrics alongside.
  A separate visualizer panel never overlaps the artwork, lyrics, or transport.
  Small windows hide that panel and skip audio analysis. Mode arrows and `Z`
  select remembered Mirror Spectrum / Polar Spectrum modes.
- FFT only runs at ~20 Hz on new capture blocks. A time-based envelope animates
  at display cadence and decays on pause/stop; track changes reset the meter.
  Unsupported shaders/missing assets produce a static status, not CPU geometry.
- The GUI requests desktop OpenGL's programmable pipeline, with a normal-display
  retry if context creation fails. GPU/font/art resources are released while
  their display still exists. Shader binding and clips are restored after drawing.
- Settings scroll as a form; credential focus reveals the active field.
- Dialogs use window-bounded cards with separate body and footer. Active metadata
  fields and track actions scroll into view at small sizes; buttons stay visible.
- Modal input blocks hover, list wheel scrolling, sidebar, and transport behind it.
- Transport clicks activate on matching release, not press. Seek/volume/scrollbar
  dragging retains capture; leaving window focus cancels transient captures.
- Double-click activation is time-bounded and scoped to the current screen.
- Keyboard shortcuts opening text fields do not insert their triggering character.
- Minimum interactive window: 360×300. New installations default to 1120×720;
  existing persisted dimensions are retained (subject to window constraints).

## Visual direction

Windows XP Media Player-inspired skin: deep blue gradient navigation, pale blue
framed content wells, beveled silver controls, and a dark LCD-style now-playing
window with bright aqua progress. Keep the album artwork gallery and current
responsive layout, but use raised buttons, specular edges, and strong blue
selection states to evoke classic WMP without copying its exact chrome. Missing
covers use deterministic blue/steel-toned placeholders and monograms. Text never
escapes its own bounds or the parent viewport, including font fallback.

## Validation

`gui_regression_test.zig` covers responsive breakpoints, focused dialog/form
visibility, clipped row hit testing, last-row reachability, focus wrap/disabled
controls, pointer capture/cancellation, and collapsed widgets. Additional tests
live alongside layout/input/rendering modules. `gui_gallery_test.zig` checks
card gutters, partial final grid rows, selection reveal, short-window artwork,
inspector collapse and blank-space hit exclusion. Artwork tests exercise real
memory-bitmap decoding/downsampling, state restoration, worker publication,
source-size rejection and ownership cleanup without needing a display.

Run `zig build test`, `zig build`, and `git diff --check`. `zig build test-gpu`
opts into a real-display OpenGL test using synthetic bands: shader compilation,
first/last uniform groups, both modes, an offset viewport, and shader/clip
restoration. Pixel readback is confined to that test, never production drawing.
`zig test vendor/allegro/src/allegro/shader_uniform.zig` verifies uniform counts
independently. The full standalone wrapper test compilation currently hits
pre-existing file/color binding errors; it is not covered by the project test
pass. The new upload logic is additionally exercised against real OpenGL by
`test-gpu`.
Smoke-test the actual
Allegro window at 360×300 and 1120×720, including list selection, search, dialogs,
credential editing, scrollbar dragging, and player controls. Use isolated XDG
config/data directories when exercising persistence.

## Follow-up

These two modes visualize FFT bands; they are not a literal port of the C++
raw-sample Polar Waveform or stereo Dual Echo Wave. Stereo capture/feedback
render targets and waveform modes are future work. Broader keyboard focus
traversal for application controls, clipboard/selection editing, and
accessibility also remain future work. Track-table sorting, artist artwork, and
rich album descriptions are not part of this visual pass. Album sort cycling and
the existing semantic operations remain.
