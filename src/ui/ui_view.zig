//! Pure "view" layer: turns a `State` snapshot into a flat list of typed draw
//! commands. No Allegro, no terminal — renderers consume the command list
//! (this is what lets TUI and GUI share one view implementation).
//!
//! Coordinates are in terminal cells (col=x, row=y, 0-based) for the TUI;
//! a future window renderer maps these to pixels.

const std = @import("std");
const U = @import("ui_state.zig");

pub const Style = enum { normal, dim, bold, title, accent, err };

pub const Cmd = union(enum) {
    text: struct { x: u16, y: u16, s: []const u8, style: Style },
    bar: struct { x: u16, y: u16, width: u16, frac: f32 },
    /// Full-width list row starting at column 1.
    row: struct { y: u16, s: []const u8, selected: bool, playing: bool },
};

pub const CmdList = struct {
    items: [512]Cmd = undefined,
    n: usize = 0,

    pub fn text(self: *CmdList, x: u16, y: u16, s: []const u8, style: Style) void {
        self.add(.{ .text = .{ .x = x, .y = y, .s = s, .style = style } });
    }
    pub fn bar(self: *CmdList, x: u16, y: u16, width: u16, f: f32) void {
        self.add(.{ .bar = .{ .x = x, .y = y, .width = width, .frac = f } });
    }
    pub fn row(self: *CmdList, y: u16, s: []const u8, selected: bool, playing: bool) void {
        self.add(.{ .row = .{ .y = y, .s = s, .selected = selected, .playing = playing } });
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

/// Rows pinned to the bottom for the persistent footer.
pub const footer_rows: u16 = 3;

/// Number of library rows that fit in the main content area (for scrolling).
pub fn libraryVisible(height: u16) usize {
    const content = height -| footer_rows;
    return @max(0, (content -| 4));
}

/// Emit the full frame for the current screen + footer into `cl`.
pub fn emit(s: *const U.State, cl: *CmdList, width: u16, height: u16, titles: []const []const u8) void {
    switch (s.screen) {
        .now_playing => emitNowPlaying(s, cl, width, height),
        .library => emitLibrary(s, cl, width, height, titles),
    }
    emitFooter(s, cl, width, height);
}

fn frac(s: *const U.State) f32 {
    if (s.duration <= 0) return 0;
    return @floatCast(@min(s.position / s.duration, 1.0));
}

fn emitNowPlaying(s: *const U.State, cl: *CmdList, width: u16, height: u16) void {
    _ = width;
    _ = height;
    cl.text(4, 1, "NOW PLAYING", .dim);
    cl.text(4, 3, s.title, .title);
    var ab: [512]u8 = undefined;
    if (s.artist.len > 0 or s.album.len > 0) {
        const line = std.fmt.bufPrint(&ab, "{s}{s}{s}", .{ s.artist, if (s.artist.len > 0 and s.album.len > 0) " — " else "", s.album }) catch "";
        cl.text(4, 4, line, .normal);
    } else if (s.path.len > 0) {
        cl.text(4, 4, s.path, .dim);
    }
    cl.text(4, 6, if (s.favorite) "★ favorite" else "☆ not favorite", .dim);

    const bw: u16 = 60;
    cl.text(4, 8, "progress", .dim);
    cl.bar(4, 9, bw, frac(s));

    var rl: [32]u8 = undefined;
    const rs = std.fmt.bufPrint(&rl, "{s}shuffle {s} : {s} / {s}", .{
        if (s.favorite) "★ favorite  " else "",
        if (s.shuffle) "on" else "off",
        tagName(s.repeat_mode),
        "",
    }) catch "";
    cl.text(4, 11, rs, .dim);
}

fn tagName(m: @import("../core/play_queue.zig").RepeatMode) []const u8 {
    return switch (m) {
        .None => "repeat off",
        .All => "repeat all",
        .One => "repeat one",
    };
}

fn emitLibrary(s: *const U.State, cl: *CmdList, width: u16, height: u16, titles: []const []const u8) void {
    _ = width;
    cl.text(2, 0, "LIBRARY", .title);
    const visible = libraryVisible(height);
    const top: u16 = 2;
    var i: usize = 0;
    while (i < visible) : (i += 1) {
        const idx = s.scroll + i;
        if (idx >= titles.len) break;
        const playing = if (s.playing_index) |p| p == idx else false;
        cl.row(top + @as(u16, @intCast(i)), titles[idx], idx == s.selection, playing);
    }
    if (titles.len == 0) cl.text(2, top, "(empty library)", .dim);
}

fn emitFooter(s: *const U.State, cl: *CmdList, width: u16, height: u16) void {
    const by = height -| 3; // progress bar
    const sy = height -| 2; // status
    const hy = height -| 1; // hint

    const bw: u16 = if (width > 8) width - 6 else 40;
    cl.bar(3, by, bw, frac(s));

    var st: [64]u8 = undefined;
    const status = std.fmt.bufPrint(&st, "{s}  vol={d:.0}%  shuffle={s}  repeat={s}", .{
        if (s.playing) "PLAYING" else "PAUSED",
        s.volume * 100,
        if (s.shuffle) "on" else "off",
        switch (s.repeat_mode) {
            .None => "off",
            .All => "all",
            .One => "one",
        },
    }) catch "";
    cl.text(3, sy, status, .accent);
    cl.text(3, hy, "[space]pause [n/p]prev-next [s]shuffle [r]repeat [+/-]vol [1/2]screen [j/k]nav [enter]play [q]quit", .dim);
}


test "view emits commands for both screens + footer" {
    var st = U.State{ .screen = .library, .row_count = 3 };
    var cl = CmdList{};
    const titles = [_][]const u8{ "Alpha", "Beta", "Gamma" };
    emit(&st, &cl, 40, 20, &titles);
    try std.testing.expect(cl.n > 0);

    st.screen = .now_playing;
    st.title = "A Song";
    cl.n = 0;
    emit(&st, &cl, 40, 20, &titles);
    try std.testing.expect(cl.n > 0);
}

test "libraryVisible leaves room for footer + header" {
    try std.testing.expectEqual(@as(usize, 13), libraryVisible(20)); // 20-3-4
}
