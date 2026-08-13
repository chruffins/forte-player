//! Impure leaf: interprets `ui_view.Cmd`s onto a terminal framebuffer and
//! synchronizes only the changed lines to the terminal.
//!
//! Cells hold a full UTF-8 character (up to 4 bytes) so unicode in tags
//! (… , ’ , ‐ ...) renders as single glyphs occupying one column — this is what
//! stops long/unicode titles from wrapping and producing mojibake/artifacts.
//! Diff-based redraw (only changed lines) avoids per-frame full-clear flicker;
//! the cursor is hidden while drawing.

const std = @import("std");
const view = @import("ui_view.zig");
const theme = @import("theme.zig");

const cterm = @cImport({
    @cInclude("termios.h");
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
    @cInclude("sys/ioctl.h");
});

pub const Style = view.Style;
pub const Size = struct { w: u16, h: u16 };

const Cell = struct {
    chars: [4]u8 = .{ ' ', 0, 0, 0 },
    len: u8 = 1,
    style: Style = .normal,

    fn eql(a: Cell, b: Cell) bool {
        if (a.len != b.len or a.style != b.style) return false;
        for (0..a.len) |k| if (a.chars[k] != b.chars[k]) return false;
        return true;
    }
};

fn blankCell() Cell {
    return .{ .chars = .{ ' ', 0, 0, 0 }, .len = 1, .style = .normal };
}

var g_palette: theme.Palette = theme.dark();
var g_w: usize = 0;
var g_h: usize = 0;
var g_cur: []Cell = &.{};
var g_prev: []Cell = &.{};
var g_cursor_hidden = false;
var g_old_tio: cterm.struct_termios = undefined;

// ---------------------------------------------------------------------------
// Raw terminal
// ---------------------------------------------------------------------------

pub fn enableRaw() void {
    if (cterm.tcgetattr(0, &g_old_tio) != 0) return;
    var raw = g_old_tio;
    raw.c_lflag &= ~(@as(cterm.tcflag_t, cterm.ICANON) | @as(cterm.tcflag_t, cterm.ECHO));
    raw.c_cc[cterm.VMIN] = 0;
    raw.c_cc[cterm.VTIME] = 0;
    _ = cterm.tcsetattr(0, cterm.TCSANOW, &raw);
    const flags = cterm.fcntl(0, cterm.F_GETFL, @as(c_int, 0));
    _ = cterm.fcntl(0, cterm.F_SETFL, @as(c_int, flags) | cterm.O_NONBLOCK);
}

pub fn restoreRaw() void {
    termWrite("\x1b[?25h\x1b[0m\x1b[2J\x1b[H");
    _ = cterm.tcsetattr(0, cterm.TCSANOW, &g_old_tio);
}

pub fn pollKey() ?u8 {
    var b: [1]u8 = undefined;
    const n = cterm.read(0, &b, 1);
    if (n <= 0) return null;
    return b[0];
}

fn termWrite(s: []const u8) void {
    _ = cterm.write(1, s.ptr, s.len);
}
fn termPrint(comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    termWrite(std.fmt.bufPrint(&buf, fmt, args) catch return);
}
fn pos(x: usize, y: usize) void {
    termPrint("\x1b[{d};{d}H", .{ @as(c_int, @intCast(y + 1)), @as(c_int, @intCast(x + 1)) });
}

// ---------------------------------------------------------------------------
// Theme
// ---------------------------------------------------------------------------

pub fn setPalette(scheme: theme.Scheme) void {
    g_palette = theme.palette(scheme);
}

pub fn detectScheme(override: theme.Scheme, auto: bool) theme.Scheme {
    if (!auto) return override;
    termWrite("\x1b]11;?\x1b\\");
    var resp: [256]u8 = undefined;
    var n: usize = 0;
    var tries: usize = 0;
    while (tries < 80 and n < resp.len) : (tries += 1) {
        var b: [1]u8 = undefined;
        if (cterm.read(0, &b, 1) == 1) {
            resp[n] = b[0];
            n += 1;
            if (b[0] == 0x07) break;
            if (n >= 2 and b[0] == 0x5c and resp[n - 2] == 0x1b) break;
        }
        _ = cterm.usleep(1000);
    }
    const rgb = theme.parseRgb(resp[0..n]) orelse return .dark;
    return if (theme.luminanceIsLight(rgb.r, rgb.g, rgb.b)) .light else .dark;
}

pub fn size() Size {
    var ws: cterm.struct_winsize = undefined;
    if (cterm.ioctl(0, @as(c_ulong, cterm.TIOCGWINSZ), &ws) == 0 and ws.ws_col > 0) {
        return .{ .w = ws.ws_col, .h = ws.ws_row };
    }
    return .{ .w = 80, .h = 24 };
}

fn styleSgr(s: Style) []const u8 {
    return switch (s) {
        .normal => g_palette.normal,
        .dim => g_palette.dim,
        .bold => g_palette.bold,
        .title => g_palette.title,
        .accent => g_palette.accent,
        .err => g_palette.err,
        .bar_fill => g_palette.bar_fill,
        .bar_empty => g_palette.bar_empty,
        .selected => g_palette.selected,
    };
}

// ---------------------------------------------------------------------------
// Framebuffer
// ---------------------------------------------------------------------------

fn ensure(w: usize, h: usize) void {
    const n = w * h;
    const a = std.heap.page_allocator;
    if (g_cur.len != n) {
        if (g_cur.len > 0) {
            a.free(g_cur);
            a.free(g_prev);
        }
        g_cur = a.alloc(Cell, n) catch unreachable;
        g_prev = a.alloc(Cell, n) catch unreachable;
        g_w = w;
        g_h = h;
    } else if (w != g_w or h != g_h) {
        g_w = w;
        g_h = h;
    }
}

fn blank() void {
    @memset(g_cur, blankCell());
}

/// Byte length of the UTF-8 character starting at `s[i]` (or 1 for invalid/truncated).
fn utf8Len(s: []const u8, i: usize) usize {
    if (i >= s.len) return 0;
    const b = s[i];
    const n: usize = if (b < 0x80) 1 else if (b >= 0xF0) 4 else if (b >= 0xE0) 3 else if (b >= 0xC0) 2 else 1;
    if (i + n > s.len) return 1;
    return n;
}

fn setCell(x: usize, y: usize, chars: []const u8, st: Style) void {
    if (y >= g_h or x >= g_w) return;
    const c = &g_cur[y * g_w + x];
    @memset(&c.chars, 0);
    const n = @min(chars.len, 4);
    for (0..n) |k| c.chars[k] = chars[k];
    c.len = @intCast(n);
    c.style = st;
}

fn blitStr(x: usize, y: usize, s: []const u8, st: Style) void {
    if (y >= g_h) return;
    var col = x;
    var i: usize = 0;
    while (i < s.len and col < g_w) {
        const n = utf8Len(s, i);
        setCell(col, y, s[i .. i + n], st);
        col += 1;
        i += n;
    }
}

fn blitBar(x: usize, y: usize, w: usize, frac: f32) void {
    if (y >= g_h) return;
    const filled: usize = if (frac <= 0) 0 else @min(@as(usize, @intFromFloat(frac * @as(f32, @floatFromInt(w)))), w);
    var i: usize = 0;
    while (i < w) : (i += 1) {
        const style: Style = if (i < filled) .bar_fill else .bar_empty;
        setCell(x + i, y, if (i < filled) "=" else "-", style);
    }
}

fn blitHline(y: usize) void {
    if (y >= g_h) return;
    for (0..g_w) |x| setCell(x, y, "-", .dim);
}

fn blitRow(y: usize, s: []const u8, selected: bool, playing: bool) void {
    if (y >= g_h) return;
    const base: Style = if (selected) .selected else .normal;
    for (0..g_w) |x| setCell(x, y, " ", base);
    if (g_w >= 1) {
        setCell(0, y, if (playing) ">" else " ", if (playing) .bar_fill else base);
        if (g_w >= 2) setCell(1, y, " ", base);
    }
    blitStr(2, y, s, base);
}

fn flush() void {
    if (!g_cursor_hidden) {
        termWrite("\x1b[?25l");
        g_cursor_hidden = true;
    }
    var y: usize = 0;
    while (y < g_h) : (y += 1) {
        const lo = y * g_w;
        var same = true;
        for (0..g_w) |x| {
            if (!g_cur[lo + x].eql(g_prev[lo + x])) {
                same = false;
                break;
            }
        }
        if (same) continue;
        pos(0, y);
        var cur_style: ?Style = null;
        for (0..g_w) |x| {
            const c = g_cur[lo + x];
            if (cur_style == null or cur_style.? != c.style) {
                cur_style = c.style;
                termWrite(styleSgr(c.style));
            }
            termWrite(c.chars[0..c.len]);
        }
        termWrite("\x1b[0m\x1b[K");
    }
    const tmp = g_cur;
    g_cur = g_prev;
    g_prev = tmp;
}

// ---------------------------------------------------------------------------
// Public render entry
// ---------------------------------------------------------------------------

pub fn render(cmds: []const view.Cmd, width: usize, height: usize) void {
    ensure(width, height);
    blank();
    for (cmds) |cmd| switch (cmd) {
        .text => |t| blitStr(t.x, t.y, t.s, t.style),
        .bar => |b| blitBar(b.x, b.y, @min(b.width, width -| 4), b.frac),
        .row => |r| blitRow(r.y, r.s, r.selected, r.playing),
        .hline => |h| blitHline(h.y),
    };
    flush();
}
