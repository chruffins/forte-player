//! Pure GUI hit testing. Allegro event structs are converted to cell
//! coordinates by the frontend, then this module returns a semantic target.
//! It intentionally knows nothing about displays, fonts, or drawing.

const std = @import("std");
const view = @import("ui_view.zig");
const ui = @import("ui.zig");

pub const Control = enum { previous, toggle_pause, next };
pub const ScrollbarHit = enum { none, thumb, page_up, page_down };

pub fn hitScrollbar(track: ui.Rect, thumb: ?ui.Rect, x: f32, y: f32) ScrollbarHit {
    if (x < track.x - 12 or x >= track.right() + 12 or y < track.y or y >= track.bottom()) return .none;
    if (thumb) |value| {
        if (value.contains(x, y)) return .thumb;
        return if (y < value.y) .page_up else .page_down;
    }
    return .none;
}

pub const Hit = union(enum) {
    none,
    row: usize,
    seek: f64,
    control: Control,
};

/// Hit-test the persistent transport panel. Keeping this separate from the
/// cell-grid test lets the GUI offer large mouse targets without changing the
/// shared terminal-oriented view coordinates.
pub fn hitTransport(player: ui.Rect, x: f32, y: f32) Hit {
    if (x < player.x or x >= player.right() or y < player.y or y >= player.bottom()) return .none;
    if (y >= player.bottom() - 22) {
        const left = player.x + 22;
        const width = @max(1.0, player.w - 44);
        return .{ .seek = @max(0.0, @min(1.0, (x - left) / width)) };
    }
    const center = player.x + player.w * 0.54;
    if (y >= player.y + 14 and y < player.y + player.h - 22 and x >= center - 72 and x < center + 72) {
        const slot: usize = @intFromFloat((x - (center - 72)) / 48.0);
        return .{ .control = switch (slot) {
            0 => .previous,
            1 => .toggle_pause,
            else => .next,
        } };
    }
    return .none;
}

/// Resolve a left-button click in the shared command-stream coordinate space.
/// Row indices are relative to the first content row; callers add their current
/// scroll offset and decide whether that screen has selectable rows.
pub fn hitTest(columns: u16, rows: u16, x: u16, y: u16) Hit {
    if (rows <= view.footer_rows) return .none;
    const footer_top = rows - view.footer_rows;
    const bar_width: u16 = @min(columns -| 18, 60);
    if (y == footer_top + 1 and x >= 3 and x < 3 + bar_width and bar_width > 1) {
        return .{ .seek = @as(f64, @floatFromInt(x - 3)) / @as(f64, @floatFromInt(bar_width - 1)) };
    }
    const content_top = view.header_rows + 1;
    if (y >= content_top and y < footer_top) {
        return .{ .row = y - content_top };
    }
    return .none;
}

test "GUI hit testing returns content rows" {
    try std.testing.expectEqual(Hit{ .row = 0 }, hitTest(80, 30, 2, 3));
    try std.testing.expectEqual(Hit{ .row = 4 }, hitTest(80, 30, 2, 7));
    try std.testing.expectEqual(Hit.none, hitTest(80, 30, 2, 2));
}

test "GUI hit testing returns clamped progress fraction" {
    try std.testing.expectEqual(Hit{ .seek = 0.0 }, hitTest(80, 30, 3, 27));
    try std.testing.expectEqual(Hit{ .seek = 1.0 }, hitTest(80, 30, 62, 27));
    try std.testing.expectEqual(Hit.none, hitTest(80, 30, 63, 27));
}

test "scrollbar hit testing distinguishes thumb and paging" {
    const track = ui.Rect{ .x = 500, .y = 100, .w = 4, .h = 300 };
    const thumb = ui.Rect{ .x = 500, .y = 180, .w = 4, .h = 60 };
    try std.testing.expectEqual(ScrollbarHit.thumb, hitScrollbar(track, thumb, 501, 200));
    try std.testing.expectEqual(ScrollbarHit.page_up, hitScrollbar(track, thumb, 501, 140));
    try std.testing.expectEqual(ScrollbarHit.page_down, hitScrollbar(track, thumb, 501, 280));
    try std.testing.expectEqual(ScrollbarHit.none, hitScrollbar(track, thumb, 100, 200));
}

test "transport uses large mouse targets" {
    const player = ui.Rect{ .x = 100, .y = 500, .w = 700, .h = 92 };
    try std.testing.expectEqual(Hit{ .control = .previous }, hitTransport(player, 410, 530));
    try std.testing.expectEqual(Hit{ .control = .toggle_pause }, hitTransport(player, 458, 530));
    try std.testing.expectEqual(Hit{ .control = .next }, hitTransport(player, 506, 530));
    try std.testing.expectEqual(Hit{ .seek = 0.0 }, hitTransport(player, 122, 580));
    try std.testing.expectEqual(Hit{ .seek = 1.0 }, hitTransport(player, 778, 580));
}
