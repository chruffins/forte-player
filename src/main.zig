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

/// Per-callback context for the bootstrap loop.
const Demo = struct {
    engine: *RealEngine,
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

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    // ---- Port of allegro_init.cpp ----
    try allegro_init.initialize();

    // ---- Real engine (valid by construction) ----
    var engine = try RealEngine.create(allocator);
    defer engine.destroy();

    // An event queue shared by the engine (stream event source) + bootstrap.
    var queue = try al.EventQueue.create();
    defer queue.destroy();
    engine.event_queue = &queue;

    // ---- Pick a media file ----
    const candidates = [_][:0]const u8{
        "/usr/share/sounds/alsa/Front_Center.wav",
        "/home/chris/projects/asteroids-cpp/res/audio/gauze.ogg",
    };
    var media_path: [:0]const u8 = candidates[0];
    for (candidates) |cand| {
        if (fileExists(cand)) {
            media_path = cand;
            break;
        }
    }
    if (!fileExists(media_path)) {
        std.debug.print("forte: no media file found\n", .{});
        return error.NoMedia;
    }

    std.debug.print("forte: opening {s}\n", .{media_path});
    try engine.playSound(media_path);
    engine.setGain(0.8);
    engine.setPan(0.0);
    engine.setSpeed(1.0);
    engine.enableCapture(true);

    var demo = Demo{ .engine = engine, .allocator = allocator };
    std.debug.print("forte: duration={d:.3}s entering event loop...\n", .{engine.getDuration()});

    // ---- Canonical Allegro loop (bootstrap; headless-safe) ----
    try bootstrap.run(&queue, .{
        .tick_interval_secs = 0.02, // ~50Hz
        .max_ticks = 100,           // ~2s demo
    }, .{
        .ctx = &demo,
        .on_tick = onTick,
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
