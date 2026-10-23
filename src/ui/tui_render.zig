//! Impure leaf: interprets `ui_view.Cmd`s onto a terminal framebuffer and
//! synchronizes only the changed lines to the terminal.
//!
//! Cells hold UTF-8 text plus terminal display width, so wide characters do not
//! shift subsequent columns or wrap at the edge. Diff-based redraw avoids
//! per-frame full-clear flicker; the cursor is hidden while drawing.

const std = @import("std");
const view = @import("ui_view.zig");
const theme = @import("theme.zig");
const U = @import("ui_state.zig");

const vaxis = @import("vaxis");

pub const Style = view.Style;
pub const Size = struct { w: u16, h: u16 };

const Cell = struct {
    chars: [16]u8 = .{ ' ', 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    len: u8 = 1,
    /// The preceding cell contains a two-column character here.
    continuation: bool = false,
    style: Style = .normal,
    /// Truecolor foreground/background overrides (for half-block art).
    fg: ?[3]u8 = null,
    bg: ?[3]u8 = null,

    fn eql(a: Cell, b: Cell) bool {
        if (a.len != b.len or a.continuation != b.continuation or a.style != b.style) return false;
        if (!optRgbEql(a.fg, b.fg) or !optRgbEql(a.bg, b.bg)) return false;
        for (0..a.len) |k| if (a.chars[k] != b.chars[k]) return false;
        return true;
    }
};

fn optRgbEql(a: ?[3]u8, b: ?[3]u8) bool {
    const aa = a orelse return (b == null);
    const bb = b orelse return false;
    return aa[0] == bb[0] and aa[1] == bb[1] and aa[2] == bb[2];
}

fn blankCell() Cell {
    return .{ .chars = .{ ' ', 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, .len = 1, .style = .normal };
}

var g_palette: theme.Palette = theme.dark();
var g_w: usize = 0;
var g_h: usize = 0;
var g_cur: []Cell = &.{};
var g_prev: []Cell = &.{};
var g_cursor_hidden = false;
var g_tty_buffer: [4096]u8 = undefined;
var g_tty: ?vaxis.Tty = null;
var g_vaxis: ?vaxis.Vaxis = null;
var g_loop: ?vaxis.Loop(vaxis.Event) = null;

// Terminal output is assembled in one reusable buffer per frame. This avoids
// a syscall for every glyph/style transition while retaining partial-write
// handling for slow or short-writing PTYs.
var g_out: [65536]u8 = undefined;
var g_out_len: usize = 0;
var g_output_failed = false;
var g_force_redraw = true;

// ---------------------------------------------------------------------------
// Raw terminal
// ---------------------------------------------------------------------------

/// Initialize Vaxis's platform-specific TTY and asynchronous input loop.
/// Vaxis uses termios on POSIX and the native Windows Console API on Windows.
pub fn init(process: std.process.Init) !bool {
    g_tty = vaxis.Tty.init(process.io, &g_tty_buffer) catch return false;
    errdefer deinit();
    g_vaxis = vaxis.init(process.io, std.heap.page_allocator, process.environ_map, .{}) catch {
        deinit();
        return false;
    };
    g_loop = .init(process.io, &g_tty.?, &g_vaxis.?);
    try g_loop.?.start();
    return true;
}

pub fn deinit() void {
    if (g_loop) |*loop| loop.stop();
    if (g_vaxis) |*vx| if (g_tty) |*tty| vx.deinit(std.heap.page_allocator, tty.writer());
    if (g_tty) |tty| tty.deinit();
    g_loop = null;
    g_vaxis = null;
    g_tty = null;
}

pub fn restoreRaw() void {
    termWrite("\x1b[?25h\x1b[0m\x1b[2J\x1b[H");
    _ = flushOutput();
}

/// Translate common ANSI cursor keys to the existing vi-style vertical bindings.
fn decodeInput(bytes: []const u8) ?u8 {
    if (bytes.len == 1) return bytes[0];
    if (bytes.len >= 3 and bytes[0] == 0x1b and bytes[1] == '[') {
        return switch (bytes[bytes.len - 1]) {
            'A' => 'k',
            'B' => 'j',
            'C', 'D' => null,
            else => null,
        };
    }
    return null;
}

pub fn pollKey() ?u8 {
    const loop = if (g_loop) |*l| l else return null;
    while (loop.tryEvent() catch null) |event| switch (event) {
        .key_press => |key| {
            if (key.mods.ctrl) return null;
            if (key.codepoint == vaxis.Key.escape) return 0x1b;
            if (key.codepoint == vaxis.Key.enter) return '\n';
            if (key.codepoint == vaxis.Key.up) return 'k';
            if (key.codepoint == vaxis.Key.down) return 'j';
            if (key.codepoint == vaxis.Key.left or key.codepoint == vaxis.Key.right) return null;
            if (key.codepoint >= 32 and key.codepoint < 127) return @intCast(key.codepoint);
            return null;
        },
        else => {},
    };
    return null;
}

fn flushOutput() bool {
    if (g_out_len == 0) return true;
    const tty = if (g_tty) |*t| t else return false;
    const writer = tty.writer();
    writer.writeAll(g_out[0..g_out_len]) catch return false;
    writer.flush() catch return false;
    g_out_len = 0;
    return true;
}

fn termWrite(s: []const u8) void {
    if (g_output_failed) return;
    var rest = s;
    while (rest.len > 0) {
        const available = g_out.len - g_out_len;
        if (available == 0) {
            if (!flushOutput()) {
                // The current command could not be queued completely. Keep
                // the framebuffer unswapped and retry the whole frame later.
                g_output_failed = true;
                return;
            }
            continue;
        }
        const n = @min(rest.len, available);
        @memcpy(g_out[g_out_len .. g_out_len + n], rest[0..n]);
        g_out_len += n;
        rest = rest[n..];
    }
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
    g_force_redraw = true;
}

pub fn detectScheme(override: theme.Scheme, auto: bool) theme.Scheme {
    // Vaxis owns terminal input parsing, so avoid consuming terminal replies
    // outside its event loop. Auto mode safely defaults to the dark palette.
    return if (auto) .dark else override;
}

pub fn size() Size {
    if (g_tty) |*tty| {
        if (tty.getWinsize()) |ws| return .{ .w = ws.cols, .h = ws.rows } else |_| {}
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
        .spectrum => g_palette.spectrum,
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
        @memset(g_cur, blankCell());
        @memset(g_prev, blankCell());
        g_w = w;
        g_h = h;
        g_force_redraw = true;
    } else if (w != g_w or h != g_h) {
        g_w = w;
        g_h = h;
        @memset(g_prev, blankCell());
        g_force_redraw = true;
    }
}

fn blank() void {
    @memset(g_cur, blankCell());
}

/// Byte length of a UTF-8 codepoint starting at `i` (1 for invalid/truncated input).
fn utf8Len(s: []const u8, i: usize) usize {
    if (i >= s.len) return 0;
    const b = s[i];
    const n: usize = if (b < 0x80) 1 else if (b >= 0xF0 and b <= 0xF4) 4 else if (b >= 0xE0) 3 else if (b >= 0xC2) 2 else 1;
    if (i + n > s.len) return 1;
    for (i + 1..i + n) |j| if ((s[j] & 0xc0) != 0x80) return 1;
    return n;
}

fn codepoint(s: []const u8) u21 {
    if (s.len == 1) return s[0];
    const mask: u8 = if (s.len == 2) 0x1f else if (s.len == 3) 0x0f else 0x07;
    var cp: u21 = @intCast(s[0] & mask);
    for (s[1..]) |b| cp = (cp << 6) | @as(u21, b & 0x3f);
    return cp;
}

/// Approximate wcwidth without depending on the process locale. Combining
/// marks attach to the previous cell; common East Asian and emoji ranges use 2.
fn displayWidth(cp: u21) usize {
    if (cp == 0 or cp < 32 or (cp >= 0x7f and cp < 0xa0)) return 0;
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

fn setCell(x: usize, y: usize, chars: []const u8, st: Style) void {
    if (y >= g_h or x >= g_w) return;
    const c = &g_cur[y * g_w + x];
    @memset(&c.chars, 0);
    const n = @min(chars.len, c.chars.len);
    for (0..n) |k| c.chars[k] = chars[k];
    c.len = @intCast(n);
    c.continuation = false;
    c.style = st;
    c.fg = null;
    c.bg = null;
}

/// Like `setCell` but with per-cell truecolor overrides (half-block art).
fn setCellRgb(x: usize, y: usize, chars: []const u8, st: Style, fg: [3]u8, bg: [3]u8) void {
    if (y >= g_h or x >= g_w) return;
    const c = &g_cur[y * g_w + x];
    @memset(&c.chars, 0);
    const n = @min(chars.len, c.chars.len);
    for (0..n) |k| c.chars[k] = chars[k];
    c.len = @intCast(n);
    c.continuation = false;
    c.style = st;
    c.fg = fg;
    c.bg = bg;
}

fn blitStr(x: usize, y: usize, s: []const u8, st: Style) void {
    if (y >= g_h) return;
    var col = x;
    var i: usize = 0;
    while (i < s.len and col < g_w) {
        const n = utf8Len(s, i);
        const glyph = s[i .. i + n];
        const width = displayWidth(codepoint(glyph));
        if (width == 0) {
            if (col > x) {
                const prev = &g_cur[y * g_w + col - 1];
                if (!prev.continuation and prev.len + n <= prev.chars.len) {
                    @memcpy(prev.chars[prev.len..][0..n], glyph);
                    prev.len += @intCast(n);
                }
            }
        } else if (col + width <= g_w) {
            setCell(col, y, glyph, st);
            if (width == 2) {
                const continuation = &g_cur[y * g_w + col + 1];
                continuation.* = blankCell();
                continuation.continuation = true;
                continuation.style = st;
            }
            col += width;
        } else break;
        i += n;
    }
}

fn blitBar(x: usize, y: usize, w: usize, frac: f32) void {
    if (y >= g_h) return;
    const filled: usize = if (frac <= 0) 0 else @min(@as(usize, @intFromFloat(frac * @as(f32, @floatFromInt(w)))), w);
    var i: usize = 0;
    while (i < w) : (i += 1) {
        const style: Style = if (i < filled) .bar_fill else .bar_empty;
        setCell(x + i, y, if (i < filled) "━" else "─", style);
    }
}

fn blitHline(y: usize) void {
    if (y >= g_h) return;
    for (0..g_w) |x| setCell(x, y, "─", .dim);
}

fn blitFrame(x: usize, y: usize, w: usize, h: usize, style: Style) void {
    if (w < 2 or h < 2 or x >= g_w or y >= g_h) return;
    const right = @min(x + w - 1, g_w - 1);
    const bottom = @min(y + h - 1, g_h - 1);
    for (x..right + 1) |xx| {
        setCell(xx, y, if (xx == x) "╭" else if (xx == right) "╮" else "─", style);
        setCell(xx, bottom, if (xx == x) "╰" else if (xx == right) "╯" else "─", style);
    }
    for (y + 1..bottom) |yy| {
        setCell(x, yy, "│", style);
        setCell(right, yy, "│", style);
    }
}

fn blitBox(x: usize, y: usize, w: usize, h: usize) void {
    if (w < 2 or h < 2 or x >= g_w or y >= g_h) return;
    const right = @min(x + w - 1, g_w - 1);
    const bottom = @min(y + h - 1, g_h - 1);
    for (y..bottom + 1) |yy| for (x..right + 1) |xx| setCell(xx, yy, " ", .normal);
    for (x..right + 1) |xx| {
        setCell(xx, y, "─", .dim);
        setCell(xx, bottom, "─", .dim);
    }
    for (y..bottom + 1) |yy| {
        setCell(x, yy, "│", .dim);
        setCell(right, yy, "│", .dim);
    }
    setCell(x, y, "╭", .accent);
    setCell(right, y, "╮", .accent);
    setCell(x, bottom, "╰", .accent);
    setCell(right, bottom, "╯", .accent);
}

/// Half-block art: every cell draws the '▀' glyph with the cell's fg as the
/// upper pixel and bg as the lower pixel (two full-color pixels per cell).
fn blitArt(x: usize, y: usize, w: usize, h: usize, cells: []const U.ArtCell) void {
    if (y >= g_h) return;
    for (0..h) |yy| {
        if (y + yy >= g_h) break;
        for (0..w) |xx| {
            const c = cells[yy * w + xx];
            setCellRgb(x + xx, y + yy, "▀", .normal, c.fg, c.bg);
        }
    }
}

fn blitRow(y: usize, s: []const u8, selected: bool, playing: bool) void {
    if (y >= g_h) return;
    const base: Style = if (selected) .selected else .normal;
    for (0..g_w) |x| setCell(x, y, " ", base);
    if (g_w >= 1) {
        const marker: []const u8 = if (playing) "▶" else if (selected) "›" else " ";
        const marker_style: Style = if (playing or selected) .accent else base;
        setCell(0, y, marker, marker_style);
        if (g_w >= 2) setCell(1, y, " ", base);
    }
    blitStr(2, y, s, base);
}

fn flush() void {
    // Retry bytes retained by a previous short/failed write before composing
    // another frame. Do not swap buffers unless this frame reached the TTY.
    if (!flushOutput()) return;
    g_output_failed = false;
    if (!g_cursor_hidden) {
        termWrite("\x1b[?25l");
        g_cursor_hidden = true;
    }
    var y: usize = 0;
    while (y < g_h) : (y += 1) {
        const lo = y * g_w;
        var same = !g_force_redraw;
        if (same) {
            for (0..g_w) |x| {
                if (!g_cur[lo + x].eql(g_prev[lo + x])) {
                    same = false;
                    break;
                }
            }
        }
        if (same) continue;
        pos(0, y);
        var cur_style: ?Style = null;
        var cur_fg: ?[3]u8 = null;
        var cur_bg: ?[3]u8 = null;
        for (0..g_w) |x| {
            const c = g_cur[lo + x];
            if (c.continuation) continue;
            if (cur_style == null or cur_style.? != c.style or !optRgbEql(cur_fg, c.fg) or !optRgbEql(cur_bg, c.bg)) {
                cur_style = c.style;
                cur_fg = c.fg;
                cur_bg = c.bg;
                termWrite(styleSgr(c.style));
                if (c.fg) |f| termPrint("\x1b[38;2;{d};{d};{d}m", .{ f[0], f[1], f[2] });
                if (c.bg) |b| termPrint("\x1b[48;2;{d};{d};{d}m", .{ b[0], b[1], b[2] });
            }
            termWrite(c.chars[0..c.len]);
        }
        termWrite("\x1b[0m\x1b[K");
    }
    if (g_output_failed or !flushOutput()) {
        g_output_failed = true;
        return;
    }
    const tmp = g_cur;
    g_cur = g_prev;
    g_prev = tmp;
    g_force_redraw = false;
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
        .box => |b| blitBox(b.x, b.y, b.w, b.h),
        .frame => |f| blitFrame(f.x, f.y, f.w, f.h, f.style),
        .art => |a| blitArt(a.x, a.y, a.w, a.h, a.cells),
    };
    flush();
}

test "terminal width handles ASCII, combining marks, and wide glyphs" {
    try std.testing.expectEqual(@as(usize, 1), displayWidth(codepoint("A")));
    try std.testing.expectEqual(@as(usize, 0), displayWidth(codepoint("\xcc\x81")));
    try std.testing.expectEqual(@as(usize, 2), displayWidth(codepoint("界")));
    try std.testing.expectEqual(@as(usize, 2), displayWidth(codepoint("🎵")));
    try std.testing.expectEqual(@as(usize, 1), utf8Len("\xc3x", 0)); // malformed leading byte fallback
}

test "blitStr reserves terminal columns for wide glyphs" {
    ensure(4, 1);
    blank();
    blitStr(0, 0, "界e\xcc\x81A", .normal);
    try std.testing.expectEqualStrings("界", g_cur[0].chars[0..@as(usize, g_cur[0].len)]);
    try std.testing.expect(g_cur[1].continuation);
    try std.testing.expectEqualStrings("e\xcc\x81", g_cur[2].chars[0..@as(usize, g_cur[2].len)]);
    try std.testing.expectEqualStrings("A", g_cur[3].chars[0..@as(usize, g_cur[3].len)]);
}

test "ANSI cursor keys map to familiar navigation bindings" {
    try std.testing.expectEqual(@as(?u8, 'k'), decodeInput("\x1b[A"));
    try std.testing.expectEqual(@as(?u8, 'j'), decodeInput("\x1b[B"));
    try std.testing.expect(decodeInput("\x1b[C") == null);
    try std.testing.expect(decodeInput("\x1b[D") == null);
    try std.testing.expectEqual(@as(?u8, 'q'), decodeInput("q"));
    try std.testing.expect(decodeInput("\x1b[5~") == null);
}
