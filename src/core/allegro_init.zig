//! Zig port of `core::initializeAllegro()` from
//! src/core/allegro_init.cpp of audio-visualizer-cpp.
//!
//! Sets up the whole Allegro stack (system, input, audio, and the addons the
//! player uses). Headless-safe: it does not create a display, only registers
//! addons and reserves mixer samples.

const std = @import("std");
const al = @import("allegro");

pub fn initialize() !void {
    return initializeWithInput(true);
}

/// Initialize the audio/add-on stack. Terminal frontends do not need
/// Allegro's native mouse/keyboard event sources (and on macOS installing
/// them can require an AppKit application context).
pub fn initializeWithInput(with_input: bool) !void {
    al.system.init() catch |err| return reportFailure("system", err);
    errdefer al.system.uninstall();

    if (with_input) {
        al.mouse.install() catch |err| return reportFailure("mouse input", err);
        al.keyboard.install() catch |err| return reportFailure("keyboard input", err);
    }

    al.audio.init() catch |err| return reportFailure("audio driver", err);
    al.font.init() catch |err| return reportFailure("font addon", err);
    al.ttf.init() catch |err| return reportFailure("TrueType font addon", err);
    al.audio.reserveSamples(16) catch |err| return reportFailure("audio sample reservation", err);
    al.acodec.init() catch |err| return reportFailure("audio codec addon", err);
    al.image.init() catch |err| return reportFailure("image addon", err);
    al.primitives.init() catch |err| return reportFailure("primitives addon", err);
}

fn reportFailure(comptime stage: []const u8, err: anyerror) anyerror {
    std.log.err("Allegro {s} initialization failed: {}", .{ stage, err });
    return err;
}
