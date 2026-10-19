//! Aggregator so `zig build test` runs every test block in the project.
const std = @import("std");

test {
    _ = @import("core/sample_capture.zig");
}

test {
    _ = @import("music/play_queue.zig");
}

test {
    _ = @import("music/loudness.zig");
}

test {
    _ = @import("music/lyrics.zig");
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
    _ = @import("integrations/lastfm.zig");
}

test {
    _ = @import("dsp/fft.zig");
}

test {
    _ = @import("dsp/spectrum.zig");
    _ = @import("dsp/vocal_presence.zig");
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
    _ = @import("music/library_health.zig");
}

test {
    _ = @import("music/metadata_edit.zig");
}

test {
    _ = @import("ui/ui_state.zig");
}

test {
    _ = @import("ui/ui_view.zig");
    _ = @import("ui/tui_render.zig");
}

test {
    _ = @import("ui/theme.zig");
}

test {
    _ = @import("ui/gui_render.zig");
}

test {
    _ = @import("ui/gui_input.zig");
}

test {
    _ = @import("ui/gui_fonts.zig");
}

test {
    _ = @import("ui/gui_framework.zig");
    _ = @import("ui/gui_regression_test.zig");
    _ = @import("ui/gui_visualizer.zig");
    _ = @import("ui/gui_artwork.zig");
    _ = @import("ui/gui_gallery_test.zig");
    _ = @import("world/model.zig");
    _ = @import("allegro").shader;
}

test {
    _ = @import("ui/gui_icons.zig");
}
