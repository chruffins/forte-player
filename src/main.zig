//! GUI frontend for forte-player.
//!
//! Builds the shared `App` (engine + library + queue), then runs the canonical
//! Allegro event loop (see `core/bootstrap.zig`) and reports live stats: mixer
//! postprocess callback, stream event source, capture ring buffer, and
//! transport control. Runs with or without a display (headless on this box if
//! no X). The shared UI layer's real GUI renderer is a WIP; this is a minimal
//! now-playing demo (title + progress bar).

const std = @import("std");
const al = @import("allegro");
const app_mod = @import("app.zig");
const bootstrap = @import("core/bootstrap.zig");
const ui = @import("ui/ui.zig");
const render = @import("ui/render.zig");

/// Per-callback context for the bootstrap loop.
const Demo = struct {
    app: *app_mod.App,
    title: [:0]const u8,
    font: al.font.Font,
    display: ?*al.Display = null,
    ticks: u64 = 0,
    allocator: std.mem.Allocator,
};

fn onTick(ctx: *anyopaque) void {
    const demo: *Demo = @ptrCast(@alignCast(ctx));
    demo.ticks += 1;
    demo.app.engine.update();
    if (demo.ticks % 10 == 0) {
        std.debug.print("  t={d: >4} pos={d:0>5.2}s playing={} samples={d: >9}\n", .{
            demo.ticks, demo.app.engine.getTime(), demo.app.engine.isPlaying(), demo.app.engine.bufferedCount(),
        });
    }
}

fn onRender(ctx: *anyopaque) void {
    const demo: *Demo = @ptrCast(@alignCast(ctx));
    const display = demo.display orelse return; // headless: nothing to draw

    render.beginFrame(display);

    // Now-playing panel
    render.fillRect(ui.Rect{ .x = 0, .y = 0, .w = @floatFromInt(display.getWidth()), .h = @floatFromInt(display.getHeight()) }, render.panel());
    render.fillRect(ui.Rect{ .x = 0, .y = 0, .w = 4, .h = @floatFromInt(display.getHeight()) }, render.accent());

    render.drawText(demo.font, 24, 24, demo.title, render.textColor());

    const dur = demo.app.engine.getDuration();
    const now = demo.app.engine.getTime();
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
    demo.app.engine.handleAudioStreamFinished() catch {
        std.debug.print("forte: auto-advance failed\n", .{});
    };
}

fn onDisplayClose(_: *anyopaque) bool {
    std.debug.print("forte: display close requested\n", .{});
    return true;
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    var app = try app_mod.App.create(allocator, null, null);
    defer app.destroy();
    std.debug.print("forte: config volume={d}% window={d}x{d} scan: +{d} imported ~{d} updated -{d} removed {d} skipped\n", .{
        app.config.getVolumePercent(),
        app.config.getDisplayWidth(),
        app.config.getDisplayHeight(),
        app.scan.imported,
        app.scan.updated,
        app.scan.removed,
        app.scan.skipped,
    });

    // An event queue shared by the engine (stream event source) + bootstrap.
    var queue = try al.EventQueue.create();
    defer queue.destroy();
    app.engine.event_queue = &queue;

    // Start the first playable song.
    var current_path: [:0]const u8 = undefined;
    const chosen = app.startFirstSong() orelse {
        std.debug.print("forte: no playable songs found\n", .{});
        return;
    };
    current_path = chosen;
    std.debug.print("forte: playing {s}\n", .{current_path});
    app.engine.setGain(@as(f32, @floatFromInt(app.config.getVolumePercent())) / 100.0);
    app.engine.setPan(0.0);
    app.engine.setSpeed(1.0);

    var demo = Demo{
        .app = app,
        .title = current_path,
        .font = al.font.Font.loadBuiltin(),
        .allocator = allocator,
    };
    std.debug.print("forte: duration={d:.3}s entering event loop...\n", .{app.engine.getDuration()});

    // ---- Canonical Allegro loop (bootstrap; headless-safe) ----
    try bootstrap.run(&queue, .{
        .width = app.config.getDisplayWidth(),
        .height = app.config.getDisplayHeight(),
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
    const mono_frames = app.engine.bufferedCount() / 2;
    const out_buf = try allocator.alloc(f32, mono_frames);
    defer allocator.free(out_buf);
    const written = app.engine.copyRecentMono(mono_frames, out_buf);

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
    app.engine.setProgress(1.0);
    app.engine.update();
    std.debug.print("forte: after seek(1.0s) pos={d:.2}s\n", .{app.engine.getTime()});

    app.engine.pause();
    std.debug.print("forte: paused -> playing={}\n", .{app.engine.isPlaying()});
    al.system.rest(0.2);
    app.engine.resumePlayback();
    std.debug.print("forte: resumed -> playing={}\n", .{app.engine.isPlaying()});

    app.engine.stop();
    std.debug.print("forte: stopped -> playing={}\n", .{app.engine.isPlaying()});

    std.debug.print("forte: done (engine destroy tears down stream/mixer/voice)\n", .{});
}

fn fileExists(path: [:0]const u8) bool {
    var f = al.file.File.open(path, "r") catch return false;
    _ = f.close();
    return true;
}
