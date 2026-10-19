//! Semantic pixel-space hit testing. Uses exactly the renderer's layout.
const std = @import("std");
const ui = @import("ui.zig");
const layout = @import("gui_layout.zig");

pub const Control = enum { previous, toggle_pause, next };
pub const ScrollbarHit = enum { none, thumb, page_up, page_down };
pub const Hit = union(enum) { none, row: usize, seek: f64, control: Control };

pub fn hitScrollbar(track: ui.Rect, thumb: ?ui.Rect, x: f32, y: f32) ScrollbarHit {
    const area = ui.Rect{ .x = track.x - 4, .y = track.y, .w = track.w + 8, .h = track.h };
    if (!area.contains(x, y)) return .none;
    if (thumb) |value| {
        if (y >= value.y and y < value.bottom()) return .thumb;
        return if (y < value.y) .page_up else .page_down;
    }
    return .none;
}

pub fn hitTransport(frame: layout.Frame, x: f32, y: f32) Hit {
    if (!frame.player.contains(x, y)) return .none;
    const track = frame.seekTrack();
    if ((ui.Rect{ .x = track.x, .y = track.y - 8, .w = track.w, .h = 16 }).contains(x, y)) {
        return .{ .seek = @max(0.0, @min(1.0, (x - track.x) / @max(1, track.w))) };
    }
    const controls = [_]Control{ .previous, .toggle_pause, .next };
    for (controls, 0..) |control, i| if (frame.transportRect(i).contains(x, y)) return .{ .control = control };
    return .none;
}
pub fn hitList(frame: layout.Frame, x: f32, y: f32, offset: f32, count: usize) Hit {
    const index = frame.rowAt(x, y, offset, count) orelse return .none;
    return .{ .row = index };
}

test "transport hit regions match buttons and exclude inter-button gaps" {
    const f = layout.Frame.fromSize(960, 600);
    const controls = [_]Control{ .previous, .toggle_pause, .next };
    for (controls, 0..) |control, i| {
        const r = f.transportRect(i);
        try std.testing.expectEqual(Hit{ .control = control }, hitTransport(f, r.x + 1, r.y + 1));
        try std.testing.expectEqual(Hit.none, hitTransport(f, r.right() + 2, r.y + 1));
    }
    const t = f.seekTrack();
    try std.testing.expectEqual(Hit{ .seek = 0 }, hitTransport(f, t.x, t.y));
    try std.testing.expectEqual(Hit{ .seek = 1 }, hitTransport(f, t.right(), t.y));
}
test "pixel lists return absolute indices and respect clipping" {
    const f = layout.Frame.fromSize(960, 600);
    try std.testing.expectEqual(Hit{ .row = 3 }, hitList(f, f.body.x + 1, f.body.y + 1, 3 * layout.row_height, 100));
    try std.testing.expectEqual(Hit.none, hitList(f, f.body.x + 1, f.body.bottom() + 1, 0, 100));
}
test "expanded scrollbar thumb target captures its narrow edges" {
    const track = ui.Rect{ .x = 500, .y = 100, .w = 6, .h = 300 };
    const thumb = ui.Rect{ .x = 500, .y = 180, .w = 6, .h = 60 };
    try std.testing.expectEqual(ScrollbarHit.thumb, hitScrollbar(track, thumb, 497, 200));
    try std.testing.expectEqual(ScrollbarHit.page_up, hitScrollbar(track, thumb, 501, 140));
    try std.testing.expectEqual(ScrollbarHit.page_down, hitScrollbar(track, thumb, 501, 280));
}
