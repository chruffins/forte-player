# allegro5-zig

A Zig wrapper for the Allegro 5 game-programming library.

This is a near-complete binding of the Allegro 5 API (core plus
all major addons), designed to take advantage of Zig's features rather than a
1:1 copy of the C API. Should feel way better to use than raw `translate-c`.

## Status

Covers nearly all of the 826 translated `al_*` functions. Every single wrapped
function is compile-checked by a `std.testing.refAllDecls` guard, so the wrapper
gets tested against the C bindings at build time.

The few unwrapped functions are all variadic `printf`
helpers (`al_draw_textf`, `al_fprintf`, `al_ustr_newf`, ...) which are made redundant by Zig's formatting,
and the exotic software-raster callback
primitives (`al_draw_soft_line`, `al_draw_soft_triangle`).

## Requirements

- **Zig 0.16.0** (pinned via `.zigversion` for `zigt`/`zvm`/`zigup` users). Verified to build
  on both stable 0.16.0 and 0.17-dev snapshots.
- Allegro 5 development libraries (apt: `liballegro5-dev` + addons)

## Layout

The library is a single Zig module (`allegro`) with its root at `src/allegro.zig`.
Sub-modules live under `src/allegro/`:

| Module | Covers |
|--------|--------|
| `system.zig`   | init/uninstall, app name/org, standard paths, cwd, version |
| `display.zig`  | `Display`, display flags/options, display modes, clipboard |
| `monitor.zig`  | video adapters, monitor info/dpi |
| `graphics.zig` | `Bitmap`, drawing, clipping, blending, render states, image I/O |
| `primitives.zig` | primitives addon: shapes, polylines/polygons, vertex/index buffers |
| `shader.zig`   | programmable-pipeline shaders + uniforms |
| `color.zig`    | `Color` + allegro_color addon colour spaces + named constants |
| `vec.zig` / `transform.zig` | `Vec2/3/4`, `Transform` |
| `events.zig`   | `Event`, `EventType`, `EventQueue`, `KeyCode`, typed accessors, user events |
| `keyboard.zig` / `mouse.zig` / `joystick.zig` / `touch.zig` | input devices + state |
| `timer.zig` / `time.zig` | `Timer`, `getTime`, `Timeout` |
| `threads.zig`  | threads, mutexes, condition variables |
| `file.zig` / `filesystem.zig` / `memory.zig` | file handles, fs entries, allocation |
| `utf8.zig`     | mutable Unicode strings (`al_ustr`), codepoint helpers, refs |
| `path.zig` / `config.zig` | portable paths, INI config |
| `font.zig` / `ttf.zig` / `image.zig` | fonts/TTF, bitmap loading/saving, plugins |
| `audio.zig` / `acodec.zig` | voices, mixers, samples, sample instances, streams |
| `video.zig`    | video playback |
| `dialog.zig`   | native dialogs, message boxes, text logs |
| `menu.zig`     | native menus |
| `fixed.zig` / `misc.zig` | fixed-point math, system info, state save/restore, versions |

The root re-exports the common types (`Color`, `Display`, `Timer`, `Event`,
`KeyCode`, ...) flat, plus flat convenience functions, so you can write:

```zig
const al = @import("allegro");
```

## Example

```zig
const std = @import("std");
const al = @import("allegro");

pub fn main() !void {
    try al.init();
    try al.installKeyboard();
    try al.installMouse();
    try al.initPrimitivesAddon();
    try al.initFontAddon();

    al.Display.setNewWindowTitle("hello");
    var display = try al.Display.create(800, 600);
    defer display.destroy();

    var queue  = try al.EventQueue.create();
    defer queue.destroy();
    queue.registerDisplay(&display);
    queue.registerKeyboard();

    var timer = try al.Timer.create(1.0 / 60.0);
    defer timer.destroy();
    queue.registerTimer(&timer);
    timer.start();

    var running = true;
    var redraw = false;
    var event: al.Event = undefined;
    while (running) {
        queue.waitForEvent(&event);
        switch (al.eventType(event)) {
            .display_close => running = false,
            .timer => if (queue.isEmpty()) redraw = true,
            .key_down => if (al.eventKeyboard(event)) |kb| {
                if (kb.keycode == .Escape) running = false;
            },
            else => {},
        }
        if (redraw) {
            al.graphics.clearToColor(al.Color.fromRgb(20, 20, 40));
            al.primitives.drawFilledCircle(400, 300, 50, al.Color.fromRgb(255, 60, 60));
            al.Display.flip();
            redraw = false;
        }
    }
}
```

> Note: on Linux (and for the separated addons) link the system libraries exactly
> as `build.zig` does — `allegro`, `allegro_primitives`, `allegro_image`,
> `allegro_font`, `allegro_ttf`, `allegro_audio`, `allegro_acodec`,
> `allegro_dialog`, `allegro_video`.

## Building / testing

```sh
zig build          # compiles the full wrapper surface (refAllDecls guard) + test exe
zig build test     # same, then runs the headless smoke test binary
```

## Design conventions

- **Ownership**: types wrapping a heap-allocated Allegro object (`Display`,
  `Timer`, `Bitmap`, `Font`, `Sample`, ...) expose a `destroy()`. The raw C
  pointer is accessible if you need it (e.g. `bmp.bmp`).
- **Errors**: failable functions return `!T` with a small named error set, or `?T`
  where `null` is the natural C failure idiom (e.g. `Bitmap.load`).
- **Strings**: input C-strings use `[:0]const u8` and are passed via `.ptr`;
  output strings are `[:0]const u8` from `std.mem.span`.
- **Enums**: integral enums (`KeyCode`, `RenderState`, colour primaries) are
  real Zig enums. Bit-flag bundles live in `struct`s of `pub const` values.
