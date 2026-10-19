//! Gallery geometry and navigation, without a display or artwork resources.
const std = @import("std");
const gui = @import("gui_layout.zig");
const U = @import("ui_state.zig");
const renderer = @import("gui_render.zig");
const sizes = [_][2]f32{ .{ 360, 300 }, .{ 600, 480 }, .{ 800, 500 }, .{ 1120, 720 }, .{ 1440, 900 }, .{ 1920, 1080 } };

test "gallery grid hits match cards, exclude gutters and reach the last album" {
    for (sizes) |size| {
        const frame = gui.Frame.forScreen(size[0], size[1], .albums, true);
        const count = 17;
        const offset = frame.maxScroll(count);
        const last = frame.rowRect(count - 1, offset);
        try std.testing.expect(last.bottom() <= frame.body.bottom());
        try std.testing.expectEqual(@as(?usize, count - 1), frame.rowAt(last.x + 2, last.bottom() - 1, offset, count));
        try std.testing.expect(frame.rowAt(frame.body.x, frame.body.y - 1, offset, count) == null);
        try std.testing.expect(frame.rowAt(frame.body.right() - 1, frame.body.y + 1, offset, count) == null);
        try std.testing.expect(frame.rowAt(frame.body.x, frame.body.y, 0, 0) == null);
        if (!frame.galleryCompact() and frame.gridColumns() > 1) {
            const first = frame.rowRect(0, 0);
            try std.testing.expect(frame.rowAt(first.right() + 4, first.y + 4, 0, count) == null);
        }
        for (0..3) |row| {
            const anchor = row * frame.gridColumns();
            try std.testing.expectEqual(anchor, frame.anchorFromOffset(frame.offsetFromAnchor(anchor)));
        }
    }
}

test "gallery keyboard movement, partial rows and reveal are bounded" {
    try std.testing.expectEqual(@as(usize, 0), gui.moveGridSelection(0, -3, 17));
    try std.testing.expectEqual(@as(usize, 16), gui.moveGridSelection(15, 3, 17));
    try std.testing.expectEqual(@as(usize, 0), gui.moveGridSelection(12, 1, 0));
    for (sizes) |size| {
        const frame = gui.Frame.forScreen(size[0], size[1], .albums, true);
        const offset = frame.reveal(16, 0, 17);
        const card = frame.rowRect(16, offset);
        try std.testing.expect(offset <= frame.maxScroll(17));
        try std.testing.expect(card.y >= frame.body.y - 0.01);
        try std.testing.expect(card.bottom() <= frame.body.bottom() + 0.01);
        try std.testing.expectEqual(@as(f32, 0), frame.reveal(0, offset, 17));
    }
}

test "inspector collapses before gallery and detail controls stay separate" {
    for (sizes) |size| {
        const frame = gui.Frame.forScreen(size[0], size[1], .albums, true);
        if (frame.inspector.w > 0) {
            try std.testing.expect(frame.content.right() < frame.inspector.x);
            try std.testing.expect(frame.inspector.bottom() < frame.player.y);
            const rows = frame.inspectorRows();
            try std.testing.expect(rows.bottom() <= frame.inspector.bottom());
            try std.testing.expectEqual(@as(?usize, 4), frame.inspectorRowAt(rows.x + 1, rows.y + 1, 4, 20));
            const visible: usize = @intFromFloat(rows.h / gui.row_height);
            if (rows.h > @as(f32, @floatFromInt(visible)) * gui.row_height) try std.testing.expect(frame.inspectorRowAt(rows.x + 1, rows.bottom() - 1, 4, 20) == null);
        } else try std.testing.expect(size[0] < 1080 or size[1] < 560);
        const closed = gui.Frame.forScreen(size[0], size[1], .albums, false);
        try std.testing.expectEqual(@as(f32, 0), closed.inspector.w);
        try std.testing.expect(closed.body.w >= frame.body.w);
        const detail = gui.Frame.forScreen(size[0], size[1], .album_detail, true);
        const art = detail.albumHeroArt();
        const play = detail.albumPlay();
        try std.testing.expect(play.x >= art.right());
        try std.testing.expect(play.bottom() <= detail.album_hero.bottom());
        try std.testing.expect(detail.album_hero.bottom() < detail.body.y);
        try std.testing.expect(detail.body.bottom() < detail.player.y);
        if (frame.galleryCompact()) try std.testing.expect(frame.galleryArt(0, 0).bottom() <= frame.body.bottom());
    }
    // Only the GUI changes its landing page; the TUI's initial state is intact.
    try std.testing.expectEqual(U.Screen.now_playing, (U.State{}).screen);
}

test "player timestamps handle invalid and fractional input" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("2:05", renderer.durationText(&buf, 125.9));
    try std.testing.expectEqualStrings("0:00", renderer.durationText(&buf, -10));
    try std.testing.expectEqualStrings("0:00", renderer.durationText(&buf, std.math.nan(f64)));
}
