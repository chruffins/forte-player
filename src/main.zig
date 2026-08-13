//! forte-player — Zig port exercise for the allegro5-zig wrapper.
//!
//! Drives the real `MusicEngine` (AllegroDriver) through the bootstrap event
//! loop and reports live stats: mixer postprocess callback, stream event
//! source, capture ring buffer, and transport control all cohere against the
//! wrapper. Runs with or without a display (headless on this box if no X).

const std = @import("std");
const al = @import("allegro");
const allegro_init = @import("core/allegro_init.zig");
const bootstrap = @import("core/bootstrap.zig");
const RealEngine = @import("core/music_engine.zig").RealEngine;
const config_mod = @import("core/config.zig");
const PlayQueue = @import("core/play_queue.zig").PlayQueue;
const db_mod = @import("music/database.zig");
const lib_mod = @import("music/library.zig");
const scanner = @import("music/scanner.zig");
const taglib_meta = @import("music/taglib_meta.zig");
const ui = @import("ui/ui.zig");
const render = @import("ui/render.zig");
const ct = @cImport({ @cInclude("time.h"); });

/// Engine-hook context: lets resolve_song reach the Library and lets
/// on_song_changed reach both the Library and Database (for playback tracking).
const PlaybackCtx = struct {
    lib: *lib_mod.Library,
    db: *db_mod.Database,
};

fn unixSeconds() i64 {
    return @intCast(ct.time(null));
}

/// Per-callback context for the bootstrap loop.
const Demo = struct {
    engine: *RealEngine,
    title: [:0]const u8,
    font: al.font.Font,
    display: ?*al.Display = null,
    ticks: u64 = 0,
    allocator: std.mem.Allocator,
};

fn onTick(ctx: *anyopaque) void {
    const demo: *Demo = @ptrCast(@alignCast(ctx));
    demo.ticks += 1;
    demo.engine.update();
    if (demo.ticks % 10 == 0) {
        std.debug.print("  t={d: >4} pos={d:0>5.2}s playing={} samples={d: >9}\n", .{
            demo.ticks, demo.engine.getTime(), demo.engine.isPlaying(), demo.engine.bufferedCount(),
        });
    }
}

fn onRender(ctx: *anyopaque) void {
    const demo: *Demo = @ptrCast(@alignCast(ctx));
    const display = demo.display orelse return; // headless: nothing to draw

    render.beginFrame(display);

    // Now-playing panel
    render.fillRect(ui.Rect{ .x = 0, .y = 0, .w = @floatFromInt((display.getWidth())), .h = @floatFromInt(display.getHeight()) }, render.panel());
    render.fillRect(ui.Rect{ .x = 0, .y = 0, .w = 4, .h = @floatFromInt(display.getHeight()) }, render.accent());

    render.drawText(demo.font, 24, 24, demo.title, render.textColor());

    const dur = demo.engine.getDuration();
    const now = demo.engine.getTime();
    const frac: f32 = if (dur > 0) @floatCast(@min(now / dur, 1.0)) else 0.0;
    render.bar(.{ .x = 24, .y = 90, .w = 640, .h = 8 }, frac, render.muted(), render.accent());

    render.endFrame();
}

fn onInitDisplay(ctx: *anyopaque, display: *al.Display) void {
    const demo: *Demo = @ptrCast(@alignCast(ctx));
    demo.display = display;
}

fn onAudioStreamFinished(ctx: *anyopaque) void {
    const demo: *Demo = @ptrCast(@alignCast(ctx));
    std.debug.print("forte: stream finished -> auto-advance\n", .{});
    demo.engine.handleAudioStreamFinished() catch {
        std.debug.print("forte: auto-advance failed\n", .{});
    };
}

fn onDisplayClose(_: *anyopaque) bool {
    std.debug.print("forte: display close requested\n", .{});
    return true;
}

/// Map a song id -> file path via the Library (engine's resolve_song hook).
fn resolveSong(id: i32, ctx: *anyopaque) ?[:0]const u8 {
    const p: *PlaybackCtx = @ptrCast(@alignCast(ctx));
    return p.lib.songPath(@intCast(id));
}

/// Fired when a song begins: bump play_count / last_played in the DB.
fn onSongChanged(path: [:0]const u8, ctx: *anyopaque) void {
    const p: *PlaybackCtx = @ptrCast(@alignCast(ctx));
    const id = p.lib.songIdByPath(path) orelse return;
    p.db.markPlayed(@intCast(id), unixSeconds()) catch return;
    std.debug.print("forte: recorded play for song id {d}\n", .{id});
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    // ---- Port of allegro_init.cpp ----
    try allegro_init.initialize();
    config_mod.initAppIdentity();

    // ---- Load persisted settings (defaults on first run) ----
    const config_path = try config_mod.configFilePath(allocator);
    defer allocator.free(config_path);
    var config = config_mod.Config.create();
    defer config.destroy();
    try config.loadOrCreate(config_path);
    std.debug.print("forte: config {s} volume={d}% window={d}x{d}\n", .{
        config_path,
        config.getVolumePercent(),
        config.getDisplayWidth(),
        config.getDisplayHeight(),
    });

    // ---- Real engine (valid by construction) ----
    var engine = try RealEngine.create(allocator);
    defer engine.destroy();

    // An event queue shared by the engine (stream event source) + bootstrap.
    var queue = try al.EventQueue.create();
    defer queue.destroy();
    engine.event_queue = &queue;

    // ---- Music library (SQLite) ----
    const db_path = try config_mod.databasePath(allocator);
    defer allocator.free(db_path);
    std.debug.print("forte: database {s}\n", .{db_path});

    var lib = try lib_mod.Library.create(allocator);
    defer lib.destroy();
    var db = try db_mod.Database.open(lib.arena.allocator(), db_path);
    defer db.deinit();

    // Scan the configured music directory into the database.
    const music_dir = config.getMusicDirectory();
    std.debug.print("forte: scanning {s}\n", .{music_dir});
    const scan = scanner.scanDirectory(&db, allocator, music_dir, taglib_meta.extractor) catch |e| {
        std.debug.print("forte: scan failed: {}\n", .{e});
        return e;
    };
    std.debug.print("forte: scanned {d} files: +{d} imported, ~{d} updated, -{d} removed, {d} unchanged\n", .{
        scan.scanned, scan.imported, scan.updated, scan.removed, scan.skipped,
    });
    try lib.load(&db);
    if (lib.count() == 0) {
        std.debug.print("forte: no songs in library\n", .{});
        return error.EmptyLibrary;
    }

    // ---- Play queue + resolve_song / playback-state over the library ----
    var playback_ctx = PlaybackCtx{ .lib = lib, .db = &db };

    var play_queue = PlayQueue.init(allocator);
    defer play_queue.deinit();
    var qi: usize = 0;
    while (qi < lib.count()) : (qi += 1) try play_queue.enqueue(@intCast(lib.songIdAt(qi)));
    engine.setPlayQueue(&play_queue);
    engine.resolve_song = resolveSong;
    engine.on_song_changed = onSongChanged;
    engine.user_context = &playback_ctx;

    // Find a playable song. Prefer non-MP3 first (this Allegro build may lack an
    // MP3 codec) and cap attempts so a huge undecodable library can't stall startup.
    var current_path: [:0]const u8 = undefined;
    var started = false;

    const try_play = struct {
        fn go(eng: *RealEngine, libv: *lib_mod.Library, current: *[:0]const u8, startedv: *bool, extended: bool) usize {
            var tries: usize = 0;
            var i: usize = 0;
            while (i < libv.count() and !startedv.* and tries < 60) : (i += 1) {
                const id = libv.songIdAt(i);
                const path = libv.songPath(id) orelse continue;
                const is_mp3 = std.mem.endsWith(u8, path, ".mp3");
                if (is_mp3 == extended) {
                    tries += 1;
                    if (eng.playSound(path)) |_| {
                        current.* = path;
                        startedv.* = true;
                    } else |_| {}
                }
            }
            return tries;
        }
    }.go;
    _ = try_play(engine, lib, &current_path, &started, false); // non-mp3
    _ = try_play(engine, lib, &current_path, &started, true); // mp3 fallback

    if (!started) {
        std.debug.print("forte: no playable songs found\n", .{});
        return;
    }
    std.debug.print("forte: playing {s}\n", .{current_path});
    engine.setGain(@as(f32, @floatFromInt(config.getVolumePercent())) / 100.0);
    engine.setPan(0.0);
    engine.setSpeed(1.0);
    engine.enableCapture(true);

    var demo = Demo{
        .engine = engine,
        .title = current_path,
        .font = al.font.Font.loadBuiltin(),
        .allocator = allocator,
    };
    std.debug.print("forte: duration={d:.3}s entering event loop...\n", .{engine.getDuration()});

    // ---- Canonical Allegro loop (bootstrap; headless-safe) ----
    try bootstrap.run(&queue, .{
        .width = config.getDisplayWidth(),
        .height = config.getDisplayHeight(),
        .tick_interval_secs = 0.02, // ~50Hz
        .max_ticks = 100,           // ~2s demo
    }, .{
        .ctx = &demo,
        .on_tick = onTick,
        .on_render = onRender,
        .on_init_display = onInitDisplay,
        .on_audio_stream_finished = onAudioStreamFinished,
        .on_display_close = onDisplayClose,
    });

    // ---- Drain the capture ring (proves the callback produced audio data) ----
    const mono_frames = engine.bufferedCount() / 2;
    const out_buf = try allocator.alloc(f32, mono_frames);
    defer allocator.free(out_buf);
    const written = engine.copyRecentMono(mono_frames, out_buf);

    var sum_sq: f64 = 0.0;
    var peak: f32 = 0.0;
    for (out_buf[0..written]) |s| {
        sum_sq += @as(f64, @floatCast(s * s));
        if (@abs(s) > peak) peak = @abs(s);
    }
    const rms: f64 = if (written > 0) @sqrt(sum_sq / @as(f64, @floatFromInt(written))) else 0.0;
    std.debug.print("\nforte: captured {d} mono frames (peak={d:.3} rms={d:.4})\n", .{
        written, peak, rms,
    });

    // ---- Transport edits ----
    engine.setProgress(1.0);
    engine.update();
    std.debug.print("forte: after seek(1.0s) pos={d:.2}s\n", .{engine.getTime()});

    engine.pause();
    std.debug.print("forte: paused -> playing={}\n", .{engine.isPlaying()});
    al.system.rest(0.2);
    engine.resumePlayback();
    std.debug.print("forte: resumed -> playing={}\n", .{engine.isPlaying()});

    engine.stop();
    std.debug.print("forte: stopped -> playing={}\n", .{engine.isPlaying()});

    std.debug.print("forte: done (engine destroy tears down stream/mixer/voice)\n", .{});
}

fn fileExists(path: [:0]const u8) bool {
    var f = al.file.File.open(path, "r") catch return false;
    _ = f.close();
    return true;
}
