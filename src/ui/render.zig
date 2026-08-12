//! The impure half of the UI layer: turns pure layout (Rect) + state into
//! Allegro draw calls. Everything here imports `allegro`; nothing above this
//! (layout/state/input) may. See `ui/DESIGN.md`.

const al = @import("allegro");
const ui = @import("ui.zig");

/// Start a frame: target the display's backbuffer and clear it.
pub fn beginFrame(display: *al.Display) void {
    al.graphics.setTargetBackbuffer(display.display);
    al.graphics.clearToColor(background());
}

/// Present the backbuffer.
pub fn endFrame() void {
    al.Display.flip();
}

pub fn fillRect(r: ui.Rect, color: al.Color) void {
    al.primitives.drawFilledRectangle(r.x, r.y, r.right(), r.bottom(), color);
}

pub fn drawText(font: al.font.Font, x: f32, y: f32, str: [:0]const u8, color: al.Color) void {
    font.drawTextAt(color, x, y, 0, str);
}

/// Draw a horizontal progress bar (background + filled portion).
pub fn bar(r: ui.Rect, fraction: f32, bg: al.Color, fg: al.Color) void {
    const full = @max(0.0, @min(fraction, 1.0));
    if (full > 0) {
        fillRect(.{ .x = r.x, .y = r.y, .w = r.w * full, .h = r.h }, fg);
    }
    if (full < 1.0) {
        fillRect(.{ .x = r.x + r.w * full, .y = r.y, .w = r.w * (1.0 - full), .h = r.h }, bg);
    }
}

/// A few palette defaults (reused by the demo; can move to a theme later).
/// Functions (not consts): al_map_rgb is an extern call, not comptime-callable.
pub fn background() al.Color {
    return al.Color.fromRgb(18, 20, 28);
}
pub fn panel() al.Color {
    return al.Color.fromRgb(30, 34, 44);
}
pub fn textColor() al.Color {
    return al.Color.fromRgb(235, 238, 245);
}
pub fn muted() al.Color {
    return al.Color.fromRgb(140, 148, 164);
}
pub fn accent() al.Color {
    return al.Color.fromRgb(95, 158, 255);
}
