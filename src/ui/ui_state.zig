//! Pure UI state + action reducer (no Allegro). Shared by any frontend.
//!
//! A frontend snapshots the engine/library into a `State`, then on input maps a
//! key to an `Action`, applies it (mutating UI-only fields: screen/selection/
//! scroll) and receives a `Cmd` describing the player operation to execute.

const std = @import("std");
const RepeatMode = @import("../core/play_queue.zig").RepeatMode;

pub const Screen = enum { now_playing, library };

/// A player operation the UI glue must run against the engine.
pub const Cmd = union(enum) {
    none,
    toggle_pause,
    next,
    prev,
    vol_up,
    vol_down,
    toggle_shuffle,
    cycle_repeat,
    toggle_favorite,
    /// Play the library song at this index.
    play_index: usize,
};

/// Semantic input (frontends map raw keys to these).
pub const Action = enum {
    toggle_pause,
    next,
    prev,
    vol_up,
    vol_down,
    toggle_shuffle,
    cycle_repeat,
    toggle_screen,
    select_up,
    toggle_favorite,
    select_down,
    page_up,
    page_down,
    enter,
};

pub const State = struct {
    // ---- UI-only fields (the reducer mutates these) ----
    screen: Screen = .now_playing,
    selection: usize = 0,
    scroll: usize = 0,

    // ---- playhead snapshot (fed by the frontend each frame) ----
    title: []const u8 = "",
    artist: []const u8 = "",
    album: []const u8 = "",
    path: []const u8 = "",
    position: f64 = 0,
    duration: f64 = 0,
    playing: bool = false,
    volume: f32 = 1.0,
    shuffle: bool = false,
    repeat_mode: RepeatMode = .None,
    favorite: bool = false,

    // ---- library snapshot ----
    /// Number of selectable songs (index 0..row_count-1 valid).
    row_count: usize = 0,
    /// Index (in the library) of the currently-playing song, if known.
    playing_index: ?usize = null,
};

/// Pure reducer. `visible` is the number of library rows that fit in the main
/// content area (used for page scrolling + keeping the selection on screen).
pub fn apply(self: *State, action: Action, visible: usize) Cmd {
    switch (action) {
        .toggle_pause => return .toggle_pause,
        .next => return .next,
        .prev => return .prev,
        .vol_up => return .vol_up,
        .vol_down => return .vol_down,
        .toggle_shuffle => return .toggle_shuffle,
        .cycle_repeat => return .cycle_repeat,
        .toggle_favorite => return .toggle_favorite,
        .enter => {
            if (self.screen == .library and self.row_count > 0) {
                return .{ .play_index = self.selection };
            }
            return .none;
        },
        .toggle_screen => {
            self.screen = if (self.screen == .now_playing) .library else .now_playing;
            return .none;
        },
        .select_up => {
            if (self.selection > 0) self.selection -= 1;
        },
        .select_down => {
            if (self.row_count > 0 and self.selection + 1 < self.row_count) self.selection += 1;
        },
        .page_up => {
            const p = @max(@as(usize, 1), visible);
            self.selection = self.selection -| p;
        },
        .page_down => {
            const p = @max(@as(usize, 1), visible);
            self.selection = @min(self.selection + p, self.row_count -| 1);
        },
    }
    // keep the selection visible after any movement
    const v = @max(@as(usize, 1), visible);
    if (self.selection < self.scroll) self.scroll = self.selection;
    if (self.selection >= self.scroll + v) self.scroll = self.selection - (v - 1);
    if (self.row_count > 0 and self.scroll > 0 and self.scroll + v > self.row_count) {
        self.scroll = self.row_count -| v;
    }
    return .none;
}

/// Map a terminal key byte to an Action (TUI-specific mapping, kept here for
/// convenience so the TUI glue stays tiny).
pub fn keyToAction(key: u8) ?Action {
    return switch (key) {
        ' ' => .toggle_pause,
        'n' => .next,
        'p' => .prev,
        '+', '=' => .vol_up,
        '-' => .vol_down,
        's' => .toggle_shuffle,
        'r' => .cycle_repeat,
        'f' => .toggle_favorite,
        '\t', '1' => .toggle_screen,
        '2' => .toggle_screen,
        'j' => .select_down,
        'k' => .select_up,
        'd' => .page_down,
        'u' => .page_up,
        '\n', '\r' => .enter,
        else => null,
    };
}

test "reducer: pause, screen toggle, selection + play" {
    var st = State{};
    try std.testing.expectEqual(@as(Cmd, .toggle_pause), apply(&st, .toggle_pause, 10));

    _ = apply(&st, .toggle_screen, 10);
    try std.testing.expectEqual(Screen.library, st.screen);

    st.row_count = 8;
    _ = apply(&st, .select_down, 3);
    _ = apply(&st, .select_down, 3);
    try std.testing.expectEqual(@as(usize, 2), st.selection);

    const c = apply(&st, .enter, 3);
    try std.testing.expectEqual(@as(Cmd, .{ .play_index = 2 }), c);
}

test "reducer: selection clamped by row_count and page" {
    var st = State{ .row_count = 4 };
    _ = apply(&st, .select_down, 3);
    _ = apply(&st, .select_down, 3);
    _ = apply(&st, .select_down, 3);
    _ = apply(&st, .select_down, 3);
    try std.testing.expectEqual(@as(usize, 3), st.selection); // clamped to last

    _ = apply(&st, .page_up, 2);
    try std.testing.expectEqual(@as(usize, 1), st.selection);
}
