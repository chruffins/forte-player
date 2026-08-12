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
const ui = @import("ui/ui.zig");
const render = @import("ui/render.zig");

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
    const lib: *lib_mod.Library = @ptrCast(@alignCast(ctx));
    return lib.songPath(@intCast(id));
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

    // Seed the (initially empty) library with a couple of known files. The real
    // taglib-based scanner isn't ported yet, so this stands in for it.
    try lib.load(&db);
    if (lib.count() == 0) {
        std.debug.print("forte: seeding empty library\n", .{});
        try db.begin();
        const artist = try db.addArtist("Demo Artist");
        const album = try db.addAlbum("Demo", artist, 2024);
        const demo_files = [_][:0]const u8{
            "/usr/share/sounds/alsa/Front_Center.wav",
            "/home/chris/projects/asteroids-cpp/res/audio/gauze.ogg",
        };
        var n: i64 = 1;
        for (demo_files) |f| {
            if (fileExists(f)) {
                const title = std.fmt.allocPrint(allocator, "Demo Track {d}", .{n}) catch "Demo";
                defer allocator.free(title);
                _ = try db.addSong(f, title, album, n, 3, 1);
            }
            n += 1;
        }
        try db.commit();
        try lib.load(&db);
    }
    if (lib.count() == 0) {
        std.debug.print("forte: no songs in library\n", .{});
        return error.EmptyLibrary;
    }

    // ---- Play queue + resolve_song over the library ----
    var play_queue = PlayQueue.init(allocator);
    defer play_queue.deinit();
    var qi: usize = 0;
    while (qi < lib.count()) : (qi += 1) try play_queue.enqueue(@intCast(lib.songIdAt(qi)));
    engine.setPlayQueue(&play_queue);
    engine.resolve_song = resolveSong;
    engine.user_context = lib;

    const first_id = lib.songIdAt(0);
    const first_path = lib.songPath(first_id).?;
    std.debug.print("forte: playing {s}\n", .{first_path});
    try engine.playSound(first_path);
    engine.setGain(@as(f32, @floatFromInt(config.getVolumePercent())) / 100.0);
    engine.setPan(0.0);
    engine.setSpeed(1.0);
    engine.enableCapture(true);

    var demo = Demo{
        .engine = engine,
        .title = first_path,
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
