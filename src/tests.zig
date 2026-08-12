//! Aggregator so `zig build test` runs every test block in the project.
const std = @import("std");

test {
    _ = @import("core/sample_capture.zig");
}

test {
    _ = @import("core/play_queue.zig");
}

test {
    _ = @import("core/config.zig");
}

test {
    _ = @import("core/music_engine_test.zig");
}

test {
    // Compile-check the real engine too (source of truth for the generic).
    _ = @import("core/music_engine.zig").RealEngine;
}

test {
    // The UI layer's foundational pieces.
    _ = @import("ui/ui.zig");
}
