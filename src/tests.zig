//! Aggregator so `zig build test` runs every test block in the project.
const std = @import("std");

test {
    _ = @import("core/sample_capture.zig");
}

test {
    _ = @import("music/play_queue.zig");
}

test {
    _ = @import("core/config.zig");
}

test {
    _ = @import("integrations/discord_rpc.zig");
}

test {
    _ = @import("integrations/cover_resolver.zig");
}

test {
    _ = @import("dsp/fft.zig");
}

test {
    _ = @import("dsp/spectrum.zig");
}

test {
    _ = @import("ui/cover_art.zig");
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

test {
    _ = @import("music/database.zig");
}

test {
    _ = @import("music/library.zig");
}

test {
    _ = @import("music/scanner.zig");
}

test {
    _ = @import("ui/ui_state.zig");
}

test {
    _ = @import("ui/ui_view.zig");
}

test {
    _ = @import("ui/theme.zig");
}
