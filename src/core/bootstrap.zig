//! Event-loop / UI bootstrap, ported from the structure of `main_loop.cpp` and
//! `event_handler.cpp` in audio-visualizer-cpp -- but with **no UI** yet.
//!
//! The app's real init creates a display, an event queue, registers the display,
//! timer, keyboard and mouse sources, then pumps events and dispatches them.
//! `run()` reproduces exactly that scaffolding; the UI layer will plug into the
//! `Handlers` callbacks later.

const std = @import("std");
const al = @import("allegro");

/// Per-frame / per-event callbacks. `ctx` is whatever the driver wants (e.g. a
/// pointer to the `MusicEngine`). All callbacks are optional.
pub const Handlers = struct {
    ctx: *anyopaque,

    /// Called once after the display is successfully created.
    on_init_display: ?*const fn (ctx: *anyopaque, display: *al.Display) void = null,
    /// Called every timer tick (approx `Options.tick_interval_secs`).
    on_tick: ?*const fn (ctx: *anyopaque) void = null,
    /// Called every frame to draw; bootstrap flips the display afterwards.
    on_render: ?*const fn (ctx: *anyopaque) void = null,
    /// Called when the audio stream finishes (e.g. to auto-advance the queue).
    on_audio_stream_finished: ?*const fn (ctx: *anyopaque) void = null,
    on_key_down: ?*const fn (ctx: *anyopaque, key: al.KeyCode) void = null,
    on_key_up: ?*const fn (ctx: *anyopaque, key: al.KeyCode) void = null,
    on_mouse_motion: ?*const fn (ctx: *anyopaque, x: f32, y: f32) void = null,
    on_mouse_button: ?*const fn (ctx: *anyopaque, button: i32, pressed: bool, x: f32, y: f32) void = null,
    /// Return true to quit the loop; defaults to quitting.
    on_display_close: ?*const fn (ctx: *anyopaque) bool = null,
};

pub const Options = struct {
    width: i32 = 960,
    height: i32 = 600,
    title: [:0]const u8 = "forte-player",
    tick_interval_secs: f64 = 1.0 / 60.0,
    /// When set, quit after this many ticks (used by headless/test runs).
    max_ticks: ?u64 = null,
};

/// Pump events from `queue`, dispatching to `handlers`. Registers the display,
/// timer, keyboard and mouse sources on the queue. Display creation is
/// optional: on a headless box we degrade to a timer + input loop.
pub fn run(queue: *al.EventQueue, options: Options, handlers: Handlers) !void {
    var display: ?al.Display = null;
    const created = al.Display.create(options.width, options.height) catch null;
    if (created != null) {
        display = created.?;
        al.Display.setNewWindowTitle(options.title);
        queue.registerDisplay(&display.?);
        if (handlers.on_init_display) |h| h(handlers.ctx, &display.?);
    } else {
        std.debug.print("bootstrap: no display available -- running headless\n", .{});
    }
    defer if (display) |*d| d.destroy();

    if (al.keyboard.installed()) {
        var src = al.keyboard.eventSource();
        queue.registerSource(&src);
    }
    if (al.mouse.installed()) {
        var src = al.mouse.eventSource();
        queue.registerSource(&src);
    }

    var ticker = try al.Timer.create(options.tick_interval_secs);
    defer ticker.destroy();
    queue.registerTimer(&ticker);

    var ev: al.Event = undefined;
    var ticks: u64 = 0;

    ticker.start();
    defer ticker.stop();

    while (true) {
        queue.waitForEvent(&ev);
        switch (al.eventType(ev)) {
            .timer => {
                ticks += 1;
                if (handlers.on_tick) |h| h(handlers.ctx);
                if (handlers.on_render) |h| {
                    h(handlers.ctx);
                    if (display != null) al.Display.flip();
                }
                if (options.max_ticks) |m| {
                    if (ticks >= m) break;
                }
            },
            .audio_stream_finished => {
                if (handlers.on_audio_stream_finished) |h| h(handlers.ctx);
            },
            .display_close => {
                const quit = if (handlers.on_display_close) |h| h(handlers.ctx) else true;
                if (quit) break;
            },
            .key_down => {
                if (handlers.on_key_down) |h| h(handlers.ctx, al.eventKeyboardKeycode(ev));
            },
            .key_up => {
                if (handlers.on_key_up) |h| h(handlers.ctx, al.eventKeyboardKeycode(ev));
            },
            .mouse_axes => {
                if (handlers.on_mouse_motion) |h| {
                    h(handlers.ctx, @floatFromInt(ev.mouse.x), @floatFromInt(ev.mouse.y));
                }
            },
            .mouse_button_down, .mouse_button_up => {
                if (handlers.on_mouse_button) |h| {
                    h(handlers.ctx, @intCast(ev.mouse.button), al.eventType(ev) == .mouse_button_down, @floatFromInt(ev.mouse.x), @floatFromInt(ev.mouse.y));
                }
            },
            else => {},
        }
    }
}
