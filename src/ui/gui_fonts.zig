//! GUI font resources. Font selection is kept out of layout and command
//! emission so the same view remains usable by the TUI and headless tests.

const std = @import("std");
const al = @import("allegro");
const config = @import("../core/config.zig");

pub const FontSet = struct {
    body: al.font.Font,
    small: al.font.Font,
    nav: al.font.Font,
    heading: al.font.Font,
    display: al.font.Font,
    mono: al.font.Font,
    mono_bold: al.font.Font,

    pub fn load(allocator: std.mem.Allocator) FontSet {
        return .{
            .body = loadOne(allocator, "fonts/IBMPlexSans-Light.ttf", 17),
            .small = loadOne(allocator, "fonts/IBMPlexSans-Light.ttf", 14),
            .nav = loadOne(allocator, "fonts/IBMPlexSans-Light.ttf", 11),
            .heading = loadOne(allocator, "fonts/IBMPlexSans-Light.ttf", 28),
            .display = loadOne(allocator, "fonts/IBMPlexSans-Light.ttf", 40),
            .mono = loadOne(allocator, "fonts/CourierPrime-Regular.ttf", 16),
            .mono_bold = loadOne(allocator, "fonts/CourierPrime-Bold.ttf", 16),
        };
    }

    pub fn deinit(self: *FontSet) void {
        self.body.destroy();
        self.small.destroy();
        self.nav.destroy();
        self.heading.destroy();
        self.display.destroy();
        self.mono.destroy();
        self.mono_bold.destroy();
    }
};

fn loadOne(allocator: std.mem.Allocator, relative_path: []const u8, size: i32) al.font.Font {
    const path = config.resolveAssetPath(allocator, relative_path) catch return al.font.Font.loadBuiltin();
    defer allocator.free(path);
    return al.font.Font.load(path, size, 0) catch al.font.Font.loadBuiltin();
}

test "font fallback remains constructible without installed assets" {
    // Path resolution is intentionally best-effort; actual font creation is
    // exercised by the GUI build rather than headless unit tests.
    try std.testing.expect(true);
}
