//! Pure UI state + action reducer (no Allegro). Shared by any frontend.
//!
//! A frontend snapshots the engine/library into a `State`, then on input maps a
//! key to an `Action`, applies it (mutating UI-only fields: screen/selection/
//! scroll) and receives a `Cmd` describing the player operation to execute.

const std = @import("std");
const RepeatMode = @import("../music/play_queue.zig").RepeatMode;

pub const Screen = enum { now_playing, library, albums, album_detail };

/// A row in the album-detail track list.
pub const AlbumTrackRow = struct {
    title: []const u8,
    track: i64,
    song_id: i64,
};

/// A playable album row for the album browser.
pub const AlbumRow = struct {
    id: i64,
    title: []const u8,
    artist: []const u8,
    year: i64,
    track_count: i64,
    has_cover: bool,
};

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
    /// Seek to this absolute position (seconds).
    seek: f64,
    /// Play the library song at this index.
    play_index: usize,
    /// Open the album detail screen for this album (load its tracks).
    open_album_detail: i64,
    /// Play the album-detail track at this index (seek into the album).
    play_track_in_album: usize,
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
    goto_nowplaying,
    goto_library,
    goto_albums,
    back,
    select_up,
    toggle_favorite,
    select_down,
    page_up,
    page_down,
    enter,
    /// Skip back/forward in the current track (reducer picks the step).
    seek_back,
    seek_forward,
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

    // ---- audio visualizer snapshot ----
    /// Per-band magnitudes in [0,1] for the TUI spectrum (empty = hidden).
    spectrum: []const f32 = &.{},

    // ---- album art snapshot ----
    /// Downsampled cover grid (half-block cells) for Now Playing.
    art: Art = .{},

    // ---- library snapshot ----
    /// Number of selectable library songs (index 0..row_count-1 valid).
    row_count: usize = 0,
    /// Index (in the library) of the currently-playing song, if known.
    playing_index: ?usize = null,

    // ---- album browser snapshot ----
    /// Album rows for the album screen (borrowed from the caller).
    albums: []const AlbumRow = &.{},
    /// Number of albums (same as albums.len; kept explicit for the reducer).
    album_count: usize = 0,
    /// Album id currently playing, or -1.
    playing_album_id: i64 = -1,
    /// Label for the current album-list sort (e.g. "name"), for the header.
    album_sort_label: []const u8 = "",

    // ---- album detail snapshot ----
    /// Album id whose tracks are shown on the album_detail screen.
    album_detail_id: i64 = -1,
    /// Track rows for the open album (borrowed from the caller).
    album_detail_tracks: []const AlbumTrackRow = &.{},
    album_detail_count: usize = 0,
    /// Index (into album_detail_tracks) of the currently-playing track, if known.
    album_detail_playing: ?usize = null,
};

/// One half-block art cell: upper pixel color (fg) + lower pixel color (bg),
/// rendered with the '▀' character so each cell shows two full-color pixels.
pub const ArtCell = struct {
    fg: [3]u8,
    bg: [3]u8,
};

/// A downsampled cover grid (w x h cells). Empty when no art is available.
pub const Art = struct {
    w: u16 = 0,
    h: u16 = 0,
    cells: []const ArtCell = &.{},
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
        .seek_back => {
            // Skip back 5s, clamped to the start of the track.
            return .{ .seek = @max(0.0, self.position - seek_step) };
        },
        .seek_forward => {
            // Skip forward 5s, clamped to the track length when known.
            const target = self.position + seek_step;
            return .{ .seek = if (self.duration > 0) @min(target, self.duration) else target };
        },
        .enter => {
            if (self.screen == .albums and self.album_count > 0 and self.selection < self.albums.len) {
                const id = self.albums[self.selection].id;
                self.album_detail_id = id;
                self.screen = .album_detail;
                // The cursor was an album index; reset to the first track so the
                // highlighted row in the detail view is actually track 0 (and
                // enter plays it). Otherwise the stale album index leaks in as
                // a wrong/out-of-range track selection.
                self.selection = 0;
                self.scroll = 0;
                return .{ .open_album_detail = id };
            }
            if (self.screen == .album_detail and self.album_detail_count > 0) {
                return .{ .play_track_in_album = self.selection };
            }
            if (self.screen == .library and self.row_count > 0) {
                return .{ .play_index = self.selection };
            }
            return .none;
        },
        .toggle_screen => {
            self.screen = switch (self.screen) {
                .now_playing => .library,
                .library => .albums,
                // tab from the album detail returns to the album list
                .albums, .album_detail => .now_playing,
            };
            return .none;
        },
        .back => {
            if (self.screen == .album_detail) self.screen = .albums;
            return .none;
        },
        .goto_nowplaying => {
            self.screen = .now_playing;
            return .none;
        },
        .goto_library => {
            self.screen = .library;
            return .none;
        },
        .goto_albums => {
            self.screen = .albums;
            return .none;
        },
        .select_up => {
            if (self.selection > 0) self.selection -= 1;
        },
        .select_down => {
            if (rowCount(self) > 0 and self.selection + 1 < rowCount(self)) self.selection += 1;
        },
        .page_up => {
            const p = @max(@as(usize, 1), visible);
            self.selection = self.selection -| p;
        },
        .page_down => {
            const p = @max(@as(usize, 1), visible);
            self.selection = @min(self.selection + p, rowCount(self) -| 1);
        },
    }
    // keep the selection visible after any movement
    const v = @max(@as(usize, 1), visible);
    if (self.selection < self.scroll) self.scroll = self.selection;
    if (self.selection >= self.scroll + v) self.scroll = self.selection - (v - 1);
    if (rowCount(self) > 0 and self.scroll > 0 and self.scroll + v > rowCount(self)) {
        self.scroll = rowCount(self) -| v;
    }
    return .none;
}

/// Number of selectable rows for the current screen.
fn rowCount(s: *const State) usize {
    return switch (s.screen) {
        .albums => s.album_count,
        .album_detail => s.album_detail_count,
        else => s.row_count,
    };
}

/// Step used by seek_back / seek_forward, in seconds.
pub const seek_step: f64 = 5.0;

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
        '[', ',' => .seek_back,
        ']', '.' => .seek_forward,
        '\t' => .toggle_screen,
        '1' => .goto_nowplaying,
        '2' => .goto_library,
        '3' => .goto_albums,
        'b', '\x1b' => .back,
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

test "reducer: seek clamps to track bounds" {
    var st = State{ .position = 100, .duration = 120 };

    // forward clamps to duration
    const f = apply(&st, .seek_forward, 0);
    try std.testing.expectEqual(@as(f64, 105.0), f.seek);
    st.position = 118;
    try std.testing.expectEqual(@as(f64, 120.0), (apply(&st, .seek_forward, 0)).seek);

    // back clamps to 0
    st.position = 3;
    try std.testing.expectEqual(@as(f64, 0.0), (apply(&st, .seek_back, 0)).seek);
    st.position = 30;
    try std.testing.expectEqual(@as(f64, 25.0), (apply(&st, .seek_back, 0)).seek);

    // unknown duration: forward just steps (no clamp)
    st.position = 10;
    st.duration = 0;
    try std.testing.expectEqual(@as(f64, 15.0), (apply(&st, .seek_forward, 0)).seek);
}

test "keyToAction maps seek keys" {
    try std.testing.expectEqual(Action.seek_back, keyToAction('[').?);
    try std.testing.expectEqual(Action.seek_back, keyToAction(',').?);
    try std.testing.expectEqual(Action.seek_forward, keyToAction(']').?);
    try std.testing.expectEqual(Action.seek_forward, keyToAction('.').?);
}

test "reducer: album screen enter opens detail; detail enter plays a track" {
    var st = State{
        .screen = .albums,
        .album_count = 2,
        .albums = &.{
            .{ .id = 10, .title = "First", .artist = "A", .year = 2000, .track_count = 3, .has_cover = false },
            .{ .id = 11, .title = "Second", .artist = "B", .year = 2001, .track_count = 5, .has_cover = true },
        },
    };

    _ = apply(&st, .select_down, 10);
    try std.testing.expectEqual(@as(usize, 1), st.selection);
    // Enter on an album opens its detail screen and asks the frontend to load it.
    const open = apply(&st, .enter, 10);
    try std.testing.expectEqual(@as(Cmd, .{ .open_album_detail = 11 }), open);
    try std.testing.expectEqual(Screen.album_detail, st.screen);
    try std.testing.expectEqual(@as(i64, 11), st.album_detail_id);
    // The cursor must reset to the first track (not inherit the album index).
    try std.testing.expectEqual(@as(usize, 0), st.selection);
    try std.testing.expectEqual(@as(usize, 0), st.scroll);

    // Back returns to the album list.
    _ = apply(&st, .back, 10);
    try std.testing.expectEqual(Screen.albums, st.screen);

    // In the detail screen, enter plays the selected track of that album, and
    // selection clamps to the album's track count (not the library's).
    st.screen = .album_detail;
    st.album_detail_id = 11;
    st.album_detail_count = 5;
    st.row_count = 100; // must NOT clamp against this
    st.selection = 0;
    st.scroll = 0;
    for (0..6) |_| _ = apply(&st, .select_down, 10);
    try std.testing.expectEqual(@as(usize, 4), st.selection); // clamped to 5 tracks
    const play = apply(&st, .enter, 10);
    try std.testing.expectEqual(@as(Cmd, .{ .play_track_in_album = 4 }), play);
}

test "reducer: toggle_screen cycles now_playing -> library -> albums -> now_playing" {
    var st = State{};
    _ = apply(&st, .toggle_screen, 10);
    try std.testing.expectEqual(Screen.library, st.screen);
    _ = apply(&st, .toggle_screen, 10);
    try std.testing.expectEqual(Screen.albums, st.screen);
    _ = apply(&st, .toggle_screen, 10);
    try std.testing.expectEqual(Screen.now_playing, st.screen);
}

test "reducer: goto_* set the screen directly" {
    var st = State{};
    _ = apply(&st, .goto_albums, 10);
    try std.testing.expectEqual(Screen.albums, st.screen);
    _ = apply(&st, .goto_library, 10);
    try std.testing.expectEqual(Screen.library, st.screen);
    _ = apply(&st, .goto_nowplaying, 10);
    try std.testing.expectEqual(Screen.now_playing, st.screen);
}
