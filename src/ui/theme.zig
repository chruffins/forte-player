//! Terminal theming: semantic style -> ANSI SGR per color scheme.
//!
//! `view.Style` is the semantic token; `Palette` maps each token to an actual
//! SGR sequence, chosen by whether the terminal background is dark or light.
//! Terminal "dark mode" isn't queryable directly, so we best-effort probe the
//! background via the OSC 11 query (`ESC ] 11 ; ? ESC \`) and fall back to dark.

const std = @import("std");

pub const Scheme = enum { dark, light };

pub const Palette = struct {
    normal: []const u8,
    dim: []const u8,
    bold: []const u8,
    title: []const u8,
    accent: []const u8,
    err: []const u8,
    /// full-line highlight for the selected/playing row (reverse video).
    selected: []const u8,
    bar_fill: []const u8,
    bar_empty: []const u8,
};

/// Light text on a dark background (the default and most common).
pub fn dark() Palette {
    return .{
        .normal = "\x1b[0m",
        .dim = "\x1b[2;37m", // dim bright-white: readable on dark
        .bold = "\x1b[1;97m",
        .title = "\x1b[1;96m", // bright cyan
        .accent = "\x1b[1;93m", // bright yellow
        .err = "\x1b[1;91m",
        .selected = "\x1b[7;1;97m", // reverse + bold
        .bar_fill = "\x1b[1;92m", // bright green
        .bar_empty = "\x1b[2;37m",
    };
}

/// Dark text on a light background.
pub fn light() Palette {
    return .{
        .normal = "\x1b[0m",
        .dim = "\x1b[2;30m",
        .bold = "\x1b[1m",
        .title = "\x1b[1;36m",
        .accent = "\x1b[1;33m",
        .err = "\x1b[1;31m",
        .selected = "\x1b[7;1m",
        .bar_fill = "\x1b[1;32m",
        .bar_empty = "\x1b[2;90m",
    };
}

pub fn palette(scheme: Scheme) Palette {
    return switch (scheme) {
        .dark => dark(),
        .light => light(),
    };
}

// ---------------------------------------------------------------------------
// OSC 11 background detection (best-effort)
// ---------------------------------------------------------------------------
//
// Sends `ESC ] 11 ; ? ESC \` and looks for a response like
//   `ESC ] 11 ; rgb:1e1e/1e1e/1e1e ESC \`  (or with BEL terminators).
// If a terminal doesn't answer, or we can't parse it, we assume dark.

/// Compute relative luminance of a parsed RGB and return whether it's light.
pub fn luminanceIsLight(r: u8, g: u8, b: u8) bool {
    const l: f32 = 0.299 * @as(f32, @floatFromInt(r)) +
        0.587 * @as(f32, @floatFromInt(g)) +
        0.114 * @as(f32, @floatFromInt(b));
    return l >= 128.0;
}

fn hexVal(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

/// Parse `rgb:R/G/B` into {r,g,b}. Terminals send per-channel hex groups
/// separated by `/` (e.g. `rgb:1e1e/1e1e/1e1e` or `rgb:ff/ff/ff`). Returns null
/// on failure.
pub fn parseRgb(resp: []const u8) ?struct { r: u8, g: u8, b: u8 } {
    const idx = std.mem.indexOf(u8, resp, "rgb:") orelse return null;
    var i = idx + 4;
    var comps: [3]u8 = undefined;
    var ci: usize = 0;
    while (ci < 3) : (ci += 1) {
        var digits: [4]u8 = undefined;
        var dn: usize = 0;
        while (i < resp.len and resp[i] != '/' and resp[i] != 0x1b and resp[i] != 0x07 and dn < 4) : (i += 1) {
            const v = hexVal(resp[i]) orelse break;
            digits[dn] = v;
            dn += 1;
        }
        if (dn == 0) return null;
        const high: u16 = digits[0];
        const low: u16 = if (dn >= 2) digits[1] else digits[0];
        comps[ci] = @intCast(high * 16 + low);
        if (i < resp.len and resp[i] == '/') i += 1;
    }
    return .{ .r = comps[0], .g = comps[1], .b = comps[2] };
}

test "parseRgb handles rgb:R/G/B groups" {
    const p = (parseRgb("\x1b]11;rgb:1e1e/3c3c/5a5a\x1b\\") orelse return error.fail);
    try std.testing.expectEqual(@as(u8, 30), p.r);
    try std.testing.expectEqual(@as(u8, 60), p.g);
    try std.testing.expectEqual(@as(u8, 90), p.b);
}

test "parseRgb handles 2-digit groups" {
    const p = (parseRgb("rgb:ff/ff/ff") orelse return error.fail);
    try std.testing.expect(p.r == 255 and p.g == 255 and p.b == 255);
}

test "luminance classifies dark vs light backgrounds" {
    try std.testing.expect(!luminanceIsLight(24, 24, 24)); // dark terminal bg
    try std.testing.expect(luminanceIsLight(240, 240, 240)); // light bg
}
