//! Pure GUI geometry. It describes the responsive shell without importing
//! Allegro, which keeps sizing and hit-test behavior easy to test headlessly.

const std = @import("std");
const ui = @import("ui.zig");
const U = @import("ui_state.zig");

pub const Frame = struct {
    width: f32,
    height: f32,
    sidebar: ui.Rect,
    content: ui.Rect,
    player: ui.Rect,
    columns: u16,
    rows: u16,
    cell_w: f32,
    cell_h: f32,

    pub fn fromSize(width: f32, height: f32) Frame {
        const sidebar_width: f32 = if (width < 760) 88 else 224;
        const content_x = sidebar_width + 20;
        const content_y: f32 = 20;
        const player_h: f32 = if (height < 540) 76 else 92;
        const player_y = @max(content_y + 1, height - player_h - 12);
        const content_width = @max(1.0, width - content_x - 20);
        // Keep the content viewport above the persistent player panel. The
        // previous full-height viewport made the shared footer draw on top of
        // the transport bar at the minimum 300px configured window height.
        const content_bottom = @max(content_y + 1, player_y - 16);
        const content_height = @max(1.0, content_bottom - content_y);
        const columns: u16 = @intCast(@max(@as(usize, 1), @as(usize, @intFromFloat(content_width / 10.0))));
        const rows: u16 = @intCast(@max(@as(usize, 1), @as(usize, @intFromFloat(content_height / 22.0))));
        return .{
            .width = width,
            .height = height,
            .sidebar = .{ .x = 0, .y = 0, .w = sidebar_width, .h = height },
            .content = .{ .x = content_x, .y = content_y, .w = content_width, .h = content_height },
            .player = .{ .x = content_x, .y = player_y, .w = content_width, .h = player_h },
            .columns = columns,
            .rows = rows,
            .cell_w = content_width / @as(f32, @floatFromInt(columns)),
            .cell_h = content_height / @as(f32, @floatFromInt(rows)),
        };
    }

    pub fn cellRect(self: Frame, x: u16, y: u16, w: u16, h: u16) ui.Rect {
        return .{
            .x = self.content.x + @as(f32, @floatFromInt(x)) * self.cell_w,
            .y = self.content.y + @as(f32, @floatFromInt(y)) * self.cell_h,
            .w = @as(f32, @floatFromInt(w)) * self.cell_w,
            .h = @as(f32, @floatFromInt(h)) * self.cell_h,
        };
    }

    pub fn pointToCell(self: Frame, x: f32, y: f32) ?struct { x: u16, y: u16 } {
        if (x < self.content.x or y < self.content.y or x >= self.content.right() or y >= self.content.bottom()) return null;
        const cx: u16 = @intCast(@min(@as(usize, self.columns - 1), @as(usize, @intFromFloat((x - self.content.x) / self.cell_w))));
        const cy: u16 = @intCast(@min(@as(usize, self.rows - 1), @as(usize, @intFromFloat((y - self.content.y) / self.cell_h))));
        return .{ .x = cx, .y = cy };
    }

    pub fn navScreen(self: Frame, x: f32, y: f32) ?U.Screen {
        if (x < 12 or x >= self.sidebar.w - 12 or y < 92) return null;
        const index: usize = @intFromFloat((y - 92) / 42.0);
        if (index >= nav_count) return null;
        return nav_screen_order[index];
    }
};

pub const nav_screen_order = [_]U.Screen{ .now_playing, .library, .albums, .artists, .genres, .playlists, .queue, .settings };
pub const nav_count = nav_screen_order.len;

pub fn navLabel(screen: U.Screen) []const u8 {
    return switch (screen) {
        .now_playing => "Now Playing",
        .library => "Library",
        .albums, .album_detail => "Albums",
        .artists, .artist_detail => "Artists",
        .genres, .genre_detail => "Genres",
        .playlists, .playlist_detail => "Playlists",
        .queue => "Queue",
        .settings => "Settings",
    };
}

pub fn navShortLabel(screen: U.Screen) []const u8 {
    return switch (screen) {
        .now_playing => "PLAY",
        .library => "LIB",
        .albums, .album_detail => "ALB",
        .artists, .artist_detail => "ART",
        .genres, .genre_detail => "GEN",
        .playlists, .playlist_detail => "PL",
        .queue => "QUEUE",
        .settings => "SET",
    };
}

test "responsive frame reserves shell regions" {
    const wide = Frame.fromSize(1200, 800);
    try std.testing.expect(wide.sidebar.w > 200);
    try std.testing.expect(wide.content.x > wide.sidebar.w);
    try std.testing.expect(wide.player.y > wide.content.y);
    try std.testing.expect(wide.pointToCell(wide.content.x + 1, wide.content.y + 1) != null);
    try std.testing.expect(wide.pointToCell(1, 1) == null);

    const narrow = Frame.fromSize(600, 480);
    try std.testing.expect(narrow.sidebar.w < wide.sidebar.w);
    try std.testing.expectEqual(U.Screen.library, narrow.navScreen(30, 92 + 42));
}
