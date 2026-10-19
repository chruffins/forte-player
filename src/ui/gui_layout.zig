//! Pure pixel-space GUI layout. Drawing and input use these same rectangles.
//! No terminal cells, Allegro handles, or resource-dependent measurements.
const std = @import("std");
const ui = @import("ui.zig");
const U = @import("ui_state.zig");
const framework = @import("gui_framework.zig");

pub const row_height: f32 = 48;
pub const nav_screen_order = [_]U.Screen{ .albums, .library, .artists, .genres, .playlists, .queue, .now_playing, .settings };
pub const nav_count = nav_screen_order.len;

pub const Frame = struct {
    width: f32,
    height: f32,
    sidebar: ui.Rect,
    content: ui.Rect,
    header: ui.Rect,
    toolbar: ui.Rect,
    body: ui.Rect,
    player: ui.Rect,
    compact: bool,
    screen: U.Screen = .library,
    inspector: ui.Rect = .{},
    album_hero: ui.Rect = .{},
    table_header: ui.Rect = .{},

    pub fn fromSize(width: f32, height: f32) Frame {
        const w = @max(1, width);
        const h = @max(1, height);
        const compact = w < 800 or h < 500;
        const sidebar_w = @min(w * 0.20, if (compact) @as(f32, 64) else 172);
        const player_h = @min(h * 0.30, if (compact) @as(f32, 84) else 92);
        const margin: f32 = if (compact) 12 else 24;
        const content = ui.Rect{ .x = sidebar_w + margin, .y = margin, .w = @max(0, w - sidebar_w - margin * 2), .h = @max(0, h - player_h - margin - 18) };
        const header_h = @min(56, content.h * 0.25);
        const toolbar_h = @min(44, content.h * 0.22);
        return .{
            .width = w,
            .height = h,
            .compact = compact,
            .sidebar = .{ .w = sidebar_w, .h = h - player_h },
            .content = content,
            .header = .{ .x = content.x, .y = content.y, .w = content.w, .h = header_h },
            .toolbar = .{ .x = content.x + 8, .y = content.y + header_h, .w = @max(0, content.w - 16), .h = toolbar_h },
            .body = .{ .x = content.x + 8, .y = content.y + header_h + toolbar_h + 8, .w = @max(0, content.w - 16), .h = @max(0, content.h - header_h - toolbar_h - 16) },
            .player = .{ .x = 0, .y = h - player_h, .w = w, .h = player_h },
        };
    }

    /// Screen-aware geometry shared by every draw/input path.
    pub fn forScreen(width: f32, height: f32, screen: U.Screen, inspector_open: bool) Frame {
        var frame = fromSize(width, height);
        frame.screen = screen;
        if (inspector_open and width >= 1080 and height >= 560 and screen != .now_playing and screen != .settings) {
            const reserve: f32 = 272;
            frame.inspector = .{ .x = frame.content.right() - 248, .y = frame.content.y, .w = 248, .h = frame.content.h };
            frame.content.w -= reserve;
            frame.header.w -= reserve;
            frame.toolbar.w -= reserve;
            frame.body.w -= reserve;
        }
        if (screen == .album_detail) {
            const hero_h = @min(if (frame.compact) @as(f32, 96) else 184, @max(0, frame.body.h - row_height));
            frame.album_hero = .{ .x = frame.body.x, .y = frame.toolbar.y, .w = frame.body.w - 12, .h = hero_h + frame.toolbar.h };
            frame.body.y += hero_h;
            frame.body.h -= hero_h;
        }
        if ((screen == .library or screen == .album_detail or screen == .artist_detail or screen == .genre_detail or screen == .playlist_detail) and frame.body.h >= row_height + 28) {
            frame.table_header = .{ .x = frame.body.x, .y = frame.body.y, .w = frame.body.w - 12, .h = 28 };
            frame.body.y += 28;
            frame.body.h -= 28;
        }
        return frame;
    }
    pub fn rowAction(self: Frame, index: usize, offset: f32) ui.Rect {
        const r = self.rowRect(index, offset);
        return .{ .x = r.right() - 34, .y = r.y + 9, .w = 28, .h = 28 };
    }
    pub fn inspectorToggle(self: Frame) ui.Rect {
        if (self.width < 1080 or self.height < 560) return .{};
        return .{ .x = self.player.right() - 72, .y = self.player.y + 16, .w = 60, .h = 32 };
    }
    pub fn inspectorArt(self: Frame) ui.Rect {
        return .{ .x = self.inspector.x + 12, .y = self.inspector.y + 44, .w = @max(0, self.inspector.w - 24), .h = @max(0, self.inspector.w - 24) };
    }
    pub fn inspectorTab(self: Frame, index: usize) ui.Rect {
        const art = self.inspectorArt();
        return .{ .x = self.inspector.x + 12 + @as(f32, @floatFromInt(index)) * 112, .y = art.bottom() + 92, .w = 104, .h = 28 };
    }
    pub fn inspectorRows(self: Frame) ui.Rect {
        const tab = self.inspectorTab(0);
        return .{ .x = self.inspector.x + 12, .y = tab.bottom() + 12, .w = @max(0, self.inspector.w - 24), .h = @max(0, self.inspector.bottom() - tab.bottom() - 20) };
    }
    pub fn inspectorRowAt(self: Frame, x: f32, y: f32, first: usize, count: usize) ?usize {
        const rows = self.inspectorRows();
        if (self.inspector.w == 0 or !framework.containsPoint(rows, x, y)) return null;
        const relative: usize = @intFromFloat((y - rows.y) / row_height);
        const visible: usize = @intFromFloat(rows.h / row_height);
        const index = first + relative;
        return if (relative < visible and index < count) index else null;
    }
    pub fn galleryAction(self: Frame, index: usize, offset: f32, more: bool) ui.Rect {
        const card = self.rowRect(index, offset);
        return .{ .x = card.right() - (if (more) @as(f32, 36) else 74), .y = card.y + (if (self.galleryCompact()) @as(f32, 46) else card.w - 38), .w = 30, .h = 30 };
    }
    pub fn galleryCompact(self: Frame) bool {
        return self.screen == .albums and self.body.h < 180;
    }
    pub fn galleryArt(self: Frame, index: usize, offset: f32) ui.Rect {
        const card = self.rowRect(index, offset);
        const size = if (self.galleryCompact()) @as(f32, 64) else card.w;
        return .{ .x = card.x, .y = card.y, .w = size, .h = size };
    }
    pub fn playerArt(self: Frame) ui.Rect {
        if (self.compact) return .{};
        return .{ .x = 20, .y = self.player.y + 14, .w = 52, .h = 52 };
    }
    pub fn albumPlay(self: Frame) ui.Rect {
        const art = self.albumHeroArt();
        return .{ .x = art.right() + 18, .y = self.album_hero.bottom() - 38, .w = @min(100, @max(0, self.album_hero.right() - art.right() - 18)), .h = 30 };
    }
    pub fn albumHeroArt(self: Frame) ui.Rect {
        const size = @max(0, @min(self.album_hero.h - 12, self.album_hero.w * 0.34));
        return .{ .x = self.album_hero.x, .y = self.album_hero.y + 4, .w = size, .h = size };
    }
    pub fn gridColumns(self: Frame) usize {
        if (self.galleryCompact()) return 1;
        const width_columns: usize = @intFromFloat(@max(1, (self.body.w - 12 + 20) / 180));
        const max_art = @max(120, self.body.h - 78);
        const height_columns: usize = @intFromFloat(@ceil(@max(1, (self.body.w - 12 + 20) / (max_art + 20))));
        return @max(width_columns, height_columns);
    }
    pub fn gridSize(self: Frame) f32 {
        const cols: f32 = @floatFromInt(self.gridColumns());
        return @max(1, (self.body.w - 12 - (cols - 1) * 20) / cols);
    }
    pub fn itemPitch(self: Frame) f32 {
        if (self.galleryCompact()) return 88;
        return if (self.screen == .albums) self.gridSize() + 78 else row_height;
    }
    pub fn offsetFromAnchor(self: Frame, anchor: usize) f32 {
        const row = if (self.screen == .albums) anchor / self.gridColumns() else anchor;
        return @as(f32, @floatFromInt(row)) * self.itemPitch();
    }
    pub fn anchorFromOffset(self: Frame, offset: f32) usize {
        const row: usize = @intFromFloat(@max(0, offset) / self.itemPitch());
        return row * (if (self.screen == .albums) self.gridColumns() else 1);
    }
    pub fn reveal(self: Frame, index: usize, offset: f32, count: usize) f32 {
        const r = self.rowRect(index, 0);
        const item_h = @min(r.h, self.body.h);
        const next = @max(r.y + item_h - self.body.bottom(), @min(offset, r.y - self.body.y));
        return @max(0, @min(next, self.maxScroll(count)));
    }

    pub fn navRect(self: Frame, index: usize) ui.Rect {
        const top: f32 = if (self.compact) 42 else 104;
        const step = @min(46, @max(0, (self.sidebar.h - top - 8) / nav_count));
        return .{ .x = 8, .y = top + @as(f32, @floatFromInt(index)) * step, .w = @max(0, self.sidebar.w - 16), .h = @max(0, step - (if (self.compact) @as(f32, 2) else 4)) };
    }

    pub fn navScreen(self: Frame, x: f32, y: f32) ?U.Screen {
        for (nav_screen_order, 0..) |screen, i| if (framework.containsPoint(self.navRect(i), x, y)) return screen;
        return null;
    }

    pub fn visibleRows(self: Frame) usize {
        return @max(1, @as(usize, @intFromFloat(self.body.h / self.itemPitch()))) * (if (self.screen == .albums) self.gridColumns() else 1);
    }

    pub fn maxScroll(self: Frame, count: usize) f32 {
        const rows = if (self.screen == .albums) std.math.divCeil(usize, count, self.gridColumns()) catch 0 else count;
        return @max(0, @as(f32, @floatFromInt(rows)) * self.itemPitch() - self.body.h);
    }

    pub fn rowRect(self: Frame, index: usize, offset: f32) ui.Rect {
        if (self.galleryCompact()) return .{ .x = self.body.x, .y = self.body.y + @as(f32, @floatFromInt(index)) * self.itemPitch() - offset, .w = @max(0, self.body.w - 12), .h = 80 };
        if (self.screen == .albums) {
            const columns = self.gridColumns();
            const size = self.gridSize();
            return .{ .x = self.body.x + @as(f32, @floatFromInt(index % columns)) * (size + 20), .y = self.body.y + @as(f32, @floatFromInt(index / columns)) * self.itemPitch() - offset, .w = size, .h = size + 58 };
        }
        return .{ .x = self.body.x, .y = self.body.y + @as(f32, @floatFromInt(index)) * row_height - offset, .w = @max(0, self.body.w - 12), .h = row_height };
    }

    pub fn rowAt(self: Frame, x: f32, y: f32, offset: f32, count: usize) ?usize {
        if (!framework.containsPoint(self.body, x, y) or x >= self.body.right() - 12) return null;
        if (self.galleryCompact()) {
            const index: usize = @intFromFloat(@max(0, y - self.body.y + offset) / self.itemPitch());
            return if (index < count and framework.containsPoint(self.rowRect(index, offset), x, y)) index else null;
        }
        if (self.screen == .albums) {
            const column: usize = @intFromFloat((x - self.body.x) / (self.gridSize() + 20));
            const row: usize = @intFromFloat(@max(0, y - self.body.y + offset) / self.itemPitch());
            const index = row * self.gridColumns() + column;
            if (column >= self.gridColumns() or index >= count) return null;
            return if (framework.containsPoint(self.rowRect(index, offset), x, y)) index else null;
        }
        const index: usize = @intFromFloat(@max(0, y - self.body.y + offset) / row_height);
        return if (index < count) index else null;
    }

    pub fn seekTrack(self: Frame) ui.Rect {
        return .{ .x = self.player.x + 18, .y = self.player.bottom() - 14, .w = @max(0, self.player.w - 36), .h = 4 };
    }

    pub fn transportRect(self: Frame, index: usize) ui.Rect {
        const size: f32 = if (self.compact) 34 else 40;
        const step = size + 8;
        const center = self.player.x + self.player.w * 0.5;
        return .{ .x = center - step * 1.5 + @as(f32, @floatFromInt(index)) * step + 4, .y = self.player.y + (if (self.compact) @as(f32, 26) else 18), .w = size, .h = size };
    }

    pub fn volumeTrack(self: Frame) ?ui.Rect {
        if (self.player.w < 620) return null;
        return .{ .x = self.player.right() - 180, .y = self.player.y + 40, .w = 90, .h = 4 };
    }

    pub fn searchRect(self: Frame) ui.Rect {
        return .{ .x = self.toolbar.x, .y = self.toolbar.y + 4, .w = @max(0, self.toolbar.w - 100), .h = @max(0, self.toolbar.h - 8) };
    }

    pub fn toolbarButton(self: Frame) ui.Rect {
        if (self.screen == .album_detail) return .{ .x = self.header.right() - 92, .y = self.header.y + 12, .w = 92, .h = 28 };
        return .{ .x = self.toolbar.right() - @min(92, self.toolbar.w), .y = self.toolbar.y + 4, .w = @min(92, self.toolbar.w), .h = @max(0, self.toolbar.h - 8) };
    }

    pub fn nowPlaying(self: Frame) struct { art: ui.Rect, info: ui.Rect, lyrics: ui.Rect, visualizer: ui.Rect } {
        const b = self.body;
        const vis_h = if (b.h >= 240 and b.w >= 240) @min(300, b.h * 0.46) else @as(f32, 0);
        const hero_h = @max(0, b.h - vis_h - (if (vis_h > 0) @as(f32, 12) else 0));
        const art_size = @max(0, @min(if (b.w >= 560) b.w * 0.38 else b.w * 0.32, @min(320, hero_h)));
        const info = ui.Rect{ .x = b.x + art_size + 20, .y = b.y, .w = @max(0, b.w - art_size - 20), .h = hero_h };
        return .{
            .art = .{ .x = b.x, .y = b.y, .w = art_size, .h = art_size },
            .info = info,
            .lyrics = .{ .x = info.x, .y = info.y + @min(150, info.h), .w = info.w, .h = @max(0, info.h - 150) },
            .visualizer = .{ .x = b.x, .y = b.bottom() - vis_h, .w = b.w, .h = vis_h },
        };
    }

    pub fn visualizerPlot(self: Frame) ui.Rect {
        const panel = self.nowPlaying().visualizer;
        if (panel.h == 0) return .{};
        return .{ .x = panel.x + 8, .y = panel.y + 32, .w = @max(0, panel.w - 16), .h = @max(0, panel.h - 40) };
    }
    pub fn visualizerButton(self: Frame, index: usize) ui.Rect {
        const panel = self.nowPlaying().visualizer;
        if (panel.h == 0) return .{};
        return .{ .x = panel.right() - 68 + @as(f32, @floatFromInt(index)) * 32, .y = panel.y + 4, .w = 28, .h = 24 };
    }

    pub fn dialog(self: Frame, max_width: f32, desired_height: f32) Dialog {
        const w = @max(0, @min(max_width, self.width - 24));
        const h = @max(0, @min(desired_height, self.height - 24));
        const card = ui.Rect{ .x = (self.width - w) / 2, .y = (self.height - h) / 2, .w = w, .h = h };
        return .{
            .card = card,
            .body = .{ .x = card.x + 16, .y = card.y + 76, .w = @max(0, w - 32), .h = @max(0, h - 136) },
            .footer = .{ .x = card.x + 16, .y = card.bottom() - 48, .w = @max(0, w - 32), .h = 32 },
        };
    }
};

/// A form/list inside a bounded dialog. Keyboard focus scrolls into view.
pub const Dialog = struct {
    card: ui.Rect,
    body: ui.Rect,
    footer: ui.Rect,

    pub fn visibleRows(self: Dialog) usize {
        return @max(1, @as(usize, @intFromFloat(self.body.h / row_height)));
    }
    pub fn firstRow(self: Dialog, active: usize) usize {
        return active -| (self.visibleRows() - 1);
    }
    pub fn row(self: Dialog, index: usize, first: usize) ui.Rect {
        return .{ .x = self.body.x, .y = self.body.y + @as(f32, @floatFromInt(index -| first)) * row_height, .w = self.body.w, .h = row_height - 4 };
    }
    pub fn rowAt(self: Dialog, x: f32, y: f32, first: usize, count: usize) ?usize {
        if (!framework.containsPoint(self.body, x, y)) return null;
        const relative: usize = @intFromFloat((y - self.body.y) / row_height);
        const index = first + relative;
        return if (index < count and relative < self.visibleRows()) index else null;
    }
    pub fn button(self: Dialog, index: usize) ui.Rect {
        const w = @min(112, (self.footer.w - 8) / 2);
        return .{ .x = self.footer.right() - w * 2 - 8 + @as(f32, @floatFromInt(index)) * (w + 8), .y = self.footer.y, .w = @max(0, w), .h = self.footer.h };
    }
};

pub const ScrollbarGeometry = struct { track: ui.Rect, thumb: ?ui.Rect };
pub fn scrollbar(frame: Frame, count: usize, offset: f32) ?ScrollbarGeometry {
    if (frame.body.h <= 0 or frame.maxScroll(count) <= 0) return null;
    var model = framework.ScrollModel{ .offset = offset, .content_height = frame.maxScroll(count) + frame.body.h, .viewport_height = frame.body.h };
    model.setOffset(offset);
    return .{ .track = .{ .x = frame.body.right() - 6, .y = frame.body.y, .w = 6, .h = frame.body.h }, .thumb = model.thumb(frame.body, 6) };
}

pub fn navLabel(screen: U.Screen) []const u8 {
    return switch (screen) {
        .now_playing => "Listening",
        .library => "Tracks",
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
        .library => "TRK",
        .albums, .album_detail => "ALB",
        .artists, .artist_detail => "ART",
        .genres, .genre_detail => "GEN",
        .playlists, .playlist_detail => "LIST",
        .queue => "QUE",
        .settings => "SET",
    };
}

pub fn itemCount(state: *const U.State) usize {
    return switch (state.screen) {
        .library => state.row_count,
        .albums => state.albums.len,
        .album_detail => state.album_detail_tracks.len,
        .artists => state.artists.len,
        .artist_detail => state.artist_detail_tracks.len,
        .genres => state.genres.len,
        .genre_detail => state.genre_detail_tracks.len,
        .playlists => state.playlists.len,
        .playlist_detail => state.playlist_detail_tracks.len,
        .queue => state.queue.len,
        else => 0,
    };
}
pub fn modalOpen(state: *const U.State) bool {
    return state.context_menu_open or state.metadata_editing or state.playlist_modal_open or state.playlist_picker_open;
}

pub fn moveGridSelection(selection: usize, delta: i64, count: usize) usize {
    if (count == 0) return 0;
    const step: usize = @intCast(@min(@abs(delta), std.math.maxInt(usize)));
    const current = @min(selection, count - 1);
    return if (delta >= 0) @min(current +| step, count - 1) else current -| step;
}

pub const settings_count: usize = 15;
pub fn scrollCount(state: *const U.State) usize {
    return if (state.screen == .settings) settings_count + state.health_findings.len else itemCount(state);
}
pub fn settingsScroll(frame: Frame, offset: f32, active_field: i8, count: usize) f32 {
    var value = @max(0, @min(offset, frame.maxScroll(count)));
    if (active_field >= 0 and active_field < 3) {
        const top = @as(f32, @floatFromInt(6 + @as(usize, @intCast(active_field)))) * row_height;
        value = @max(top + row_height - frame.body.h, @min(value, top));
    }
    return @max(0, @min(value, frame.maxScroll(count)));
}

test "responsive GUI regions never overlap the transport" {
    for ([_][2]f32{ .{ 360, 300 }, .{ 600, 480 }, .{ 960, 600 }, .{ 1440, 1000 } }) |size| {
        const f = Frame.fromSize(size[0], size[1]);
        try std.testing.expect(f.content.bottom() < f.player.y);
        try std.testing.expect(f.body.bottom() <= f.content.bottom());
        try std.testing.expect(f.body.x >= f.sidebar.right());
        for (nav_screen_order, 0..) |screen, i| {
            const r = f.navRect(i);
            try std.testing.expect(r.bottom() <= f.sidebar.bottom());
            try std.testing.expectEqual(screen, f.navScreen(r.x + 1, r.y + 1));
        }
        for (0..3) |i| {
            const r = f.transportRect(i);
            try std.testing.expect(r.bottom() < f.seekTrack().y);
            try std.testing.expect(f.player.contains(r.x, r.y));
        }
    }
}
test "list geometry and hit testing share fractional scroll offsets" {
    const f = Frame.fromSize(960, 600);
    const r = f.rowRect(7, 219.5);
    try std.testing.expectEqual(@as(?usize, 7), f.rowAt(r.x + 2, r.y + 10, 219.5, 100));
    try std.testing.expect(f.rowAt(r.x, f.body.y - 1, 219.5, 100) == null);
    const s = scrollbar(f, 100, f.maxScroll(100)).?;
    try std.testing.expectApproxEqAbs(s.track.bottom(), s.thumb.?.bottom(), 0.01);
}
test "small dialogs keep focused rows and buttons inside the window" {
    const f = Frame.fromSize(360, 300);
    const d = f.dialog(700, 600);
    const first = d.firstRow(7);
    const r = d.row(7, first);
    try std.testing.expect(r.bottom() <= d.body.bottom());
    try std.testing.expectEqual(@as(?usize, 7), d.rowAt(r.x + 1, r.y + 1, first, 8));
    for (0..2) |i| try std.testing.expect(d.card.contains(d.button(i).right(), d.button(i).bottom()));
}
