//! Native GUI renderer. Semantic state is shared with the TUI, geometry is not.
//! Every interactive rectangle comes from gui_layout; no terminal draw commands.
const std = @import("std");
const al = @import("allegro");
const ui = @import("ui.zig");
const low = @import("render.zig");
const fonts = @import("gui_fonts.zig");
const layout = @import("gui_layout.zig");
const U = @import("ui_state.zig");
const input = @import("gui_input.zig");
const framework = @import("gui_framework.zig");
const gpu_vis = @import("gui_visualizer.zig");
const artwork = @import("gui_artwork.zig");
pub const Layout = layout.Frame;
pub const TrackRow = struct { title: []const u8, artist: []const u8, album: []const u8, duration: i64 };

/// Transient frontend state, kept separate from the shared playback snapshot.
pub const Interaction = struct {
    hover_nav: ?U.Screen = null,
    hover_control: ?input.Control = null,
    pressed_control: ?input.Control = null,
    hover_row: ?usize = null,
    scroll_offset: f32 = 0,
    search_cursor: ?usize = null,
    metadata_cursor: usize = 0,
    visualizer_mode: gpu_vis.Mode = .mirror,
    inspector_open: bool = true,
    inspector_lyrics: bool = false,
    album_actions: bool = false,
};

// Fixed cache: font fitting must not allocate or measure every possible prefix.
const Fit = struct { font: usize = 0, hash: u64 = 0, width: i32 = 0, len: usize = 0 };
var fits: [256]Fit = @splat(.{});
var next_fit: usize = 0;
fn text(font: al.font.Font, r: ui.Rect, value: []const u8, tint: al.Color) void {
    if (r.w <= 0 or r.h <= 0 or value.len == 0) return;
    const previous_clip = low.pushClip(r);
    defer low.popClip(previous_clip);
    var buf: [1024:0]u8 = undefined;
    var n: usize = @min(value.len, buf.len - 1);
    while (n > 0 and n < value.len and framework.isUtf8Continuation(value[n])) n -= 1;
    @memcpy(buf[0..n], value[0..n]);
    buf[n] = 0;
    const hash = std.hash.Wyhash.hash(0, value[0..n]);
    const width: i32 = @intFromFloat(r.w);
    const id = @intFromPtr(font.data);
    var cached: ?usize = null;
    for (fits) |f| if (f.font == id and f.hash == hash and f.width == width) {
        cached = f.len;
        break;
    };
    if (cached) |len| {
        n = len;
    } else {
        var boundaries: [1024]usize = undefined;
        boundaries[0] = 0;
        var count: usize = 1;
        var i: usize = 0;
        while (i < n) {
            i += 1;
            while (i < n and framework.isUtf8Continuation(buf[i])) i += 1;
            boundaries[count] = i;
            count += 1;
        }
        var lo: usize = 0;
        var hi = count - 1;
        while (lo < hi) {
            const mid = lo + (hi - lo + 1) / 2;
            const end = boundaries[mid];
            const saved = buf[end];
            buf[end] = 0;
            const ok = font.getTextWidth(buf[0..end :0]) <= width;
            buf[end] = saved;
            if (ok) lo = mid else hi = mid - 1;
        }
        n = boundaries[lo];
        fits[next_fit] = .{ .font = id, .hash = hash, .width = width, .len = n };
        next_fit = (next_fit + 1) % fits.len;
    }
    buf[n] = 0;
    font.drawTextAt(tint, r.x, r.y + @max(0, (r.h - @as(f32, @floatFromInt(font.getLineHeight()))) / 2), 0, buf[0..n :0]);
}
fn label(f: *const fonts.FontSet, r: ui.Rect, value: []const u8) void {
    text(f.body, r, value, low.textColor());
}
fn muted(f: *const fonts.FontSet, r: ui.Rect, value: []const u8) void {
    text(f.body, r, value, low.muted());
}
fn heading(f: *const fonts.FontSet, r: ui.Rect, value: []const u8) void {
    text(f.heading, r, value, low.textColor());
}
fn button(f: *const fonts.FontSet, r: ui.Rect, value: []const u8, active: bool) void {
    if (r.w < 1 or r.h < 1) return;
    low.chromeButton(r, active);
    text(if (r.h < 28 or r.w < 48) f.small else f.body, .{ .x = r.x + 6, .y = r.y, .w = r.w - 12, .h = r.h }, value, low.buttonInk());
}
fn lineBox(r: ui.Rect, tint: al.Color) void {
    low.line(r.x, r.y, r.right(), r.y, tint, 1);
    low.line(r.right(), r.y, r.right(), r.bottom(), tint, 1);
    low.line(r.right(), r.bottom(), r.x, r.bottom(), tint, 1);
    low.line(r.x, r.bottom(), r.x, r.y, tint, 1);
}
fn field(f: *const fonts.FontSet, r: ui.Rect, name: []const u8, value: []const u8, active: bool, cursor: ?usize) void {
    const title = ui.Rect{ .x = r.x + 8, .y = r.y, .w = r.w - 16, .h = 18 };
    const box = ui.Rect{ .x = r.x + 4, .y = r.y + 18, .w = @max(0, r.w - 8), .h = @max(0, r.h - 20) };
    text(f.small, title, name, low.muted());
    low.roundedRect(box, 4, low.background());
    if (active) lineBox(box, low.accent());
    // Keep a bounded suffix around the cursor visible; never split UTF-8.
    var display = value;
    if (active and cursor != null) {
        const end = @min(cursor.?, value.len);
        const glyphs = framework.glyphCount(value[0..end]);
        const capacity: usize = @intFromFloat(@max(1, box.w / 12));
        if (glyphs > capacity -| 1) {
            const prefix = framework.truncate(value, glyphs - (capacity -| 1));
            display = value[prefix.len..];
        }
        var with_cursor: [1024]u8 = undefined;
        const pos = end - (value.len - display.len);
        const shown = std.fmt.bufPrint(&with_cursor, "{s}|{s}", .{ display[0..pos], display[pos..] }) catch display;
        text(f.small, box.inset(3), shown, low.textColor());
    } else text(f.small, box.inset(3), if (display.len > 0) display else "—", low.textColor());
}

pub fn volumeTrack(frame: Layout) ?ui.Rect {
    return frame.volumeTrack();
}
pub fn scrollbarGeometry(frame: Layout, state: *const U.State, offset: f32) ?layout.ScrollbarGeometry {
    return layout.scrollbar(frame, layout.scrollCount(state), offset);
}
pub fn contextMenuCard(frame: Layout) ui.Rect {
    return frame.dialog(480, 456).card;
}
pub fn contextMenuActionAt(frame: Layout, x: f32, y: f32, active: usize) ?usize {
    const d = frame.dialog(480, 456);
    return d.rowAt(x, y, d.firstRow(active), 6);
}
pub fn metadataEditorCard(frame: Layout) ui.Rect {
    return frame.dialog(680, 580).card;
}
pub fn metadataEditorFieldAt(frame: Layout, x: f32, y: f32, active: usize) ?usize {
    const d = frame.dialog(680, 580);
    return d.rowAt(x, y, d.firstRow(active), 8);
}
pub fn metadataEditorFieldRect(frame: Layout, index: usize, active: usize) ui.Rect {
    const d = frame.dialog(680, 580);
    return d.row(index, d.firstRow(active));
}
pub fn metadataEditorSaveRect(frame: Layout) ui.Rect {
    return frame.dialog(680, 580).button(0);
}
pub fn metadataEditorCancelRect(frame: Layout) ui.Rect {
    return frame.dialog(680, 580).button(1);
}
pub fn playlistPickerCard(frame: Layout) ui.Rect {
    return frame.dialog(560, 540).card;
}
pub fn playlistPickerVisibleRows(frame: Layout) usize {
    return frame.dialog(560, 540).visibleRows();
}
pub fn playlistPickerRowAt(frame: Layout, x: f32, y: f32, scroll: usize) ?usize {
    return frame.dialog(560, 540).rowAt(x, y, scroll, std.math.maxInt(usize));
}
pub fn playlistPickerDoneRect(frame: Layout) ui.Rect {
    return frame.dialog(560, 540).button(1);
}
pub fn playlistModalCard(frame: Layout) ui.Rect {
    return frame.dialog(540, 276).card;
}
pub fn playlistModalInputRect(frame: Layout) ui.Rect {
    const body = frame.dialog(540, 276).body;
    return .{ .x = body.x, .y = body.y, .w = body.w, .h = @min(56, body.h) };
}
pub fn playlistModalSaveRect(frame: Layout) ui.Rect {
    return frame.dialog(540, 276).button(0);
}
pub fn playlistModalCancelRect(frame: Layout) ui.Rect {
    return frame.dialog(540, 276).button(1);
}

fn filter(state: *const U.State) []const u8 {
    return switch (state.screen) {
        .library => state.library_filter,
        .albums => state.album_filter,
        else => state.filter,
    };
}
fn searchable(screen: U.Screen) bool {
    return switch (screen) {
        .library, .albums, .artists, .genres, .playlists => true,
        else => false,
    };
}
fn activeNav(screen: U.Screen) U.Screen {
    return switch (screen) {
        .album_detail => .albums,
        .artist_detail => .artists,
        .genre_detail => .genres,
        .playlist_detail => .playlists,
        else => screen,
    };
}
fn shell(frame: Layout, f: *const fonts.FontSet, s: *const U.State, bitmap: ?*const al.graphics.Bitmap, interaction: Interaction) void {
    const hover_nav = interaction.hover_nav;
    const hover_control = interaction.hover_control;
    const pressed = interaction.pressed_control;
    low.verticalGradient(frame.sidebar, low.sidebarTop(), low.sidebarBottom());
    low.line(frame.sidebar.right() - 1, 0, frame.sidebar.right() - 1, frame.sidebar.bottom(), al.Color.fromRgb(7, 37, 76), 2);
    text(if (frame.compact) f.small else f.heading, .{ .x = 12, .y = 8, .w = frame.sidebar.w - 24, .h = 30 }, "forte", al.Color.fromRgb(255, 255, 255));
    if (!frame.compact) text(f.small, .{ .x = 18, .y = 72, .w = frame.sidebar.w - 36, .h = 20 }, "YOUR COLLECTION", low.muted());
    for (layout.nav_screen_order, 0..) |screen, i| {
        const r = frame.navRect(i);
        const active = activeNav(s.screen) == screen;
        if (active) {
            low.roundedRect(r.translate(0, 2), 6, al.Color.fromRgb(5, 34, 74));
            low.verticalGradient(r, al.Color.fromRgb(126, 193, 242), al.Color.fromRgb(36, 111, 183));
            low.chromeFrame(r, 6);
        } else if (hover_nav != null and hover_nav.? == screen) {
            low.roundedRect(r, 6, al.Color.fromRgba(222, 241, 255, 44));
        }
        text(if (frame.compact) f.nav else f.body, .{ .x = r.x + 6, .y = r.y, .w = r.w - 12, .h = r.h }, if (frame.compact) layout.navShortLabel(screen) else layout.navLabel(screen), if (active) al.Color.fromRgb(255, 255, 255) else al.Color.fromRgb(230, 242, 254));
    }
    // A beveled pale-blue content well evokes the framed panels of classic WMP.
    low.chromePanel(frame.content, 10, low.panel());
    heading(f, .{ .x = frame.header.x + 12, .y = frame.header.y, .w = frame.header.w - 24, .h = frame.header.h }, switch (s.screen) {
        .album_detail => "Album",
        .artist_detail => s.artist_detail_name,
        .genre_detail => s.genre_detail_name,
        .playlist_detail => s.playlist_detail_name,
        else => layout.navLabel(s.screen),
    });
    if (searchable(s.screen)) {
        low.roundedRect(frame.searchRect(), 4, al.Color.fromRgb(255, 255, 255));
        lineBox(frame.searchRect(), al.Color.fromRgb(139, 166, 190));
        const searching = s.library_searching or s.album_searching or s.searching;
        var search_buf: [1024]u8 = undefined;
        const query = filter(s);
        const search_text = if (interaction.search_cursor) |cursor| blk: {
            const pos = @min(query.len, cursor);
            break :blk std.fmt.bufPrint(&search_buf, "{s}|{s}", .{ query[0..pos], query[pos..] }) catch query;
        } else if (query.len > 0) query else "Search your collection…";
        text(f.body, frame.searchRect().inset(6), search_text, if (searching) low.accent() else low.muted());
        if (searching) lineBox(frame.searchRect(), low.accent());
    } else if (s.screen != .album_detail) muted(f, frame.searchRect().inset(4), switch (s.screen) {
        .queue => "Up next · drag to rearrange",
        .settings => "Playback & integrations",
        .now_playing => if (s.playing) "Enjoy the music." else "Choose something to listen to.",
        else => "Your collection",
    });
    button(f, frame.toolbarButton(), switch (s.screen) {
        .albums => s.album_sort_label,
        .playlists => "New",
        .queue => "Save",
        .settings => "Rescan",
        .now_playing, .library => "Actions",
        else => "Back",
    }, false);
    low.line(frame.body.x, frame.body.y - 4, frame.body.right(), frame.body.y - 4, low.hairline(), 1);

    low.metallicFascia(frame.player, 12);
    const title_x = if (frame.compact) frame.player.x + 16 else frame.playerArt().right() + 12;
    const left_w = @max(0, frame.transportRect(0).x - title_x - 16);
    if (!frame.compact) {
        coverSquare(f, frame.playerArt(), bitmap, s.album, 0);
        low.chromeFrame(frame.playerArt(), 3);
        low.lcdWindow(.{ .x = title_x - 6, .y = frame.player.y + 12, .w = @max(0, left_w + 12), .h = 58 }, 7);
    }
    if (frame.compact) {
        label(f, .{ .x = frame.player.x + 16, .y = frame.player.y + 4, .w = frame.player.w - 32, .h = 20 }, if (s.title.len > 0) s.title else "Nothing playing");
    } else {
        label(f, .{ .x = title_x, .y = frame.player.y + 16, .w = left_w, .h = 26 }, if (s.path.len > 0) s.title else "Nothing playing");
        text(f.small, .{ .x = title_x, .y = frame.player.y + 42, .w = left_w, .h = 22 }, s.artist, low.muted());
    }
    const controls = [_]input.Control{ .previous, .toggle_pause, .next };
    for (controls, 0..) |control, i| {
        const r = frame.transportRect(i);
        const active = pressed != null and pressed.? == control;
        const hover = hover_control != null and hover_control.? == control;
        low.chromeButton(r, active or hover or (i == 1 and s.playing));
        transportGlyph(r, i, s.playing, low.buttonInk());
    }
    button(f, frame.inspectorToggle(), "Panel", interaction.inspector_open);
    if (frame.volumeTrack()) |track| {
        muted(f, .{ .x = track.x, .y = track.y - 24, .w = track.w, .h = 20 }, "VOLUME");
        low.metallicBar(track, s.volume);
        low.chromeButton(.{ .x = track.x + track.w * s.volume - 7, .y = track.y - 7, .w = 14, .h = 18 }, false);
    }
    const progress: f32 = if (s.duration > 0) @floatCast(s.position / s.duration) else 0;
    low.metallicBar(frame.seekTrack(), progress);
    if (!frame.compact) {
        var pos: [24]u8 = undefined;
        var dur: [24]u8 = undefined;
        var buf: [64]u8 = undefined;
        text(f.small, .{ .x = frame.player.x + frame.player.w / 2 - 64, .y = frame.player.bottom() - 34, .w = 128, .h = 18 }, std.fmt.bufPrint(&buf, "{s} / {s}", .{ durationText(&pos, s.position), durationText(&dur, s.duration) }) catch "", low.muted());
    }
}

fn transportGlyph(r: ui.Rect, index: usize, playing: bool, tint: al.Color) void {
    const cx = r.x + r.w / 2;
    const cy = r.y + r.h / 2;
    if (index == 1 and playing) {
        low.fillRect(.{ .x = cx - 6, .y = cy - 7, .w = 4, .h = 14 }, tint);
        low.fillRect(.{ .x = cx + 2, .y = cy - 7, .w = 4, .h = 14 }, tint);
    } else if (index == 0) {
        al.primitives.drawFilledTriangle(cx + 5, cy - 7, cx - 4, cy, cx + 5, cy + 7, tint);
        low.fillRect(.{ .x = cx - 7, .y = cy - 7, .w = 2, .h = 14 }, tint);
    } else {
        al.primitives.drawFilledTriangle(cx - 4, cy - 7, cx + 6, cy, cx - 4, cy + 7, tint);
        if (index == 2) low.fillRect(.{ .x = cx + 8, .y = cy - 7, .w = 2, .h = 14 }, tint);
    }
}

pub fn durationText(buf: []u8, seconds: f64) []const u8 {
    const value: u64 = @intFromFloat(if (std.math.isFinite(seconds)) @max(0, @min(seconds, 359999)) else 0);
    return std.fmt.bufPrint(buf, "{d}:{d:0>2}", .{ value / 60, value % 60 }) catch "0:00";
}

fn coverSquare(f: *const fonts.FontSet, r: ui.Rect, bitmap: ?*const al.graphics.Bitmap, name: []const u8, id: i64) void {
    if (r.w <= 0 or r.h <= 0) return;
    const previous = low.pushClip(r);
    defer low.popClip(previous);
    const tones = [_][3]u8{ .{ 164, 190, 215 }, .{ 135, 169, 203 }, .{ 184, 204, 220 }, .{ 151, 180, 207 }, .{ 193, 205, 218 }, .{ 126, 157, 190 } };
    const tone = tones[@as(u64, @bitCast(id)) % tones.len];
    low.fillRect(r, al.Color.fromRgb(tone[0], tone[1], tone[2]));
    if (bitmap) |b| {
        const mutable = @constCast(b);
        low.bitmapScaled(b, framework.imagePlacement(@floatFromInt(mutable.getWidth()), @floatFromInt(mutable.getHeight()), r, .fit, .center, .center));
    } else {
        const trimmed = std.mem.trim(u8, name, " \t\r\n");
        const monogram = if (trimmed.len > 0) framework.truncate(trimmed, 2) else "fp";
        text(if (r.w >= 96) f.display else f.small, .{ .x = r.x + r.w * 0.16, .y = r.y + r.h * 0.28, .w = r.w * 0.7, .h = r.h * 0.44 }, monogram, low.textColor());
        if (r.w >= 120) text(f.small, .{ .x = r.x + r.w * 0.16, .y = r.bottom() - 30, .w = r.w * 0.7, .h = 20 }, "NO ARTWORK", low.muted());
    }
}

fn gallery(frame: Layout, f: *const fonts.FontSet, s: *const U.State, covers: *const artwork.Cache, offset: f32, hover: ?usize) void {
    if (s.albums.len == 0) {
        heading(f, .{ .x = frame.body.x + 12, .y = frame.body.y + 24, .w = frame.body.w - 24, .h = 42 }, if (filter(s).len > 0) "No albums found" else "Your collection starts here");
        muted(f, .{ .x = frame.body.x + 12, .y = frame.body.y + 70, .w = frame.body.w - 24, .h = 32 }, if (filter(s).len > 0) "Try another album or artist name." else "Add music to your configured folder, then rescan in Settings.");
        return;
    }
    const first = frame.anchorFromOffset(offset);
    const end = @min(s.albums.len, first + frame.visibleRows() + frame.gridColumns() * 2);
    low.setClip(frame.body);
    for (first..end) |index| {
        const album = s.albums[index];
        const card = frame.rowRect(index, offset);
        const art = frame.galleryArt(index, offset);
        low.fillRect(art.translate(0, 2), low.hairline());
        coverSquare(f, art, covers.get(album.id), album.title, album.id);
        const hovered = hover != null and hover.? == index;
        if (s.selection == index or hovered) lineBox(art.inset(1), if (s.selection == index) low.accent() else low.muted());
        const compact = frame.galleryCompact();
        const label_x = if (compact) art.right() + 12 else card.x;
        const label_w = if (compact) @max(0, card.right() - label_x) else card.w;
        label(f, .{ .x = label_x, .y = if (compact) card.y + 2 else art.bottom() + 8, .w = label_w, .h = 23 }, album.title);
        text(f.small, .{ .x = label_x, .y = if (compact) card.y + 28 else art.bottom() + 31, .w = label_w, .h = 21 }, album.artist, low.muted());
        if (hovered or s.selection == index) {
            button(f, frame.galleryAction(index, offset, false), ">", true);
            button(f, frame.galleryAction(index, offset, true), "…", false);
        }
        if (s.playing_album_id == album.id and !compact) {
            low.roundedRect(.{ .x = art.x + 6, .y = art.y + 6, .w = 62, .h = 24 }, 3, low.panel());
            text(f.small, .{ .x = art.x + 12, .y = art.y + 6, .w = 52, .h = 24 }, "Playing", low.accent());
        }
    }
}

fn albumHero(frame: Layout, f: *const fonts.FontSet, s: *const U.State, covers: *const artwork.Cache) void {
    low.setClip(frame.album_hero);
    var album: ?U.AlbumRow = null;
    for (s.albums) |row| if (row.id == s.album_detail_id) {
        album = row;
        break;
    };
    const art = frame.albumHeroArt();
    const title = if (album) |a| a.title else "Album";
    coverSquare(f, art, covers.get(s.album_detail_id), title, s.album_detail_id);
    const info = ui.Rect{ .x = art.right() + 18, .y = art.y, .w = @max(0, frame.album_hero.right() - art.right() - 18), .h = art.h };
    text(if (frame.compact) f.body else f.heading, .{ .x = info.x, .y = info.y, .w = info.w, .h = if (frame.compact) @as(f32, 24) else 42 }, title, low.textColor());
    if (frame.album_hero.h >= 110) text(f.small, .{ .x = info.x, .y = info.y + 44, .w = info.w, .h = 22 }, if (album) |a| a.artist else "", low.muted());
    if (info.h > 120) {
        var detail: [96]u8 = undefined;
        const year = if (album) |a| a.year else 0;
        const summary = if (year > 0) std.fmt.bufPrint(&detail, "{d} · {d} tracks", .{ year, s.album_detail_tracks.len }) catch "" else std.fmt.bufPrint(&detail, "{d} tracks", .{s.album_detail_tracks.len}) catch "";
        text(f.small, .{ .x = info.x, .y = info.y + 74, .w = info.w, .h = 24 }, summary, low.muted());
    }
    button(f, frame.albumPlay(), "Play album", true);
}

fn inspector(frame: Layout, f: *const fonts.FontSet, s: *const U.State, bitmap: ?*const al.graphics.Bitmap, show_lyrics: bool) void {
    const r = frame.inspector;
    low.setClip(r);
    text(f.small, .{ .x = r.x + 12, .y = r.y + 4, .w = r.w - 24, .h = 28 }, "NOW PLAYING", low.muted());
    const art = frame.inspectorArt();
    coverSquare(f, art, bitmap, s.album, 0);
    label(f, .{ .x = art.x, .y = art.bottom() + 14, .w = art.w, .h = 26 }, if (s.path.len > 0) s.title else "Nothing playing");
    text(f.small, .{ .x = art.x, .y = art.bottom() + 42, .w = art.w, .h = 22 }, s.artist, low.muted());
    text(f.small, .{ .x = art.x, .y = art.bottom() + 64, .w = art.w, .h = 20 }, s.album, low.muted());
    button(f, frame.inspectorTab(0), "Queue", !show_lyrics);
    button(f, frame.inspectorTab(1), "Lyrics", show_lyrics);
    const rows = frame.inspectorRows();
    const previous = low.pushClip(rows);
    defer low.popClip(previous);
    const visible: usize = @intFromFloat(rows.h / layout.row_height);
    if (show_lyrics) {
        if (s.lyrics.len == 0) text(f.small, rows, "No local lyrics", low.muted()) else {
            const first = (s.active_lyric orelse 0) -| 1;
            for (first..@min(s.lyrics.len, first + visible)) |i| text(f.small, .{ .x = rows.x, .y = rows.y + @as(f32, @floatFromInt(i - first)) * layout.row_height, .w = rows.w, .h = layout.row_height }, s.lyrics[i].text, if (s.active_lyric != null and s.active_lyric.? == i) low.accent() else low.muted());
        }
    } else {
        if (s.queue.len == 0) text(f.small, rows, "Your queue is empty", low.muted());
        const first = (s.queue_current_index orelse 0) -| 1;
        for (first..@min(s.queue.len, first + visible)) |i| {
            const y = rows.y + @as(f32, @floatFromInt(i - first)) * layout.row_height;
            text(f.small, .{ .x = rows.x, .y = y, .w = rows.w, .h = 24 }, s.queue[i].title, if (s.queue_current_index != null and s.queue_current_index.? == i) low.accent() else low.textColor());
            text(f.small, .{ .x = rows.x, .y = y + 24, .w = rows.w, .h = 20 }, s.queue[i].artist, low.muted());
        }
    }
}

fn rowLabels(s: *const U.State, index: usize, library: []const TrackRow, detail: *[256]u8) struct { title: []const u8, subtitle: []const u8, playing: bool } {
    const tracks: []const U.AlbumTrackRow = switch (s.screen) {
        .album_detail => s.album_detail_tracks,
        .artist_detail => s.artist_detail_tracks,
        .genre_detail => s.genre_detail_tracks,
        .playlist_detail => s.playlist_detail_tracks,
        else => &.{},
    };
    if (index < tracks.len) {
        const t = tracks[index];
        return .{ .title = t.title, .subtitle = std.fmt.bufPrint(detail, "{s} · {d}:{d:0>2}", .{ t.artist, @divTrunc(t.duration, 60), @mod(t.duration, 60) }) catch t.artist, .playing = if (s.screen == .album_detail) s.album_detail_playing != null and s.album_detail_playing.? == index else false };
    }
    return switch (s.screen) {
        .library => .{ .title = if (index < library.len) library[index].title else "", .subtitle = "", .playing = s.playing_index != null and s.playing_index.? == index },
        .albums => .{ .title = s.albums[index].title, .subtitle = std.fmt.bufPrint(detail, "{s} · {d} · {d} tracks", .{ s.albums[index].artist, s.albums[index].year, s.albums[index].track_count }) catch "", .playing = s.albums[index].id == s.playing_album_id },
        .artists => .{ .title = s.artists[index].name, .subtitle = std.fmt.bufPrint(detail, "{d} albums · {d} tracks", .{ s.artists[index].album_count, s.artists[index].song_count }) catch "", .playing = false },
        .genres => .{ .title = s.genres[index].name, .subtitle = std.fmt.bufPrint(detail, "{d} tracks", .{s.genres[index].song_count}) catch "", .playing = false },
        .playlists => .{ .title = s.playlists[index].name, .subtitle = std.fmt.bufPrint(detail, "{d} tracks{s}", .{ s.playlists[index].song_count, if (s.playlists[index].is_smart) " · Smart playlist" else "" }) catch "", .playing = false },
        .queue => .{ .title = s.queue[index].title, .subtitle = s.queue[index].artist, .playing = s.queue_current_index != null and s.queue_current_index.? == index },
        else => .{ .title = "", .subtitle = "", .playing = false },
    };
}
fn list(frame: Layout, f: *const fonts.FontSet, s: *const U.State, library: []const TrackRow, offset: f32, hover: ?usize) void {
    const count = layout.itemCount(s);
    if (count == 0) {
        heading(f, frame.body.inset(16), if (filter(s).len > 0) "No matches" else "Nothing here yet");
        return;
    }
    const first: usize = @intFromFloat(offset / layout.row_height);
    const end = @min(count, first + frame.visibleRows() + 2);
    low.setClip(frame.body);
    for (first..end) |index| {
        const r = frame.rowRect(index, offset);
        const active = s.selection == index;
        if (hover != null and hover.? == index) low.roundedRect(r.inset(2), 3, low.elevated());
        if (active) lineBox(r.inset(2), low.hairline());
        var buf: [256]u8 = undefined;
        const row = rowLabels(s, index, library, &buf);
        const inset: f32 = if (s.screen == .queue) 32 else 12;
        if (s.screen == .queue) muted(f, .{ .x = r.x + 6, .y = r.y, .w = 22, .h = r.h }, "≡");
        if (row.playing) low.roundedRect(.{ .x = r.x + 3, .y = r.y + 12, .w = 3, .h = 24 }, 1.5, low.accent());
        const detail_tracks: []const U.AlbumTrackRow = switch (s.screen) {
            .album_detail => s.album_detail_tracks,
            .artist_detail => s.artist_detail_tracks,
            .genre_detail => s.genre_detail_tracks,
            .playlist_detail => s.playlist_detail_tracks,
            else => &.{},
        };
        const is_track = s.screen == .library or detail_tracks.len > 0;
        if (is_track and r.w >= 340) {
            const library_track = if (s.screen == .library and index < library.len) library[index] else null;
            const track = if (index < detail_tracks.len) detail_tracks[index] else null;
            const columns = trackColumns(r, s.screen == .library);
            text(f.body, columns.title, row.title, if (row.playing) low.accent() else low.textColor());
            text(f.small, columns.artist, if (library_track) |t| t.artist else if (track) |t| t.artist else "", low.muted());
            if (library_track) |t| text(f.small, columns.album, t.album, low.muted());
            var duration: [24]u8 = undefined;
            text(f.small, columns.duration, durationText(&duration, @floatFromInt(if (library_track) |t| t.duration else if (track) |t| t.duration else 0)), low.muted());
        } else {
            text(f.body, .{ .x = r.x + inset, .y = r.y + 2, .w = @max(0, r.w - inset - (if (is_track or s.screen == .queue) @as(f32, 42) else 8)), .h = if (row.subtitle.len > 0) @as(f32, 24) else r.h - 4 }, row.title, if (row.playing) low.accent() else low.textColor());
            if (row.subtitle.len > 0) text(f.small, .{ .x = r.x + inset, .y = r.y + 25, .w = r.w - inset - 42, .h = 20 }, row.subtitle, low.muted());
        }
        if ((is_track or s.screen == .queue) and (active or (hover != null and hover.? == index))) button(f, frame.rowAction(index, offset), "…", false);
        if (s.queue_dragging and s.queue_drop_target != null and s.queue_drop_target.? == index) low.line(r.x, r.y, r.right(), r.y, low.accent(), 2);
    }
}
fn trackColumns(r: ui.Rect, albums: bool) struct { title: ui.Rect, artist: ui.Rect, album: ui.Rect, duration: ui.Rect } {
    const usable = @max(0, r.w - 114);
    const title_w = usable * (if (albums and r.w >= 560) @as(f32, 0.46) else 0.65);
    const artist_w = usable * (if (albums and r.w >= 560) @as(f32, 0.27) else 0.35);
    return .{
        .title = .{ .x = r.x + 12, .y = r.y, .w = title_w - 12, .h = r.h },
        .artist = .{ .x = r.x + 12 + title_w, .y = r.y, .w = artist_w - 12, .h = r.h },
        .album = .{ .x = r.x + 12 + title_w + artist_w, .y = r.y, .w = @max(0, usable - title_w - artist_w - 12), .h = r.h },
        .duration = .{ .x = r.right() - 90, .y = r.y, .w = 48, .h = r.h },
    };
}
fn tableHeader(frame: Layout, f: *const fonts.FontSet, albums: bool) void {
    low.setClip(frame.table_header);
    if (frame.table_header.w < 340) {
        text(f.small, frame.table_header.inset(4), "TRACKS", low.muted());
        return;
    }
    const columns = trackColumns(frame.table_header, albums);
    text(f.small, columns.title, "TITLE", low.muted());
    text(f.small, columns.artist, "ARTIST", low.muted());
    if (albums) text(f.small, columns.album, "ALBUM", low.muted());
    text(f.small, columns.duration, "TIME", low.muted());
}

fn nowPlaying(frame: Layout, f: *const fonts.FontSet, s: *const U.State, bitmap: ?*const al.graphics.Bitmap, visualizer: ?*gpu_vis.Visualizer, mode: gpu_vis.Mode) void {
    const n = frame.nowPlaying();
    low.setClip(frame.body);
    coverSquare(f, n.art, bitmap, s.album, 0);
    heading(f, .{ .x = n.info.x, .y = n.info.y, .w = n.info.w, .h = 42 }, if (s.title.len > 0) s.title else "Ready to listen");
    label(f, .{ .x = n.info.x, .y = n.info.y + 44, .w = n.info.w, .h = 28 }, s.artist);
    muted(f, .{ .x = n.info.x, .y = n.info.y + 74, .w = n.info.w, .h = 28 }, s.album);
    muted(f, .{ .x = n.info.x, .y = n.info.y + 106, .w = n.info.w, .h = 24 }, if (s.shuffle) "Shuffle on" else "Album listening");
    if (n.lyrics.h >= 28) {
        const active = s.active_lyric orelse 0;
        const first = active -| 1;
        const visible: usize = @intFromFloat(n.lyrics.h / 28);
        if (s.lyrics.len == 0) muted(f, n.lyrics, "No local lyrics") else for (first..@min(s.lyrics.len, first + visible)) |i| {
            text(f.body, .{ .x = n.lyrics.x, .y = n.lyrics.y + @as(f32, @floatFromInt(i - first)) * 28, .w = n.lyrics.w, .h = 28 }, s.lyrics[i].text, if (s.active_lyric != null and s.active_lyric.? == i) low.accent() else low.muted());
        }
    }
    if (n.visualizer.h > 0) {
        low.roundedRect(n.visualizer, 6, low.background());
        var mode_label: [96]u8 = undefined;
        text(f.small, .{ .x = n.visualizer.x + 10, .y = n.visualizer.y + 4, .w = n.visualizer.w - 84, .h = 24 }, std.fmt.bufPrint(&mode_label, "{s}", .{mode.label()}) catch mode.label(), low.muted());
        button(f, frame.visualizerButton(0), "‹", false);
        button(f, frame.visualizerButton(1), "›", false);
        const plot = frame.visualizerPlot();
        const rendered = if (visualizer) |gpu| gpu.draw(plot, s.spectrum, mode, al.time.getTime()) else false;
        if (!rendered) muted(f, plot.inset(4), "GPU visualizer unavailable");
    }
}
fn settings(frame: Layout, f: *const fonts.FontSet, s: *const U.State, offset: f32) void {
    low.setClip(frame.body);
    const names = [_][]const u8{ "Music directory", "Playback profile · click to cycle", "Normalization · click to toggle", "Normalization policy · click to cycle", "Crossfade · left decrease / right increase", "Last.fm", "API key", "Shared secret", "Session key", "Begin authorization", "Finish authorization", "Library health check", "Authorization status", "Authorization URL", "Health status" };
    var crossfade: [32]u8 = undefined;
    const values = [_][]const u8{ s.settings_music_directory, s.settings_playback_profile, if (s.settings_normalization_enabled) "Enabled" else "Disabled", if (s.settings_normalization_album) "Album" else "Track", std.fmt.bufPrint(&crossfade, "{d} seconds", .{s.settings_crossfade_seconds}) catch "", if (s.settings_lastfm_enabled) "Connected" else "Not connected", s.settings_api_key, s.settings_shared_secret, s.settings_session_key, "Click to open Last.fm authorization", "Click after approving authorization", "Click to inspect library", s.settings_auth_status, s.settings_auth_url, s.health_status };
    for (names, values, 0..) |name, value, i| {
        const r = frame.rowRect(i, offset);
        if (r.bottom() <= frame.body.y or r.y >= frame.body.bottom()) continue;
        const editing = i >= 6 and i < 9 and s.settings_active_field == @as(i8, @intCast(i - 6));
        field(f, r, name, if (i >= 6 and i < 9 and !editing and value.len > 0) "Configured · click to edit" else value, editing, if (editing) s.settings_cursor else null);
    }
    const first = @max(layout.settings_count, @as(usize, @intFromFloat(offset / layout.row_height)));
    const end = @min(layout.scrollCount(s), first + frame.visibleRows() + 2);
    for (first..end) |index| {
        const finding = s.health_findings[index - layout.settings_count];
        var detail: [256]u8 = undefined;
        const name = switch (finding) {
            .missing_file => "Missing file",
            .missing_tag => |v| std.fmt.bufPrint(&detail, "Missing tag: {s}", .{@tagName(v.tag)}) catch "Missing tag",
            .duplicate => "Duplicate files",
        };
        const path = switch (finding) {
            .missing_file => |v| v,
            .missing_tag => |v| v.path,
            .duplicate => |v| if (v.len > 0) v[0] else "",
        };
        field(f, frame.rowRect(index, offset), name, path, false, null);
    }
}
fn dialogBase(frame: Layout, f: *const fonts.FontSet, d: layout.Dialog, title: []const u8, subtitle: []const u8) void {
    low.resetClip();
    low.fillRect(.{ .w = frame.width, .h = frame.height }, al.Color.fromRgba(0, 4, 10, 185));
    low.roundedRect(d.card, 6, low.panel());
    heading(f, .{ .x = d.card.x + 16, .y = d.card.y + 10, .w = d.card.w - 32, .h = 34 }, title);
    muted(f, .{ .x = d.card.x + 16, .y = d.card.y + 44, .w = d.card.w - 32, .h = 24 }, subtitle);
}
fn dialogs(frame: Layout, f: *const fonts.FontSet, s: *const U.State, metadata_cursor: usize, album_actions: bool) void {
    if (s.playlist_modal_open) {
        const d = frame.dialog(540, 276);
        dialogBase(frame, f, d, switch (s.playlist_modal_mode) {
            .save_queue => "Save queue",
            .create => "New playlist",
            .rename => "Rename playlist",
            .delete => "Delete playlist?",
        }, s.playlist_modal_status);
        low.setClip(d.body);
        field(f, playlistModalInputRect(frame), "Playlist name", s.playlist_modal_name, s.playlist_modal_mode != .delete, s.playlist_modal_cursor);
        low.resetClip();
        button(f, d.button(0), if (s.playlist_modal_saved) "Done" else if (s.playlist_modal_mode == .delete) "Delete" else "Save", true);
        button(f, d.button(1), "Cancel", false);
    } else if (s.playlist_picker_open) {
        const d = frame.dialog(560, 540);
        dialogBase(frame, f, d, "Add to playlist", if (s.playlist_picker_status.len > 0) s.playlist_picker_status else s.playlist_picker_title);
        low.setClip(d.body);
        const first = s.playlist_picker_scroll;
        for (first..@min(s.playlists.len, first + d.visibleRows())) |i| button(f, d.row(i, first), s.playlists[i].name, s.playlist_picker_selection == i);
        if (s.playlists.len == 0) muted(f, d.body, "Create a playlist first.");
        low.resetClip();
        button(f, d.button(1), if (s.playlist_picker_saved) "Done" else "Cancel", false);
    } else if (s.metadata_editing) {
        const d = frame.dialog(680, 580);
        dialogBase(frame, f, d, "Edit track tags", if (s.metadata_status.len > 0) s.metadata_status else "Tab selects field · Enter saves · Esc cancels");
        const first = d.firstRow(s.metadata_active_index);
        low.setClip(d.body);
        for (first..@min(s.metadata_fields.len, first + d.visibleRows())) |i| field(f, d.row(i, first), s.metadata_fields[i].name, s.metadata_fields[i].value, i == s.metadata_active_index, if (i == s.metadata_active_index) metadata_cursor else null);
        low.resetClip();
        button(f, d.button(0), "Save", true);
        button(f, d.button(1), "Cancel", false);
    } else if (s.context_menu_open) {
        const d = frame.dialog(480, 456);
        dialogBase(frame, f, d, if (album_actions) "Album actions" else "Track actions", s.context_menu_title);
        const options = if (album_actions) [_][]const u8{ "Play album", "Add album to queue", "Play album next", "View album", "Change album sort", "Close" } else [_][]const u8{ "Play now", "Add to queue", "Play next", if (s.context_menu_favorite) "Remove favorite" else "Add favorite", "Edit tags", "Add to playlist" };
        const first = d.firstRow(s.context_menu_selection);
        low.setClip(d.body);
        for (first..@min(options.len, first + d.visibleRows())) |i| button(f, d.row(i, first), options[i], s.context_menu_selection == i);
        low.resetClip();
        muted(f, d.footer, "↑/↓ choose · Enter select · Esc close");
    }
}

pub fn render(display: *al.Display, f: *const fonts.FontSet, s: *const U.State, covers: *const artwork.Cache, visualizer: ?*gpu_vis.Visualizer, library: []const TrackRow, interaction: Interaction, current_album_id: i64) void {
    const bitmap = covers.get(current_album_id);
    const offset = interaction.scroll_offset;
    const frame = Layout.forScreen(@floatFromInt(display.getWidth()), @floatFromInt(display.getHeight()), s.screen, interaction.inspector_open);
    low.beginFrame(display);
    shell(frame, f, s, bitmap, interaction);
    if (frame.inspector.w > 0) inspector(frame, f, s, bitmap, interaction.inspector_lyrics);
    if (frame.table_header.h > 0) tableHeader(frame, f, s.screen == .library);
    low.setClip(frame.body);
    if (s.scanning) {
        var buf: [128]u8 = undefined;
        heading(f, frame.body.inset(12), std.fmt.bufPrint(&buf, "Scanning library… {d} files", .{s.scan_scanned}) catch "Scanning library…");
    } else switch (s.screen) {
        .now_playing => nowPlaying(frame, f, s, bitmap, visualizer, interaction.visualizer_mode),
        .settings => settings(frame, f, s, offset),
        .albums => gallery(frame, f, s, covers, offset, interaction.hover_row),
        .album_detail => {
            albumHero(frame, f, s, covers);
            list(frame, f, s, library, offset, interaction.hover_row);
        },
        else => list(frame, f, s, library, offset, interaction.hover_row),
    }
    low.resetClip();
    if (s.screen != .now_playing and !s.scanning) if (scrollbarGeometry(frame, s, offset)) |g| {
        low.roundedRect(g.track, 3, low.hairline());
        if (g.thumb) |thumb| low.roundedRect(thumb, 3, low.muted());
    };
    dialogs(frame, f, s, interaction.metadata_cursor, interaction.album_actions);
    low.resetClip();
}

test "dialog hit testing shares rendered row bounds at minimum window size" {
    const frame = Layout.fromSize(360, 300);
    const d = frame.dialog(680, 580);
    const r = metadataEditorFieldRect(frame, 7, 7);
    try std.testing.expectEqual(@as(?usize, 7), metadataEditorFieldAt(frame, r.x + 1, r.y + 1, 7));
    try std.testing.expect(metadataEditorFieldAt(frame, r.x, d.footer.y, 7) == null);
    const picker = frame.dialog(560, 540);
    try std.testing.expect(playlistPickerRowAt(frame, picker.card.x - 1, picker.body.y, 0) == null);
}
