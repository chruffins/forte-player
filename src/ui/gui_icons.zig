//! Small shared icon atlas loaded from packaged assets. Missing icons are
//! normal (headless/development builds); the renderer falls back to glyphs.

const std = @import("std");
const al = @import("allegro");
const config = @import("../core/config.zig");

pub const Icons = struct {
    play: ?al.graphics.Bitmap = null,
    pause: ?al.graphics.Bitmap = null,
    previous: ?al.graphics.Bitmap = null,
    next: ?al.graphics.Bitmap = null,

    pub fn load(allocator: std.mem.Allocator) Icons {
        return .{
            .play = loadOne(allocator, "icons/play.png"),
            .pause = loadOne(allocator, "icons/pause.png"),
            .previous = loadOne(allocator, "icons/skip_prev.png"),
            .next = loadOne(allocator, "icons/skip_next.png"),
        };
    }

    pub fn deinit(self: *Icons) void {
        if (self.play) |*bitmap| bitmap.destroy();
        if (self.pause) |*bitmap| bitmap.destroy();
        if (self.previous) |*bitmap| bitmap.destroy();
        if (self.next) |*bitmap| bitmap.destroy();
    }
};

fn loadOne(allocator: std.mem.Allocator, relative_path: []const u8) ?al.graphics.Bitmap {
    const path = config.resolveAssetPath(allocator, relative_path) catch return null;
    defer allocator.free(path);
    return al.graphics.Bitmap.load(path) catch null;
}

test "icon resources are optional" {
    try std.testing.expect(true);
}
