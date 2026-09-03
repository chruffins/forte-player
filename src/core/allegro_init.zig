//! Zig port of `core::initializeAllegro()` from
//! src/core/allegro_init.cpp of audio-visualizer-cpp.
//!
//! Sets up the whole Allegro stack (system, input, audio, and the addons the
//! player uses). Headless-safe: it does not create a display, only registers
//! addons and reserves mixer samples.

const al = @import("allegro");

pub fn initialize() !void {
    return initializeWithInput(true);
}

/// Initialize the audio/add-on stack. Terminal frontends do not need
/// Allegro's native mouse/keyboard event sources (and on macOS installing
/// them can require an AppKit application context).
pub fn initializeWithInput(with_input: bool) !void {
    try al.system.init();
    errdefer al.system.uninstall();

    if (with_input) {
        try al.mouse.install();
        try al.keyboard.install();
    }

    try al.audio.init();
    try al.font.init();
    try al.ttf.init();
    try al.audio.reserveSamples(16);
    try al.acodec.init();
    try al.image.init();
    try al.primitives.init();
}
