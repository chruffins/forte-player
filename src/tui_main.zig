//! A terminal (ncurses-free) frontend for forte-player.
//!
//! Drives the same headless audio stack as the app (config, db, library,
//! scanner, engine) and renders a now-playing view + controls with ANSI escape
//! codes. Raw-mode key input comes from libc `termios` (avoids the churned
//! `std.io` API in this Zig snapshot).

const std = @import("std");
const al = @import("allegro");
const allegro_init = @import("core/allegro_init.zig");
const RealEngine = @import("core/music_engine.zig").RealEngine;
const config_mod = @import("core/config.zig");
const PlayQueue = @import("core/play_queue.zig").PlayQueue;
const db_mod = @import("music/database.zig");
const lib_mod = @import("music/library.zig");
const scanner = @import("music/scanner.zig");

const cterm = @cImport({
    @cInclude("termios.h");
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
});

// ---------------------------------------------------------------------------
// Minimal raw-terminal helpers (libc)
// ---------------------------------------------------------------------------

var g_old_tio: cterm.struct_termios = undefined;

fn enableRaw() void {
    _ = cterm.tcgetattr(0, &g_old_tio);
    var raw = g_old_tio;
    raw.c_lflag &= ~(@as(cterm.tcflag_t, cterm.ICANON) | @as(cterm.tcflag_t, cterm.ECHO));
    raw.c_cc[cterm.VMIN] = 0; // non-blocking read
    raw.c_cc[cterm.VTIME] = 0;
    _ = cterm.tcsetattr(0, cterm.TCSANOW, &raw);
    const flags = cterm.fcntl(0, cterm.F_GETFL, @as(c_int, 0));
    _ = cterm.fcntl(0, cterm.F_SETFL, @as(c_int, flags) | cterm.O_NONBLOCK);
}

fn restoreRaw() void {
    _ = cterm.tcsetattr(0, cterm.TCSANOW, &g_old_tio);
}

fn pollKey() ?u8 {
    var b: [1]u8 = undefined;
    const n = cterm.read(0, &b, 1);
    if (n <= 0) return null;
    return b[0];
}

fn termWrite(s: []const u8) void {
    _ = cterm.write(1, s.ptr, s.len);
}

fn termPrint(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    termWrite(s);
}

fn clearScreen() void {
    termWrite("\x1b[2J\x1b[H");
}

// basic ANSI palette
const Color = enum(u8) {
    reset = 0,
    bold = 1,
    red = 31,
    green = 32,
    yellow = 33,
    blue = 34,
    magenta = 35,
    cyan = 36,
    white = 37,
    bright_white = 97,
};

fn paint(color: Color) void {
    termPrint("\x1b[{d}m", .{@intFromEnum(color)});
}

fn mmss(secs: f64, buf: *[5]u8) []const u8 {
    const total: i64 = @max(0, @as(i64, @intFromFloat(secs)));
    const m = @divTrunc(total, 60);
    const s = @mod(total, 60);
    buf[0] = @as(u8, '0') + @as(u8, @intCast(@divTrunc(m, 10)));
    buf[1] = @as(u8, '0') + @as(u8, @intCast(@mod(m, 10)));
    buf[2] = ':';
    buf[3] = @as(u8, '0') + @as(u8, @intCast(@divTrunc(s, 10)));
    buf[4] = @as(u8, '0') + @as(u8, @intCast(@mod(s, 10)));
    return buf;
}

fn drawBar(frac: f32, width: usize) void {
    const filled = if (frac <= 0) 0 else @min(@as(usize, @intFromFloat(frac * @as(f32, @floatFromInt(width)))), width);
    termWrite("[");
    paint(.green);
    var i: usize = 0;
    while (i < filled) : (i += 1) termWrite("#");
    paint(.white);
    while (i < width) : (i += 1) termWrite(".");
    paint(.reset);
    termWrite("]");
}

// ---------------------------------------------------------------------------
// Playback-tracking hook context (same wiring as the GUI main)
// ---------------------------------------------------------------------------

const PlaybackCtx = struct { lib: *lib_mod.Library, db: *db_mod.Database };

fn unixSeconds() i64 {
    const ct2 = @cImport(@cInclude("time.h"));
    return @intCast(ct2.time(null));
}

fn resolveSong(id: i32, ctx: *anyopaque) ?[:0]const u8 {
    const p: *PlaybackCtx = @ptrCast(@alignCast(ctx));
    return p.lib.songPath(@intCast(id));
}

fn onSongChanged(path: [:0]const u8, ctx: *anyopaque) void {
    const p: *PlaybackCtx = @ptrCast(@alignCast(ctx));
    const id = p.lib.songIdByPath(path) orelse return;
    p.db.markPlayed(@intCast(id), unixSeconds()) catch return;
}

// ---------------------------------------------------------------------------

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    try allegro_init.initialize();
    config_mod.initAppIdentity();

    const config_path = try config_mod.configFilePath(allocator);
    defer allocator.free(config_path);
    var config = config_mod.Config.create();
    defer config.destroy();
    try config.loadOrCreate(config_path);

    const db_path = try config_mod.databasePath(allocator);
    defer allocator.free(db_path);

    var lib = try lib_mod.Library.create(allocator);
    defer lib.destroy();
    var db = try db_mod.Database.open(lib.arena.allocator(), db_path);
    defer db.deinit();

    // Scan isn't needed every launch when nothing changed, but run it once so an
    // in-memory/empty DB still gets populated at first run.
    const music_dir = config.getMusicDirectory();
    const scan: scanner.ScanResult = scanner.scanDirectory(&db, allocator, music_dir) catch .{};
    try lib.load(&db);
    if (lib.count() == 0) {
        termPrint("\x1b[1;31mno songs in library\x1b[0m\n", .{});
        return;
    }

    // ---- engine + queue + hooks (shared wiring with the GUI) ----
    var engine = try RealEngine.create(allocator);
    defer engine.destroy();
    var playback_ctx = PlaybackCtx{ .lib = lib, .db = &db };
    var play_queue = PlayQueue.init(allocator);
    defer play_queue.deinit();
    var qi: usize = 0;
    while (qi < lib.count()) : (qi += 1) try play_queue.enqueue(@intCast(lib.songIdAt(qi)));
    engine.setPlayQueue(&play_queue);
    engine.resolve_song = resolveSong;
    engine.on_song_changed = onSongChanged;
    engine.user_context = &playback_ctx;
    engine.setGain(@as(f32, @floatFromInt(config.getVolumePercent())) / 100.0);

    // Start the first playable song (skip undecodable files, e.g. MP3 w/o codec).
    var current_path: [:0]const u8 = undefined;
    var started = false;
    var tries: usize = 0;
    var i: usize = 0;
    while (i < lib.count() and !started and tries < 80) : (i += 1) {
        const id = lib.songIdAt(i);
        const path = lib.songPath(id) orelse continue;
        tries += 1;
        if (engine.playSound(path)) |_| {
            current_path = path;
            started = true;
        } else |_| {}
    }
    if (!started) {
        termPrint("\x1b[1;31mno playable songs\x1b[0m\n", .{});
        return;
    }

    enableRaw();
    defer restoreRaw();
    clearScreen();

    var quitting = false;
    while (!quitting) {
        // handle keys
        while (pollKey()) |k| {
            switch (k) {
                'q' => quitting = true,
                ' ' => {
                    if (engine.isPlaying()) engine.pause() else engine.resumePlayback();
                },
                'n' => _ = engine.playNext() catch {},
                'p' => engine.playPrevious() catch {},
                's' => engine.setShuffled(!engine.isShuffled()) catch {},
                'r' => engine.cycleRepeatMode(),
                '+' => engine.setGain(engine.getGain() + 0.05),
                '-' => engine.setGain(engine.getGain() - 0.05),
                else => {},
            }
        }

        // advance when a track ends
        engine.update();
        if (!engine.isPlaying() and engine.getTime() >= engine.getDuration() and engine.getDuration() > 0) {
            engine.handleAudioStreamFinished() catch {};
        }

        // ---- render ----
        clearScreen();
        const now_id = lib.songIdByPath(current_path);
        const song = if (now_id) |idv| lib.getSongById(idv) else null;
        termPrint("\x1b[36mforte-player\x1b[0m  (tui)\n\n", .{});
        paint(.bold);
        termWrite(if (song) |s| s.title else current_path);
        paint(.reset);
        termWrite("\n");
        if (song) |s| termPrint("\x1b[90m{s}\x1b[0m\n", .{s.path});

        const dur = engine.getDuration();
        const now = engine.getTime();
        const frac: f32 = if (dur > 0) @floatCast(@min(now / dur, 1.0)) else 0.0;
        drawBar(frac, 40);
        var t1: [5]u8 = undefined;
        var t2: [5]u8 = undefined;
        termPrint(" {s} / {s}\n", .{ mmss(now, &t1), mmss(dur, &t2) });

        paint(.yellow);
        termPrint("{s}  ", .{if (engine.isPlaying()) "PLAYING" else "PAUSED "});
        paint(.reset);
        termPrint("vol={d:.0}%  shuffle={s}  repeat={s}\n\n", .{
            engine.getGain() * 100, if (engine.isShuffled()) "on" else "off",
            switch (engine.getRepeatMode()) { .None => "off", .All => "all", .One => "one" },
        });
        termPrint("scan: {d} files (+{d}/~{d}/-{d})   library: {d} songs\n", .{ scan.scanned, scan.imported, scan.updated, scan.removed, lib.count() });
        termWrite("\x1b[37m[space] pause/resume  [n] next  [p] prev  [s] shuffle  [r] repeat  [+/-] vol  [q] quit\x1b[0m\n");

        al.system.rest(0.1);
    }

    restoreRaw();
    termWrite("\x1b[2J\x1b[H");
    termPrint("bye.\n", .{});
}
