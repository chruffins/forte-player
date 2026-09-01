//! Allegro renderer for the shared command stream.
//!
//! The view remains a small, deterministic command list. This renderer adds
//! the GUI shell (sidebar, content surface, and transport panel) underneath
//! it, so the same semantic screens can look native without a retained widget
//! tree or callback graph.

const std = @import("std");
const al = @import("allegro");
const ui = @import("ui.zig");
const view = @import("ui_view.zig");
const low = @import("render.zig");
const fonts = @import("gui_fonts.zig");
const icons = @import("gui_icons.zig");
const layout_mod = @import("gui_layout.zig");
const U = @import("ui_state.zig");
const input = @import("gui_input.zig");
const framework = @import("gui_framework.zig");

pub const Layout = layout_mod.Frame;

fn color(style: view.Style) al.Color {
    return switch (style) {
        .normal => low.textColor(),
        .dim => low.muted(),
        .bold, .title => low.textColor(),
        .accent, .bar_fill => low.accent(),
        .err => al.Color.fromRgb(235, 100, 100),
        .bar_empty => al.Color.fromRgb(55, 62, 76),
        .selected => low.textColor(),
    };
}

fn drawString(font: al.font.Font, x: f32, y: f32, text: []const u8, tint: al.Color) void {
    drawStringClipped(font, x, y, text, tint, null);
}

fn drawStringClipped(font: al.font.Font, x: f32, y: f32, text: []const u8, tint: al.Color, max_width: ?f32) void {
    var buf: [512:0]u8 = undefined;
    var n = @min(text.len, buf.len - 1);
    @memcpy(buf[0..n], text[0..n]);
    buf[n] = 0;
    if (max_width) |limit| {
        const max_pixels: i32 = @intFromFloat(@max(0, limit));
        while (n > 0) {
            buf[n] = 0;
            if (font.getTextWidth(buf[0..n :0]) <= max_pixels) break;
            n -= 1;
            while (n > 0 and (buf[n] & 0xc0) == 0x80) n -= 1;
        }
        // An ellipsis makes clipped footer hints and long metadata look
        // intentional instead of ending at an arbitrary glyph boundary.
        if (n < text.len and n >= 3) {
            buf[n - 3] = '.';
            buf[n - 2] = '.';
            buf[n - 1] = '.';
        }
        buf[n] = 0;
    }
    font.drawTextAt(tint, x, y, 0, buf[0..n :0]);
}

fn drawSlice(font_set: *const fonts.FontSet, x: f32, y: f32, text: []const u8, style: view.Style, max_width: ?f32) void {
    const font = switch (style) {
        .title => &font_set.heading,
        .dim, .normal, .accent, .err, .bar_fill, .bar_empty => &font_set.body,
        .bold, .selected => &font_set.mono_bold,
    };
    drawStringClipped(font.*, x, y, text, color(style), max_width);
}

fn isActive(current: U.Screen, item: U.Screen) bool {
    return switch (item) {
        .now_playing => current == .now_playing,
        .library => current == .library,
        .albums => current == .albums or current == .album_detail,
        .artists => current == .artists or current == .artist_detail,
        .genres => current == .genres or current == .genre_detail,
        .playlists => current == .playlists or current == .playlist_detail,
        .queue => current == .queue,
        .settings => current == .settings,
        else => false,
    };
}

fn itemCount(state: *const U.State) usize {
    return switch (state.screen) {
        .library => state.row_count,
        .albums => state.album_count,
        .album_detail => state.album_detail_count,
        .artists => state.artist_count,
        .artist_detail => state.artist_detail_count,
        .genres => state.genre_count,
        .genre_detail => state.genre_detail_count,
        .playlists => state.playlist_count,
        .playlist_detail => state.playlist_detail_count,
        .queue => state.queue_count,
        else => 0,
    };
}

pub const ScrollbarGeometry = struct {
    track: ui.Rect,
    thumb: ?ui.Rect,
};

pub fn scrollbarGeometry(frame: Layout, state: *const U.State, scroll_offset: f32) ?ScrollbarGeometry {
    const count = itemCount(state);
    const visible = view.libraryVisible(frame.rows + view.footer_rows);
    if (count <= visible or visible == 0) return null;
    const top = frame.cellRect(0, view.header_rows + 1, 1, 1).y;
    const bottom = frame.content.bottom();
    const viewport = ui.Rect{ .x = frame.content.x, .y = top, .w = frame.content.w, .h = @max(8.0, bottom - top) };
    var scroll = framework.ScrollModel{
        .offset = scroll_offset,
        .content_height = @as(f32, @floatFromInt(count)) * frame.cell_h,
        .viewport_height = @as(f32, @floatFromInt(visible)) * frame.cell_h,
    };
    scroll.setOffset(scroll.offset);
    return .{ .track = .{ .x = frame.content.right() - 4, .y = viewport.y, .w = 4, .h = viewport.h }, .thumb = scroll.thumb(viewport, 4) };
}

fn drawScrollbar(frame: Layout, state: *const U.State, scroll_offset: f32) void {
    const geometry = scrollbarGeometry(frame, state, scroll_offset) orelse return;
    low.roundedRect(geometry.track, 2, low.hairline());
    if (geometry.thumb) |thumb| low.roundedRect(thumb, 2, low.accent());
}

fn drawShell(frame: Layout, font_set: *const fonts.FontSet, icon_set: *const icons.Icons, state: *const U.State, hover_nav: ?U.Screen, hover_control: ?input.Control, pressed_control: ?input.Control) void {
    low.fillRect(frame.sidebar, low.sidebar());
    low.fillRect(frame.content, low.panel());
    low.roundedRect(frame.player, 12, low.elevated());
    low.line(frame.sidebar.w, 0, frame.sidebar.w, frame.height, low.hairline(), 1);

    const compact = frame.sidebar.w < 120;
    drawString(font_set.heading, 28, 30, "forte", low.accent());
    drawString(font_set.body, 28, 56, if (compact) "MUSIC" else "MUSIC PLAYER", low.muted());

    for (layout_mod.nav_screen_order, 0..) |item, index| {
        const y = 92.0 + @as(f32, @floatFromInt(index)) * 42.0;
        const active = isActive(state.screen, item);
        if (active) {
            low.roundedRect(.{ .x = 12, .y = y - 7, .w = frame.sidebar.w - 24, .h = 32 }, 7, low.selectedPanel());
        } else if (hover_nav) |hover| {
            if (hover == item) {
                low.roundedRect(.{ .x = 12, .y = y - 7, .w = frame.sidebar.w - 24, .h = 32 }, 7, low.elevated());
            }
        }
        low.fillRect(.{ .x = 28, .y = y + 3, .w = 5, .h = 5 }, if (active) low.accent() else low.muted());
        drawString(font_set.body, if (compact) 43 else 48, y - 2, if (compact) layout_mod.navShortLabel(item) else layout_mod.navLabel(item), if (active) low.textColor() else low.muted());
    }

    // The transport panel is deliberately rendered independently of the view;
    // it stays visible while browsing every screen.
    var track: [256]u8 = undefined;
    const track_text = if (state.title.len > 0) std.fmt.bufPrint(&track, "{s}  ·  {s}", .{ state.title, state.artist }) catch "Now playing" else "Nothing playing";
    drawString(font_set.body, frame.player.x + 22, frame.player.y + 19, track_text, low.textColor());
    drawString(font_set.body, frame.player.x + 22, frame.player.y + 45, if (state.album.len > 0) state.album else "Ready", low.muted());

    const center = frame.player.x + frame.player.w * 0.54;
    const controls = [_]input.Control{ .previous, .toggle_pause, .next };
    const symbols = [_][]const u8{ "‹", "▶", "›" };
    const bitmap_slots = [_]?*const al.graphics.Bitmap{
        if (icon_set.previous) |*bitmap| bitmap else null,
        if (state.playing) if (icon_set.pause) |*bitmap| bitmap else null else if (icon_set.play) |*bitmap| bitmap else null,
        if (icon_set.next) |*bitmap| bitmap else null,
    };
    for (controls, 0..) |control, index| {
        const button = ui.Rect{ .x = center - 72 + @as(f32, @floatFromInt(index)) * 48, .y = frame.player.y + 18, .w = 40, .h = 40 };
        const button_model = framework.ButtonModel{
            .interaction = .{
                .hovered = hover_control != null and hover_control.? == control,
                .pressed = pressed_control != null and pressed_control.? == control,
            },
        };
        switch (button_model.visualState()) {
            .hovered, .focused => low.roundedRect(button, 9, low.selectedPanel()),
            .pressed => low.roundedRect(button.inset(2), 8, low.accent()),
            .disabled, .normal => {},
        }
        if (bitmap_slots[index]) |bitmap| {
            low.bitmapScaled(bitmap, button.inset(9));
        } else {
            drawString(font_set.heading, button.x + 11, button.y + 5, symbols[index], if (control == .toggle_pause and state.playing) low.accent() else low.textColor());
        }
    }
    const progress = ui.Rect{ .x = frame.player.x + 22, .y = frame.player.bottom() - 10, .w = frame.player.w - 44, .h = 3 };
    const slider = framework.SliderModel{ .value = @floatCast(state.position), .min = 0, .max = @floatCast(@max(state.duration, 1)) };
    low.bar(progress, slider.normalized(), low.hairline(), low.accent());
}

pub fn render(display: *al.Display, font_set: *const fonts.FontSet, icon_set: *const icons.Icons, state: *const U.State, art_bitmap: ?*al.graphics.Bitmap, hover_nav: ?U.Screen, hover_control: ?input.Control, pressed_control: ?input.Control, hover_cell_y: ?u16, scroll_offset: f32, cmds: []const view.Cmd) void {
    const frame = Layout.fromSize(@floatFromInt(display.getWidth()), @floatFromInt(display.getHeight()));
    low.beginFrame(display);
    drawShell(frame, font_set, icon_set, state, hover_nav, hover_control, pressed_control);
    drawScrollbar(frame, state, scroll_offset);
    low.setClip(frame.content);
    defer low.resetClip();
    for (cmds) |cmd| switch (cmd) {
        .text => |t| {
            const rect = frame.cellRect(t.x, t.y, 1, 1);
            // The shared header right-aligns its screen name. Do not apply the
            // normal left-cell inset there or the label will be clipped at the
            // content edge in narrow windows.
            const inset: f32 = if (t.y == 0 and t.x > frame.columns / 2) 0 else 12;
            drawSlice(font_set, rect.x + inset, rect.y + 2, t.s, t.style, frame.content.right() - rect.x + inset);
        },
        .bar => |b| low.bar(frame.cellRect(b.x, b.y, b.width, 1), b.frac, low.muted(), low.accent()),
        .row => |r| {
            var rect = frame.cellRect(0, r.y, frame.columns, 1);
            if (scroll_offset > 0 and r.y >= view.header_rows + 1 and r.y < frame.rows) rect.y -= scroll_offset;
            if (r.selected) {
                low.roundedRect(.{ .x = rect.x + 4, .y = rect.y + 2, .w = rect.w - 8, .h = rect.h - 4 }, 5, low.selectedPanel());
            } else if (hover_cell_y) |hover| {
                if (hover == r.y) {
                    low.roundedRect(.{ .x = rect.x + 4, .y = rect.y + 2, .w = rect.w - 8, .h = rect.h - 4 }, 5, low.elevated());
                }
            }
            drawSlice(font_set, rect.x + 12, rect.y + 2, r.s, if (r.selected) .bold else if (r.playing) .accent else .normal, rect.w - 16);
        },
        .hline => |h| {
            const rect = frame.cellRect(0, h.y, frame.columns, 1);
            low.line(rect.x, rect.y + rect.h / 2, rect.right(), rect.y + rect.h / 2, low.hairline(), 1);
        },
        .art => |a| {
            const art_rect = frame.cellRect(a.x, a.y, a.w, a.h);
            if (art_bitmap) |bitmap| {
                const destination = framework.imagePlacement(
                    @floatFromInt(bitmap.getWidth()),
                    @floatFromInt(bitmap.getHeight()),
                    art_rect,
                    .fit,
                    .center,
                    .center,
                );
                low.bitmapScaled(bitmap, destination);
            } else {
                const count = @min(a.cells.len, @as(usize, a.w) * a.h);
                for (0..count) |index| {
                    const cell = a.cells[index];
                    const cx: u16 = a.x + @as(u16, @intCast(index % a.w));
                    const cy: u16 = a.y + @as(u16, @intCast(index / a.w));
                    const rect = frame.cellRect(cx, cy, 1, 1);
                    const upper = ui.Rect{ .x = rect.x, .y = rect.y, .w = rect.w, .h = rect.h / 2.0 };
                    const lower = ui.Rect{ .x = rect.x, .y = rect.y + rect.h / 2.0, .w = rect.w, .h = rect.h / 2.0 };
                    low.fillRect(upper, al.Color.fromRgb(cell.fg[0], cell.fg[1], cell.fg[2]));
                    low.fillRect(lower, al.Color.fromRgb(cell.bg[0], cell.bg[1], cell.bg[2]));
                }
            }
        },
    };
}

test "GUI layout maps cells to content pixels" {
    const frame = Layout.fromSize(800, 600);
    const rect = frame.cellRect(2, 2, 3, 1);
    try std.testing.expectEqual(frame.content.x + 2 * frame.cell_w, rect.x);
    try std.testing.expectEqual(frame.content.y + 2 * frame.cell_h, rect.y);
    try std.testing.expect(rect.w > 0 and rect.h > 0);
}
