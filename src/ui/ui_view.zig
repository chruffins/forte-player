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
    spectrum,
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
    /// TUI overlay box. GUI renderers may ignore it when they use emitContent.
    box: struct { x: u16, y: u16, w: u16, h: u16 },
    /// Subtle panel frame. GUI renderers may ignore it.
    frame: struct { x: u16, y: u16, w: u16, h: u16, style: Style },
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
    pub fn box(self: *CmdList, x: u16, y: u16, w: u16, h: u16) void {
        self.add(.{ .box = .{ .x = x, .y = y, .w = w, .h = h } });
    }
    pub fn frame(self: *CmdList, x: u16, y: u16, w: u16, h: u16, style: Style) void {
        self.add(.{ .frame = .{ .x = x, .y = y, .w = w, .h = h, .style = style } });
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
    if (s.help_visible) emitHelp(s, cl, width, height);
    if (s.context_menu_open) emitContextMenu(s, cl, width, height);
}

fn emitHelp(s: *const U.State, cl: *CmdList, width: u16, height: u16) void {
    if (width < 30 or height < 14) return;
    const box_w = @min(@as(u16, 78), width -| 4);
    const box_h: u16 = @min(10, height -| 4);
    const x = (width - box_w) / 2;
    const y = (height - box_h) / 2;
    cl.box(x, y, box_w, box_h);
    cl.text(x + 2, y + 1, "Keyboard help", .title);
    cl.text(x + 2, y + 2, "? / Esc close · Q quit · 1-8 switch screens", .normal);
    cl.text(x + 2, y + 3, "J/K move · D/U page · G then letter jumps · Enter activates", .normal);
    cl.text(x + 2, y + 4, "Space pause · N/P track · +/- volume · V track actions", .normal);
    cl.text(x + 2, y + 5, "S smart shuffle · R repeat · F favorite · B back", .normal);
    cl.text(x + 2, y + 6, truncGlyphs(hintForScreen(s.screen), box_w -| 4), .dim);
    cl.text(x + 2, y + 8, "Press ? from any screen for this help", .dim);
}

fn emitContextMenu(s: *const U.State, cl: *CmdList, width: u16, height: u16) void {
    const box_h: u16 = 13;
    if (width < 30 or height < box_h + 2) return;
    const box_w = @min(@as(u16, 58), width -| 4);
    const x = (width - box_w) / 2;
    const y = (height - box_h) / 2;
    cl.box(x, y, box_w, box_h);
    cl.text(x + 2, y + 1, "Track actions", .title);
    cl.text(x + 2, y + 2, truncGlyphs(s.context_menu_title, box_w -| 4), .bold);
    if (s.context_menu_artist.len > 0) {
        cl.text(x + 2, y + 3, truncGlyphs(s.context_menu_artist, box_w -| 4), .dim);
    }
    cl.text(x + 2, y + 4, "────────────────────────", .dim);
    const options = [_][]const u8{ "Play now", "Add to queue", "Play next", if (s.context_menu_favorite) "Remove favorite" else "Add to favorites", "Edit tags" };
    for (options, 0..) |option, index| {
        const selected = index == s.context_menu_selection;
        const row_y = y + 5 + @as(u16, @intCast(index));
        cl.text(x + 2, row_y, if (selected) "›" else " ", if (selected) .accent else .dim);
        var line: [96]u8 = undefined;
        const label = std.fmt.bufPrint(&line, "{d}. {s}", .{ index + 1, option }) catch continue;
        cl.text(x + 4, row_y, truncGlyphs(label, box_w -| 6), if (selected) .bold else .normal);
    }
    cl.text(x + 2, y + 11, "J/K move · 1-5 run · Enter select · Esc close", .dim);
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
/// readout after the bar, plus one trailing margin cell. The bar is capped at
/// a sane maximum so it never runs wall-to-wall.
fn barWidth(width: u16) u16 {
    return @min(width -| 19, 60);
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
    emitNavigation(s.screen, cl, width);
}

fn emitNavigation(screen: U.Screen, cl: *CmdList, width: u16) void {
    const labels = [_][]const u8{ "Now", "Library", "Albums", "Artists", "Genres", "Playlists", "Queue", "Settings" };
    const screens = [_]U.Screen{ .now_playing, .library, .albums, .artists, .genres, .playlists, .queue, .settings };
    const active = switch (screen) {
        .album_detail => U.Screen.albums,
        .artist_detail => U.Screen.artists,
        .genre_detail => U.Screen.genres,
        .playlist_detail => U.Screen.playlists,
        else => screen,
    };
    var x: u16 = 2;
    for (labels, screens, 0..) |label, tab, i| {
        if (x >= width) break;
        var segment: [24]u8 = undefined;
        const text = std.fmt.bufPrint(&segment, " {s} ", .{label}) catch break;
        cl.text(x, 1, truncGlyphs(text, width -| x), if (tab == active) .accent else .dim);
        x += @as(u16, @intCast(text.len));
        if (i + 1 < labels.len and x < width) {
            cl.text(x, 1, "·", .dim);
            x += 1;
        }
    }
}

fn emitNowPlaying(s: *const U.State, cl: *CmdList, width: u16, height: u16) void {
    const x: u16 = 4;
    const yTitle: u16 = 3;

    // Album art occupies the right side; the left column of text and the
    // spectrum are clipped so they never run underneath it.
    const has_art = s.art.w > 0 and s.art.h > 0 and s.art.cells.len > 0;
    const art_x: u16 = if (has_art) width -| s.art.w -| 4 else width;
    const text_max: u16 = art_x -| x -| (if (has_art) @as(u16, 4) else @as(u16, 2)); // keep text inside its panel
    const panel_bottom = height -| footer_rows;
    const panel_height = panel_bottom -| header_rows;
    if (width >= 44 and panel_height >= 8) {
        const left_width = if (has_art) art_x -| 5 else width -| 4;
        if (left_width >= 14) cl.frame(2, header_rows, left_width, panel_height, .dim);
        if (has_art and s.art.w + 4 >= 8) cl.frame(art_x -| 2, header_rows, s.art.w + 4, panel_height, .dim);
    }
    if (text_max >= 12) cl.text(x + 2, header_rows, "NOW PLAYING", .accent);
    cl.text(x, yTitle, truncGlyphs(s.title, text_max), .title);
    if (s.artist.len > 0 or s.album.len > 0) {
        var ab: [512]u8 = undefined;
        const line = std.fmt.bufPrint(&ab, "{s}{s}{s}", .{ s.artist, if (s.artist.len > 0 and s.album.len > 0) " - " else "", s.album }) catch "";
        cl.text(x, yTitle + 1, truncGlyphs(line, text_max), .normal);
    }

    // playback state
    cl.text(x, yTitle + 2, if (s.playing) "▶ PLAYING" else "Ⅱ PAUSED", .accent);

    // Favorite + track time. Keep the time fixed in place so toggling the
    // favorite state does not make the metadata jump horizontally.
    var t1: [5]u8 = undefined;
    var t2: [5]u8 = undefined;
    var time_line: [16]u8 = undefined;
    const time_text = std.fmt.bufPrint(&time_line, "{s} / {s}", .{
        mmss(s.position, &t1),
        mmss(s.duration, &t2),
    }) catch "";
    cl.text(x, yTitle + 3, if (s.favorite) "★" else "☆", if (s.favorite) .accent else .normal);
    cl.text(x + 2, yTitle + 3, truncGlyphs(time_text, text_max -| 2), .dim);

    // big progress bar
    const bw = @min(barWidth(width), text_max);
    cl.text(x, yTitle + 5, "PROGRESS", .dim);
    cl.bar(x, yTitle + 6, bw, frac(s));

    // repeat/shuffle
    var rs: [40]u8 = undefined;
    const rl = std.fmt.bufPrint(&rs, "{s}  {s}", .{
        if (s.shuffle) "smart shuffle: on" else "shuffle: off",
        switch (s.repeat_mode) {
            .None => "repeat: off",
            .All => "repeat: all",
            .One => "repeat: one",
        },
    }) catch "";
    cl.text(x, yTitle + 8, truncGlyphs(rl, text_max), .dim);

    // Lyrics are deliberately bounded so they cannot run into the footer or
    // cover-art panel. Plain-text lyrics are listed without a current marker.
    const lyric_top = yTitle + 10;
    if (s.lyrics.len == 0) {
        if (lyric_top < height -| footer_rows) cl.text(x, lyric_top, "No local lyrics", .dim);
    } else {
        cl.text(x, lyric_top, "LYRICS", .dim);
        const lyric_limit: usize = @min(5, @as(usize, height -| footer_rows -| (lyric_top +| 1)));
        const visible = @min(lyric_limit, s.lyrics.len);
        for (0..visible) |i| {
            const line = s.lyrics[i];
            const active = s.active_lyric != null and s.active_lyric.? == i;
            cl.text(x, lyric_top + 1 + @as(u16, @intCast(i)), truncGlyphs(line.text, text_max), if (active) .accent else .dim);
        }
    }

    // album art block (right side, above the footer)
    if (has_art) {
        const max_rows = height -| footer_rows -| yTitle;
        if (s.art.h <= max_rows) {
            cl.text(art_x, yTitle -| 1, "COVER ART", .accent);
            cl.art(art_x, yTitle, s.art.w, s.art.h, s.art.cells);
        }
    }

    // live spectrum (bars fill the space above the footer, left of the art)
    if (s.spectrum.len > 0) {
        const spectrum_top = if (s.lyrics.len > 0) yTitle + 17 else yTitle + 12;
        emitSpectrum(cl, x, spectrum_top, height, s.spectrum, art_x -| x);
    }
}

/// Truncate `s` at a UTF-8 boundary to the terminal-cell width.
fn truncGlyphs(s: []const u8, max_columns: u16) []const u8 {
    if (s.len == 0 or max_columns == 0) return "";
    var columns: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const size = glyphLen(s, i);
        const width = glyphColumns(s, i, size);
        if (columns + width > max_columns) break;
        columns += width;
        i += size;
    }
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
        cl.text(x, top + @as(u16, @intCast(r)), buf[0..n], .spectrum);
    }
}

const LibraryDisplayParts = struct { title: []const u8, artist: []const u8, album: []const u8 };

fn splitLibraryDisplay(display: []const u8) ?LibraryDisplayParts {
    const artist_sep = std.mem.indexOf(u8, display, "  —  ") orelse return null;
    const artist_start = artist_sep + "  —  ".len;
    const album_sep_rel = std.mem.indexOf(u8, display[artist_start..], "  [") orelse return null;
    const album_sep = artist_start + album_sep_rel;
    if (display.len <= album_sep + 4 or display[display.len - 1] != ']') return null;
    return .{
        .title = display[0..artist_sep],
        .artist = display[artist_start..album_sep],
        .album = display[album_sep + 3 .. display.len - 1],
    };
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
        var row_buf: [512]u8 = undefined;
        var row_text = titles[idx];
        if (width >= 72) {
            if (splitLibraryDisplay(titles[idx])) |parts| {
                const row_width: usize = width -| 4;
                const artist_width = @min(@as(usize, 22), row_width / 4);
                const album_width = @min(@as(usize, 26), row_width / 3);
                const title_width = row_width - artist_width - album_width - 4;
                var used: usize = 0;
                appendPaddedColumn(&row_buf, &used, parts.title, title_width);
                appendColumnGap(&row_buf, &used);
                appendPaddedColumn(&row_buf, &used, parts.artist, artist_width);
                appendColumnGap(&row_buf, &used);
                appendPaddedColumn(&row_buf, &used, parts.album, album_width);
                row_text = row_buf[0..used];
            }
        }
        cl.row(top + @as(u16, @intCast(i)), truncGlyphs(row_text, width -| 2), idx == s.selection, playing);
    }
    if (titles.len == 0) cl.text(2, top, if (s.library_filter.len > 0) "(no matches)" else "(empty library)", .dim);
}

fn appendPaddedColumn(buffer: anytype, used: *usize, text: []const u8, columns: usize) void {
    var index: usize = 0;
    var written: usize = 0;
    while (index < text.len) {
        const size = glyphLen(text, index);
        const cells = glyphColumns(text, index, size);
        if (cells > 0 and written + cells > columns) break;
        if (used.* + size > buffer.len) return;
        @memcpy(buffer[used.* .. used.* + size], text[index .. index + size]);
        used.* += size;
        index += size;
        written += cells;
    }
    while (written < columns and used.* < buffer.len) : (written += 1) {
        buffer[used.*] = ' ';
        used.* += 1;
    }
}

fn appendColumnGap(buffer: anytype, used: *usize) void {
    if (used.* + 2 <= buffer.len) {
        buffer[used.*] = ' ';
        buffer[used.* + 1] = ' ';
        used.* += 2;
    }
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
        var line: []const u8 = undefined;
        const row_width: usize = width -| 4;
        if (row_width >= 44) {
            const artist_width = @min(@as(usize, 24), row_width / 3);
            const year_width: usize = 5;
            const count_width: usize = 9;
            const title_width = row_width - artist_width - year_width - count_width - 6;
            const year_text = if (a.year > 0) std.fmt.bufPrint(&yb, "{d}", .{a.year}) catch "" else "—";
            var count_buf: [24]u8 = undefined;
            const count_text = std.fmt.bufPrint(&count_buf, "{d} {s}", .{ a.track_count, track_word }) catch "";
            var used: usize = 0;
            appendPaddedColumn(&line_buf, &used, a.title, title_width);
            appendColumnGap(&line_buf, &used);
            appendPaddedColumn(&line_buf, &used, a.artist, artist_width);
            appendColumnGap(&line_buf, &used);
            appendPaddedColumn(&line_buf, &used, year_text, year_width);
            appendColumnGap(&line_buf, &used);
            appendPaddedColumn(&line_buf, &used, count_text, count_width);
            line = line_buf[0..used];
        } else {
            line = std.fmt.bufPrint(&line_buf, "{s}{s}  ·  {s}  ·  {d} {s}", .{
                a.title,
                year_part,
                a.artist,
                a.track_count,
                track_word,
            }) catch continue;
        }
        const playing = s.playing_album_id >= 0 and a.id == s.playing_album_id;
        cl.row(top + @as(u16, @intCast(i)), truncGlyphs(line, width -| 2), idx == s.selection, playing);
    }
    if (s.album_count == 0) cl.text(2, top, if (s.album_filter.len > 0) "(no matches)" else "(no albums)", .dim);
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

fn emitArtists(s: *const U.State, cl: *CmdList, width: u16, height: u16) void {
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
        var line: [256]u8 = undefined;
        var text: []const u8 = undefined;
        const row_width: usize = width -| 4;
        if (row_width >= 48) {
            const song_width: usize = 12;
            const album_width: usize = 10;
            const name_width = row_width - song_width - album_width - 4;
            var songs: [32]u8 = undefined;
            var albums: [32]u8 = undefined;
            const song_text = std.fmt.bufPrint(&songs, "{d} songs", .{a.song_count}) catch "";
            const album_text = std.fmt.bufPrint(&albums, "{d} albums", .{a.album_count}) catch "";
            var used: usize = 0;
            appendPaddedColumn(&line, &used, a.name, name_width);
            appendColumnGap(&line, &used);
            appendPaddedColumn(&line, &used, song_text, song_width);
            appendColumnGap(&line, &used);
            appendPaddedColumn(&line, &used, album_text, album_width);
            text = line[0..used];
        } else {
            text = std.fmt.bufPrint(&line, "{s}  ·  {d} songs  ·  {d} albums", .{ a.name, a.song_count, a.album_count }) catch continue;
        }
        cl.row(top + @as(u16, @intCast(i)), truncGlyphs(text, width -| 2), idx == s.selection, false);
    }
    if (s.artist_count == 0) cl.text(2, top, if (s.filter.len > 0) "(no matches)" else "(no artists)", .dim);
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
        const text = std.fmt.bufPrint(&line, "{s}  ·  {d} songs", .{ g.name, g.song_count }) catch continue;
        cl.row(top + @as(u16, @intCast(i)), text, idx == s.selection, false);
    }
    if (s.genre_count == 0) cl.text(2, top, if (s.filter.len > 0) "(no matches)" else "(no genres)", .dim);
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
    var hd: [256]u8 = undefined;
    const hline = if (s.searching)
        std.fmt.bufPrint(&hd, "Playlists  ({d})  search: {s}", .{ s.playlist_count, s.filter }) catch "Playlists"
    else
        std.fmt.bufPrint(&hd, "Playlists  ({d})   Create: F favorites  M played  R recent  S short tracks", .{s.playlist_count}) catch "Playlists";
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
        const text = std.fmt.bufPrint(&line, "{s}{s}  ({d} {s}){s}{s}", .{ if (p.is_smart) "⚡ " else "", p.name, p.song_count, word, if (desc.len > 0) "  —  " else "", desc }) catch continue;
        cl.row(top + @as(u16, @intCast(i)), text, idx == s.selection, false);
    }
    if (s.playlist_count == 0) cl.text(2, top, if (s.filter.len > 0) "(no matches)" else "(no playlists)", .dim);
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
        if (s.shuffle) "smart" else "off",
        switch (s.repeat_mode) {
            .None => "off",
            .All => "all",
            .One => "one",
        },
    }) catch "Settings unavailable";
    cl.text(2, header_rows + 3, line, .normal);
    var normalize: [96]u8 = undefined;
    const normalize_line = std.fmt.bufPrint(&normalize, "Loudness normalization: {s}   mode: {s}", .{
        if (s.settings_normalization_enabled) "on" else "off",
        if (s.settings_normalization_album) "album" else "track",
    }) catch "Loudness normalization";
    cl.text(2, header_rows + 4, normalize_line, .normal);
    var profile: [96]u8 = undefined;
    const profile_line = std.fmt.bufPrint(&profile, "Playback profile: {s}", .{s.settings_playback_profile}) catch "Playback profile";
    cl.text(2, header_rows + 5, profile_line, .normal);
    var crossfade: [128]u8 = undefined;
    const crossfade_line = std.fmt.bufPrint(&crossfade, "Crossfade: {d}s   (0–30s, 3s steps; click left/right or ←/→)", .{s.settings_crossfade_seconds}) catch "Crossfade";
    cl.text(2, header_rows + 6, crossfade_line, .normal);
    cl.text(2, header_rows + 7, "Music directory", .dim);
    cl.text(2, header_rows + 8, s.settings_music_directory, .normal);
    cl.text(2, header_rows + 9, "Last.fm", .dim);
    emitSettingsField(s, cl, "API Key", s.settings_api_key, header_rows + 10, 0, width);
    emitSettingsField(s, cl, "Shared Secret", s.settings_shared_secret, header_rows + 13, 1, width);
    emitSettingsField(s, cl, "Session Key", s.settings_session_key, header_rows + 16, 2, width);
    if (s.settings_editing) {
        cl.text(2, header_rows + 17, "Enter: next/save   Esc: cancel   arrows/Home/End: cursor", .dim);
    } else {
        cl.text(2, header_rows + 17, "L: edit fields   P: profile   O/K: Last.fm   R: rescan   H: read-only health report", .dim);
    }
    if (s.settings_auth_status.len > 0) cl.text(2, header_rows + 18, s.settings_auth_status, .accent);
    if (s.settings_auth_url.len > 0) cl.text(2, header_rows + 19, truncGlyphs(s.settings_auth_url, width -| 4), .dim);
    var health_line: [192]u8 = undefined;
    if (s.health_running) {
        const status = std.fmt.bufPrint(&health_line, "Library health: checking {d} files...  Esc: cancel", .{s.health_scanned}) catch "Library health: checking...";
        cl.text(2, header_rows + 20, status, .accent);
    } else if (s.health_status.len > 0) {
        cl.text(2, header_rows + 20, truncGlyphs(s.health_status, width -| 4), .accent);
        var missing_count: usize = 0;
        var duplicate_count: usize = 0;
        var tag_count: usize = 0;
        for (s.health_findings) |finding| switch (finding) {
            .missing_file => missing_count += 1,
            .duplicate => duplicate_count += 1,
            .missing_tag => tag_count += 1,
        };
        var counts_buffer: [192]u8 = undefined;
        const counts = std.fmt.bufPrint(&counts_buffer, "Missing files: {d}   duplicate groups: {d}   missing tags: {d}", .{ missing_count, duplicate_count, tag_count }) catch "Health findings";
        cl.text(2, header_rows + 21, counts, .dim);
        var row: u16 = header_rows + 22;
        for (s.health_findings[0..@min(s.health_findings.len, 3)]) |finding| {
            var text: [384]u8 = undefined;
            const finding_line = switch (finding) {
                .missing_file => |path| std.fmt.bufPrint(&text, "Missing file: {s}", .{path}) catch "Missing file",
                .duplicate => |paths| std.fmt.bufPrint(&text, "Duplicate files ({d}): {s}", .{ paths.len, paths[0] }) catch "Duplicate files",
                .missing_tag => |value| std.fmt.bufPrint(&text, "Missing {s} tag: {s}", .{ @tagName(value.tag), value.path }) catch "Missing essential tag",
            };
            cl.text(2, row, truncGlyphs(finding_line, width -| 4), .dim);
            row += 1;
        }
    }
}

fn emitMetadataEditor(s: *const U.State, cl: *CmdList, width: u16, height: u16) void {
    cl.text(2, header_rows, "Edit track metadata", .title);
    cl.text(2, header_rows + 2, truncGlyphs(s.metadata_song_title, width -| 4), .dim);
    const first_row = header_rows + 4;
    const available_rows = height -| (footer_rows + first_row + 1);
    if (s.metadata_fields.len > 0) {
        for (s.metadata_fields, 0..) |field, index| {
            if (index >= available_rows) break;
            var line: [384]u8 = undefined;
            const value = if (field.value.len > 0) field.value else "—";
            const text = std.fmt.bufPrint(&line, "{s:<10}  {s}", .{ field.name, value }) catch continue;
            const row_y = first_row + @as(u16, @intCast(index));
            const active = index == s.metadata_active_index;
            cl.text(2, row_y, if (active) "›" else " ", if (active) .accent else .dim);
            cl.text(4, row_y, truncGlyphs(text, width -| 6), if (active) .bold else .normal);
        }
    } else {
        var line: [256]u8 = undefined;
        const prompt = std.fmt.bufPrint(&line, "{s}: {s}", .{ s.metadata_field, s.metadata_value }) catch "Edit";
        cl.text(2, first_row, truncGlyphs(prompt, width -| 4), .normal);
    }
    cl.text(2, header_rows + 13, "Tab/Ctrl+N next · Ctrl+P previous · Enter next/save · Esc cancel", .dim);
    cl.text(2, header_rows + 14, "Backspace erase · Ctrl+U clear current field", .dim);
}

fn emitProgressFooter(s: *const U.State, cl: *CmdList, top: u16, width: u16) void {
    const by = top + 1;
    const bw = barWidth(width);
    cl.bar(3, by, bw, frac(s));
    var t1: [5]u8 = undefined;
    var t2: [5]u8 = undefined;
    cl.text(3 + bw + 2, by, mmss(s.position, &t1), .accent);
    cl.text(3 + bw + 8, by, "/", .dim);
    cl.text(3 + bw + 10, by, mmss(s.duration, &t2), .dim);
}

fn emitStatusFooter(s: *const U.State, cl: *CmdList, y: u16, width: u16) void {
    var line: [96]u8 = undefined;
    const status = std.fmt.bufPrint(&line, "{s}   vol {d:.0}%   shuffle {s}   repeat {s}", .{
        if (s.playing) "PLAYING" else "PAUSED",
        s.volume * 100,
        if (s.shuffle) "smart" else "off",
        switch (s.repeat_mode) {
            .None => "off",
            .All => "all",
            .One => "one",
        },
    }) catch "";
    cl.text(3, y, truncGlyphs(status, width -| 3), .accent);
}

fn hintForScreen(screen: U.Screen) []const u8 {
    return switch (screen) {
        .now_playing => "? Help · v actions · Space pause · N/P track · [/]/. seek · +/- volume · 1-8 screens · Q quit",
        .library => "? Help · v actions · J/K move · D/U page · / search · A add · Shift+A next · Enter play · Q quit",
        .albums => "? Help · J/K move · / search · C clear · A sort · Enter open · B back · 1-8 screens · Q quit",
        .album_detail => "? Help · v actions · J/K move · A add all · Shift+A next · Enter play · B back · Q quit",
        .artists => "? Help · J/K move · / search · C clear · Enter open · 1-8 screens · Q quit",
        .artist_detail => "? Help · v actions · J/K move · A add all · Shift+A next · Enter play · B back · Q quit",
        .genres => "? Help · J/K move · / search · C clear · Enter open · 1-8 screens · Q quit",
        .genre_detail => "? Help · v actions · J/K move · A add all · Shift+A next · Enter play · B back · Q quit",
        .playlists => "? Help · J/K move · F/M/R/S smart list · N new · A add current · X delete · Enter open · Q quit",
        .playlist_detail => "? Help · v actions · J/K move · A add current · X remove · </> reorder · Enter play · B back · Q quit",
        .queue => "? Help · v actions · J/K move · </> reorder · X remove · C clear · Enter play · N/P track · Q quit",
        .settings => "? Help · P profile · N normalization · M mode · X crossfade · L Last.fm · R rescan · T theme · +/- volume · Q quit",
    };
}

fn emitFooter(s: *const U.State, cl: *CmdList, width: u16, height: u16) void {
    if (height <= footer_rows) return;
    const top = height - footer_rows;
    cl.hline(top);
    emitProgressFooter(s, cl, top, width);
    emitStatusFooter(s, cl, top + 2, width);
    cl.text(3, top + 3, truncGlyphs(hintForScreen(s.screen), width -| 6), .dim);
}

test "artist rows align song and album counts across names" {
    const artists = [_]U.ArtistRow{
        .{ .id = 1, .name = "A", .song_count = 7, .album_count = 2 },
        .{ .id = 2, .name = "A much longer artist name", .song_count = 123, .album_count = 14 },
    };
    var state = U.State{ .screen = .artists, .artists = &artists, .artist_count = artists.len };
    var commands = CmdList{};
    emit(&state, &commands, 100, 24, &.{});
    var song_columns: [2]usize = undefined;
    var album_columns: [2]usize = undefined;
    var found: usize = 0;
    for (commands.slice()) |command| switch (command) {
        .row => |row| {
            const songs = std.mem.indexOf(u8, row.s, " songs") orelse return error.MissingSongCount;
            const albums = std.mem.indexOf(u8, row.s, " albums") orelse return error.MissingAlbumCount;
            song_columns[found] = countColumns(row.s[0..songs]) - (if (found == 0) @as(usize, 1) else 3);
            album_columns[found] = countColumns(row.s[0..albums]) - (if (found == 0) @as(usize, 1) else 2);
            found += 1;
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 2), found);
    try std.testing.expectEqual(song_columns[0], song_columns[1]);
    try std.testing.expectEqual(album_columns[0], album_columns[1]);
}

test "wide library rows align artist and album columns" {
    const titles = [_][]const u8{
        "Short  —  Artist  [Blue]",
        "A much longer title  —  A longer artist  [Kind of Blue]",
    };
    var state = U.State{ .screen = .library, .row_count = titles.len };
    var commands = CmdList{};
    emit(&state, &commands, 100, 24, &titles);
    var artist_columns: [2]usize = undefined;
    var album_columns: [2]usize = undefined;
    var found: usize = 0;
    var delimiters_removed = true;
    for (commands.slice()) |command| switch (command) {
        .row => |row| {
            artist_columns[found] = countColumns(row.s[0..46]);
            album_columns[found] = countColumns(row.s[0..70]);
            delimiters_removed = delimiters_removed and std.mem.indexOf(u8, row.s, "  —  ") == null;
            found += 1;
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 2), found);
    try std.testing.expectEqual(artist_columns[0], artist_columns[1]);
    try std.testing.expectEqual(album_columns[0], album_columns[1]);
    try std.testing.expect(delimiters_removed);
}

test "column counting treats common wide glyphs as two cells" {
    try std.testing.expectEqual(@as(usize, 4), countColumns("A界B"));
    try std.testing.expectEqual(@as(usize, 1), countColumns("e\xcc\x81"));
}

test "metadata editor presents multiple fields together" {
    const fields = [_]U.MetadataField{
        .{ .name = "title", .value = "Blue in Green" },
        .{ .name = "artist", .value = "Miles Davis" },
        .{ .name = "album", .value = "Kind of Blue" },
    };
    var state = U.State{
        .metadata_editing = true,
        .metadata_song_title = "Blue in Green",
        .metadata_fields = &fields,
        .metadata_active_index = 1,
    };
    var commands = CmdList{};
    emit(&state, &commands, 80, 24, &.{});
    var found_title = false;
    var found_artist = false;
    var found_album = false;
    for (commands.slice()) |command| switch (command) {
        .text => |text| {
            found_title = found_title or std.mem.indexOf(u8, text.s, "Blue in Green") != null;
            found_artist = found_artist or std.mem.indexOf(u8, text.s, "Miles Davis") != null;
            found_album = found_album or std.mem.indexOf(u8, text.s, "Kind of Blue") != null;
        },
        else => {},
    };
    try std.testing.expect(found_title and found_artist and found_album);
}

test "track context overlay shows actions and selected track" {
    var state = U.State{
        .context_menu_open = true,
        .context_menu_title = "Blue in Green",
        .context_menu_artist = "Miles Davis",
        .context_menu_favorite = true,
    };
    var commands = CmdList{};
    emit(&state, &commands, 80, 24, &.{});
    var found_box = false;
    var found_title = false;
    var found_artist = false;
    var found_favorite_action = false;
    var found_edit_action = false;
    for (commands.slice()) |command| switch (command) {
        .box => found_box = true,
        .text => |text| {
            found_title = found_title or std.mem.indexOf(u8, text.s, "Track actions") != null;
            found_artist = found_artist or std.mem.indexOf(u8, text.s, "Miles Davis") != null;
            found_favorite_action = found_favorite_action or std.mem.indexOf(u8, text.s, "Remove favorite") != null;
            found_edit_action = found_edit_action or std.mem.indexOf(u8, text.s, "Edit tags") != null;
        },
        else => {},
    };
    try std.testing.expect(found_box and found_title and found_artist and found_favorite_action and found_edit_action);
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
                .bar => |b| {
                    try std.testing.expect(b.x + b.width <= width);
                    if (b.y == footer_row) try std.testing.expect(b.x + b.width + 15 <= width);
                },
                .text => |t| if (t.y == footer_row) {
                    const end = t.x + @as(u16, @intCast(t.s.len));
                    try std.testing.expect(end <= width);
                },
                else => {},
            };
        }
    }
}

test "footer status and shortcut hints stay within narrow terminals" {
    const width: u16 = 40;
    const height: u16 = 14;
    var state = U.State{ .screen = .playlists };
    var commands = CmdList{};
    emit(&state, &commands, width, height, &.{});
    var saw_hint = false;
    for (commands.slice()) |command| switch (command) {
        .text => |text| if (text.y == height - 1) {
            saw_hint = true;
            try std.testing.expect(text.x + countColumns(text.s) <= width);
        },
        else => {},
    };
    try std.testing.expect(saw_hint);
}

test "progress bar is capped and leaves room for the readout" {
    // barWidth caps at a sane length and never exceeds what fits beside the
    // "MM:SS / MM:SS" readout.
    try std.testing.expectEqual(@as(u16, 60), barWidth(300));
    try std.testing.expectEqual(@as(u16, 60), barWidth(80));
    try std.testing.expectEqual(@as(u16, 21), barWidth(40)); // width-19 leaves one margin cell
}

test "settings renders categorized library health findings and report status" {
    var state = U.State{ .screen = .settings, .health_status = "Health report complete (read-only)." };
    const findings = [_]@import("../music/library_health.zig").Finding{
        .{ .missing_file = "/music/lost.mp3" },
        .{ .duplicate = &.{ "/music/a.mp3", "/music/b.mp3" } },
        .{ .missing_tag = .{ .path = "/music/untagged.mp3", .tag = .artist } },
    };
    state.health_findings = &findings;
    var commands = CmdList{};
    emit(&state, &commands, 100, 40, &.{});
    var missing = false;
    var duplicate = false;
    var tag = false;
    var status = false;
    for (commands.slice()) |command| switch (command) {
        .text => |text| {
            missing = missing or std.mem.indexOf(u8, text.s, "Missing file: /music/lost.mp3") != null;
            duplicate = duplicate or std.mem.indexOf(u8, text.s, "Duplicate files (2): /music/a.mp3") != null;
            tag = tag or std.mem.indexOf(u8, text.s, "Missing artist tag: /music/untagged.mp3") != null;
            status = status or std.mem.indexOf(u8, text.s, "Health report complete") != null;
        },
        else => {},
    };
    try std.testing.expect(missing and duplicate and tag and status);
}

test "now-playing renders bounded lyrics and a no-lyrics fallback" {
    var state = U.State{ .screen = .now_playing };
    var commands = CmdList{};
    emit(&state, &commands, 80, 30, &.{});
    var fallback = false;
    for (commands.slice()) |cmd| switch (cmd) {
        .text => |text| if (std.mem.eql(u8, text.s, "No local lyrics")) {
            fallback = true;
        },
        else => {},
    };
    try std.testing.expect(fallback);

    const lines = [_]@import("../music/lyrics.zig").Line{
        .{ .text = "one", .time = 1 }, .{ .text = "two", .time = 2 },
    };
    state.lyrics = &lines;
    state.active_lyric = 1;
    commands = .{};
    emit(&state, &commands, 80, 30, &.{});
    var found_active = false;
    for (commands.slice()) |cmd| switch (cmd) {
        .text => |text| if (std.mem.eql(u8, text.s, "two") and text.style == .accent) {
            found_active = true;
        },
        else => {},
    };
    try std.testing.expect(found_active);
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
            if (t.style == .spectrum and t.y >= 15 and t.y < 20) {
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
            if (t.y == 23) hint_ok = hint_ok or std.mem.indexOf(u8, t.s, "A sort") != null;
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 2), rows_seen);
    try std.testing.expect(header_ok);
    try std.testing.expect(hint_ok);
}

test "album rows align artist year and track columns at wide widths" {
    var state = U.State{ .screen = .albums, .album_count = 2 };
    const albums = [_]U.AlbumRow{
        .{ .id = 1, .title = "A", .artist = "Artist One", .year = 1984, .track_count = 9, .has_cover = false },
        .{ .id = 2, .title = "A Much Longer Album Name", .artist = "B", .year = 2001, .track_count = 12, .has_cover = false },
    };
    state.albums = &albums;
    var commands = CmdList{};
    emit(&state, &commands, 80, 24, &.{});
    var year_columns: [2]usize = undefined;
    var count_columns: [2]usize = undefined;
    var found: usize = 0;
    for (commands.slice()) |command| switch (command) {
        .row => |row| {
            const year = std.mem.indexOf(u8, row.s, if (found == 0) "1984" else "2001") orelse return error.YearNotRendered;
            const count_text = if (found == 0) "9 tracks" else "12 tracks";
            const count = std.mem.indexOf(u8, row.s, count_text) orelse return error.TrackCountNotRendered;
            year_columns[found] = countColumns(row.s[0..year]);
            count_columns[found] = countColumns(row.s[0..count]);
            found += 1;
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 2), found);
    try std.testing.expectEqual(year_columns[0], year_columns[1]);
    try std.testing.expectEqual(count_columns[0], count_columns[1]);
}

test "playlist browser marks smart playlists distinctly" {
    var st = U.State{ .screen = .playlists, .playlist_count = 2 };
    const rows = [_]U.PlaylistRow{
        .{ .id = 1, .name = "Manual", .song_count = 1 },
        .{ .id = 2, .name = "Favorites", .song_count = 0, .is_smart = true },
    };
    st.playlists = &rows;
    var cl = CmdList{};
    emit(&st, &cl, 120, 24, &.{});
    var found = false;
    for (cl.slice()) |cmd| switch (cmd) {
        .row => |row| {
            if (std.mem.indexOf(u8, row.s, "⚡ Favorites") != null) found = true;
        },
        else => {},
    };
    try std.testing.expect(found);
    var hint_found = false;
    for (cl.slice()) |cmd| switch (cmd) {
        .text => |text| if (text.y == header_rows) {
            hint_found = std.mem.indexOf(u8, text.s, "F favorites") != null and std.mem.indexOf(u8, text.s, "S short tracks") != null;
        },
        else => {},
    };
    try std.testing.expect(hint_found);
}

test "settings shows bounded crossfade value and GUI adjustment hint" {
    var st = U.State{ .screen = .settings, .settings_crossfade_seconds = 6 };
    var cl = CmdList{};
    emit(&st, &cl, 100, 30, &.{});
    var found = false;
    for (cl.slice()) |cmd| switch (cmd) {
        .text => |text| if (std.mem.indexOf(u8, text.s, "Crossfade: 6s") != null) {
            found = std.mem.indexOf(u8, text.s, "0–30s") != null and std.mem.indexOf(u8, text.s, "←/→") != null;
        },
        else => {},
    };
    try std.testing.expect(found);
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
    const n: usize = if (b < 0x80) 1 else if (b >= 0xF0 and b <= 0xF4) 4 else if (b >= 0xE0) 3 else if (b >= 0xC2) 2 else 1;
    if (i + n > s.len) return 1;
    for (i + 1..i + n) |j| if ((s[j] & 0xc0) != 0x80) return 1;
    return n;
}

fn glyphColumns(s: []const u8, i: usize, size: usize) usize {
    const b = s[i];
    if (size == 1) return if (b < 0x20 or (b >= 0x7f and b < 0xa0)) 0 else 1;
    const mask: u8 = if (size == 2) 0x1f else if (size == 3) 0x0f else 0x07;
    var cp: u21 = @intCast(b & mask);
    for (s[i + 1 .. i + size]) |next| cp = (cp << 6) | @as(u21, next & 0x3f);
    if ((cp >= 0x0300 and cp <= 0x036f) or (cp >= 0x1ab0 and cp <= 0x1aff) or
        (cp >= 0x1dc0 and cp <= 0x1dff) or (cp >= 0x20d0 and cp <= 0x20ff) or
        (cp >= 0xfe00 and cp <= 0xfe0f) or (cp >= 0xfe20 and cp <= 0xfe2f) or
        (cp >= 0xe0100 and cp <= 0xe01ef)) return 0;
    if ((cp >= 0x1100 and cp <= 0x115f) or cp == 0x2329 or cp == 0x232a or
        (cp >= 0x2e80 and cp <= 0xa4cf and cp != 0x303f) or
        (cp >= 0xac00 and cp <= 0xd7a3) or (cp >= 0xf900 and cp <= 0xfaff) or
        (cp >= 0xfe10 and cp <= 0xfe19) or (cp >= 0xfe30 and cp <= 0xfe6f) or
        (cp >= 0xff00 and cp <= 0xff60) or (cp >= 0xffe0 and cp <= 0xffe6) or
        (cp >= 0x1f300 and cp <= 0x1faff) or (cp >= 0x20000 and cp <= 0x3fffd)) return 2;
    return 1;
}

/// Terminal-cell width of a UTF-8 string (using common wcwidth ranges).
fn countColumns(s: []const u8) usize {
    var cols: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const size = glyphLen(s, i);
        cols += glyphColumns(s, i, size);
        i += size;
    }
    return cols;
}
