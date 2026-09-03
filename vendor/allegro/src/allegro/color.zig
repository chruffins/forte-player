const std = @import("std");
const c = @import("c");

pub const Color = extern struct {
    r: f32,
    g: f32,
    b: f32,
    a: f32,

    // -- Construction from 8-bit channels --

    pub fn fromPremul(r: u8, g: u8, b: u8, a: u8) Color {
        return @bitCast(c.al_premul_rgba(r, g, b, a));
    }

    pub fn fromPremulFloat(r: f32, g: f32, b: f32, a: f32) Color {
        return @bitCast(c.al_premul_rgba_f(r, g, b, a));
    }

    pub fn fromRgb(r: u8, g: u8, b: u8) Color {
        return @bitCast(c.al_map_rgb(r, g, b));
    }

    pub fn fromRgba(r: u8, g: u8, b: u8, a: u8) Color {
        return @bitCast(c.al_map_rgba(r, g, b, a));
    }

    pub fn fromRgbaFloat(r: f32, g: f32, b: f32, a: f32) Color {
        return @bitCast(c.al_map_rgba_f(r, g, b, a));
    }

    pub fn fromRgbFloat(r: f32, g: f32, b: f32) Color {
        return @bitCast(c.al_map_rgb_f(r, g, b));
    }

    // -- Color-addon colour spaces --

    pub fn fromCmyk(cyan: f32, magenta: f32, yellow: f32, key: f32) Color {
        return @bitCast(c.al_color_cmyk(cyan, magenta, yellow, key));
    }

    pub fn fromHsl(h: f32, s: f32, l: f32) Color {
        return @bitCast(c.al_color_hsl(h, s, l));
    }

    pub fn fromHsv(h: f32, s: f32, v: f32) Color {
        return @bitCast(c.al_color_hsv(h, s, v));
    }

    /// Parse an HTML/CSS colour string such as "#ff0077".
    pub fn fromHtml(html: [:0]const u8) Color {
        return @bitCast(c.al_color_html(html.ptr));
    }

    pub fn fromLab(l: f32, a: f32, b: f32) Color {
        return @bitCast(c.al_color_lab(l, a, b));
    }

    pub fn fromLch(l: f32, chroma: f32, hue: f32) Color {
        return @bitCast(c.al_color_lch(l, chroma, hue));
    }

    pub fn fromLinear(r: f32, g: f32, b: f32) Color {
        return @bitCast(c.al_color_linear(r, g, b));
    }

    /// Look up a colour by CSS colour name (e.g. "red").
    pub fn fromName(name: [:0]const u8) Color {
        return @bitCast(c.al_color_name(name.ptr));
    }

    pub fn fromOklab(l: f32, a: f32, b: f32) Color {
        return @bitCast(c.al_color_oklab(l, a, b));
    }

    pub fn fromXyy(x: f32, y: f32, y2: f32) Color {
        return @bitCast(c.al_color_xyy(x, y, y2));
    }

    pub fn fromXyz(x: f32, y: f32, z: f32) Color {
        return @bitCast(c.al_color_xyz(x, y, z));
    }

    pub fn fromYuv(y: f32, u: f32, v: f32) Color {
        return @bitCast(c.al_color_yuv(y, u, v));
    }

    pub fn isValid(self: *const Color) bool {
        return c.al_is_color_valid(self.toAllegroColor());
    }

    // -- Conversions back to 8-bit channels --

    pub fn toRgb(self: *const Color) struct { r: u8, g: u8, b: u8 } {
        var r: u8 = 0;
        var g: u8 = 0;
        var b: u8 = 0;
        c.al_unmap_rgb(self.toAllegroColor(), &r, &g, &b);
        return .{ .r = r, .g = g, .b = b };
    }

    pub fn toRgba(self: *const Color) struct { r: u8, g: u8, b: u8, a: u8 } {
        var r: u8 = 0;
        var g: u8 = 0;
        var b: u8 = 0;
        var a: u8 = 0;
        c.al_unmap_rgba(self.toAllegroColor(), &r, &g, &b, &a);
        return .{ .r = r, .g = g, .b = b, .a = a };
    }

    pub fn toRgbFloat(self: *const Color) struct { r: f32, g: f32, b: f32 } {
        return .{ .r = self.r, .g = self.g, .b = self.b };
    }

    pub fn toRgbaFloat(self: *const Color) struct { r: f32, g: f32, b: f32, a: f32 } {
        return .{ .r = self.r, .g = self.g, .b = self.b, .a = self.a };
    }

    /// The CIEDE2000 perceptual difference between two colours (0 = identical).
    pub fn distanceCiede2000(self: *const Color, other: *const Color) f32 {
        return c.al_color_distance_ciede2000(self.toAllegroColor(), other.toAllegroColor());
    }

    // -- Colour-space decomposition (color addon) --

    pub fn toHsv(self: *const Color) struct { h: f32, s: f32, v: f32 } {
        var h: f32 = 0;
        var s: f32 = 0;
        var v: f32 = 0;
        c.al_color_rgb_to_hsv(self.r, self.g, self.b, &h, &s, &v);
        return .{ .h = h, .s = s, .v = v };
    }

    pub fn toHsl(self: *const Color) struct { h: f32, s: f32, l: f32 } {
        var h: f32 = 0;
        var s: f32 = 0;
        var l: f32 = 0;
        c.al_color_rgb_to_hsl(self.r, self.g, self.b, &h, &s, &l);
        return .{ .h = h, .s = s, .l = l };
    }

    pub fn toCmyk(self: *const Color) struct { c: f32, m: f32, y: f32, k: f32 } {
        var cc: f32 = 0;
        var m: f32 = 0;
        var y: f32 = 0;
        var k: f32 = 0;
        c.al_color_rgb_to_cmyk(self.r, self.g, self.b, &cc, &m, &y, &k);
        return .{ .c = cc, .m = m, .y = y, .k = k };
    }

    pub fn toLab(self: *const Color) struct { l: f32, a: f32, b: f32 } {
        var l: f32 = 0;
        var a: f32 = 0;
        var b: f32 = 0;
        c.al_color_rgb_to_lab(self.r, self.g, self.b, &l, &a, &b);
        return .{ .l = l, .a = a, .b = b };
    }

    pub fn toLch(self: *const Color) struct { l: f32, c: f32, h: f32 } {
        var l: f32 = 0;
        var cc: f32 = 0;
        var h: f32 = 0;
        c.al_color_rgb_to_lch(self.r, self.g, self.b, &l, &cc, &h);
        return .{ .l = l, .c = cc, .h = h };
    }

    pub fn toLinear(self: *const Color) struct { r: f32, g: f32, b: f32 } {
        var r: f32 = 0;
        var g: f32 = 0;
        var b: f32 = 0;
        c.al_color_rgb_to_linear(self.r, self.g, self.b, &r, &g, &b);
        return .{ .r = r, .g = g, .b = b };
    }

    pub fn toOklab(self: *const Color) struct { l: f32, a: f32, b: f32 } {
        var l: f32 = 0;
        var a: f32 = 0;
        var b: f32 = 0;
        c.al_color_rgb_to_oklab(self.r, self.g, self.b, &l, &a, &b);
        return .{ .l = l, .a = a, .b = b };
    }

    pub fn toXyz(self: *const Color) struct { x: f32, y: f32, z: f32 } {
        var x: f32 = 0;
        var y: f32 = 0;
        var z: f32 = 0;
        c.al_color_rgb_to_xyz(self.r, self.g, self.b, &x, &y, &z);
        return .{ .x = x, .y = y, .z = z };
    }

    pub fn toXyy(self: *const Color) struct { x: f32, y: f32, y2: f32 } {
        var x: f32 = 0;
        var y: f32 = 0;
        var y2: f32 = 0;
        c.al_color_rgb_to_xyy(self.r, self.g, self.b, &x, &y, &y2);
        return .{ .x = x, .y = y, .y2 = y2 };
    }

    pub fn toYuv(self: *const Color) struct { y: f32, u: f32, v: f32 } {
        var y: f32 = 0;
        var u: f32 = 0;
        var v: f32 = 0;
        c.al_color_rgb_to_yuv(self.r, self.g, self.b, &y, &u, &v);
        return .{ .y = y, .u = u, .v = v };
    }

    /// Write the colour as an HTML hex string like "#rrggbb" into `buf`.
    pub fn toHtml(self: *const Color, buf: []u8) ?[:0]u8 {
        if (buf.len < 7) return null;
        c.al_color_rgb_to_html(self.r, self.g, self.b, buf.ptr);
        buf[7] = 0;
        return buf[0..7 :0];
    }

    pub fn toName(self: *const Color) [:0]const u8 {
        return std.mem.span(c.al_color_rgb_to_name(self.r, self.g, self.b));
    }

    // -- Allegro interop --

    pub fn toAllegroColor(self: Color) c.ALLEGRO_COLOR {
        return @bitCast(self);
    }

    /// Unmap using the allegro_color addon's float decomposition.
    pub fn unmapRgbFloat(self: Color) struct { r: f32, g: f32, b: f32 } {
        var r: f32 = 0;
        var g: f32 = 0;
        var b: f32 = 0;
        c.al_unmap_rgb_f(self.toAllegroColor(), &r, &g, &b);
        return .{ .r = r, .g = g, .b = b };
    }

    pub fn unmapRgbaFloat(self: Color) struct { r: f32, g: f32, b: f32, a: f32 } {
        var r: f32 = 0;
        var g: f32 = 0;
        var b: f32 = 0;
        var a: f32 = 0;
        c.al_unmap_rgba_f(self.toAllegroColor(), &r, &g, &b, &a);
        return .{ .r = r, .g = g, .b = b, .a = a };
    }

    pub fn fromAllegroColor(color: c.ALLEGRO_COLOR) Color {
        return @bitCast(color);
    }
};

pub const BLACK = Color.fromRgbFloat(0.0, 0.0, 0.0);
pub const WHITE = Color.fromRgbFloat(1.0, 1.0, 1.0);
pub const RED = Color.fromRgbFloat(1.0, 0.0, 0.0);
pub const GREEN = Color.fromRgbFloat(0.0, 1.0, 0.0);
pub const BLUE = Color.fromRgbFloat(0.0, 0.0, 1.0);
pub const YELLOW = Color.fromRgbFloat(1.0, 1.0, 0.0);
pub const CYAN = Color.fromRgbFloat(0.0, 1.0, 1.0);
pub const MAGENTA = Color.fromRgbFloat(1.0, 0.0, 1.0);
pub const ORANGE = Color.fromRgbFloat(1.0, 0.5, 0.0);
pub const GRAY = Color.fromRgbFloat(0.5, 0.5, 0.5);
pub const GREY = GRAY;
pub const DARK_GRAY = Color.fromRgbFloat(0.25, 0.25, 0.25);

/// Colour-space component helpers (allegro_color addon).
pub const Convert = struct {
    pub const HtmlToRgb = struct {
        pub fn convert(html: [:0]const u8) ?struct { r: f32, g: f32, b: f32 } {
            var r: f32 = 0;
            var g: f32 = 0;
            var b: f32 = 0;
            if (!c.al_color_html_to_rgb(html.ptr, &r, &g, &b)) return null;
            return .{ .r = r, .g = g, .b = b };
        }
    };

    pub const NameToRgb = struct {
        pub fn convert(name: [:0]const u8) ?struct { r: f32, g: f32, b: f32 } {
            var r: f32 = 0;
            var g: f32 = 0;
            var b: f32 = 0;
            if (!c.al_color_name_to_rgb(name.ptr, &r, &g, &b)) return null;
            return .{ .r = r, .g = g, .b = b };
        }
    };

    pub const Hsv = struct {
        pub fn toRgb(h: f32, s: f32, v: f32) struct { r: f32, g: f32, b: f32 } {
            var r: f32 = 0;
            var g: f32 = 0;
            var b: f32 = 0;
            c.al_color_hsv_to_rgb(h, s, v, &r, &g, &b);
            return .{ .r = r, .g = g, .b = b };
        }
    };

    pub const Hsl = struct {
        pub fn toRgb(h: f32, s: f32, l: f32) struct { r: f32, g: f32, b: f32 } {
            var r: f32 = 0;
            var g: f32 = 0;
            var b: f32 = 0;
            c.al_color_hsl_to_rgb(h, s, l, &r, &g, &b);
            return .{ .r = r, .g = g, .b = b };
        }
    };

    pub const Cmyk = struct {
        pub fn toRgb(c2: f32, m: f32, y: f32, k: f32) struct { r: f32, g: f32, b: f32 } {
            var r: f32 = 0;
            var g: f32 = 0;
            var b: f32 = 0;
            c.al_color_cmyk_to_rgb(c2, m, y, k, &r, &g, &b);
            return .{ .r = r, .g = g, .b = b };
        }
    };

    pub const Lab = struct {
        pub fn toRgb(l: f32, a: f32, b: f32) struct { r: f32, g: f32, bl: f32 } {
            var r: f32 = 0;
            var g: f32 = 0;
            var bl: f32 = 0;
            c.al_color_lab_to_rgb(l, a, b, &r, &g, &bl);
            return .{ .r = r, .g = g, .bl = bl };
        }
    };

    pub const Lch = struct {
        pub fn toRgb(l: f32, c2: f32, h: f32) struct { r: f32, g: f32, b: f32 } {
            var r: f32 = 0;
            var g: f32 = 0;
            var b: f32 = 0;
            c.al_color_lch_to_rgb(l, c2, h, &r, &g, &b);
            return .{ .r = r, .g = g, .b = b };
        }
    };

    pub const Linear = struct {
        pub fn toRgb(x: f32, y: f32, z: f32) struct { r: f32, g: f32, b: f32 } {
            var r: f32 = 0;
            var g: f32 = 0;
            var b: f32 = 0;
            c.al_color_linear_to_rgb(x, y, z, &r, &g, &b);
            return .{ .r = r, .g = g, .b = b };
        }
    };

    pub const Oklab = struct {
        pub fn toRgb(l: f32, a: f32, b: f32) struct { r: f32, g: f32, bl: f32 } {
            var r: f32 = 0;
            var g: f32 = 0;
            var bl: f32 = 0;
            c.al_color_oklab_to_rgb(l, a, b, &r, &g, &bl);
            return .{ .r = r, .g = g, .bl = bl };
        }
    };

    pub const Xyz = struct {
        pub fn toRgb(x: f32, y: f32, z: f32) struct { r: f32, g: f32, b: f32 } {
            var r: f32 = 0;
            var g: f32 = 0;
            var b: f32 = 0;
            c.al_color_xyz_to_rgb(x, y, z, &r, &g, &b);
            return .{ .r = r, .g = g, .b = b };
        }
    };

    pub const Xyy = struct {
        pub fn toRgb(x: f32, y: f32, y2: f32) struct { r: f32, g: f32, b: f32 } {
            var r: f32 = 0;
            var g: f32 = 0;
            var b: f32 = 0;
            c.al_color_xyy_to_rgb(x, y, y2, &r, &g, &b);
            return .{ .r = r, .g = g, .b = b };
        }
    };

    pub const Yuv = struct {
        pub fn toRgb(y: f32, u: f32, v: f32) struct { r: f32, g: f32, b: f32 } {
            var r: f32 = 0;
            var g: f32 = 0;
            var b: f32 = 0;
            c.al_color_yuv_to_rgb(y, u, v, &r, &g, &b);
            return .{ .r = r, .g = g, .b = b };
        }
    };

    test "convert" {
        _ = Convert.Hsv.toRgb(0, 1, 1);
    }
};

test "refAllDecls" {
    std.testing.refAllDecls(Color);
}
