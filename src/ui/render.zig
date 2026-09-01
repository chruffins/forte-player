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

pub fn roundedRect(r: ui.Rect, radius: f32, color: al.Color) void {
    al.primitives.drawFilledRoundedRectangle(r.x, r.y, r.right(), r.bottom(), radius, radius, color);
}

pub fn line(x1: f32, y1: f32, x2: f32, y2: f32, color: al.Color, thickness: f32) void {
    al.primitives.drawLine(x1, y1, x2, y2, color, thickness);
}

pub fn bitmapScaled(bitmap: *const al.graphics.Bitmap, r: ui.Rect) void {
    const mutable = @constCast(bitmap);
    mutable.drawScaled(0, 0, @floatFromInt(mutable.getWidth()), @floatFromInt(mutable.getHeight()), r.x, r.y, r.w, r.h, 0);
}

pub fn setClip(r: ui.Rect) void {
    al.graphics.setClipRectangle(@intFromFloat(r.x), @intFromFloat(r.y), @intFromFloat(r.w), @intFromFloat(r.h));
}

pub fn resetClip() void {
    al.graphics.resetClipRectangle();
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

pub fn sidebar() al.Color {
    return al.Color.fromRgb(23, 26, 36);
}

pub fn elevated() al.Color {
    return al.Color.fromRgb(38, 43, 56);
}

pub fn selectedPanel() al.Color {
    return al.Color.fromRgb(44, 67, 100);
}

pub fn hairline() al.Color {
    return al.Color.fromRgb(57, 64, 80);
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
