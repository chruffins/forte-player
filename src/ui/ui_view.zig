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

    pub fn text(self: *CmdList, x: u16, y: u16, s: []const u8, style: Style) void {
        const avail = self.scratch.len - self.scratch_n;
        const len = @min(s.len, avail);
        @memcpy(self.scratch[self.scratch_n .. self.scratch_n + len], s[0..len]);
        const owned = self.scratch[self.scratch_n .. self.scratch_n + len];
        self.scratch_n += len;
        self.add(.{ .text = .{ .x = x, .y = y, .s = owned, .style = style } });
    }
    pub fn bar(self: *CmdList, x: u16, y: u16, width: u16, f: f32) void {
        self.add(.{ .bar = .{ .x = x, .y = y, .width = width, .frac = f } });
    }
    pub fn row(self: *CmdList, y: u16, s: []const u8, selected: bool, playing: bool) void {
        self.add(.{ .row = .{ .y = y, .s = s, .selected = selected, .playing = playing } });
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

pub fn emit(s: *const U.State, cl: *CmdList, width: u16, height: u16, titles: []const []const u8) void {
    emitHeader(s, cl, width);
    switch (s.screen) {
        .now_playing => emitNowPlaying(s, cl, width, height),
        .library => emitLibrary(s, cl, width, height, titles),
        .albums => emitAlbums(s, cl, width, height),
        .album_detail => emitAlbumDetail(s, cl, width, height),
    }
    emitFooter(s, cl, width, height);
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
    _ = width;
    var hd: [64]u8 = undefined;
    const hline = std.fmt.bufPrint(&hd, "Library  ({d} songs)", .{titles.len}) catch "Library";
    cl.text(2, header_rows, hline, .bold);

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
    var hd: [96]u8 = undefined;
    const hline = std.fmt.bufPrint(&hd, "Albums  ({d})   sort: {s}", .{ s.album_count, if (s.album_sort_label.len > 0) s.album_sort_label else "name" }) catch "Albums";
    cl.text(2, header_rows, hline, .bold);

    const visible = libraryVisible(height);
    const top: u16 = header_rows + 1;
    var i: usize = 0;
    while (i < visible) : (i += 1) {
        const idx = s.scroll + i;
        if (idx >= s.album_count) break;
        const a = s.albums[idx];
        var line_buf: [256]u8 = undefined;
        const line = std.fmt.bufPrint(&line_buf, "{s}{s}  {s}  {d} tracks{s}", .{
            a.title,
            if (a.year > 0) blk: {
                var yb: [16]u8 = undefined;
                break :blk std.fmt.bufPrint(&yb, "  ({d})", .{a.year}) catch "";
            } else "",
            a.artist,
            a.track_count,
            if (a.has_cover) "  [art]" else "",
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

    var hd: [256]u8 = undefined;
    const hline = std.fmt.bufPrint(&hd, "{s}{s}  {s}   ({d} tracks)", .{
        title,
        if (year > 0) blk: {
            var yb: [16]u8 = undefined;
            break :blk std.fmt.bufPrint(&yb, " ({d})", .{year}) catch "";
        } else "",
        artist,
        s.album_detail_count,
    }) catch "Album";
    cl.text(2, header_rows, truncGlyphs(hline, width -| 2), .bold);

    const visible = libraryVisible(height);
    const top: u16 = header_rows + 1;
    var i: usize = 0;
    while (i < visible) : (i += 1) {
        const idx = s.scroll + i;
        if (idx >= s.album_detail_count) break;
        const t = s.album_detail_tracks[idx];
        const tnum: []const u8 = if (t.track > 0) blk: {
            var tb: [8]u8 = undefined;
            break :blk std.fmt.bufPrint(&tb, "{d:>2}. ", .{t.track}) catch "";
        } else "";
        var lb: [256]u8 = undefined;
        const line = std.fmt.bufPrint(&lb, "{s}{s}", .{ tnum, t.title }) catch continue;
        const playing = if (s.album_detail_playing) |p| p == idx else false;
        cl.row(top + @as(u16, @intCast(i)), truncGlyphs(line, width -| 2), idx == s.selection, playing);
    }
    if (s.album_detail_count == 0) cl.text(2, top, "(no tracks)", .dim);
}

fn emitFooter(s: *const U.State, cl: *CmdList, width: u16, height: u16) void {
    if (height <= footer_rows) return;
    const top = height - footer_rows;

    cl.hline(top); // separator above footer

    // progress bar + time
    const by = top + 1;
    const bw = barWidth(width);
    cl.bar(3, by, bw, frac(s));
    var t1: [5]u8 = undefined;
    var t2: [5]u8 = undefined;
    cl.text(@as(u16, 3 + bw + 2), by, mmss(s.position, &t1), .normal);
    cl.text(@as(u16, 3 + bw + 8), by, "/", .dim);
    cl.text(@as(u16, 3 + bw + 10), by, mmss(s.duration, &t2), .dim);

    // status line
    var st: [96]u8 = undefined;
    const status = std.fmt.bufPrint(&st, "{s}   vol {d:.0}%   shuffle {s}   repeat {s}", .{
        if (s.playing) "PLAYING" else "PAUSED",
        s.volume * 100,
        if (s.shuffle) "on" else "off",
        switch (s.repeat_mode) {
            .None => "off",
            .All => "all",
            .One => "one",
        },
    }) catch "";
    cl.text(3, by + 1, status, .accent);

    // hint line
    cl.text(3, by + 2, "space:pause  n/p:next/prev  [ ]/.:seek +/-:vol  s:shuffle  r:repeat  f:favorite  1/2/3:view  j/k:nav  enter:play  q:quit", .dim);
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
