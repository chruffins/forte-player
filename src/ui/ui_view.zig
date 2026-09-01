//! Pure "view" layer: turns a `State` snapshot into a flat list of typed draw
//! commands (text/bar/row/hline). No Allegro, no terminal — renderers interpret
//! the command list (this is what lets TUI and GUI share one view).
//!
//! Coordinates are terminal cells (col=x, row=y, 0-based). Everything here is
//! ASCII so grid alignment is exact in any renderer.

const std = @import("std");
const U = @import("ui_state.zig");

pub const Style = enum {
    normal,
    dim,
    bold,
    title,
    accent,
    err,
    bar_fill,
    bar_empty,
    selected,
};

pub const Cmd = union(enum) {
    text: struct { x: u16, y: u16, s: []const u8, style: Style },
    bar: struct { x: u16, y: u16, width: u16, frac: f32 },
    /// Full-width list row starting at column 1.
    row: struct { y: u16, s: []const u8, selected: bool, playing: bool },
    /// A full-width dim separator line.
    hline: struct { y: u16 },
    /// Half-block color art grid; `cells` is borrowed (owned by the caller).
    art: struct { x: u16, y: u16, w: u16, h: u16, cells: []const U.ArtCell },
};

pub const CmdList = struct {
    items: [512]Cmd = undefined,
    n: usize = 0,
    /// Owns copies of ephemeral text (bufPrint results etc.) so command strings
    /// never dangle after the emitting function returns.
    scratch: [8192]u8 = undefined,
    scratch_n: usize = 0,

    fn copyScratch(self: *CmdList, s: []const u8) []const u8 {
        const avail = self.scratch.len - self.scratch_n;
        const len = @min(s.len, avail);
        @memcpy(self.scratch[self.scratch_n .. self.scratch_n + len], s[0..len]);
        const owned = self.scratch[self.scratch_n .. self.scratch_n + len];
        self.scratch_n += len;
        return owned;
    }

    pub fn text(self: *CmdList, x: u16, y: u16, s: []const u8, style: Style) void {
        self.add(.{ .text = .{ .x = x, .y = y, .s = self.copyScratch(s), .style = style } });
    }
    pub fn bar(self: *CmdList, x: u16, y: u16, width: u16, f: f32) void {
        self.add(.{ .bar = .{ .x = x, .y = y, .width = width, .frac = f } });
    }
    pub fn row(self: *CmdList, y: u16, s: []const u8, selected: bool, playing: bool) void {
        // Rows are commonly formatted into stack buffers by the emitter, so
        // copy into the persistent scratch before storing the command.
        self.add(.{ .row = .{ .y = y, .s = self.copyScratch(s), .selected = selected, .playing = playing } });
    }
    pub fn hline(self: *CmdList, y: u16) void {
        self.add(.{ .hline = .{ .y = y } });
    }
    pub fn art(self: *CmdList, x: u16, y: u16, w: u16, h: u16, cells: []const U.ArtCell) void {
        self.add(.{ .art = .{ .x = x, .y = y, .w = w, .h = h, .cells = cells } });
    }
    fn add(self: *CmdList, c: Cmd) void {
        if (self.n < self.items.len) {
            self.items[self.n] = c;
            self.n += 1;
        }
    }
    pub fn slice(self: *const CmdList) []const Cmd {
        return self.items[0..self.n];
    }
};

pub const header_rows: u16 = 2;
pub const footer_rows: u16 = 4;

/// Number of library rows that fit in the main content area (for scrolling).
pub fn libraryVisible(height: u16) usize {
    if (height <= header_rows + footer_rows) return 0;
    return (height - header_rows - footer_rows -| 1);
}

pub fn emitContent(s: *const U.State, cl: *CmdList, width: u16, height: u16, titles: []const []const u8) void {
    emitHeader(s, cl, width);
    if (s.scanning) {
        emitScan(s, cl, width, height);
        return;
    }
    if (s.metadata_editing) {
        emitMetadataEditor(s, cl, width, height);
        return;
    }
    switch (s.screen) {
        .now_playing => emitNowPlaying(s, cl, width, height),
        .library => emitLibrary(s, cl, width, height, titles),
        .albums => emitAlbums(s, cl, width, height),
        .album_detail => emitAlbumDetail(s, cl, width, height),
        .artists => emitArtists(s, cl, width, height),
        .artist_detail => emitPersonDetail(s.artist_detail_name, s.artist_detail_tracks, s.artist_detail_count, s.selection, s.scroll, cl, width, height),
        .genres => emitGenres(s, cl, width, height),
        .genre_detail => emitPersonDetail(s.genre_detail_name, s.genre_detail_tracks, s.genre_detail_count, s.selection, s.scroll, cl, width, height),
        .playlists => emitPlaylists(s, cl, width, height),
        .playlist_detail => emitPlaylistDetail(s, cl, width, height),
        .queue => emitQueue(s, cl, width, height),
        .settings => emitSettings(s, cl, width, height),
    }
}

pub fn emit(s: *const U.State, cl: *CmdList, width: u16, height: u16, titles: []const []const u8) void {
    emitContent(s, cl, width, height, titles);
    emitFooter(s, cl, width, height);
}

fn emitScan(s: *const U.State, cl: *CmdList, width: u16, height: u16) void {
    cl.text(2, header_rows, "Scanning library", .bold);
    cl.text(2, header_rows + 2, "Playback is paused while the library is updated.", .dim);
    var line: [192]u8 = undefined;
    const progress = std.fmt.bufPrint(&line, "Files: {d}   imported: {d}   updated: {d}   removed: {d}", .{
        s.scan_scanned,
        s.scan_imported,
        s.scan_updated,
        s.scan_removed,
    }) catch "Scanning...";
    cl.text(2, header_rows + 4, truncGlyphs(progress, width -| 4), .normal);
    cl.text(2, header_rows + 6, "Esc: cancel   q: quit", .dim);
    _ = height;
}

fn frac(s: *const U.State) f32 {
    if (s.duration <= 0) return 0;
    return @floatCast(@min(s.position / s.duration, 1.0));
}

fn mmss(secs: f64, buf: *[5]u8) []const u8 {
    const t: i64 = @max(0, @as(i64, @intFromFloat(secs)));
    const m = @divTrunc(t, 60);
    const sec = @mod(t, 60);
    buf[0] = @as(u8, '0') + @as(u8, @intCast(@divTrunc(m, 10)));
    buf[1] = @as(u8, '0') + @as(u8, @intCast(@mod(m, 10)));
    buf[2] = ':';
    buf[3] = @as(u8, '0') + @as(u8, @intCast(@divTrunc(sec, 10)));
    buf[4] = @as(u8, '0') + @as(u8, @intCast(@mod(sec, 10)));
    return buf;
}

/// Progress-bar length in cells. Room is reserved for the "MM:SS / MM:SS"
/// readout after the bar, and the bar is capped at a sane maximum so it
/// never runs wall-to-wall. (The old `width - 10` drew a near-full-width bar
/// on very wide terminals, which visually spilled into the status line below
/// and pushed the `/ duration` readout off-screen.)
fn barWidth(width: u16) u16 {
    return @min(width -| 18, 60);
}

fn emitHeader(s: *const U.State, cl: *CmdList, width: u16) void {
    cl.text(2, 0, " forte-player ", .title);
    const name = switch (s.screen) {
        .now_playing => " NOW PLAYING ",
        .library => " LIBRARY ",
        .albums => " ALBUMS ",
        .album_detail => " ALBUM ",
        .artists => " ARTISTS ",
        .artist_detail => " ARTIST ",
        .genres => " GENRES ",
        .genre_detail => " GENRE ",
        .playlists => " PLAYLISTS ",
        .playlist_detail => " PLAYLIST ",
        .queue => " QUEUE ",
        .settings => " SETTINGS ",
    };
    const x = width -| @as(u16, @intCast(name.len)); // right-aligned
    cl.text(x, 0, name, .dim);
    cl.hline(1);
}

fn emitNowPlaying(s: *const U.State, cl: *CmdList, width: u16, height: u16) void {
    const x: u16 = 4;
    const yTitle: u16 = 3;

    // Album art occupies the right side; the left column of text and the
    // spectrum are clipped so they never run underneath it.
    const has_art = s.art.w > 0 and s.art.h > 0 and s.art.cells.len > 0;
    const art_x: u16 = if (has_art) width -| s.art.w -| 4 else width;
    const text_max: u16 = art_x -| x -| 2; // max glyphs for a left line

    cl.text(x, yTitle, truncGlyphs(s.title, text_max), .title);
    if (s.artist.len > 0 or s.album.len > 0) {
        var ab: [512]u8 = undefined;
        const line = std.fmt.bufPrint(&ab, "{s}{s}{s}", .{ s.artist, if (s.artist.len > 0 and s.album.len > 0) " - " else "", s.album }) catch "";
        cl.text(x, yTitle + 1, truncGlyphs(line, text_max), .normal);
    }

    // favorite + track time
    var t1: [5]u8 = undefined;
    var t2: [5]u8 = undefined;
    var fav: [64]u8 = undefined;
    const favline = std.fmt.bufPrint(&fav, "{s}  {s} / {s}", .{
        if (s.favorite) "* favorite" else "  not favorite",
        mmss(s.position, &t1),
        mmss(s.duration, &t2),
    }) catch "";
    cl.text(x, yTitle + 3, truncGlyphs(favline, text_max), .dim);

    // big progress bar
    const bw = @min(barWidth(width), text_max);
    cl.text(x, yTitle + 5, "progress", .dim);
    cl.bar(x, yTitle + 6, bw, frac(s));

    // repeat/shuffle
    var rs: [40]u8 = undefined;
    const rl = std.fmt.bufPrint(&rs, "{s}  {s}", .{
        if (s.shuffle) "shuffle: on" else "shuffle: off",
        switch (s.repeat_mode) {
            .None => "repeat: off",
            .All => "repeat: all",
            .One => "repeat: one",
        },
    }) catch "";
    cl.text(x, yTitle + 8, truncGlyphs(rl, text_max), .dim);

    // album art block (right side, above the footer)
    if (has_art) {
        const max_rows = height -| footer_rows -| yTitle;
        if (s.art.h <= max_rows) {
            cl.art(art_x, yTitle, s.art.w, s.art.h, s.art.cells);
        }
    }

    // live spectrum (bars fill the space above the footer, left of the art)
    if (s.spectrum.len > 0) {
        emitSpectrum(cl, x, yTitle + 12, height, s.spectrum, art_x -| x);
    }
}

/// Truncate `s` to at most `max_glyphs` whole UTF-8 glyphs.
fn truncGlyphs(s: []const u8, max_glyphs: u16) []const u8 {
    if (s.len == 0 or max_glyphs == 0) return "";
    var cols: u16 = 0;
    var i: usize = 0;
    while (i < s.len and cols < max_glyphs) : (cols += 1) i += glyphLen(s, i);
    return s[0..i];
}

/// Terminal spectrum blocks, top row first. `███`-style bars via the 8-level
/// unicode block set; each column is one band.
const spectrum_chars = [_][]const u8{ " ", "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" };

fn emitSpectrum(cl: *CmdList, x: u16, top: u16, height: u16, bands: []const f32, max_cols: u16) void {
    const avail = height -| footer_rows -| top;
    const rows: u16 = @min(8, avail);
    if (rows < 2) return;
    const cols: u16 = @min(@as(u16, @intCast(bands.len)), @min(64, max_cols));

    // Precompute each band's cell height in eighth-steps (0..8*rows).
    var levels: [64]u16 = undefined;
    for (0..cols) |i| {
        const v: f32 = if (i < bands.len) bands[i] else 0;
        levels[i] = @intFromFloat(@min(v, 1.0) * @as(f32, @floatFromInt(rows)) * 8.0);
    }

    // Bottom-up: the fractional top block of each bar sits on its own row.
    var r: usize = 0;
    while (r < rows) : (r += 1) {
        const row_from_bottom: usize = rows - 1 - r;
        var buf: [192]u8 = undefined;
        var n: usize = 0;
        for (0..cols) |i| {
            const lvl = levels[i];
            const covered: usize = lvl / 8; // rows fully covered (bottom-up)
            const rem: usize = lvl % 8; // eighths on the partial top row
            const ch = if (row_from_bottom < covered)
                spectrum_chars[8]
            else if (row_from_bottom == covered and rem > 0)
                spectrum_chars[rem]
            else
                spectrum_chars[0];
            if (n + ch.len > buf.len) break;
            @memcpy(buf[n .. n + ch.len], ch);
            n += ch.len;
        }
        cl.text(x, top + @as(u16, @intCast(r)), buf[0..n], .bar_fill);
    }
}

fn emitLibrary(s: *const U.State, cl: *CmdList, width: u16, height: u16, titles: []const []const u8) void {
    var hd: [192]u8 = undefined;
    const filter_part: []const u8 = if (s.library_searching)
        "  search: "
    else if (s.library_filter.len > 0)
        "  filter: "
    else
        "";
    const hline = if (filter_part.len > 0)
        std.fmt.bufPrint(&hd, "Library  ({d} songs){s}{s}", .{ titles.len, filter_part, s.library_filter }) catch "Library"
    else
        std.fmt.bufPrint(&hd, "Library  ({d} songs)", .{titles.len}) catch "Library";
    cl.text(2, header_rows, truncGlyphs(hline, width -| 2), .bold);

    const visible = libraryVisible(height);
    const top: u16 = header_rows + 1;
    var i: usize = 0;
    while (i < visible) : (i += 1) {
        const idx = s.scroll + i;
        if (idx >= titles.len) break;
        const playing = if (s.playing_index) |p| p == idx else false;
        cl.row(top + @as(u16, @intCast(i)), titles[idx], idx == s.selection, playing);
    }
    if (titles.len == 0) cl.text(2, top, "(empty library)", .dim);
}

fn emitAlbums(s: *const U.State, cl: *CmdList, width: u16, height: u16) void {
    var hd: [192]u8 = undefined;
    const filter_part: []const u8 = if (s.album_searching)
        "  search: "
    else if (s.album_filter.len > 0)
        "  filter: "
    else
        "";
    const hline = if (filter_part.len > 0)
        std.fmt.bufPrint(&hd, "Albums  ({d})   sort: {s}{s}{s}", .{ s.album_count, if (s.album_sort_label.len > 0) s.album_sort_label else "name", filter_part, s.album_filter }) catch "Albums"
    else
        std.fmt.bufPrint(&hd, "Albums  ({d})   sort: {s}", .{ s.album_count, if (s.album_sort_label.len > 0) s.album_sort_label else "name" }) catch "Albums";
    cl.text(2, header_rows, truncGlyphs(hline, width -| 2), .bold);

    const visible = libraryVisible(height);
    const top: u16 = header_rows + 1;
    var yb: [16]u8 = undefined;
    var i: usize = 0;
    while (i < visible) : (i += 1) {
        const idx = s.scroll + i;
        if (idx >= s.album_count) break;
        const a = s.albums[idx];
        const year_part: []const u8 = if (a.year > 0) std.fmt.bufPrint(&yb, "  ({d})", .{a.year}) catch "" else "";
        var line_buf: [256]u8 = undefined;
        const track_word: []const u8 = if (a.track_count == 1) "track" else "tracks";
        const line = std.fmt.bufPrint(&line_buf, "{s}{s}  {s}  {d} {s}", .{
            a.title,
            year_part,
            a.artist,
            a.track_count,
            track_word,
        }) catch continue;
        const playing = s.playing_album_id >= 0 and a.id == s.playing_album_id;
        cl.row(top + @as(u16, @intCast(i)), truncGlyphs(line, width -| 2), idx == s.selection, playing);
    }
    if (s.album_count == 0) cl.text(2, top, "(no albums)", .dim);
}

fn emitAlbumDetail(s: *const U.State, cl: *CmdList, width: u16, height: u16) void {
    var title: []const u8 = "Album";
    var artist: []const u8 = "";
    var year: i64 = -1;
    for (s.albums) |a| {
        if (a.id == s.album_detail_id) {
            title = a.title;
            artist = a.artist;
            year = a.year;
            break;
        }
    }

    // Album detail is a full-width track list. Rows are clipped to the
    // terminal width by truncGlyphs, so long titles never collide with a
    // secondary panel or wrap into the footer.
    const content_width: u16 = width -| 4;
    const top: u16 = header_rows + 1;

    var yb: [16]u8 = undefined;
    const year_part: []const u8 = if (year > 0) std.fmt.bufPrint(&yb, " ({d})", .{year}) catch "" else "";
    var hd: [256]u8 = undefined;
    const track_word: []const u8 = if (s.album_detail_count == 1) "track" else "tracks";
    const hline = std.fmt.bufPrint(&hd, "{s}{s}  {s}   ({d} {s})", .{
        title,
        year_part,
        artist,
        s.album_detail_count,
        track_word,
    }) catch "Album";
    cl.text(2, header_rows, truncGlyphs(hline, content_width), .bold);

    const visible = libraryVisible(height);
    var tb: [16]u8 = undefined;
    var i: usize = 0;
    while (i < visible) : (i += 1) {
        const idx = s.scroll + i;
        if (idx >= s.album_detail_count) break;
        const t = s.album_detail_tracks[idx];
        const tnum: []const u8 = if (t.track > 0)
            if (t.disc_number > 1) std.fmt.bufPrint(&tb, "{d}.{d:0>2} ", .{ t.disc_number, t.track }) catch "" else std.fmt.bufPrint(&tb, "{d}. ", .{t.track}) catch ""
        else
            "";
        var duration_buf: [5]u8 = undefined;
        const duration = if (t.duration > 0) mmss(@floatFromInt(t.duration), &duration_buf) else "";
        var duration_part_buf: [10]u8 = undefined;
        const duration_part = if (duration.len > 0) std.fmt.bufPrint(&duration_part_buf, "  [{s}]", .{duration}) catch "" else "";
        var lb: [256]u8 = undefined;
        const line = std.fmt.bufPrint(&lb, "{s}{s}  —  {s}{s}", .{ tnum, t.title, t.artist, duration_part }) catch continue;
        const playing = if (s.album_detail_playing) |p| p == idx else false;
        cl.row(top + @as(u16, @intCast(i)), truncGlyphs(line, content_width), idx == s.selection, playing);
    }
    if (s.album_detail_count == 0) cl.text(2, top, "(no tracks)", .dim);
}

fn emitArtists(s: *const U.State, cl: *CmdList, _: u16, height: u16) void {
    var hd: [128]u8 = undefined;
    const hline = std.fmt.bufPrint(&hd, "Artists  ({d}){s}{s}", .{
        s.artist_count,
        if (s.searching) "  search: " else "",
        if (s.searching) s.filter else "",
    }) catch "Artists";
    cl.text(2, header_rows, hline, .bold);
    const top = header_rows + 1;
    const visible = libraryVisible(height);
    for (0..visible) |i| {
        const idx = s.scroll + i;
        if (idx >= s.artist_count) break;
        const a = s.artists[idx];
        var line: [192]u8 = undefined;
        const text = std.fmt.bufPrint(&line, "{s}  ({d} songs, {d} albums)", .{ a.name, a.song_count, a.album_count }) catch continue;
        cl.row(top + @as(u16, @intCast(i)), text, idx == s.selection, false);
    }
    if (s.artist_count == 0) cl.text(2, top, "(no artists)", .dim);
}

fn emitPersonDetail(name: []const u8, tracks: []const U.AlbumTrackRow, count: usize, selection: usize, scroll: usize, cl: *CmdList, width: u16, height: u16) void {
    var hd: [256]u8 = undefined;
    const word: []const u8 = if (count == 1) "song" else "songs";
    const heading = std.fmt.bufPrint(&hd, "{s}  ({d} {s})", .{ name, count, word }) catch "Detail";
    cl.text(2, header_rows, truncGlyphs(heading, width -| 4), .bold);
    const top = header_rows + 1;
    const visible = libraryVisible(height);
    for (0..visible) |i| {
        const idx = scroll + i;
        if (idx >= count) break;
        const t = tracks[idx];
        var line: [256]u8 = undefined;
        const text = std.fmt.bufPrint(&line, "{d:>2}. {s}  —  {s}", .{ idx + 1, t.title, t.artist }) catch continue;
        cl.row(top + @as(u16, @intCast(i)), truncGlyphs(text, width -| 4), idx == selection, false);
    }
    if (count == 0) cl.text(2, top, "(no songs)", .dim);
}

fn emitGenres(s: *const U.State, cl: *CmdList, _: u16, height: u16) void {
    var hd: [128]u8 = undefined;
    const hline = std.fmt.bufPrint(&hd, "Genres  ({d}){s}{s}", .{
        s.genre_count,
        if (s.searching) "  search: " else "",
        if (s.searching) s.filter else "",
    }) catch "Genres";
    cl.text(2, header_rows, hline, .bold);
    const top = header_rows + 1;
    const visible = libraryVisible(height);
    for (0..visible) |i| {
        const idx = s.scroll + i;
        if (idx >= s.genre_count) break;
        const g = s.genres[idx];
        var line: [160]u8 = undefined;
        const text = std.fmt.bufPrint(&line, "{s}  ({d} songs)", .{ g.name, g.song_count }) catch continue;
        cl.row(top + @as(u16, @intCast(i)), text, idx == s.selection, false);
    }
    if (s.genre_count == 0) cl.text(2, top, "(no genres)", .dim);
}

fn emitPlaylistDetail(s: *const U.State, cl: *CmdList, _: u16, height: u16) void {
    var hd: [192]u8 = undefined;
    const hline = std.fmt.bufPrint(&hd, "{s}  ({d} songs)", .{ s.playlist_detail_name, s.playlist_detail_count }) catch "Playlist";
    cl.text(2, header_rows, hline, .bold);
    const top = header_rows + 1;
    const visible = libraryVisible(height);
    for (0..visible) |i| {
        const idx = s.scroll + i;
        if (idx >= s.playlist_detail_count) break;
        const t = s.playlist_detail_tracks[idx];
        var line: [256]u8 = undefined;
        const text = std.fmt.bufPrint(&line, "{d:>2}. {s}  —  {s}", .{ idx + 1, t.title, t.artist }) catch continue;
        cl.row(top + @as(u16, @intCast(i)), text, idx == s.selection, false);
    }
    if (s.playlist_detail_count == 0) cl.text(2, top, "(playlist is empty)", .dim);
}

fn emitPlaylists(s: *const U.State, cl: *CmdList, _: u16, height: u16) void {
    var hd: [64]u8 = undefined;
    const hline = std.fmt.bufPrint(&hd, "Playlists  ({d})", .{s.playlist_count}) catch "Playlists";
    cl.text(2, header_rows, hline, .bold);
    const top = header_rows + 1;
    const visible = libraryVisible(height);
    for (0..visible) |i| {
        const idx = s.scroll + i;
        if (idx >= s.playlist_count) break;
        const p = s.playlists[idx];
        var line: [256]u8 = undefined;
        const word: []const u8 = if (p.song_count == 1) "song" else "songs";
        const desc = if (p.description.len > 0) p.description else "";
        const text = std.fmt.bufPrint(&line, "{s}  ({d} {s}){s}{s}", .{ p.name, p.song_count, word, if (desc.len > 0) "  —  " else "", desc }) catch continue;
        cl.row(top + @as(u16, @intCast(i)), text, idx == s.selection, false);
    }
    if (s.playlist_count == 0) cl.text(2, top, "(no playlists)", .dim);
}

fn emitQueue(s: *const U.State, cl: *CmdList, _: u16, height: u16) void {
    var hd: [128]u8 = undefined;
    const hline = std.fmt.bufPrint(&hd, "{s}  ({d} songs)", .{ s.queue_context_label, s.queue_count }) catch "Queue";
    cl.text(2, header_rows, hline, .bold);
    const top = header_rows + 1;
    const visible = libraryVisible(height);
    for (0..visible) |i| {
        const idx = s.scroll + i;
        if (idx >= s.queue_count) break;
        const q = s.queue[idx];
        var line: [256]u8 = undefined;
        const text = std.fmt.bufPrint(&line, "{s}{d:>2}. {s}  —  {s}", .{ if (s.queue_current_index) |cur| if (cur == idx) "> " else "  " else "  ", idx + 1, q.title, q.artist }) catch continue;
        cl.row(top + @as(u16, @intCast(i)), text, idx == s.selection, s.queue_current_index != null and s.queue_current_index.? == idx);
    }
    if (s.queue_count == 0) cl.text(2, top, "(queue is empty)", .dim);
}

fn emitSettingsField(s: *const U.State, cl: *CmdList, label: []const u8, value: []const u8, y: u16, index: usize, width: u16) void {
    const active = s.settings_active_field == @as(i8, @intCast(index));
    cl.text(2, y, label, if (active) .accent else .dim);
    var line: [512]u8 = undefined;
    var n: usize = 0;
    const cursor = if (active) @min(s.settings_cursor, value.len) else value.len;
    const limit = @min(value.len, line.len - 2);
    for (value[0..cursor]) |byte| {
        if (n >= limit) break;
        line[n] = byte;
        n += 1;
    }
    if (active and n < line.len - 1) {
        line[n] = '|';
        n += 1;
    }
    if (active) for (value[cursor..]) |byte| {
        if (n >= line.len - 1) break;
        line[n] = byte;
        n += 1;
    };
    cl.text(2, y + 1, truncGlyphs(line[0..n], width -| 4), if (active) .selected else .normal);
}

fn emitSettings(s: *const U.State, cl: *CmdList, width: u16, _: u16) void {
    cl.text(2, header_rows, "Settings", .bold);
    cl.text(2, header_rows + 2, "Playback", .dim);
    var volume: [96]u8 = undefined;
    const line = std.fmt.bufPrint(&volume, "Volume: {d:.0}%   Shuffle: {s}   Repeat: {s}", .{
        s.volume * 100,
        if (s.shuffle) "on" else "off",
        switch (s.repeat_mode) {
            .None => "off",
            .All => "all",
            .One => "one",
        },
    }) catch "Settings unavailable";
    cl.text(2, header_rows + 3, line, .normal);
    cl.text(2, header_rows + 5, "Music directory", .dim);
    cl.text(2, header_rows + 6, s.settings_music_directory, .normal);
    cl.text(2, header_rows + 7, "Last.fm", .dim);
    emitSettingsField(s, cl, "API Key", s.settings_api_key, header_rows + 8, 0, width);
    emitSettingsField(s, cl, "Shared Secret", s.settings_shared_secret, header_rows + 11, 1, width);
    emitSettingsField(s, cl, "Session Key", s.settings_session_key, header_rows + 14, 2, width);
    if (s.settings_editing) {
        cl.text(2, header_rows + 16, "Enter: next/save   Esc: cancel   arrows/Home/End: cursor", .dim);
    } else {
        cl.text(2, header_rows + 16, "Click a field or press L   O: authorize   K: finish auth   R: rescan", .dim);
    }
    if (s.settings_auth_status.len > 0) cl.text(2, header_rows + 17, s.settings_auth_status, .accent);
    if (s.settings_auth_url.len > 0) cl.text(2, header_rows + 18, truncGlyphs(s.settings_auth_url, width -| 4), .dim);
}

fn emitMetadataEditor(s: *const U.State, cl: *CmdList, _: u16, _: u16) void {
    cl.text(2, header_rows, "Edit metadata", .bold);
    cl.text(2, header_rows + 2, s.metadata_song_title, .title);
    var line: [256]u8 = undefined;
    const prompt = std.fmt.bufPrint(&line, "{s}: {s}", .{ s.metadata_field, s.metadata_value }) catch "Edit";
    cl.text(2, header_rows + 4, prompt, .normal);
    cl.text(2, header_rows + 6, "enter: next/save   esc: cancel   backspace: erase", .dim);
}

fn emitProgressFooter(s: *const U.State, cl: *CmdList, top: u16, width: u16) void {
    const by = top + 1;
    const bw = barWidth(width);
    cl.bar(3, by, bw, frac(s));
    var t1: [5]u8 = undefined;
    var t2: [5]u8 = undefined;
    cl.text(3 + bw + 2, by, mmss(s.position, &t1), .normal);
    cl.text(3 + bw + 8, by, "/", .dim);
    cl.text(3 + bw + 10, by, mmss(s.duration, &t2), .dim);
}

fn emitStatusFooter(s: *const U.State, cl: *CmdList, y: u16) void {
    var line: [96]u8 = undefined;
    const status = std.fmt.bufPrint(&line, "{s}   vol {d:.0}%   shuffle {s}   repeat {s}", .{
        if (s.playing) "PLAYING" else "PAUSED",
        s.volume * 100,
        if (s.shuffle) "on" else "off",
        switch (s.repeat_mode) {
            .None => "off",
            .All => "all",
            .One => "one",
        },
    }) catch "";
    cl.text(3, y, status, .accent);
}

fn hintForScreen(screen: U.Screen) []const u8 {
    return switch (screen) {
        .now_playing => "space:pause  n/p:next/prev  [ ]/.:seek  +/-:vol  s:shuffle  r:repeat  f:fav  e:edit  1-8:view  q:quit",
        .library => "j/k:nav  d/u:page  /:search  a:add  A:next  enter:play  e:edit  1-8:view  q:quit",
        .albums => "j/k:nav  d/u:page  /:search  c:clear  a:sort  enter:open  b:back  1-8:view  q:quit",
        .album_detail => "j/k:nav  a:add all  A:next  enter:play  b/esc:back  n/p:next/prev  1-8:view  q:quit",
        .artists => "j/k:nav  /:search  c:clear  enter:open  1-8:view  q:quit",
        .artist_detail => "j/k:nav  a:add all  A:next  enter:play  b/esc:back  1-8:view  q:quit",
        .genres => "j/k:nav  /:search  c:clear  enter:open  1-8:view  q:quit",
        .genre_detail => "j/k:nav  a:add all  A:next  enter:play  b/esc:back  1-8:view  q:quit",
        .playlists => "j/k:nav  n:new  r:rename  a:add-current  x:delete  enter:open  1-8:view  q:quit",
        .playlist_detail => "j/k:nav  a:add-current  x:remove  </>:move  enter:play  b:back  1-8:view  q:quit",
        .queue => "j/k:nav  </>:move  x:remove  C:clear  enter:play  n/p:next/prev  1-8:view  q:quit",
        .settings => "l:Last.fm  R:rescan  t:theme  +/-:volume  s:shuffle  r:repeat  1-8:view  q:quit",
    };
}

fn emitFooter(s: *const U.State, cl: *CmdList, width: u16, height: u16) void {
    if (height <= footer_rows) return;
    const top = height - footer_rows;
    cl.hline(top);
    emitProgressFooter(s, cl, top, width);
    emitStatusFooter(s, cl, top + 2);
    cl.text(3, top + 3, hintForScreen(s.screen), .dim);
}

test "footer progress bar + readout never overflows the terminal width" {
    // Regression: on very wide terminals the bar previously ran wall-to-wall and
    // its "MM:SS / MM:SS" readout was pushed off-screen. The footer bar row
    // (y == height-3) must always contain a bar and its readout wholly on-screen.
    var st = U.State{};
    st.title = "A Track";
    st.artist = "Artist";
    st.album = "Album";
    st.position = 61.5;
    st.duration = 250;
    st.playing = true;
    st.volume = 1.0;
    st.shuffle = true;
    st.repeat_mode = .All;
    const titles: []const []const u8 = &.{};

    // Wide enough that metadata lines clamp is not the point here; the footer
    // readout must fit at a breadth of widths including very wide terminals.
    for ([_]u16{ 40, 80, 120, 300, 1000 }) |width| {
        const height: u16 = 14;
        const footer_row = height - 3; // top(=height-4) + 1
        for ([_]U.Screen{ .now_playing, .library }) |screen| {
            st.screen = screen;
            var cl = CmdList{};
            emit(&st, &cl, width, height, titles);
            for (cl.slice()) |cmd| switch (cmd) {
                .bar => |b| try std.testing.expect(b.x + b.width <= width),
                .text => |t| if (t.y == footer_row) {
                    const end = t.x + @as(u16, @intCast(t.s.len));
                    try std.testing.expect(end <= width);
                },
                else => {},
            };
        }
    }
}

test "progress bar is capped and leaves room for the readout" {
    // barWidth caps at a sane length and never exceeds what fits beside the
    // "MM:SS / MM:SS" readout.
    try std.testing.expectEqual(@as(u16, 60), barWidth(300));
    try std.testing.expectEqual(@as(u16, 60), barWidth(80));
    try std.testing.expectEqual(@as(u16, 22), barWidth(40)); // width-18 < cap
}

test "now-playing renders spectrum bars as block glyphs" {
    var st = U.State{};
    st.title = "T";
    st.position = 10;
    st.duration = 100;
    var spectrum_values = [_]f32{0} ** 48;
    // full height on the left half, silence on the right half
    for (0..24) |i| spectrum_values[i] = 1.0;
    st.spectrum = &spectrum_values;
    st.screen = .now_playing;

    const width: u16 = 80;
    const height: u16 = 24;
    var cl = CmdList{};
    emit(&st, &cl, width, height, &.{});

    // Expect 8 rows of spectrum text, first 24 columns = full block (█),
    // remaining columns = blank/space block.
    var seen_rows: usize = 0;
    for (cl.slice()) |cmd| switch (cmd) {
        .text => |t| {
            if (t.style == .bar_fill and t.y >= 15 and t.y < 20) {
                seen_rows += 1;
                try std.testing.expectEqual(@as(usize, 48), countColumns(t.s));
                // left 24 columns must be the full block glyph
                var pos: usize = 0;
                for (0..24) |_| {
                    pos += glyphLen(t.s, pos);
                }
                try std.testing.expectEqualStrings("█", t.s[0..glyphLen(t.s, 0)]);
            }
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 5), seen_rows); // footer starts at row 20
}

test "album view renders rows + sort header without garbage" {
    var st = U.State{ .screen = .albums, .album_count = 2 };
    const rows = [_]U.AlbumRow{
        .{ .id = 1, .title = "Kind of Blue", .artist = "Miles Davis", .year = 1959, .track_count = 5, .has_cover = true },
        .{ .id = 2, .title = "Zed", .artist = "A. Artist", .year = 2005, .track_count = 1, .has_cover = false },
    };
    st.albums = &rows;
    st.album_sort_label = "name";

    var cl = CmdList{};
    emit(&st, &cl, 80, 24, &.{});

    var rows_seen: usize = 0;
    var header_ok = false;
    var hint_ok = false;
    for (cl.slice()) |cmd| switch (cmd) {
        .row => |r| {
            rows_seen += 1;
            if (rows_seen == 1) {
                try std.testing.expect(std.mem.indexOf(u8, r.s, "Kind of Blue") != null);
                try std.testing.expect(std.mem.indexOf(u8, r.s, "1959") != null);
                try std.testing.expect(std.mem.indexOf(u8, r.s, "5 tracks") != null);
            } else {
                try std.testing.expect(std.mem.indexOf(u8, r.s, "Zed") != null);
                try std.testing.expect(std.mem.indexOf(u8, r.s, "2005") != null);
                try std.testing.expect(std.mem.indexOf(u8, r.s, "1 track") != null);
            }
        },
        .text => |t| {
            if (t.y == header_rows) header_ok = header_ok or std.mem.indexOf(u8, t.s, "sort: name") != null;
            if (t.y == 23) hint_ok = hint_ok or std.mem.indexOf(u8, t.s, "a:sort") != null;
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 2), rows_seen);
    try std.testing.expect(header_ok);
    try std.testing.expect(hint_ok);
}

test "album detail view lists numbered tracks + playing highlight" {
    var st = U.State{
        .screen = .album_detail,
        .album_detail_id = 1,
        .album_detail_count = 2,
        .album_detail_playing = 1,
        .albums = &.{.{ .id = 1, .title = "Zed", .artist = "X", .year = 2001, .track_count = 2, .has_cover = false }},
    };
    const tracks = [_]U.AlbumTrackRow{
        .{ .title = "First", .artist = "Artist A", .track = 1, .song_id = 11 },
        .{ .title = "Second", .artist = "Artist B", .track = 2, .song_id = 12 },
    };
    st.album_detail_tracks = &tracks;

    var cl = CmdList{};
    emit(&st, &cl, 80, 24, &.{});

    var found = [_]bool{ false, false };
    for (cl.slice()) |cmd| switch (cmd) {
        .row => |r| {
            if (std.mem.indexOf(u8, r.s, "1. First") != null) found[0] = true;
            if (std.mem.indexOf(u8, r.s, "2. Second") != null) {
                try std.testing.expect(r.playing); // playing track is highlighted
                found[1] = true;
            }
        },
        else => {},
    };
    try std.testing.expect(found[0] and found[1]);
}

/// Byte length of the UTF-8 glyph starting at s[i] (for cell-width counting).
fn glyphLen(s: []const u8, i: usize) usize {
    if (i >= s.len) return 1;
    const b = s[i];
    const n: usize = if (b < 0x80) 1 else if (b >= 0xF0) 4 else if (b >= 0xE0) 3 else if (b >= 0xC0) 2 else 1;
    return @min(n, s.len - i);
}

/// Column count of a UTF-8 string (1 column per glyph).
fn countColumns(s: []const u8) usize {
    var cols: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (cols += 1) i += glyphLen(s, i);
    return cols;
}
