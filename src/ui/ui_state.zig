//! Pure UI state + action reducer (no Allegro). Shared by any frontend.
//!
//! A frontend snapshots the engine/library into a `State`, then on input maps a
//! key to an `Action`, applies it (mutating UI-only fields: screen/selection/
//! scroll) and receives a `Cmd` describing the player operation to execute.

const std = @import("std");
const RepeatMode = @import("../music/play_queue.zig").RepeatMode;
const lyrics_mod = @import("../music/lyrics.zig");
const health_mod = @import("../music/library_health.zig");

pub const Screen = enum { now_playing, library, albums, album_detail, artists, artist_detail, genres, genre_detail, playlists, playlist_detail, queue, settings };

/// Find a source index in a filtered library view. Filtering preserves source
/// order, so binary search avoids scanning the entire library every frame just
/// to highlight the currently playing row.
pub fn sortedIndexOf(items: []const usize, target: usize) ?usize {
    var low: usize = 0;
    var high: usize = items.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        if (items[mid] < target) {
            low = mid + 1;
        } else if (items[mid] > target) {
            high = mid;
        } else {
            return mid;
        }
    }
    return null;
}

/// A row in the album-detail track list.
pub const AlbumTrackRow = struct {
    title: []const u8,
    artist: []const u8 = "",
    track: i64 = 0,
    disc_number: i64 = 1,
    duration: i64 = 0,
    song_id: i64 = -1,
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

pub const ArtistRow = struct { id: i64, name: []const u8, song_count: i64, album_count: i64 };
pub const GenreRow = struct { id: i64, name: []const u8, song_count: i64 };
pub const PlaylistRow = struct { id: i64, name: []const u8, description: []const u8 = "", song_count: i64, is_smart: bool = false, smart_rule: i64 = 0 };
pub const QueueRow = struct { song_id: i64, title: []const u8, artist: []const u8 = "" };
pub const MetadataField = struct { name: []const u8, value: []const u8 };
pub const PlaylistModalMode = enum { save_queue, create, rename, delete };

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
    /// Play all songs belonging to an artist or genre.
    play_artist: i64,
    play_genre: i64,
    open_artist_detail: i64,
    play_artist_track: usize,
    open_genre_detail: i64,
    play_genre_track: usize,
    /// Open/playlist-detail operations.
    open_playlist_detail: i64,
    play_playlist_track: usize,
    play_playlist: i64,
    play_queue_index: usize,
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
    goto_artists,
    goto_genres,
    goto_playlists,
    goto_queue,
    goto_settings,
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
    toggle_help,
    toggle_context_menu,
};

pub const State = struct {
    // ---- UI-only fields (the reducer mutates these) ----
    screen: Screen = .now_playing,
    selection: usize = 0,
    scroll: usize = 0,
    /// TUI-only overlays. GUI frontends may ignore them.
    help_visible: bool = false,
    context_menu_open: bool = false,
    context_menu_selection: usize = 0,
    context_menu_song_id: i64 = -1,
    context_menu_title: []const u8 = "",
    context_menu_artist: []const u8 = "",
    context_menu_favorite: bool = false,
    playlist_modal_open: bool = false,
    playlist_modal_saved: bool = false,
    playlist_modal_mode: PlaylistModalMode = .save_queue,
    playlist_modal_edit_id: i64 = -1,
    playlist_modal_name: []const u8 = "",
    playlist_modal_cursor: usize = 0,
    playlist_modal_status: []const u8 = "",
    playlist_picker_open: bool = false,
    playlist_picker_saved: bool = false,
    playlist_picker_selection: usize = 0,
    playlist_picker_scroll: usize = 0,
    playlist_picker_title: []const u8 = "",
    playlist_picker_artist: []const u8 = "",
    playlist_picker_status: []const u8 = "",

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
    lyrics: []const lyrics_mod.Line = &.{},
    active_lyric: ?usize = null,

    // ---- audio visualizer snapshot ----
    /// Per-band magnitudes in [0,1], shared by TUI bars and GUI shaders.
    /// Empty means the frontend is not displaying a visualizer.
    spectrum: []const f32 = &.{},

    // ---- album art snapshot ----
    /// Downsampled cover grid (half-block cells) for Now Playing.
    art: Art = .{},
    art_status: ArtStatus = .none,

    // ---- library snapshot ----
    /// Number of selectable library songs (index 0..row_count-1 valid).
    row_count: usize = 0,
    library_filter: []const u8 = "",
    library_searching: bool = false,
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
    /// Current album-browser search filter.
    album_filter: []const u8 = "",
    album_searching: bool = false,

    // ---- album detail snapshot ----
    album_art: Art = .{},
    album_art_status: ArtStatus = .none,
    /// Album id whose tracks are shown on the album_detail screen.
    album_detail_id: i64 = -1,
    /// Track rows for the open album (borrowed from the caller).
    album_detail_tracks: []const AlbumTrackRow = &.{},
    album_detail_count: usize = 0,
    /// Index (into album_detail_tracks) of the currently-playing track, if known.
    album_detail_playing: ?usize = null,

    // ---- artist / genre browser snapshots ----
    artists: []const ArtistRow = &.{},
    artist_count: usize = 0,
    artist_detail_id: i64 = -1,
    artist_detail_name: []const u8 = "",
    artist_detail_tracks: []const AlbumTrackRow = &.{},
    artist_detail_count: usize = 0,
    genres: []const GenreRow = &.{},
    genre_count: usize = 0,
    genre_detail_id: i64 = -1,
    genre_detail_name: []const u8 = "",
    genre_detail_tracks: []const AlbumTrackRow = &.{},
    genre_detail_count: usize = 0,
    filter: []const u8 = "",
    searching: bool = false,

    // ---- playlist detail snapshot ----
    playlist_detail_id: i64 = -1,
    playlist_detail_name: []const u8 = "",
    playlist_detail_tracks: []const AlbumTrackRow = &.{},
    playlist_detail_count: usize = 0,

    // ---- queue snapshot ----
    playlists: []const PlaylistRow = &.{},
    playlist_count: usize = 0,
    queue: []const QueueRow = &.{},
    queue_count: usize = 0,
    queue_current_index: ?usize = null,
    queue_context_label: []const u8 = "Queue",
    queue_dragging: bool = false,
    queue_drop_target: ?usize = null,

    // ---- metadata editor snapshot ----
    metadata_editing: bool = false,
    metadata_status: []const u8 = "",
    metadata_fields: []const MetadataField = &.{},

    metadata_active_index: usize = 0,
    metadata_field: []const u8 = "",
    metadata_value: []const u8 = "",
    metadata_song_title: []const u8 = "",

    // ---- settings snapshot ----
    settings_music_directory: []const u8 = "",
    settings_lastfm_enabled: bool = false,
    settings_normalization_enabled: bool = false,
    settings_normalization_album: bool = false,
    settings_playback_profile: []const u8 = "Default",
    settings_crossfade_seconds: u8 = 0,
    settings_api_key: []const u8 = "",
    settings_shared_secret: []const u8 = "",
    settings_session_key: []const u8 = "",
    settings_editing: bool = false,
    settings_active_field: i8 = -1,
    settings_cursor: usize = 0,
    settings_field: []const u8 = "",
    settings_value: []const u8 = "",
    settings_auth_status: []const u8 = "",
    settings_auth_url: []const u8 = "",
    health_running: bool = false,
    health_scanned: usize = 0,
    health_status: []const u8 = "",
    health_findings: []const health_mod.Finding = &.{},

    // ---- background library scan snapshot
    scanning: bool = false,
    scan_scanned: usize = 0,
    scan_imported: usize = 0,
    scan_updated: usize = 0,
    scan_removed: usize = 0,
};

/// One half-block art cell: upper pixel color (fg) + lower pixel color (bg),
/// rendered with the '▀' character so each cell shows two full-color pixels.
pub const ArtCell = struct {
    fg: [3]u8,
    bg: [3]u8,
};

/// A downsampled cover grid (w x h cells). Empty when no art is available.
pub const ArtStatus = enum { none, loading, ready, unavailable };

pub const Art = struct {
    w: u16 = 0,
    h: u16 = 0,
    cells: []const ArtCell = &.{},
};

fn resetCursor(self: *State) void {
    self.selection = 0;
    self.scroll = 0;
}

fn enter(self: *State) Cmd {
    switch (self.screen) {
        .artists => if (self.selection < self.artists.len and self.artist_count > 0) {
            self.artist_detail_id = self.artists[self.selection].id;
            self.artist_detail_name = self.artists[self.selection].name;
            self.screen = .artist_detail;
            resetCursor(self);
            return .{ .open_artist_detail = self.artist_detail_id };
        },
        .artist_detail => if (self.artist_detail_count > 0) return .{ .play_artist_track = self.selection },
        .genres => if (self.selection < self.genres.len and self.genre_count > 0) {
            self.genre_detail_id = self.genres[self.selection].id;
            self.genre_detail_name = self.genres[self.selection].name;
            self.screen = .genre_detail;
            resetCursor(self);
            return .{ .open_genre_detail = self.genre_detail_id };
        },
        .genre_detail => if (self.genre_detail_count > 0) return .{ .play_genre_track = self.selection },
        .playlists => if (self.selection < self.playlists.len and self.playlist_count > 0) {
            self.playlist_detail_id = self.playlists[self.selection].id;
            self.playlist_detail_name = self.playlists[self.selection].name;
            self.screen = .playlist_detail;
            resetCursor(self);
            return .{ .open_playlist_detail = self.playlist_detail_id };
        },
        .playlist_detail => if (self.playlist_detail_count > 0) return .{ .play_playlist_track = self.selection },
        .queue => if (self.selection < self.queue.len and self.queue_count > 0) return .{ .play_queue_index = self.selection },
        .albums => if (self.selection < self.albums.len and self.album_count > 0) {
            self.album_detail_id = self.albums[self.selection].id;
            self.screen = .album_detail;
            resetCursor(self);
            return .{ .open_album_detail = self.album_detail_id };
        },
        .album_detail => if (self.album_detail_count > 0) return .{ .play_track_in_album = self.selection },
        .library => if (self.row_count > 0) return .{ .play_index = self.selection },
        else => {},
    }
    return .none;
}

fn nextScreen(screen: Screen) Screen {
    return switch (screen) {
        .now_playing => .library,
        .library => .albums,
        .albums => .artists,
        .artists => .genres,
        .artist_detail => .genres,
        .genres => .playlists,
        .genre_detail => .playlists,
        .playlists => .queue,
        .queue => .settings,
        .album_detail, .playlist_detail, .settings => .now_playing,
    };
}

fn screenForNavigation(action: Action) ?Screen {
    return switch (action) {
        .goto_nowplaying => .now_playing,
        .goto_library => .library,
        .goto_albums => .albums,
        .goto_artists => .artists,
        .goto_genres => .genres,
        .goto_playlists => .playlists,
        .goto_queue => .queue,
        .goto_settings => .settings,
        else => null,
    };
}

/// Pure reducer. `visible` is the number of library rows that fit in the main
/// content area (used for page scrolling + keeping the selection on screen).
pub fn apply(self: *State, action: Action, visible: usize) Cmd {
    // List rebuilds can happen between input events (for example after a
    // rescan). Clamp stale state before interpreting Enter or page movement.
    self.selection = @min(self.selection, rowCount(self) -| 1);
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
        .toggle_help => {
            self.help_visible = !self.help_visible;
            return .none;
        },
        .toggle_context_menu => {
            self.context_menu_open = !self.context_menu_open;
            self.context_menu_selection = 0;
            return .none;
        },
        .enter => return enter(self),
        .toggle_screen => {
            self.screen = nextScreen(self.screen);
            resetCursor(self);
            return .none;
        },
        .back => {
            self.screen = switch (self.screen) {
                .album_detail => .albums,
                .artist_detail => .artists,
                .genre_detail => .genres,
                .playlist_detail => .playlists,
                else => self.screen,
            };
            resetCursor(self);
            return .none;
        },
        .goto_nowplaying, .goto_library, .goto_albums, .goto_artists, .goto_genres, .goto_playlists, .goto_queue, .goto_settings => {
            self.screen = screenForNavigation(action).?;
            resetCursor(self);
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
        .playlists => s.playlist_count,
        .queue => s.queue_count,
        .settings => 0,
        .artists => s.artist_count,
        .artist_detail => s.artist_detail_count,
        .genres => s.genre_count,
        .genre_detail => s.genre_detail_count,
        .playlist_detail => s.playlist_detail_count,
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
        '?' => .toggle_help,
        'v' => .toggle_context_menu,
        '\t' => .toggle_screen,
        '1' => .goto_nowplaying,
        '2' => .goto_library,
        '3' => .goto_albums,
        '4' => .goto_artists,
        '5' => .goto_genres,
        '6' => .goto_playlists,
        '7' => .goto_queue,
        '8' => .goto_settings,
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

test "context menu hotkey is mapped and reducer-visible" {
    var state = State{};
    try std.testing.expectEqual(Action.toggle_context_menu, keyToAction('v').?);
    _ = apply(&state, .toggle_context_menu, 0);
    try std.testing.expect(state.context_menu_open);
    _ = apply(&state, .toggle_context_menu, 0);
    try std.testing.expect(!state.context_menu_open);
}

test "help toggle is mapped and reducer-visible" {
    var st = State{};
    try std.testing.expectEqual(Action.toggle_help, keyToAction('?').?);
    _ = apply(&st, .toggle_help, 10);
    try std.testing.expect(st.help_visible);
    _ = apply(&st, .toggle_help, 10);
    try std.testing.expect(!st.help_visible);
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

test "reducer: toggle_screen cycles through library browsers" {
    var st = State{};
    _ = apply(&st, .toggle_screen, 10);
    try std.testing.expectEqual(Screen.library, st.screen);
    _ = apply(&st, .toggle_screen, 10);
    try std.testing.expectEqual(Screen.albums, st.screen);
    _ = apply(&st, .toggle_screen, 10);
    try std.testing.expectEqual(Screen.artists, st.screen);
    _ = apply(&st, .toggle_screen, 10);
    try std.testing.expectEqual(Screen.genres, st.screen);
    _ = apply(&st, .toggle_screen, 10);
    try std.testing.expectEqual(Screen.playlists, st.screen);
}

test "sortedIndexOf finds source indices in filtered order" {
    const indices = [_]usize{ 0, 3, 8, 21 };
    try std.testing.expectEqual(@as(?usize, 2), sortedIndexOf(&indices, 8));
    try std.testing.expectEqual(@as(?usize, 0), sortedIndexOf(&indices, 0));
    try std.testing.expect(sortedIndexOf(&indices, 9) == null);
    try std.testing.expect(sortedIndexOf(&.{}, 0) == null);
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
