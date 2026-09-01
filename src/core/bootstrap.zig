//! Event-loop / UI bootstrap, ported from the structure of `main_loop.cpp` and
//! `event_handler.cpp` in audio-visualizer-cpp without importing its drawable
//! tree. Frontends provide callbacks for state updates, command rendering, and
//! edge input while this module owns Allegro source registration and teardown.
//!
//! Display creation is optional so the same loop remains safe on headless
//! systems and in tests.

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
    on_key_char: ?*const fn (ctx: *anyopaque, codepoint: u32) void = null,
    on_key_up: ?*const fn (ctx: *anyopaque, key: al.KeyCode) void = null,
    on_mouse_motion: ?*const fn (ctx: *anyopaque, x: f32, y: f32) void = null,
    /// Called for wheel motion; `dz` follows Allegro's wheel direction.
    on_mouse_wheel: ?*const fn (ctx: *anyopaque, x: f32, y: f32, dz: i32) void = null,
    on_mouse_button: ?*const fn (ctx: *anyopaque, button: i32, pressed: bool, x: f32, y: f32) void = null,
    /// Return true to quit the loop; defaults to quitting.
    on_display_close: ?*const fn (ctx: *anyopaque) bool = null,
    /// Optional frontend-owned quit flag, checked after every event.
    should_quit: ?*const fn (ctx: *anyopaque) bool = null,
};

pub const Options = struct {
    width: i32 = 960,
    height: i32 = 600,
    title: [:0]const u8 = "forte-player",
    tick_interval_secs: f64 = 1.0 / 60.0,
    /// When set, quit after this many ticks.
    max_ticks: ?u64 = null,
    /// Optional bound for a headless run; null keeps it running.
    headless_max_ticks: ?u64 = 1,
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
    defer if (display) |*d| {
        // Do not leave the queue holding a display source after the display is
        // destroyed; callers may continue using the queue after run returns.
        queue.unregisterDisplay(d);
        d.destroy();
    };

    var keyboard_source: ?al.EventSource = null;
    if (al.keyboard.installed()) {
        keyboard_source = al.keyboard.eventSource();
        queue.registerSource(&keyboard_source.?);
    }
    defer if (keyboard_source != null) queue.unregisterSource(&keyboard_source.?);

    var mouse_source: ?al.EventSource = null;
    if (al.mouse.installed()) {
        mouse_source = al.mouse.eventSource();
        queue.registerSource(&mouse_source.?);
    }
    defer if (mouse_source != null) queue.unregisterSource(&mouse_source.?);

    var ticker = try al.Timer.create(options.tick_interval_secs);
    var timer_source = ticker.eventSource();
    defer {
        ticker.stop();
        queue.unregisterSource(&timer_source);
        ticker.destroy();
    }
    queue.registerSource(&timer_source);

    var ev: al.Event = undefined;
    var ticks: u64 = 0;

    ticker.start();

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
                if (display == null) {
                    if (options.headless_max_ticks) |m| {
                        if (ticks >= m) break;
                    }
                }
            },
            .audio_stream_finished => {
                if (handlers.on_audio_stream_finished) |h| h(handlers.ctx);
            },
            .display_close => {
                const quit = if (handlers.on_display_close) |h| h(handlers.ctx) else true;
                if (quit) break;
            },
            .display_resize => {
                if (display) |*d| {
                    _ = d.acknowledgeResize();
                }
            },
            .key_down => {
                if (handlers.on_key_down) |h| h(handlers.ctx, al.eventKeyboardKeycode(ev));
            },
            .key_char => {
                if (handlers.on_key_char) |h| h(handlers.ctx, @intCast(ev.keyboard.unichar));
            },
            .key_up => {
                if (handlers.on_key_up) |h| h(handlers.ctx, al.eventKeyboardKeycode(ev));
            },
            .mouse_axes => {
                if (handlers.on_mouse_motion) |h| {
                    h(handlers.ctx, @floatFromInt(ev.mouse.x), @floatFromInt(ev.mouse.y));
                }
                if (ev.mouse.dz != 0) if (handlers.on_mouse_wheel) |h| {
                    h(handlers.ctx, @floatFromInt(ev.mouse.x), @floatFromInt(ev.mouse.y), ev.mouse.dz);
                };
            },
            .mouse_button_down, .mouse_button_up => {
                if (handlers.on_mouse_button) |h| {
                    h(handlers.ctx, @intCast(ev.mouse.button), al.eventType(ev) == .mouse_button_down, @floatFromInt(ev.mouse.x), @floatFromInt(ev.mouse.y));
                }
            },
            else => {},
        }
        if (handlers.should_quit) |should_quit| if (should_quit(handlers.ctx)) break;
    }
}
