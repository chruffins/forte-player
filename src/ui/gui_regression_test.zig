//! Regression coverage for the native GUI, independent of display/assets.
const std = @import("std");
const gui = @import("gui_layout.zig");
const input = @import("gui_input.zig");
const framework = @import("gui_framework.zig");
const render = @import("gui_render.zig");
const U = @import("ui_state.zig");

const sizes = [_][2]f32{ .{ 360, 300 }, .{ 480, 320 }, .{ 600, 480 }, .{ 799, 499 }, .{ 800, 500 }, .{ 1120, 720 }, .{ 1920, 1080 } };

test "all dialog controls remain bounded across responsive breakpoints" {
    for (sizes) |size| {
        const frame = gui.Frame.fromSize(size[0], size[1]);
        for ([_]gui.Dialog{ frame.dialog(680, 580), frame.dialog(560, 540), frame.dialog(540, 276), frame.dialog(480, 456) }) |d| {
            try std.testing.expect(d.card.x >= 0 and d.card.y >= 0);
            try std.testing.expect(d.card.right() <= frame.width and d.card.bottom() <= frame.height);
            try std.testing.expect(d.body.bottom() < d.footer.y);
            for (0..2) |i| {
                const b = d.button(i);
                try std.testing.expect(b.x >= d.card.x and b.right() <= d.card.right());
                try std.testing.expect(b.y >= d.card.y and b.bottom() <= d.card.bottom());
            }
        }
        for (0..8) |active| {
            const d = frame.dialog(680, 580);
            const r = render.metadataEditorFieldRect(frame, active, active);
            try std.testing.expect(r.y >= d.body.y and r.bottom() <= d.body.bottom());
            try std.testing.expectEqual(@as(?usize, active), render.metadataEditorFieldAt(frame, r.x + 2, r.y + 2, active));
        }
    }
}

test "visualizer never overlaps artwork, lyrics or transport" {
    for (sizes) |size| {
        const frame = gui.Frame.fromSize(size[0], size[1]);
        const n = frame.nowPlaying();
        if (n.visualizer.h == 0) {
            try std.testing.expectEqual(@as(f32, 0), frame.visualizerPlot().h);
            try std.testing.expectEqual(@as(f32, 0), frame.visualizerButton(0).h);
            continue;
        }
        try std.testing.expect(n.art.bottom() <= n.visualizer.y);
        try std.testing.expect(n.lyrics.bottom() <= n.visualizer.y);
        try std.testing.expect(n.visualizer.bottom() <= frame.body.bottom());
        try std.testing.expect(n.visualizer.bottom() < frame.player.y);
        const plot = frame.visualizerPlot();
        try std.testing.expect(n.visualizer.contains(plot.x, plot.y));
        try std.testing.expect(n.visualizer.contains(plot.right(), plot.bottom()));
        for (0..2) |i| {
            const b = frame.visualizerButton(i);
            try std.testing.expect(b.bottom() <= plot.y);
            try std.testing.expect(n.visualizer.contains(b.x, b.y));
        }
    }
}

test "settings focus reveals any credential without scrolling outside viewport" {
    for (sizes) |size| {
        const frame = gui.Frame.fromSize(size[0], size[1]);
        for (0..3) |i| {
            const offset = gui.settingsScroll(frame, 0, @intCast(i), gui.settings_count);
            const r = frame.rowRect(6 + i, offset);
            try std.testing.expect(r.y >= frame.body.y - 0.01);
            try std.testing.expect(r.bottom() <= frame.body.bottom() + 0.01);
            try std.testing.expect(offset >= 0 and offset <= frame.maxScroll(gui.settings_count));
        }
    }
}

test "list clicks exclude shell, toolbar, scrollbar and transport" {
    for (sizes) |size| {
        const f = gui.Frame.fromSize(size[0], size[1]);
        try std.testing.expectEqual(input.Hit.none, input.hitList(f, f.toolbar.x, f.toolbar.y, 0, 100));
        try std.testing.expectEqual(input.Hit.none, input.hitList(f, f.player.x + 1, f.player.y + 1, 0, 100));
        try std.testing.expectEqual(input.Hit.none, input.hitList(f, f.body.right() - 1, f.body.y + 1, 0, 100));
        const offset = f.maxScroll(100);
        const last = f.rowRect(99, offset);
        try std.testing.expectApproxEqAbs(f.body.bottom(), last.bottom(), 0.01);
        try std.testing.expectEqual(input.Hit{ .row = 99 }, input.hitList(f, last.x + 1, last.bottom() - 1, offset, 100));
    }
}

test "modal flag covers every dialog and shared state leaves TUI unconstrained" {
    var s = U.State{};
    try std.testing.expect(!gui.modalOpen(&s));
    s.context_menu_open = true;
    try std.testing.expect(gui.modalOpen(&s));
    s.context_menu_open = false;
    s.metadata_editing = true;
    try std.testing.expect(gui.modalOpen(&s));
    s.metadata_editing = false;
    s.playlist_modal_open = true;
    try std.testing.expect(gui.modalOpen(&s));
    s.playlist_modal_open = false;
    s.playlist_picker_open = true;
    try std.testing.expect(gui.modalOpen(&s));
}

fn spec(x: f32) framework.WidgetSpec {
    return .{ .position = .{ .px_x = x, .px_y = 10 }, .size = .{ .px_x = 40, .px_y = 40 }, .focusable = true };
}
test "dispatcher focus advances, wraps, and skips disabled targets" {
    var d = framework.Dispatcher{};
    try std.testing.expect(d.add(1, spec(10)));
    var disabled = spec(60);
    disabled.enabled = false;
    try std.testing.expect(d.add(2, disabled));
    try std.testing.expect(d.add(3, spec(110)));
    try std.testing.expectEqual(@as(?u16, 1), d.dispatch(.focus_next, 400, 300).target);
    try std.testing.expectEqual(@as(?u16, 3), d.dispatch(.focus_next, 400, 300).target);
    try std.testing.expectEqual(@as(?u16, 1), d.dispatch(.focus_next, 400, 300).target);
    try std.testing.expectEqual(@as(?u16, 3), d.dispatch(.focus_previous, 400, 300).target);
}
test "pointer capture survives motion but cannot activate another button" {
    var d = framework.Dispatcher{};
    try std.testing.expect(d.add(1, spec(10)));
    try std.testing.expect(d.add(2, spec(60)));
    _ = d.dispatch(.{ .mouse_down = .{ .x = 20, .y = 20, .button = 1 } }, 400, 300);
    try std.testing.expectEqual(@as(?u16, 1), d.dispatch(.{ .mouse_move = .{ .x = 80, .y = 20 } }, 400, 300).target);
    try std.testing.expect(!d.dispatch(.{ .mouse_up = .{ .x = 80, .y = 20, .button = 1 } }, 400, 300).activated);
    _ = d.dispatch(.{ .mouse_down = .{ .x = 20, .y = 20, .button = 2 } }, 400, 300);
    try std.testing.expect(d.pressed == null);
    _ = d.dispatch(.{ .mouse_down = .{ .x = 20, .y = 20, .button = 1 } }, 400, 300);
    _ = d.dispatch(.cancel, 400, 300);
    try std.testing.expect(!d.dispatch(.{ .mouse_up = .{ .x = 20, .y = 20, .button = 1 } }, 400, 300).activated);
}
test "clipped and collapsed widgets do not receive input" {
    var w = spec(10);
    w.clip = .{ .x = 20, .y = 20, .w = 20, .h = 20 };
    try std.testing.expect(!w.hitTest(400, 300, 12, 12));
    try std.testing.expect(w.hitTest(400, 300, 22, 22));
    try std.testing.expect(!w.hitTest(400, 300, 40, 40));
    w.size = .{};
    try std.testing.expect(!w.hitTest(400, 300, 20, 20));
}
