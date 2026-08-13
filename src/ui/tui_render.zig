//! Impure leaf: turns `ui_view.Cmd`s into ANSI on a raw-mode terminal.
//! Owns the termios raw-mode + key-reading helpers too.

const std = @import("std");
const view = @import("ui_view.zig");

const cterm = @cImport({
    @cInclude("termios.h");
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
    @cInclude("sys/ioctl.h");
});

pub const Size = struct { w: u16, h: u16 };

/// Current terminal size in cells (falls back to 80x24 if unknown).
pub fn size() Size {
    var ws: cterm.struct_winsize = undefined;
    if (cterm.ioctl(0, @as(c_ulong, cterm.TIOCGWINSZ), &ws) == 0 and ws.ws_col > 0) {
        return .{ .w = ws.ws_col, .h = ws.ws_row };
    }
    return .{ .w = 80, .h = 24 };
}

var g_old_tio: cterm.struct_termios = undefined;

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

fn pos(x: u16, y: u16) void {
    termPrint("\x1b[{d};{d}H", .{ @as(c_int, y + 1), @as(c_int, x + 1) });
}

fn style(s: view.Style) void {
    switch (s) {
        .normal => termWrite("\x1b[0m"),
        .dim => termWrite("\x1b[2;90m"),
        .bold => termWrite("\x1b[1m"),
        .title => termWrite("\x1b[1;36m"),
        .accent => termWrite("\x1b[1;33m"),
        .err => termWrite("\x1b[1;31m"),
    }
}

fn reset() void {
    termWrite("\x1b[0m");
}

fn writeBar(x: u16, y: u16, w: u16, frac: f32, _: usize) void {
    pos(x, y);
    const full = @max(0.0, @min(frac, 1.0));
    const filled: usize = if (full <= 0) 0 else @min(@as(usize, @intFromFloat(full * @as(f32, @floatFromInt(w)))), w);
    termWrite("[");
    style(.normal);
    var i: usize = 0;
    while (i < filled) : (i += 1) termWrite("+");
    style(.dim);
    while (i < w) : (i += 1) termWrite("-");
    reset();
    termWrite("]");
}

pub fn render(cmds: []const view.Cmd, width: usize) void {
    termWrite("\x1b[2J\x1b[H");
    for (cmds) |cmd| switch (cmd) {
        .text => |t| {
            pos(t.x, t.y);
            style(t.style);
            termWrite(t.s);
            reset();
        },
        .bar => |b| {
            writeBar(b.x, b.y, @min(b.width, @as(u16, @intCast(width -| 4))), b.frac, width);
        },
        .row => |r| {
            pos(0, r.y);
            if (r.selected) style(.accent) else style(.normal);
            termWrite("  ");
            var s = std.mem.sliceTo(r.s, 0); // safety
            if (s.len > width - 4) s = s[0 .. width - 4];
            termWrite(s);
            reset();
            // clear rest of the line
            termPrint("\x1b[K", .{});
        },
    };
}
