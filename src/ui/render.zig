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

/// A bounded strip gradient for glossy Y2K-style panels. The fixed band count
/// keeps the draw cost predictable and avoids allocating a bitmap per frame.
pub fn verticalGradient(r: ui.Rect, top: al.Color, bottom: al.Color) void {
    // Keep gradients smooth even in the compact default window; a fixed 32
    // strips produced obvious horizontal banding that read as scanlines rather
    // than glass or polished metal.
    if (r.w <= 0 or r.h <= 0) return;
    const bands: usize = @intFromFloat(@max(1.0, @min(512.0, r.h)));
    for (0..bands) |index| {
        const t = @as(f32, @floatFromInt(index)) / @as(f32, @floatFromInt(@max(1, bands - 1)));
        const color = al.Color.fromRgbaFloat(
            top.r + (bottom.r - top.r) * t,
            top.g + (bottom.g - top.g) * t,
            top.b + (bottom.b - top.b) * t,
            1,
        );
        const y = r.y + r.h * t;
        const next_y = r.y + r.h * @as(f32, @floatFromInt(index + 1)) / @as(f32, @floatFromInt(bands));
        fillRect(.{ .x = r.x, .y = y, .w = r.w, .h = @max(1, next_y - y) }, color);
    }
}

pub fn roundedRect(r: ui.Rect, radius: f32, color: al.Color) void {
    al.primitives.drawFilledRoundedRectangle(r.x, r.y, r.right(), r.bottom(), radius, radius, color);
}

/// A thin multi-tone perimeter that makes dark glass panels read as molded
/// chrome instead of flat neon cards.
pub fn chromePanel(r: ui.Rect, radius: f32, interior: al.Color) void {
    if (r.w < 12 or r.h < 12) {
        fillRect(r, interior);
        return;
    }
    const shadow = r.translate(0, 4);
    roundedRect(shadow, radius, al.Color.fromRgb(2, 7, 14));
    roundedRect(r, radius, al.Color.fromRgb(21, 36, 47));
    roundedRect(r.inset(1), @max(1, radius - 1), al.Color.fromRgb(224, 240, 245));
    roundedRect(r.inset(3), @max(1, radius - 3), al.Color.fromRgb(91, 119, 135));
    roundedRect(r.inset(5), @max(1, radius - 5), interior);
    chromeFrame(r, radius);
}

pub fn chromeFrame(r: ui.Rect, radius: f32) void {
    if (r.w < 8 or r.h < 8) return;
    const inset = @min(@min(radius, 12), @min(r.w, r.h) / 2 - 2);
    line(r.x + inset, r.y + 1, r.right() - inset, r.y + 1, al.Color.fromRgb(225, 244, 250), 1.4);
    line(r.x + inset + 2, r.y + 3, r.right() - inset - 2, r.y + 3, al.Color.fromRgb(121, 165, 185), 1);
    line(r.x + 2, r.y + inset, r.x + 2, r.bottom() - inset, al.Color.fromRgb(160, 199, 214), 1);
    line(r.right() - 2, r.y + inset, r.right() - 2, r.bottom() - inset, al.Color.fromRgb(30, 53, 72), 1.4);
    line(r.x + inset, r.bottom() - 2, r.right() - inset, r.bottom() - 2, al.Color.fromRgb(25, 44, 62), 1.4);
    line(r.x + inset + 4, r.bottom() - 4, r.right() - inset - 4, r.bottom() - 4, al.Color.fromRgb(95, 129, 146), 1);
}

/// Raised brushed-aluminum fascia used by the persistent transport deck.
pub fn metallicFascia(r: ui.Rect, radius: f32) void {
    if (r.w < 12 or r.h < 12) {
        fillRect(r, al.Color.fromRgb(86, 123, 141));
        return;
    }
    roundedRect(r.translate(0, 2), radius, al.Color.fromRgb(9, 19, 27));
    roundedRect(r, radius, al.Color.fromRgb(35, 55, 66));
    roundedRect(r.inset(1), @max(1, radius - 1), al.Color.fromRgb(231, 244, 248));
    roundedRect(r.inset(3), @max(1, radius - 3), al.Color.fromRgb(77, 103, 117));
    const face = r.inset(5);
    verticalGradient(face, al.Color.fromRgb(190, 215, 224), al.Color.fromRgb(72, 103, 121));
    brushedTexture(face.inset(2));
    chromeFrame(r, radius);
}

/// Dark, recessed LCD glass with a cyan specular edge and inner bevel.
pub fn lcdWindow(r: ui.Rect, radius: f32) void {
    roundedRect(r.translate(0, 2), radius, al.Color.fromRgb(5, 11, 18));
    roundedRect(r, radius, al.Color.fromRgb(27, 46, 58));
    roundedRect(r.inset(2), @max(1, radius - 2), al.Color.fromRgb(122, 157, 171));
    const glass = r.inset(4);
    verticalGradient(glass, al.Color.fromRgb(13, 40, 59), al.Color.fromRgb(4, 17, 29));
    line(glass.x + radius, glass.y + 1, glass.right() - radius, glass.y + 1, al.Color.fromRgb(133, 233, 247), 1);
    line(glass.x + radius, glass.bottom() - 1, glass.right() - radius, glass.bottom() - 1, al.Color.fromRgb(2, 9, 17), 1);
}

/// Fine horizontal grain, used sparingly on chrome surfaces to break up
/// otherwise perfectly smooth gradients.
pub fn brushedTexture(r: ui.Rect) void {
    if (r.w < 12 or r.h < 7) return;
    var y = r.y + 4;
    var band: usize = 0;
    while (y < r.bottom() - 3) : ({
        y += 6;
        band += 1;
    }) {
        const tint = if (band % 2 == 0) al.Color.fromRgba(220, 239, 245, 10) else al.Color.fromRgba(20, 47, 65, 9);
        line(r.x + 5, y, r.right() - 5, y, tint, 1);
    }
}

/// Raised aqua-steel button with a dark lower bevel and a broad specular cap.
pub fn chromeButton(r: ui.Rect, pressed: bool) void {
    if (r.w < 8 or r.h < 8) {
        fillRect(r, al.Color.fromRgb(63, 100, 120));
        return;
    }
    const radius = @min(10.0, r.h / 2);
    roundedRect(.{ .x = r.x, .y = r.y + 2, .w = r.w, .h = r.h }, radius, al.Color.fromRgb(8, 19, 32));
    roundedRect(r, radius, al.Color.fromRgb(43, 67, 82));
    roundedRect(r.inset(1), @max(1, radius - 1), al.Color.fromRgb(190, 218, 229));
    const face = r.inset(3);
    roundedRect(face, @max(1, radius - 3), if (pressed) al.Color.fromRgb(44, 105, 133) else al.Color.fromRgb(78, 129, 153));
    if (!pressed) {
        roundedRect(.{ .x = face.x + 2, .y = face.y + 1, .w = @max(1, face.w - 4), .h = @max(4, face.h * 0.42) }, @max(2, radius - 4), al.Color.fromRgb(151, 192, 208));
        line(face.x + 5, face.y + 2, face.right() - 5, face.y + 2, al.Color.fromRgb(241, 250, 253), 1);
    } else {
        line(face.x + 5, face.bottom() - 2, face.right() - 5, face.bottom() - 2, al.Color.fromRgb(135, 198, 218), 1);
    }
    brushedTexture(.{ .x = face.x + 1, .y = face.y + face.h * 0.48, .w = face.w - 2, .h = face.h * 0.45 });
    line(r.x + radius, r.bottom() - 1, r.right() - radius, r.bottom() - 1, al.Color.fromRgb(23, 42, 57), 1);
}

/// Recessed metallic rail with a glossy aqua fill and specular edge.
pub fn metallicBar(r: ui.Rect, fraction: f32) void {
    if (r.w < 1) return;
    const full = @max(0.0, @min(fraction, 1.0));
    const rail = ui.Rect{ .x = r.x, .y = r.y - 2, .w = r.w, .h = @max(6, r.h + 4) };
    roundedRect(rail, rail.h / 2, al.Color.fromRgb(18, 34, 48));
    roundedRect(rail.inset(1), @max(1, rail.h / 2 - 1), al.Color.fromRgb(119, 157, 174));
    const inner = rail.inset(2);
    roundedRect(inner, inner.h / 2, al.Color.fromRgb(20, 42, 59));
    if (full > 0) {
        const fill = ui.Rect{ .x = inner.x, .y = inner.y, .w = @max(inner.h, inner.w * full), .h = inner.h };
        roundedRect(fill, inner.h / 2, al.Color.fromRgb(38, 179, 208));
        line(fill.x + 4, fill.y + 1, fill.right() - 4, fill.y + 1, al.Color.fromRgb(177, 248, 255), 1);
    }
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

/// Nest a clip without escaping the parent viewport. Restore with popClip.
pub fn pushClip(r: ui.Rect) ui.Rect {
    var x: i32 = 0;
    var y: i32 = 0;
    var w: i32 = 0;
    var h: i32 = 0;
    al.graphics.getClipRectangle(&x, &y, &w, &h);
    const previous = ui.Rect{ .x = @floatFromInt(x), .y = @floatFromInt(y), .w = @floatFromInt(w), .h = @floatFromInt(h) };
    const left = @max(r.x, previous.x);
    const top = @max(r.y, previous.y);
    setClip(.{ .x = left, .y = top, .w = @max(0, @min(r.right(), previous.right()) - left), .h = @max(0, @min(r.bottom(), previous.bottom()) - top) });
    return previous;
}
pub fn popClip(previous: ui.Rect) void {
    setClip(previous);
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
    return al.Color.fromRgb(211, 224, 239);
}
pub fn panel() al.Color {
    return al.Color.fromRgb(242, 247, 252);
}

pub fn sidebar() al.Color {
    return al.Color.fromRgb(21, 75, 132);
}

pub fn elevated() al.Color {
    return al.Color.fromRgb(226, 237, 248);
}

pub fn selectedPanel() al.Color {
    return al.Color.fromRgb(190, 220, 247);
}

pub fn hairline() al.Color {
    return al.Color.fromRgb(123, 153, 181);
}
pub fn textColor() al.Color {
    return al.Color.fromRgb(18, 38, 61);
}
pub fn muted() al.Color {
    return al.Color.fromRgb(67, 91, 117);
}
pub fn accent() al.Color {
    return al.Color.fromRgb(0, 104, 190);
}
pub fn gloss() al.Color {
    return al.Color.fromRgb(87, 177, 235);
}
pub fn buttonInk() al.Color {
    return al.Color.fromRgb(18, 38, 61);
}
pub fn pink() al.Color {
    return al.Color.fromRgb(255, 111, 213);
}
pub fn panelTop() al.Color {
    return al.Color.fromRgb(255, 255, 255);
}
pub fn panelBottom() al.Color {
    return al.Color.fromRgb(222, 234, 246);
}
pub fn sidebarTop() al.Color {
    return al.Color.fromRgb(57, 139, 211);
}
pub fn sidebarBottom() al.Color {
    return al.Color.fromRgb(12, 47, 91);
}
pub fn playerTop() al.Color {
    return al.Color.fromRgb(219, 231, 241);
}
pub fn playerBottom() al.Color {
    return al.Color.fromRgb(105, 132, 156);
}
