const std = @import("std");
const c = @import("c");
const Color = @import("color.zig").Color;
const Vec2 = @import("vec.zig").Vec2;
const Str = @import("utf8.zig").String;

pub const Error = error{ InitFailed };

pub fn init() !void {
    if (!c.al_init_font_addon()) return Error.InitFailed;
}

pub fn shutdown() void {
    c.al_shutdown_font_addon();
}

pub fn initialized() bool {
    return c.al_is_font_addon_initialized();
}

pub fn version() u32 {
    return c.al_get_allegro_font_version();
}

/// Font alignment flags.
pub const Align = struct {
    pub const LEFT = c.ALLEGRO_ALIGN_LEFT;
    pub const CENTRE = c.ALLEGRO_ALIGN_CENTRE;
    pub const CENTER = c.ALLEGRO_ALIGN_CENTER;
    pub const RIGHT = c.ALLEGRO_ALIGN_RIGHT;
    pub const INTEGER = c.ALLEGRO_ALIGN_INTEGER;
};

pub const FontError = error{ LoadFailed };

pub const Font = struct {
    data: *c.ALLEGRO_FONT,

    /// Load a font (bitmap or TTF, depending on installed addons).
    pub fn load(filename: [:0]const u8, size: i32, flags: i32) !Font {
        const f = c.al_load_font(filename.ptr, size, flags) orelse return FontError.LoadFailed;
        return .{ .data = f };
    }

    pub fn loadBuiltin() Font {
        return .{ .data = c.al_create_builtin_font().? };
    }

    /// Load a pre-rendered bitmap-font (grid of glyphs), no TTF needed.
    pub fn loadBitmapFont(filename: [:0]const u8) !Font {
        const f = c.al_load_bitmap_font(filename.ptr) orelse return FontError.LoadFailed;
        return .{ .data = f };
    }

    pub fn loadBitmapFontFlags(filename: [:0]const u8, flags: i32) !Font {
        const f = c.al_load_bitmap_font_flags(filename.ptr, flags) orelse return FontError.LoadFailed;
        return .{ .data = f };
    }

    pub fn destroy(self: *Font) void {
        c.al_destroy_font(self.data);
    }

    pub fn getLineHeight(self: *const Font) i32 {
        return c.al_get_font_line_height(self.data);
    }

    pub fn getAscent(self: *const Font) i32 {
        return c.al_get_font_ascent(self.data);
    }

    pub fn getDescent(self: *const Font) i32 {
        return c.al_get_font_descent(self.data);
    }

    pub fn getTextWidth(self: *const Font, text: [:0]const u8) i32 {
        return c.al_get_text_width(self.data, text.ptr);
    }

    pub fn getUstrWidth(self: *const Font, text: *const Str) i32 {
        return c.al_get_ustr_width(self.data, text.us);
    }

    pub fn getTextDimensions(self: *const Font, text: [:0]const u8) struct { x: i32, y: i32, w: i32, h: i32 } {
        var x: i32 = 0;
        var y: i32 = 0;
        var w: i32 = 0;
        var h: i32 = 0;
        c.al_get_text_dimensions(self.data, text.ptr, &x, &y, &w, &h);
        return .{ .x = x, .y = y, .w = w, .h = h };
    }

    pub fn getUstrDimensions(self: *const Font, text: *const Str) struct { x: i32, y: i32, w: i32, h: i32 } {
        var x: i32 = 0;
        var y: i32 = 0;
        var w: i32 = 0;
        var h: i32 = 0;
        c.al_get_ustr_dimensions(self.data, text.us, &x, &y, &w, &h);
        return .{ .x = x, .y = y, .w = w, .h = h };
    }

    /// The list of glyph ranges covered by this font, as [start, end] pairs.
    pub fn getRanges(self: *Font, allocator: std.mem.Allocator) ![]i32 {
        // Query the required count first.
        const n = c.al_get_font_ranges(self.data, 0, null);
        const ranges = try allocator.alloc(i32, @intCast(@max(n, 0)));
        _ = c.al_get_font_ranges(self.data, @intCast(ranges.len), ranges.ptr);
        return ranges;
    }

    /// Build a font from a sprite-sheet bitmap, cutting `n` ranges from it.
    pub fn grabFromBitmap(bmp: *c.ALLEGRO_BITMAP, ranges: []const i32) ?Font {
        const f = c.al_grab_font_from_bitmap(bmp, @intCast(ranges.len), ranges.ptr);
        return if (f) |ptr| Font{ .data = ptr } else null;
    }

    // -- Drawing --

    pub fn drawText(self: *const Font, color: Color, pos: Vec2, flags: i32, text: [:0]const u8) void {
        c.al_draw_text(self.data, color.toAllegroColor(), pos.x, pos.y, flags, text.ptr);
    }

    pub fn drawTextAt(self: *const Font, color: Color, x: f32, y: f32, flags: i32, text: [:0]const u8) void {
        c.al_draw_text(self.data, color.toAllegroColor(), x, y, flags, text.ptr);
    }

    pub fn drawTextFormat(self: *const Font, color: Color, x: f32, y: f32, flags: i32, comptime fmt: [:0]const u8, args: anytype) void {
        var buf: [2048]u8 = undefined;
        const rendered = std.fmt.bufPrintZ(&buf, fmt, args) catch return;
        c.al_draw_text(self.data, color.toAllegroColor(), x, y, flags, rendered.ptr);
    }

    pub fn drawJustifiedText(self: *const Font, color: Color, x1: f32, x2: f32, y: f32, diff: f32, flags: i32, text: [:0]const u8) void {
        c.al_draw_justified_text(self.data, color.toAllegroColor(), x1, x2, y, diff, flags, text.ptr);
    }

    pub fn drawMultilineText(self: *const Font, color: Color, x: f32, y: f32, maxWidth: f32, lineHeight: f32, flags: i32, text: [:0]const u8) void {
        c.al_draw_multiline_text(self.data, color.toAllegroColor(), x, y, maxWidth, lineHeight, flags, text.ptr);
    }

    pub fn drawTextUstr(self: *const Font, color: Color, x: f32, y: f32, flags: i32, text: *const Str) void {
        c.al_draw_ustr(self.data, color.toAllegroColor(), x, y, flags, text.us);
    }

    pub fn drawJustifiedTextUstr(self: *const Font, color: Color, x1: f32, x2: f32, y: f32, diff: f32, flags: i32, text: *const Str) void {
        c.al_draw_justified_ustr(self.data, color.toAllegroColor(), x1, x2, y, diff, flags, text.us);
    }

    pub fn drawMultilineTextUstr(self: *const Font, color: Color, x: f32, y: f32, maxWidth: f32, lineHeight: f32, flags: i32, text: *const Str) void {
        c.al_draw_multiline_ustr(self.data, color.toAllegroColor(), x, y, maxWidth, lineHeight, flags, text.us);
    }

    pub fn drawGlyph(self: *const Font, color: Color, pos: Vec2, codepoint: i32) void {
        c.al_draw_glyph(self.data, color.toAllegroColor(), pos.x, pos.y, codepoint);
    }

    // -- Glyph metrics --

    pub fn getGlyphWidth(self: *const Font, codepoint: i32) i32 {
        return c.al_get_glyph_width(self.data, codepoint);
    }

    pub fn getGlyphAdvance(self: *const Font, codepoint1: i32, codepoint2: i32) i32 {
        return c.al_get_glyph_advance(self.data, codepoint1, codepoint2);
    }

    pub fn getGlyphDimensions(self: *const Font, codepoint: i32) ?struct { x: i32, y: i32, w: i32, h: i32 } {
        var x: i32 = 0;
        var y: i32 = 0;
        var w: i32 = 0;
        var h: i32 = 0;
        if (!c.al_get_glyph_dimensions(self.data, codepoint, &x, &y, &w, &h)) return null;
        return .{ .x = x, .y = y, .w = w, .h = h };
    }

    // -- Fallback fonts --

    /// Set a fallback font used for glyphs missing from this font.
    pub fn setFallback(self: *Font, fallback: ?*Font) void {
        c.al_set_fallback_font(self.data, if (fallback) |f| f.data else null);
    }

    pub fn getFallback(self: *Font) ?Font {
        const f = c.al_get_fallback_font(self.data);
        return if (f) |ptr| Font{ .data = ptr } else null;
    }

    /// Call `callback` for each wrapped line of `text` (up to `maxWidth`).
    pub fn doMultilineText(self: *const Font, maxWidth: f32, text: [:0]const u8, callback: ?*const fn (lineNum: i32, line: [*c]const u8, size: i32, extra: ?*anyopaque) callconv(.c) bool, extra: ?*anyopaque) void {
        c.al_do_multiline_text(self.data, maxWidth, text.ptr, callback, extra);
    }

    /// String variant of `doMultilineText`.
    pub fn doMultilineUstr(self: *const Font, maxWidth: f32, text: *const Str, callback: ?*const fn (lineNum: i32, line: [*c]const c.ALLEGRO_USTR, extra: ?*anyopaque) callconv(.c) bool, extra: ?*anyopaque) void {
        c.al_do_multiline_ustr(self.data, maxWidth, text.us, callback, extra);
    }
};
pub const FontLoader = *const fn (filename: [*:0]const u8, size: i32, flags: i32) callconv(.c) ?*c.ALLEGRO_FONT;

/// Register a custom font loader for a filename extension.
pub fn registerFontLoader(ext: [:0]const u8, loader: FontLoader) bool {
    return c.al_register_font_loader(ext.ptr, @ptrCast(loader));
}

test "refAllDecls" {
    std.testing.refAllDecls(Font);
}
