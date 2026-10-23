//! GUI frontend for Forte Player.
//!
//! Shares semantic state/reducer operations with the TUI, but uses a native
//! pixel-space layout shared by rendering and hit testing.

const std = @import("std");
const al = @import("allegro");
const app_mod = @import("app.zig");
const db_mod = @import("music/database.zig");
const metadata_edit = @import("music/metadata_edit.zig");
const PlaybackContextType = @import("music/play_queue.zig").PlaybackContextType;
const gui_jobs = @import("ui/gui_jobs.zig");
const bootstrap = @import("core/bootstrap.zig");
const gui_render = @import("ui/gui_render.zig");
const gui_fonts = @import("ui/gui_fonts.zig");
const gui_input = @import("ui/gui_input.zig");
const gui_framework = @import("ui/gui_framework.zig");
const ui = @import("ui/ui.zig");
const gui_artwork = @import("ui/gui_artwork.zig");
const spectrum = @import("dsp/spectrum.zig");
const lyrics_mod = @import("music/lyrics.zig");
const U = @import("ui/ui_state.zig");
const gui_layout = @import("ui/gui_layout.zig");
const gui_visualizer = @import("ui/gui_visualizer.zig");
const player_control = @import("integrations/player_control.zig");

const ScanJob = gui_jobs.ScanJob;
const AuthJob = gui_jobs.AuthJob;
const AuthOp = gui_jobs.AuthOp;

const Demo = struct {
    app: *app_mod.App,
    control: ?*player_control.Server = null,
    scan: ScanJob,
    health: gui_jobs.HealthJob,
    auth: AuthJob,
    fonts: gui_fonts.FontSet,
    display: ?*al.Display = null,
    state: U.State = .{ .screen = .albums },
    covers: gui_artwork.Cache,
    current_album_id: i64 = -1,
    inspector_open: bool = true,
    inspector_lyrics: bool = false,
    album_actions: ?i64 = null,
    selection_anchor: usize = 0,
    gallery_columns: usize = 0,
    gallery_pitch: f32 = 0,
    viewport_height: f32 = 0,
    quit: bool = false,
    snapshot_arena: std.heap.ArenaAllocator,
    detail_arena: std.heap.ArenaAllocator,
    queue_arena: std.heap.ArenaAllocator,
    current_arena: std.heap.ArenaAllocator,
    library_rows: std.ArrayList(gui_render.TrackRow) = .empty,
    filtered_library_rows: std.ArrayList(gui_render.TrackRow) = .empty,
    library_titles: std.ArrayList([]const u8) = .empty,
    filtered_library_titles: std.ArrayList([]const u8) = .empty,
    filtered_library_indices: std.ArrayList(usize) = .empty,
    filtered_albums: std.ArrayList(U.AlbumRow) = .empty,
    filtered_artists: std.ArrayList(U.ArtistRow) = .empty,
    filtered_genres: std.ArrayList(U.GenreRow) = .empty,
    filtered_playlists: std.ArrayList(U.PlaylistRow) = .empty,
    search_input: gui_framework.TextInput = .{},
    search_active: bool = false,
    search_screen: U.Screen = .library,
    ignore_search_trigger_char: bool = false,
    ignore_text_trigger: ?u32 = null,
    albums: std.ArrayList(U.AlbumRow) = .empty,
    album_sort: db_mod.Database.AlbumSort = .by_name,
    album_tracks: std.ArrayList(U.AlbumTrackRow) = .empty,
    artists: std.ArrayList(U.ArtistRow) = .empty,
    genres: std.ArrayList(U.GenreRow) = .empty,
    playlists: std.ArrayList(U.PlaylistRow) = .empty,
    artist_tracks: std.ArrayList(U.AlbumTrackRow) = .empty,
    genre_tracks: std.ArrayList(U.AlbumTrackRow) = .empty,
    playlist_tracks: std.ArrayList(U.AlbumTrackRow) = .empty,
    queue_rows: std.ArrayList(U.QueueRow) = .empty,
    queue_generation: u64 = std.math.maxInt(u64),
    current_song_id: i64 = -1,
    current_artist: []const u8 = "",
    current_album: []const u8 = "",
    visualizer: gui_visualizer.Visualizer = .{},
    display_resources_released: bool = false,
    visualizer_mode: gui_visualizer.Mode = .mirror,
    last_spectrum_time: f64 = 0,
    analyzer: spectrum.Analyzer,
    smoother: spectrum.Smoother = .{},
    /// The capture sequence lets the GUI avoid running an FFT when the audio
    /// callback has not published a newer block (and when the spectrum is not
    /// visible at all).
    last_capture_sequence: u64 = std.math.maxInt(u64),
    spectrum_ticks: u8 = 0,
    audio_samples: [spectrum.n_samples]f32 = undefined,
    spectrum_bands: [spectrum.n_bands]f32 = @splat(0),
    auth_token: []u8 = &.{},
    auth_url: []u8 = &.{},
    auth_status: []const u8 = "",
    hover_nav: ?U.Screen = null,
    hover_control: ?gui_input.Control = null,
    pressed_control: ?gui_input.Control = null,
    hover_row: ?usize = null,
    last_click_index: ?usize = null,
    last_click_time: f64 = 0,
    last_click_screen: U.Screen = .now_playing,
    metadata_rows: [8]U.MetadataField = undefined,
    settings_fields: [3]gui_framework.TextInput = .{ .{}, .{}, .{} },
    settings_active_field: ?usize = null,
    metadata_fields: [8]gui_framework.TextInput = .{ .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{} },
    metadata_song_id: i64 = -1,
    metadata_status: []const u8 = "",
    scroll_offset: f32 = 0,
    scroll_anchor: usize = 0,
    scroll_screen: U.Screen = .now_playing,
    queue_drag_from: usize = 0,
    scrollbar_dragging: bool = false,
    scrollbar_drag_offset: f32 = 0,
    seek_dragging: bool = false,
    volume_dragging: bool = false,
    playlist_name_input: gui_framework.TextInput = .{},
    playlist_modal_status: []const u8 = "",
    playlist_picker_song_id: i64 = -1,
};

fn guiAlbumSortLabel(sort: db_mod.Database.AlbumSort) []const u8 {
    return switch (sort) {
        .by_name => "Name",
        .by_year => "Year",
        .by_artist => "Artist",
    };
}

fn cycleGuiAlbumSort(demo: *Demo) void {
    demo.album_sort = switch (demo.album_sort) {
        .by_name => .by_year,
        .by_year => .by_artist,
        .by_artist => .by_name,
    };
    refreshSnapshots(demo);
    demo.state.selection = 0;
    demo.state.scroll = 0;
    demo.scroll_offset = 0;
    demo.scroll_anchor = 0;
    updateCollections(demo, &demo.state);
}

fn guiSearchable(screen: U.Screen) bool {
    return switch (screen) {
        .library, .albums, .artists, .genres, .playlists => true,
        else => false,
    };
}

fn guiSearchQuery(demo: *const Demo, screen: U.Screen) []const u8 {
    return if (demo.search_screen == screen) demo.search_input.text() else "";
}

fn guiSearchMatches(text: []const u8, query: []const u8) bool {
    return query.len == 0 or std.ascii.findIgnoreCase(text, query) != null;
}

fn rebuildGuiFilters(demo: *Demo) void {
    const allocator = demo.app.allocator;
    demo.filtered_library_titles.clearRetainingCapacity();
    demo.filtered_library_rows.clearRetainingCapacity();
    demo.filtered_library_indices.clearRetainingCapacity();
    demo.filtered_albums.clearRetainingCapacity();
    demo.filtered_artists.clearRetainingCapacity();
    demo.filtered_genres.clearRetainingCapacity();
    demo.filtered_playlists.clearRetainingCapacity();

    const library_query = guiSearchQuery(demo, .library);
    for (demo.library_titles.items, 0..) |title, index| {
        if (!guiSearchMatches(title, library_query)) continue;
        demo.filtered_library_rows.append(allocator, demo.library_rows.items[index]) catch return;
        demo.filtered_library_titles.append(allocator, title) catch return;
        demo.filtered_library_indices.append(allocator, index) catch return;
    }
    const album_query = guiSearchQuery(demo, .albums);
    for (demo.albums.items) |row| {
        if (!guiSearchMatches(row.title, album_query) and !guiSearchMatches(row.artist, album_query)) continue;
        demo.filtered_albums.append(allocator, row) catch return;
    }
    const artist_query = guiSearchQuery(demo, .artists);
    for (demo.artists.items) |row| {
        if (!guiSearchMatches(row.name, artist_query)) continue;
        demo.filtered_artists.append(allocator, row) catch return;
    }
    const genre_query = guiSearchQuery(demo, .genres);
    for (demo.genres.items) |row| {
        if (!guiSearchMatches(row.name, genre_query)) continue;
        demo.filtered_genres.append(allocator, row) catch return;
    }
    const playlist_query = guiSearchQuery(demo, .playlists);
    for (demo.playlists.items) |row| {
        if (!guiSearchMatches(row.name, playlist_query)) continue;
        demo.filtered_playlists.append(allocator, row) catch return;
    }
}

fn refreshSnapshots(demo: *Demo) void {
    const allocator = demo.app.allocator;
    // Snapshot rows are rebuilt after a rescan. Keep their string storage in a
    // separate arena so refreshes reclaim old metadata instead of accumulating
    // every historical library view.
    _ = demo.snapshot_arena.reset(.retain_capacity);
    const strings = demo.snapshot_arena.allocator();
    demo.library_titles.clearRetainingCapacity();
    demo.library_rows.clearRetainingCapacity();
    demo.albums.clearRetainingCapacity();
    demo.artists.clearRetainingCapacity();
    demo.genres.clearRetainingCapacity();
    demo.playlists.clearRetainingCapacity();
    // The grouped display query avoids one song/context query per library row.
    // Keep its temporary row array outside the long-lived snapshot arena.
    var query_arena = std.heap.ArenaAllocator.init(allocator);
    defer query_arena.deinit();
    if (demo.app.db.getAllSongDisplaysWithAllocator(query_arena.allocator())) |displays| {
        for (displays) |display| {
            const title = std.fmt.allocPrint(strings, "{s}  —  {s}  —  {s}", .{ display.title, display.artist, display.album }) catch break;
            const song = demo.app.lib.getSongById(display.id);
            const row_title = strings.dupe(u8, display.title) catch break;
            const row_artist = strings.dupe(u8, display.artist) catch break;
            const row_album = strings.dupe(u8, display.album) catch break;
            demo.library_rows.append(allocator, .{ .title = row_title, .artist = row_artist, .album = row_album, .duration = if (song) |s| s.duration else 0 }) catch break;
            demo.library_titles.append(allocator, title) catch break;
        }
    } else |_| {}
    if (demo.app.db.getAlbumsWithAllocator(strings, demo.album_sort)) |rows| {
        for (rows) |row| demo.albums.append(allocator, .{
            .id = row.id,
            .title = row.name,
            .artist = row.artist,
            .year = row.year,
            .track_count = row.track_count,
            .has_cover = row.has_cover,
        }) catch break;
    } else |_| {}
    if (demo.app.db.getArtistsWithAllocator(strings)) |rows| {
        for (rows) |row| demo.artists.append(allocator, .{
            .id = row.id,
            .name = row.name,
            .song_count = row.song_count,
            .album_count = row.album_count,
        }) catch break;
    } else |_| {}
    if (demo.app.db.getGenresWithAllocator(strings)) |rows| {
        for (rows) |row| demo.genres.append(allocator, .{ .id = row.id, .name = row.name, .song_count = row.song_count }) catch break;
    } else |_| {}
    if (demo.app.db.getPlaylistsWithAllocator(strings)) |rows| {
        for (rows) |row| demo.playlists.append(allocator, .{
            .id = row.id,
            .name = row.name,
            .description = row.description,
            .song_count = row.song_count,
            .is_smart = row.is_smart,
            .smart_rule = row.smart_rule,
        }) catch break;
    } else |_| {}
    rebuildGuiFilters(demo);
}

fn pollScan(demo: *Demo) bool {
    const status = demo.scan.status.load(.acquire);
    if (status == 1) {
        demo.state.scanning = true;
        demo.state.scan_scanned = demo.scan.scanned.load(.acquire);
        demo.state.scan_imported = demo.scan.imported.load(.acquire);
        demo.state.scan_updated = demo.scan.updated.load(.acquire);
        demo.state.scan_removed = demo.scan.removed.load(.acquire);
        return true;
    }
    // A small scan can finish before the display's first tick. Consume its
    // terminal status even if no tick ever observed the running state.
    if (status == 0) return false;
    demo.scan.join();
    if (status == 2) {
        demo.app.finishRescan(demo.scan.result, demo.scan.previous_path) catch |err| std.log.err("rescan reconciliation failed: {}", .{err});
        if (demo.scan.startup) {
            demo.app.restoreSavedQueueState();
            if (!demo.app.has_current_path) _ = demo.app.startFirstSong();
        }
        demo.covers.reset();
        refreshSnapshots(demo);
        updateCollections(demo, &demo.state);
    } else {
        std.log.err("library scan failed", .{});
        if (demo.scan.previous_path.len > 0) {
            if (demo.app.lib.songIdByPath(demo.scan.previous_path)) |id| {
                _ = demo.app.playSongId(id) catch {};
            }
        } else if (demo.scan.startup) _ = demo.app.startFirstSong();
    }
    demo.state.scanning = false;
    demo.scan.status.store(0, .release);
    if (demo.scan.music_directory.len > 0) {
        demo.scan.allocator.free(demo.scan.music_directory);
        demo.scan.music_directory = &.{};
    }
    if (demo.scan.previous_path.len > 0) {
        demo.scan.allocator.free(demo.scan.previous_path);
        demo.scan.previous_path = &.{};
    }
    return true;
}

fn pollHealth(demo: *Demo) void {
    const status = demo.health.status.load(.acquire);
    demo.state.health_running = status == 1;
    demo.state.health_scanned = demo.health.scanned.load(.acquire);
    if (status == 1 or status == 0) return;
    demo.health.join();
    demo.state.health_running = false;
    demo.state.health_findings = if (demo.health.report) |*report| report.findings.items else &.{};
    demo.state.health_status = switch (status) {
        2 => "Health report complete (read-only).",
        3 => "Health report failed: root/file inaccessible or traversal incomplete; missing-file results are withheld.",
        4 => "Health report cancelled; partial findings discarded.",
        else => "",
    };
}

fn startHealth(demo: *Demo) void {
    if (demo.health.status.load(.acquire) == 1) return;
    demo.health.reset();
    demo.state.health_findings = &.{};
    demo.state.health_status = "Library health report running...";
    var arena = std.heap.ArenaAllocator.init(demo.app.allocator);
    defer arena.deinit();
    const paths = demo.app.db.getAllSongPathsWithAllocator(arena.allocator()) catch {
        demo.state.health_status = "Could not read library paths; no report was run.";
        return;
    };
    const known = arena.allocator().alloc([]const u8, paths.len) catch return;
    for (paths, 0..) |entry, i| known[i] = entry.path;
    demo.health.start(demo.app.config.getMusicDirectory(), known) catch {
        demo.state.health_status = "Could not start library health report.";
    };
}

fn pollAuth(demo: *Demo) void {
    const status = demo.auth.status.load(.acquire);
    if (status == 1) {
        demo.auth_status = "Contacting Last.fm...";
        return;
    }
    if (status == 0) return;
    demo.auth.join();
    if (status == 2) {
        switch (demo.auth.op) {
            .begin => {
                if (demo.auth_url.len > 0) demo.app.allocator.free(demo.auth_url);
                demo.auth_url = demo.auth.result_url;
                demo.auth.result_url = &.{};
                if (demo.auth_token.len > 0) demo.app.allocator.free(demo.auth_token);
                demo.auth_token = demo.auth.result_token;
                demo.auth.result_token = &.{};
                demo.auth_status = "Open the URL, approve access, then press K.";
            },
            .finish => {
                if (demo.auth.result_session.len > 0) {
                    demo.app.config.setLastFmSessionKey(demo.auth.result_session);
                    demo.app.saveConfig();
                    demo.auth_status = "Last.fm connected.";
                } else demo.auth_status = "Last.fm returned an empty session.";
            },
        }
    } else demo.auth_status = "Last.fm authorization failed.";
    if (demo.auth.op == .finish and demo.auth_token.len > 0) {
        demo.auth.allocator.free(demo.auth_token);
        demo.auth_token = &.{};
    }
    demo.auth.clearResults();
    if (demo.auth.api_key.len > 0) demo.auth.allocator.free(demo.auth.api_key);
    if (demo.auth.shared_secret.len > 0) demo.auth.allocator.free(demo.auth.shared_secret);
    if (demo.auth.token.len > 0) demo.auth.allocator.free(demo.auth.token);
    demo.auth.api_key = &.{};
    demo.auth.shared_secret = &.{};
    demo.auth.token = &.{};
    demo.auth.status.store(0, .release);
}

fn guiFrame(demo: *const Demo, display: *al.Display) gui_render.Layout {
    return gui_render.Layout.forScreen(@floatFromInt(display.getWidth()), @floatFromInt(display.getHeight()), demo.state.screen, demo.inspector_open);
}

fn updateArtwork(demo: *Demo) void {
    demo.covers.poll();
    demo.covers.request(&demo.app.db, demo.current_album_id);
    if (demo.state.screen == .album_detail) demo.covers.request(&demo.app.db, demo.state.album_detail_id);
    if (demo.state.screen != .albums) return;
    const display = demo.display orelse return;
    const frame = guiFrame(demo, display);
    const first = @min(demo.state.albums.len, frame.anchorFromOffset(demo.scroll_offset));
    const end = @min(demo.state.albums.len, first + frame.visibleRows() + frame.gridColumns() * 2);
    for (demo.state.albums[first..end]) |album| if (album.has_cover) demo.covers.request(&demo.app.db, album.id);
}

fn handleGalleryKey(demo: *Demo, key: al.KeyCode, frame: gui_render.Layout) bool {
    if (demo.state.screen != .albums) return false;
    const move: i64 = switch (key) {
        .Down, .J => @intCast(frame.gridColumns()),
        .Up, .K => -@as(i64, @intCast(frame.gridColumns())),
        .Left => -1,
        .Right => 1,
        else => return false,
    };
    demo.state.selection = gui_layout.moveGridSelection(demo.state.selection, move, demo.state.albums.len);
    return true;
}

fn updateCurrentTrack(demo: *Demo, state: *U.State) void {
    state.path = if (demo.app.has_current_path) demo.app.current_path else "";
    state.title = "No track";
    state.artist = demo.current_artist;
    state.album = demo.current_album;
    state.favorite = false;
    if (!demo.app.has_current_path) {
        demo.current_song_id = -1;
        state.lyrics = &.{};
        state.active_lyric = null;
        demo.current_artist = "";
        demo.current_album = "";
        demo.current_album_id = -1;
    } else if (demo.app.lib.songIdByPath(demo.app.current_path)) |id| {
        if (demo.app.lib.getSongById(id)) |song| {
            state.title = song.title;
            state.favorite = song.favorite != 0;
            if (demo.current_song_id != id) {
                demo.current_song_id = id;
                demo.smoother = .{};
                demo.spectrum_bands = @splat(0);
                demo.last_capture_sequence = std.math.maxInt(u64);
                demo.current_artist = "";
                demo.current_album = "";
                _ = demo.current_arena.reset(.retain_capacity);
                if (demo.app.db.getSongContextWithAllocator(demo.current_arena.allocator(), id) catch null) |context| {
                    demo.current_artist = context.artist;
                    demo.current_album = context.album;
                }
                demo.current_album_id = song.album_id;
                state.lyrics = if (lyrics_mod.loadSidecar(demo.current_arena.allocator(), demo.app.current_path) catch null) |lyrics| lyrics.lines else &.{};
                state.artist = demo.current_artist;
                state.album = demo.current_album;
            }
        }
    }
    state.artist = demo.current_artist;
    state.album = demo.current_album;
    state.art = .{}; // Terminal pixels are not generated by the GUI.
    state.art_status = if (demo.covers.get(demo.current_album_id) != null) .ready else .none;
}

fn updateSpectrum(demo: *Demo, state: *U.State) void {
    const now = al.time.getTime();
    const dt: f32 = @floatCast(if (demo.last_spectrum_time == 0) 1.0 / 60.0 else @max(0, @min(0.25, now - demo.last_spectrum_time)));
    demo.last_spectrum_time = now;
    const visible = if (demo.display) |display| guiFrame(demo, display).visualizerPlot().h > 0 else false;
    if (state.screen != .now_playing or !visible or !demo.visualizer.available() or state.scanning) {
        state.spectrum = &.{};
        demo.smoother = .{};
        demo.spectrum_bands = @splat(0);
        demo.spectrum_ticks = 0;
        demo.last_capture_sequence = std.math.maxInt(u64);
        return;
    }
    // FFT at 20 Hz on new capture blocks; animate the envelope at display rate.
    demo.spectrum_ticks += 1;
    if (!demo.app.engine.isPlaying()) {
        demo.spectrum_bands = @splat(0);
        demo.last_capture_sequence = std.math.maxInt(u64);
    } else if (demo.spectrum_ticks >= 3) {
        const sequence = demo.app.engine.captureSequence();
        if (sequence != demo.last_capture_sequence) {
            demo.last_capture_sequence = sequence;
            const captured = demo.app.engine.copyRecentMono(spectrum.n_samples, &demo.audio_samples);
            demo.analyzer.compute(demo.audio_samples[0..captured], &demo.spectrum_bands);
        }
    }
    if (demo.spectrum_ticks >= 3) demo.spectrum_ticks = 0;
    demo.smoother.updateTimed(&demo.spectrum_bands, dt);
    state.spectrum = &demo.smoother.levels;
}

fn updateQueueSnapshot(demo: *Demo, state: *U.State) void {
    if (demo.queue_generation != demo.app.play_queue.generation) {
        _ = demo.queue_arena.reset(.retain_capacity);
        demo.queue_rows.clearRetainingCapacity();
        for (demo.app.play_queue.items()) |raw_id| {
            const id: i64 = raw_id;
            const song = demo.app.lib.getSongById(id);
            const title = if (song) |value| value.title else "[missing song]";
            const artist = if (demo.app.db.getSongContextWithAllocator(demo.queue_arena.allocator(), id) catch null) |context| context.artist else "";
            demo.queue_rows.append(demo.app.allocator, .{ .song_id = id, .title = title, .artist = artist }) catch break;
        }
        demo.queue_generation = demo.app.play_queue.generation;
    }
    state.queue = demo.queue_rows.items;
    state.queue_count = demo.queue_rows.items.len;
    state.queue_current_index = if (demo.queue_rows.items.len > 0) demo.app.play_queue.current_index else null;
    state.queue_context_label = switch (demo.app.play_queue.context_type) {
        .Individual => "Queue",
        .Album => "Album queue",
        .Playlist => "Playlist queue",
        .Artist => "Artist queue",
        .Genre => "Genre queue",
    };
}

fn updateCollections(demo: *Demo, state: *U.State) void {
    if (demo.search_active and demo.search_screen != state.screen) {
        demo.search_active = false;
        demo.ignore_search_trigger_char = false;
    }
    state.row_count = demo.filtered_library_titles.items.len;
    state.playing_index = null;
    if (demo.app.has_current_path) if (demo.app.lib.songIdByPath(demo.app.current_path)) |id| if (demo.app.lib.indexOfId(id)) |full_index| {
        for (demo.filtered_library_indices.items, 0..) |source_index, visible_index| {
            if (source_index == full_index) {
                state.playing_index = visible_index;
                break;
            }
        }
    };
    state.library_filter = guiSearchQuery(demo, .library);
    state.library_searching = demo.search_active and demo.search_screen == .library;
    state.album_filter = guiSearchQuery(demo, .albums);
    state.album_searching = demo.search_active and demo.search_screen == .albums;
    state.albums = if (state.screen == .albums) demo.filtered_albums.items else demo.albums.items;
    state.album_count = state.albums.len;
    state.album_sort_label = guiAlbumSortLabel(demo.album_sort);
    state.album_detail_tracks = demo.album_tracks.items;
    state.album_detail_count = demo.album_tracks.items.len;
    state.artists = if (state.screen == .artists) demo.filtered_artists.items else demo.artists.items;
    state.artist_count = state.artists.len;
    state.searching = (demo.search_active and demo.search_screen == state.screen) or
        (state.screen == .artists and guiSearchQuery(demo, .artists).len > 0) or
        (state.screen == .genres and guiSearchQuery(demo, .genres).len > 0) or
        (state.screen == .playlists and guiSearchQuery(demo, .playlists).len > 0);
    state.filter = switch (state.screen) {
        .artists => guiSearchQuery(demo, .artists),
        .genres => guiSearchQuery(demo, .genres),
        .playlists => guiSearchQuery(demo, .playlists),
        else => "",
    };
    state.artist_detail_tracks = demo.artist_tracks.items;
    state.artist_detail_count = demo.artist_tracks.items.len;
    if (state.screen == .artist_detail) for (demo.artists.items) |artist| if (artist.id == state.artist_detail_id) {
        state.artist_detail_name = artist.name;
        break;
    };
    state.genres = if (state.screen == .genres) demo.filtered_genres.items else demo.genres.items;
    state.genre_count = state.genres.len;
    state.genre_detail_tracks = demo.genre_tracks.items;
    state.genre_detail_count = demo.genre_tracks.items.len;
    if (state.screen == .genre_detail) for (demo.genres.items) |genre| if (genre.id == state.genre_detail_id) {
        state.genre_detail_name = genre.name;
        break;
    };
    state.playlists = if (state.screen == .playlists) demo.filtered_playlists.items else demo.playlists.items;
    state.playlist_count = state.playlists.len;
    state.playlist_detail_tracks = demo.playlist_tracks.items;
    state.playlist_detail_count = demo.playlist_tracks.items.len;
    if (state.screen == .playlist_detail) for (demo.playlists.items) |playlist| if (playlist.id == state.playlist_detail_id) {
        state.playlist_detail_name = playlist.name;
        break;
    };
    state.playing_album_id = if (demo.app.play_queue.context_type == .Album) @as(i64, demo.app.play_queue.context_id) else -1;
    state.settings_music_directory = demo.app.config.getMusicDirectory();
    state.settings_api_key = demo.settings_fields[0].text();
    state.settings_shared_secret = demo.settings_fields[1].text();
    state.settings_session_key = demo.settings_fields[2].text();
    state.settings_lastfm_enabled = state.settings_session_key.len > 0;
    state.settings_normalization_enabled = demo.app.config.getNormalizationEnabled();
    state.settings_normalization_album = demo.app.config.getNormalizationPolicy() == .album;
    state.settings_playback_profile = @tagName(demo.app.config.getPlaybackProfile());
    state.settings_crossfade_seconds = demo.app.config.getCrossfadeSeconds();
    state.settings_editing = demo.settings_active_field != null;
    state.settings_active_field = if (demo.settings_active_field) |index| @intCast(index) else -1;
    if (demo.settings_active_field) |index| {
        state.settings_field = switch (index) {
            0 => "API Key",
            1 => "Shared Secret",
            2 => "Session Key",
            else => "",
        };
        state.settings_value = demo.settings_fields[index].text();
        state.settings_cursor = demo.settings_fields[index].cursor;
    } else {
        state.settings_field = "";
        state.settings_value = "";
        state.settings_cursor = 0;
    }
    state.settings_auth_status = demo.auth_status;
    state.settings_auth_url = demo.auth_url;
    state.health_running = demo.health.status.load(.acquire) == 1;
    state.health_scanned = demo.health.scanned.load(.acquire);
    if (demo.health.status.load(.acquire) >= 2) {
        state.health_findings = if (demo.health.report) |*report| report.findings.items else &.{};
        state.health_status = switch (demo.health.status.load(.acquire)) {
            2 => "Health report complete (read-only).",
            3 => "Health report failed: root/file inaccessible or traversal incomplete; missing-file results withheld.",
            4 => "Health report cancelled; partial findings discarded.",
            else => "",
        };
    }
}

fn updateAlbumPlaying(demo: *Demo, state: *U.State) void {
    if (state.screen != .album_detail or !demo.app.has_current_path) return;
    state.album_detail_playing = null;
    if (demo.app.lib.songIdByPath(demo.app.current_path)) |id| {
        for (demo.album_tracks.items, 0..) |track, index| if (track.song_id == id) {
            state.album_detail_playing = index;
            break;
        };
    }
}

fn onTick(ctx: *anyopaque) void {
    const demo: *Demo = @ptrCast(@alignCast(ctx));
    if (demo.control) |server| server.poll(demo.app);
    demo.app.engine.update();
    pollAuth(demo);
    pollHealth(demo);
    if (pollScan(demo)) return;
    const state = &demo.state;
    updateCurrentTrack(demo, state);
    updateSpectrum(demo, state);
    state.position = demo.app.engine.getTime();
    state.active_lyric = (lyrics_mod.Lyrics{ .lines = state.lyrics }).activeLine(state.position);
    state.duration = demo.app.engine.getDuration();
    state.playing = demo.app.engine.isPlaying();
    state.volume = demo.app.engine.getGain();
    state.shuffle = demo.app.engine.isShuffled();
    state.repeat_mode = demo.app.engine.getRepeatMode();
    updateCollections(demo, state);
    updateQueueSnapshot(demo, state);
    updateAlbumPlaying(demo, state);
    updateArtwork(demo);
}

fn onRender(ctx: *anyopaque) void {
    const demo: *Demo = @ptrCast(@alignCast(ctx));
    const display = demo.display orelse return;
    const layout = guiFrame(demo, display);
    if (demo.scroll_screen != demo.state.screen) {
        demo.scroll_screen = demo.state.screen;
        demo.scroll_offset = layout.offsetFromAnchor(demo.state.scroll);
        demo.selection_anchor = demo.state.selection;
        demo.hover_row = null;
        demo.last_click_index = null;
    }
    if (!demo.scrollbar_dragging and demo.state.scroll != demo.scroll_anchor) {
        demo.scroll_offset = layout.offsetFromAnchor(demo.state.scroll);
    }
    const count = gui_layout.scrollCount(&demo.state);
    demo.scroll_offset = @max(0, @min(demo.scroll_offset, layout.maxScroll(count)));
    if (demo.state.screen == .settings) demo.scroll_offset = gui_layout.settingsScroll(layout, demo.scroll_offset, demo.state.settings_active_field, count);
    if (demo.state.screen == .albums and (demo.selection_anchor != demo.state.selection or demo.gallery_columns != layout.gridColumns() or demo.gallery_pitch != layout.itemPitch() or demo.viewport_height != layout.body.h)) {
        demo.scroll_offset = layout.reveal(demo.state.selection, demo.scroll_offset, count);
    }
    demo.selection_anchor = demo.state.selection;
    demo.gallery_columns = layout.gridColumns();
    demo.gallery_pitch = layout.itemPitch();
    demo.viewport_height = layout.body.h;
    demo.state.scroll = layout.anchorFromOffset(demo.scroll_offset);
    demo.scroll_anchor = demo.state.scroll;
    demo.state.playlist_modal_name = demo.playlist_name_input.text();
    demo.state.playlist_modal_cursor = demo.playlist_name_input.cursor;
    demo.state.playlist_modal_status = demo.playlist_modal_status;
    if (demo.state.metadata_editing) {
        for (gui_metadata_names, &demo.metadata_fields, 0..) |name, *field, index| {
            demo.metadata_rows[index] = .{ .name = name, .value = field.text() };
        }
        demo.state.metadata_fields = &demo.metadata_rows;
        demo.state.metadata_status = demo.metadata_status;
        demo.state.metadata_active_index = @min(demo.state.metadata_active_index, demo.metadata_rows.len - 1);
        demo.state.metadata_field = demo.metadata_rows[demo.state.metadata_active_index].name;
        demo.state.metadata_value = demo.metadata_rows[demo.state.metadata_active_index].value;
        demo.state.metadata_song_title = demo.metadata_fields[0].text();
    } else {
        demo.state.metadata_fields = &.{};
        demo.state.metadata_status = "";
    }
    gui_render.render(display, &demo.fonts, &demo.state, &demo.covers, &demo.visualizer, demo.filtered_library_rows.items, .{
        .visualizer_mode = demo.visualizer_mode,
        .inspector_open = demo.inspector_open,
        .inspector_lyrics = demo.inspector_lyrics,
        .album_actions = demo.album_actions != null,
        .hover_nav = demo.hover_nav,
        .hover_control = demo.hover_control,
        .pressed_control = demo.pressed_control,
        .hover_row = demo.hover_row,
        .scroll_offset = demo.scroll_offset,
        .search_cursor = if (demo.search_active) demo.search_input.cursor else null,
        .metadata_cursor = if (demo.state.metadata_editing) demo.metadata_fields[demo.state.metadata_active_index].cursor else 0,
    }, demo.current_album_id);
}

fn actionForKey(key: al.KeyCode) ?U.Action {
    return switch (key) {
        .Space => .toggle_pause,
        .N => .next,
        .P => .prev,
        .S => .toggle_shuffle,
        .Tab => .toggle_screen,
        .Equals, .VolumeUp, .PadPlus => .vol_up,
        .Minus, .VolumeDown, .PadMinus => .vol_down,
        .Left, .Comma => .seek_back,
        .Right, .Fullstop => .seek_forward,
        .R => .cycle_repeat,
        .F => .toggle_favorite,
        .J, .Down => .select_down,
        .K, .Up => .select_up,
        .U, .PgUp => .page_up,
        .D, .PgDn => .page_down,
        .Enter, .PadEnter => .enter,
        .B, .Escape => .back,
        .Num1 => .goto_nowplaying,
        .Num2 => .goto_library,
        .Num3 => .goto_albums,
        .Num4 => .goto_artists,
        .Num5 => .goto_genres,
        .Num6 => .goto_playlists,
        .Num7 => .goto_queue,
        .Num8 => .goto_settings,
        else => null,
    };
}

fn beginDetailLoad(demo: *Demo) void {
    _ = demo.detail_arena.reset(.retain_capacity);
    demo.album_tracks.clearRetainingCapacity();
    demo.artist_tracks.clearRetainingCapacity();
    demo.genre_tracks.clearRetainingCapacity();
    demo.playlist_tracks.clearRetainingCapacity();
}

fn appendTrackRows(demo: *Demo, out: *std.ArrayList(U.AlbumTrackRow), listings: []const db_mod.Database.TrackListing) void {
    const strings = demo.detail_arena.allocator();
    for (listings) |listing| {
        const title = strings.dupe(u8, listing.title) catch return;
        const artist = strings.dupe(u8, if (listing.artist.len > 0) listing.artist else "Unknown Artist") catch return;
        out.append(demo.app.allocator, .{
            .title = title,
            .artist = artist,
            .track = listing.track,
            .disc_number = listing.disc_number,
            .duration = listing.duration,
            .song_id = listing.id,
        }) catch return;
    }
}

fn loadAlbumTracks(demo: *Demo, album_id: i64) void {
    beginDetailLoad(demo);
    var query_arena = std.heap.ArenaAllocator.init(demo.app.allocator);
    defer query_arena.deinit();
    const listings = demo.app.db.getTrackListingsByAlbumWithAllocator(query_arena.allocator(), album_id) catch return;
    appendTrackRows(demo, &demo.album_tracks, listings);
}

fn loadArtistTracks(demo: *Demo, artist_id: i64) void {
    beginDetailLoad(demo);
    var query_arena = std.heap.ArenaAllocator.init(demo.app.allocator);
    defer query_arena.deinit();
    const listings = demo.app.db.getTrackListingsByArtistWithAllocator(query_arena.allocator(), artist_id) catch return;
    appendTrackRows(demo, &demo.artist_tracks, listings);
}

fn loadGenreTracks(demo: *Demo, genre_id: i64) void {
    beginDetailLoad(demo);
    var query_arena = std.heap.ArenaAllocator.init(demo.app.allocator);
    defer query_arena.deinit();
    const listings = demo.app.db.getTrackListingsByGenreWithAllocator(query_arena.allocator(), genre_id) catch return;
    appendTrackRows(demo, &demo.genre_tracks, listings);
}

fn loadPlaylistTracks(demo: *Demo, playlist_id: i64) void {
    beginDetailLoad(demo);
    var query_arena = std.heap.ArenaAllocator.init(demo.app.allocator);
    defer query_arena.deinit();
    const listings = if (demo.app.db.isSmartPlaylist(playlist_id))
        demo.app.db.getTrackListingsBySmartPlaylistWithAllocator(query_arena.allocator(), playlist_id) catch return
    else
        demo.app.db.getTrackListingsByPlaylistWithAllocator(query_arena.allocator(), playlist_id) catch return;
    appendTrackRows(demo, &demo.playlist_tracks, listings);
}

fn playSongSet(demo: *Demo, tracks: []const U.AlbumTrackRow, context: PlaybackContextType, context_id: i64, start: usize) bool {
    if (tracks.len == 0 or start >= tracks.len) return false;
    var ids = std.ArrayList(i64).empty;
    defer ids.deinit(demo.app.allocator);
    for (tracks) |track| ids.append(demo.app.allocator, track.song_id) catch return false;
    return demo.app.playSongIdsInContext(ids.items, context, context_id, start) != null;
}

fn execute(demo: *Demo, cmd: U.Cmd) void {
    const engine = demo.app.engine;
    switch (cmd) {
        .none => {},
        .toggle_pause => if (engine.isPlaying()) engine.pause() else engine.resumePlayback(),
        .next => _ = engine.playNext() catch {},
        .prev => engine.playPrevious() catch {},
        .vol_up => {
            engine.setGain(@min(engine.getGain() + 0.05, 1.0));
            demo.app.config.setVolumePercent(@intFromFloat(engine.getGain() * 100.0));
            demo.app.saveConfig();
        },
        .vol_down => {
            engine.setGain(@max(engine.getGain() - 0.05, 0.0));
            demo.app.config.setVolumePercent(@intFromFloat(engine.getGain() * 100.0));
            demo.app.saveConfig();
        },
        .toggle_shuffle => engine.setShuffled(!engine.isShuffled()) catch {},
        .cycle_repeat => engine.cycleRepeatMode(),
        .seek => |value| engine.setProgress(value),
        .play_index => |index| {
            const id = if (demo.state.screen == .library and index < demo.filtered_library_indices.items.len)
                demo.app.lib.songIdAt(demo.filtered_library_indices.items[index])
            else
                demo.app.lib.songIdAt(index);
            if (id >= 0) _ = demo.app.playSongId(id) catch {};
        },
        .open_album_detail => |album_id| loadAlbumTracks(demo, album_id),
        .play_track_in_album => |index| {
            _ = demo.app.playAlbumFromIndex(demo.state.album_detail_id, index);
        },
        .play_artist => |artist_id| {
            loadArtistTracks(demo, artist_id);
            _ = playSongSet(demo, demo.artist_tracks.items, .Artist, artist_id, 0);
        },
        .open_artist_detail => |artist_id| loadArtistTracks(demo, artist_id),
        .play_artist_track => |index| _ = playSongSet(demo, demo.artist_tracks.items, .Artist, demo.state.artist_detail_id, index),
        .play_genre => |genre_id| {
            loadGenreTracks(demo, genre_id);
            _ = playSongSet(demo, demo.genre_tracks.items, .Genre, genre_id, 0);
        },
        .open_genre_detail => |genre_id| loadGenreTracks(demo, genre_id),
        .play_genre_track => |index| _ = playSongSet(demo, demo.genre_tracks.items, .Genre, demo.state.genre_detail_id, index),
        .open_playlist_detail => |playlist_id| loadPlaylistTracks(demo, playlist_id),
        .play_playlist_track => |index| {
            if (demo.app.db.isSmartPlaylist(demo.state.playlist_detail_id))
                _ = playSongSet(demo, demo.playlist_tracks.items, .Playlist, demo.state.playlist_detail_id, index)
            else
                _ = demo.app.playPlaylist(demo.state.playlist_detail_id, index);
        },
        .play_playlist => |playlist_id| {
            if (demo.app.db.isSmartPlaylist(playlist_id)) {
                loadPlaylistTracks(demo, playlist_id);
                _ = playSongSet(demo, demo.playlist_tracks.items, .Playlist, playlist_id, 0);
            } else _ = demo.app.playPlaylist(playlist_id, 0);
        },
        .play_queue_index => |index| _ = demo.app.playQueueIndex(index) catch {},
        .toggle_favorite => if (demo.app.has_current_path) if (demo.app.lib.songIdByPath(demo.app.current_path)) |id| {
            const current = if (demo.app.lib.getSongById(id)) |song| song.favorite != 0 else false;
            demo.app.db.setFavorite(id, @intFromBool(!current)) catch {};
            demo.app.lib.setFavorite(id, !current);
            if (id >= std.math.minInt(i32) and id <= std.math.maxInt(i32)) demo.app.play_queue.setShuffleFavorite(@intCast(id), !current);
        },
    }
}

fn removeGuiPlaylistTrack(demo: *Demo) void {
    if (demo.app.db.isSmartPlaylist(demo.state.playlist_detail_id) or demo.state.selection >= demo.playlist_tracks.items.len) return;
    demo.app.db.removePlaylistTrackAt(demo.state.playlist_detail_id, demo.state.selection) catch |err| {
        std.log.err("GUI remove playlist track failed: {}", .{err});
        return;
    };
    loadPlaylistTracks(demo, demo.state.playlist_detail_id);
    demo.state.selection = @min(demo.state.selection, demo.playlist_tracks.items.len -| 1);
    refreshSnapshots(demo);
    updateCollections(demo, &demo.state);
}

fn moveGuiPlaylistTrack(demo: *Demo, direction: i8) void {
    if (demo.app.db.isSmartPlaylist(demo.state.playlist_detail_id) or demo.playlist_tracks.items.len < 2) return;
    const from = demo.state.selection;
    const to = if (direction < 0) from -| 1 else @min(from + 1, demo.playlist_tracks.items.len - 1);
    if (from == to or from >= demo.playlist_tracks.items.len) return;
    const ids = demo.app.allocator.alloc(i64, demo.playlist_tracks.items.len) catch return;
    defer demo.app.allocator.free(ids);
    for (demo.playlist_tracks.items, 0..) |track, index| ids[index] = track.song_id;
    std.mem.swap(i64, &ids[from], &ids[to]);
    demo.app.db.reorderPlaylist(demo.state.playlist_detail_id, ids) catch |err| {
        std.log.err("GUI reorder playlist failed: {}", .{err});
        return;
    };
    loadPlaylistTracks(demo, demo.state.playlist_detail_id);
    demo.state.selection = to;
}

fn enqueueSong(demo: *Demo, song_id: i64, next: bool) void {
    if (song_id < std.math.minInt(i32) or song_id > std.math.maxInt(i32)) return;
    if (next) demo.app.play_queue.enqueueNext(@intCast(song_id)) catch {} else demo.app.play_queue.enqueue(@intCast(song_id)) catch {};
}

const GuiContextTrack = struct { id: i64, title: []const u8, artist: []const u8, favorite: bool };

fn makeGuiContextTrack(demo: *Demo, id: i64, title: []const u8, artist: []const u8) ?GuiContextTrack {
    const song = demo.app.lib.getSongById(id) orelse return null;
    return .{ .id = id, .title = if (title.len > 0) title else song.title, .artist = artist, .favorite = song.favorite != 0 };
}

fn selectedLibrarySongId(demo: *Demo) ?i64 {
    if (demo.state.selection >= demo.filtered_library_indices.items.len) return null;
    const source_index = demo.filtered_library_indices.items[demo.state.selection];
    const id = demo.app.lib.songIdAt(source_index);
    return if (id >= 0) id else null;
}

fn selectedGuiContextTrack(demo: *Demo) ?GuiContextTrack {
    const state = &demo.state;
    switch (state.screen) {
        .now_playing => {
            if (!demo.app.has_current_path) return null;
            const id = demo.app.lib.songIdByPath(demo.app.current_path) orelse return null;
            return makeGuiContextTrack(demo, id, state.title, state.artist);
        },
        .library => {
            const id = selectedLibrarySongId(demo) orelse return null;
            const song = demo.app.lib.getSongById(id) orelse return null;
            const context = demo.app.db.getSongContext(id) catch null;
            return makeGuiContextTrack(demo, id, song.title, if (context) |value| value.artist else "Unknown Artist");
        },
        .album_detail => if (state.selection < demo.album_tracks.items.len) {
            const track = demo.album_tracks.items[state.selection];
            return makeGuiContextTrack(demo, track.song_id, track.title, track.artist);
        } else return null,
        .artist_detail => if (state.selection < demo.artist_tracks.items.len) {
            const track = demo.artist_tracks.items[state.selection];
            return makeGuiContextTrack(demo, track.song_id, track.title, track.artist);
        } else return null,
        .genre_detail => if (state.selection < demo.genre_tracks.items.len) {
            const track = demo.genre_tracks.items[state.selection];
            return makeGuiContextTrack(demo, track.song_id, track.title, track.artist);
        } else return null,
        .playlist_detail => if (state.selection < demo.playlist_tracks.items.len) {
            const track = demo.playlist_tracks.items[state.selection];
            return makeGuiContextTrack(demo, track.song_id, track.title, track.artist);
        } else return null,
        .queue => if (state.selection < state.queue.len) {
            const track = state.queue[state.selection];
            return makeGuiContextTrack(demo, track.song_id, track.title, track.artist);
        } else return null,
        else => return null,
    }
}

const gui_metadata_names = [_][]const u8{ "Title", "Artist", "Album", "Genre", "Comment", "Year", "Track", "Disc" };

fn setGuiMetadataField(demo: *Demo, index: usize, value: []const u8) void {
    if (index < demo.metadata_fields.len) demo.metadata_fields[index].setText(value);
}

fn setGuiMetadataInt(demo: *Demo, index: usize, value: i64) void {
    var buffer: [32]u8 = undefined;
    setGuiMetadataField(demo, index, std.fmt.bufPrint(&buffer, "{d}", .{value}) catch "0");
}

fn beginGuiMetadataEditor(demo: *Demo, song_id: i64) bool {
    const song = demo.app.db.getSongById(song_id) catch null orelse return false;
    const context = demo.app.db.getSongContext(song_id) catch null;
    var genre_arena = std.heap.ArenaAllocator.init(demo.app.allocator);
    defer genre_arena.deinit();
    const genre = demo.app.db.getSongGenreStringWithAllocator(genre_arena.allocator(), song_id) catch "";
    setGuiMetadataField(demo, 0, song.title);
    setGuiMetadataField(demo, 1, if (context) |value| value.artist else "");
    setGuiMetadataField(demo, 2, if (context) |value| value.album else "");
    setGuiMetadataField(demo, 3, genre);
    setGuiMetadataField(demo, 4, song.comment);
    var year: i64 = 0;
    if (song.album_id >= 0) if (demo.app.db.getAlbumById(song.album_id) catch null) |album| {
        year = album.year;
    };
    setGuiMetadataInt(demo, 5, year);
    setGuiMetadataInt(demo, 6, song.track);
    setGuiMetadataInt(demo, 7, song.disc_number);
    demo.metadata_song_id = song_id;
    demo.metadata_status = "";
    demo.state.metadata_editing = true;
    demo.state.metadata_active_index = 0;
    demo.state.metadata_song_title = song.title;
    return true;
}

fn parseGuiMetadataInt(value: []const u8) ?u32 {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len == 0) return null;
    return std.fmt.parseInt(u32, trimmed, 10) catch null;
}

fn openPlaylistDialog(demo: *Demo, mode: U.PlaylistModalMode, playlist_id: i64, initial_name: []const u8) void {
    demo.playlist_name_input = .{};
    demo.playlist_name_input.setText(initial_name);
    demo.playlist_modal_status = "";
    demo.state.playlist_modal_saved = false;
    demo.state.playlist_modal_mode = mode;
    demo.state.playlist_modal_edit_id = playlist_id;
    demo.state.playlist_modal_open = true;
}

fn openQueuePlaylistDialog(demo: *Demo) void {
    openPlaylistDialog(demo, .save_queue, -1, "");
}

fn submitPlaylistModal(demo: *Demo) void {
    if (demo.state.playlist_modal_saved) {
        demo.state.playlist_modal_open = false;
        return;
    }
    if (demo.state.playlist_modal_mode == .delete) {
        demo.app.db.deletePlaylist(demo.state.playlist_modal_edit_id) catch |err| {
            demo.playlist_modal_status = "Could not delete this playlist.";
            std.log.err("GUI delete playlist failed: {}", .{err});
            return;
        };
        refreshSnapshots(demo);
        demo.state.selection = @min(demo.state.selection, demo.filtered_playlists.items.len -| 1);
        updateCollections(demo, &demo.state);
        demo.playlist_modal_status = "Playlist deleted.";
        demo.state.playlist_modal_saved = true;
        return;
    }

    const name = std.mem.trim(u8, demo.playlist_name_input.text(), " \t\r\n");
    if (name.len == 0) {
        demo.playlist_modal_status = "Enter a name for this playlist.";
        return;
    }
    switch (demo.state.playlist_modal_mode) {
        .create => {
            _ = demo.app.db.createPlaylist(name) catch |err| {
                demo.playlist_modal_status = "Could not create playlist.";
                std.log.err("GUI create playlist failed: {}", .{err});
                return;
            };
            demo.playlist_modal_status = "Playlist created.";
        },
        .rename => {
            demo.app.db.renamePlaylist(demo.state.playlist_modal_edit_id, name) catch |err| {
                demo.playlist_modal_status = "Could not rename playlist.";
                std.log.err("GUI rename playlist failed: {}", .{err});
                return;
            };
            demo.playlist_modal_status = "Playlist renamed.";
        },
        .save_queue => {
            if (demo.app.play_queue.size() == 0) {
                demo.playlist_modal_status = "The queue is empty.";
                return;
            }
            const playlist_id = demo.app.db.createPlaylist(name) catch |err| {
                demo.playlist_modal_status = "Could not create playlist.";
                std.log.err("GUI create playlist failed: {}", .{err});
                return;
            };
            for (demo.app.play_queue.items()) |song_id| {
                demo.app.db.addSongToPlaylist(playlist_id, song_id) catch |err| {
                    demo.playlist_modal_status = "Playlist created, but some songs could not be added.";
                    demo.state.playlist_modal_saved = true;
                    std.log.err("GUI add queued song to playlist failed: {}", .{err});
                    return;
                };
            }
            demo.playlist_modal_status = "Queue saved as a playlist.";
        },
        .delete => unreachable,
    }
    refreshSnapshots(demo);
    updateCollections(demo, &demo.state);
    demo.state.playlist_modal_saved = true;
}

fn saveGuiMetadataEditor(demo: *Demo) void {
    for (demo.metadata_fields) |field| {
        if (field.truncated) {
            demo.metadata_status = "A field is too long to edit safely. Clear it or shorten it before saving.";
            return;
        }
    }
    const year_text = demo.metadata_fields[5].text();
    const track_text = demo.metadata_fields[6].text();
    const disc_text = demo.metadata_fields[7].text();
    if ((year_text.len > 0 and parseGuiMetadataInt(year_text) == null) or
        (track_text.len > 0 and parseGuiMetadataInt(track_text) == null) or
        (disc_text.len > 0 and parseGuiMetadataInt(disc_text) == null))
    {
        demo.metadata_status = "Year, track, and disc must be non-negative whole numbers.";
        return;
    }
    metadata_edit.editSong(&demo.app.db, demo.app.allocator, demo.metadata_song_id, .{
        .title = demo.metadata_fields[0].text(),
        .artist = demo.metadata_fields[1].text(),
        .album = demo.metadata_fields[2].text(),
        .genre = demo.metadata_fields[3].text(),
        .comment = demo.metadata_fields[4].text(),
        .year = parseGuiMetadataInt(year_text),
        .track = parseGuiMetadataInt(track_text),
        .disc = parseGuiMetadataInt(disc_text),
    }) catch |err| {
        demo.metadata_status = "Could not write tags. Check the file permissions and try again.";
        std.log.err("GUI metadata save failed: {}", .{err});
        return;
    };
    demo.app.reloadLibrary() catch |err| {
        demo.metadata_status = "Tags saved, but the library refresh failed.";
        std.log.err("GUI library reload after metadata edit failed: {}", .{err});
        return;
    };
    demo.current_song_id = -1;
    refreshSnapshots(demo);
    updateCollections(demo, &demo.state);
    if (demo.state.screen == .album_detail and demo.state.album_detail_id >= 0) loadAlbumTracks(demo, demo.state.album_detail_id);
    if (demo.state.screen == .artist_detail and demo.state.artist_detail_id >= 0) loadArtistTracks(demo, demo.state.artist_detail_id);
    if (demo.state.screen == .genre_detail and demo.state.genre_detail_id >= 0) loadGenreTracks(demo, demo.state.genre_detail_id);
    if (demo.state.screen == .playlist_detail and demo.state.playlist_detail_id >= 0) loadPlaylistTracks(demo, demo.state.playlist_detail_id);
    demo.queue_generation = std.math.maxInt(u64);
    updateQueueSnapshot(demo, &demo.state);
    updateCurrentTrack(demo, &demo.state);
    demo.state.metadata_editing = false;
    demo.state.metadata_active_index = 0;
    demo.metadata_song_id = -1;
}

fn openGuiContextMenu(demo: *Demo) bool {
    if (demo.state.screen == .albums and demo.state.selection < demo.state.albums.len) {
        const album = demo.state.albums[demo.state.selection];
        demo.album_actions = album.id;
        demo.state.context_menu_title = album.title;
        demo.state.context_menu_selection = 0;
        demo.state.context_menu_open = true;
        return true;
    }
    demo.album_actions = null;
    const track = selectedGuiContextTrack(demo) orelse return false;
    demo.state.context_menu_song_id = track.id;
    demo.state.context_menu_title = track.title;
    demo.state.context_menu_artist = track.artist;
    demo.state.context_menu_favorite = track.favorite;
    demo.state.context_menu_selection = 0;
    demo.state.context_menu_open = true;
    return true;
}

fn openGuiPlaylistPicker(demo: *Demo, song_id: i64) void {
    demo.playlist_picker_song_id = song_id;
    demo.state.playlist_picker_open = true;
    demo.state.playlist_picker_saved = false;
    demo.state.playlist_picker_selection = 0;
    demo.state.playlist_picker_scroll = 0;
    demo.state.playlist_picker_status = "Choose a regular playlist.";
    demo.state.playlist_picker_title = demo.state.context_menu_title;
    demo.state.playlist_picker_artist = demo.state.context_menu_artist;
}

fn moveGuiPlaylistPicker(demo: *Demo, direction: i8) void {
    const count = demo.state.playlists.len;
    if (count == 0) return;
    if (direction < 0) {
        demo.state.playlist_picker_selection -|= 1;
    } else {
        demo.state.playlist_picker_selection = @min(demo.state.playlist_picker_selection + 1, count - 1);
    }
    const display = demo.display orelse return;
    const frame = guiFrame(demo, display);
    const visible = @max(1, gui_render.playlistPickerVisibleRows(frame));
    if (demo.state.playlist_picker_selection < demo.state.playlist_picker_scroll) {
        demo.state.playlist_picker_scroll = demo.state.playlist_picker_selection;
    } else if (demo.state.playlist_picker_selection >= demo.state.playlist_picker_scroll + visible) {
        demo.state.playlist_picker_scroll = demo.state.playlist_picker_selection - visible + 1;
    }
}

fn addGuiSongToSelectedPlaylist(demo: *Demo) void {
    if (demo.state.playlist_picker_saved) {
        demo.state.playlist_picker_open = false;
        return;
    }
    if (demo.state.playlist_picker_selection >= demo.state.playlists.len) return;
    const playlist = demo.state.playlists[demo.state.playlist_picker_selection];
    if (playlist.is_smart) {
        demo.state.playlist_picker_status = "Smart playlists are generated from rules.";
        return;
    }
    demo.app.db.addSongToPlaylist(playlist.id, demo.playlist_picker_song_id) catch |err| {
        demo.state.playlist_picker_status = "Could not add this track to the playlist.";
        std.log.err("GUI add track to playlist failed: {}", .{err});
        return;
    };
    refreshSnapshots(demo);
    updateCollections(demo, &demo.state);
    demo.state.playlist_picker_status = "Track added to playlist.";
    demo.state.playlist_picker_saved = true;
}

fn runGuiContextAction(demo: *Demo) void {
    if (demo.album_actions) |album_id| {
        demo.state.context_menu_open = false;
        demo.album_actions = null;
        switch (demo.state.context_menu_selection) {
            0 => _ = demo.app.playAlbum(album_id),
            1, 2 => {
                loadAlbumTracks(demo, album_id);
                enqueueTracks(demo, demo.album_tracks.items, demo.state.context_menu_selection == 2);
            },
            3 => {
                demo.state.screen = .album_detail;
                demo.state.album_detail_id = album_id;
                demo.state.selection = 0;
                demo.state.scroll = 0;
                loadAlbumTracks(demo, album_id);
            },
            4 => cycleGuiAlbumSort(demo),
            else => {},
        }
        return;
    }
    const id = demo.state.context_menu_song_id;
    switch (demo.state.context_menu_selection) {
        0 => _ = demo.app.playSongId(id) catch |err| std.log.err("GUI context play failed: {}", .{err}),
        1 => enqueueSong(demo, id, false),
        2 => enqueueSong(demo, id, true),
        3 => {
            const current = if (demo.app.lib.getSongById(id)) |song| song.favorite != 0 else false;
            const next = !current;
            demo.app.db.setFavorite(id, @intFromBool(next)) catch |err| {
                std.log.err("GUI context favorite update failed: {}", .{err});
                return;
            };
            demo.app.lib.setFavorite(id, next);
            if (id >= std.math.minInt(i32) and id <= std.math.maxInt(i32)) demo.app.play_queue.setShuffleFavorite(@intCast(id), next);
        },
        4 => {
            demo.state.context_menu_open = false;
            _ = beginGuiMetadataEditor(demo, id);
            return;
        },
        5 => {
            openGuiPlaylistPicker(demo, id);
            demo.state.context_menu_open = false;
            return;
        },
        else => {},
    }
    demo.state.context_menu_open = false;
}

fn enqueueTracks(demo: *Demo, tracks: []const U.AlbumTrackRow, next: bool) void {
    if (tracks.len == 0) return;
    if (next) {
        enqueueSong(demo, tracks[0].song_id, true);
        return;
    }
    var ids = std.ArrayList(i32).empty;
    defer ids.deinit(demo.app.allocator);
    for (tracks) |track| {
        if (track.song_id < std.math.minInt(i32) or track.song_id > std.math.maxInt(i32)) continue;
        ids.append(demo.app.allocator, @intCast(track.song_id)) catch return;
    }
    demo.app.play_queue.enqueueMany(ids.items) catch {};
}

fn removeQueueSelection(demo: *Demo) void {
    const queue = &demo.app.play_queue;
    if (demo.state.selection >= queue.size()) return;
    const removed = demo.state.selection;
    const current = removed == queue.currentIndex();
    if (current and queue.size() > 1) {
        const replacement = if (removed + 1 < queue.size()) removed + 1 else removed - 1;
        if (demo.app.playQueueIndex(replacement)) |_| {
            queue.removeAt(removed) catch {};
        } else |_| {
            queue.removeAt(removed) catch {};
            demo.app.engine.stop();
            demo.app.has_current_path = false;
        }
    } else {
        queue.removeAt(removed) catch {};
        if (current) {
            demo.app.engine.stop();
            demo.app.has_current_path = false;
        }
    }
    demo.state.selection = @min(removed, queue.size() -| 1);
}

fn saveSettingsField(demo: *Demo, index: usize) void {
    const value = demo.settings_fields[index].text();
    var buffer: [513:0]u8 = undefined;
    @memcpy(buffer[0..value.len], value);
    buffer[value.len] = 0;
    const sentinel_value = buffer[0..value.len :0];
    switch (index) {
        0 => demo.app.config.setStr("lastfm", "api_key", sentinel_value),
        1 => demo.app.config.setStr("lastfm", "shared_secret", sentinel_value),
        2 => demo.app.config.setStr("lastfm", "session_key", sentinel_value),
        else => unreachable,
    }
    demo.app.saveConfig();
}

fn beginSettingsField(demo: *Demo, index: usize) void {
    if (index >= demo.settings_fields.len) return;
    demo.settings_active_field = index;
    demo.state.settings_editing = true;
    demo.state.settings_active_field = @intCast(index);
}

fn finishSettingsField(demo: *Demo, save: bool) void {
    if (demo.settings_active_field) |index| if (save) saveSettingsField(demo, index);
    demo.settings_active_field = null;
    demo.state.settings_editing = false;
    demo.state.settings_active_field = -1;
}

fn onKeyChar(ctx: *anyopaque, codepoint: u32) void {
    const demo: *Demo = @ptrCast(@alignCast(ctx));
    if (demo.ignore_text_trigger) |trigger| {
        demo.ignore_text_trigger = null;
        if (codepoint == trigger) return;
    }
    if (demo.state.playlist_modal_open) {
        if (!demo.state.playlist_modal_saved and demo.state.playlist_modal_mode != .delete) _ = demo.playlist_name_input.insertCodepoint(codepoint);
        return;
    }
    if (demo.search_active) {
        if (demo.ignore_search_trigger_char and codepoint == '/') {
            demo.ignore_search_trigger_char = false;
            return;
        }
        demo.ignore_search_trigger_char = false;
        if (demo.search_input.insertCodepoint(codepoint)) {
            demo.state.selection = 0;
            demo.state.scroll = 0;
            demo.scroll_offset = 0;
            demo.scroll_anchor = 0;
            rebuildGuiFilters(demo);
            updateCollections(demo, &demo.state);
        }
        return;
    }
    if (demo.settings_active_field) |index| {
        if (demo.settings_fields[index].insertCodepoint(codepoint)) saveSettingsField(demo, index);
        return;
    }
    if (demo.state.metadata_editing and demo.metadata_fields[demo.state.metadata_active_index].insertCodepoint(codepoint)) {
        demo.metadata_status = "";
    }
}

fn hasTextFocus(demo: *const Demo) bool {
    return demo.search_active or demo.settings_active_field != null or demo.state.metadata_editing or demo.state.playlist_modal_open;
}

fn onKeyDown(ctx: *anyopaque, key: al.KeyCode) void {
    const demo: *Demo = @ptrCast(@alignCast(ctx));
    const had_focus = hasTextFocus(demo);
    handleKeyDown(ctx, key);
    // Allegro delivers KEY_DOWN followed by KEY_CHAR. A shortcut that opens a
    // field must not type itself into the newly focused field.
    if (!had_focus and hasTextFocus(demo)) demo.ignore_text_trigger = switch (key) {
        .E => 'e',
        .L => 'l',
        .N => 'n',
        .Num5 => '5',
        .Num6 => '6',
        else => null,
    };
}

fn handleKeyDown(ctx: *anyopaque, key: al.KeyCode) void {
    const demo: *Demo = @ptrCast(@alignCast(ctx));
    if (key == .Q and demo.settings_active_field == null and !demo.state.metadata_editing and !demo.search_active and !demo.state.playlist_modal_open and !demo.state.playlist_picker_open) {
        persistWindowSize(demo);
        demo.quit = true;
        return;
    }
    if (demo.settings_active_field) |index| {
        switch (key) {
            .Escape => finishSettingsField(demo, false),
            .Enter, .PadEnter, .Tab => {
                saveSettingsField(demo, index);
                if (index + 1 < demo.settings_fields.len) beginSettingsField(demo, index + 1) else finishSettingsField(demo, false);
            },
            .Backspace => {
                if (demo.settings_fields[index].backspace()) saveSettingsField(demo, index);
            },
            .Delete, .PadDelete => {
                if (demo.settings_fields[index].deleteForward()) saveSettingsField(demo, index);
            },
            .Left => demo.settings_fields[index].moveLeft(),
            .Right => demo.settings_fields[index].moveRight(),
            .Home => demo.settings_fields[index].home(),
            .End => demo.settings_fields[index].end(),
            else => {},
        }
        return;
    }
    if (demo.state.playlist_picker_open) {
        if (demo.state.playlist_picker_saved) {
            if (key == .Escape or key == .Enter or key == .PadEnter) demo.state.playlist_picker_open = false;
            return;
        }
        switch (key) {
            .Escape => demo.state.playlist_picker_open = false,
            .Up, .K => moveGuiPlaylistPicker(demo, -1),
            .Down, .J => moveGuiPlaylistPicker(demo, 1),
            .Enter, .PadEnter => addGuiSongToSelectedPlaylist(demo),
            else => {},
        }
        return;
    }
    if (demo.state.playlist_modal_open) {
        if (demo.state.playlist_modal_saved) {
            if (key == .Escape or key == .Enter or key == .PadEnter) demo.state.playlist_modal_open = false;
            return;
        }
        switch (key) {
            .Escape => demo.state.playlist_modal_open = false,
            .Enter, .PadEnter => submitPlaylistModal(demo),
            .Backspace => {
                if (demo.state.playlist_modal_mode != .delete) _ = demo.playlist_name_input.backspace();
            },
            .Delete, .PadDelete => {
                if (demo.state.playlist_modal_mode != .delete) _ = demo.playlist_name_input.deleteForward();
            },
            .Left => demo.playlist_name_input.moveLeft(),
            .Right => demo.playlist_name_input.moveRight(),
            .Home => demo.playlist_name_input.home(),
            .End => demo.playlist_name_input.end(),
            else => {},
        }
        return;
    }
    if (demo.search_active) {
        switch (key) {
            .Escape => {
                demo.search_input.setText("");
                demo.search_active = false;
                demo.ignore_search_trigger_char = false;
                rebuildGuiFilters(demo);
                updateCollections(demo, &demo.state);
            },
            .Enter, .PadEnter, .Tab => {
                demo.search_active = false;
                demo.ignore_search_trigger_char = false;
                updateCollections(demo, &demo.state);
            },
            .Left => demo.search_input.moveLeft(),
            .Right => demo.search_input.moveRight(),
            .Home => demo.search_input.home(),
            .End => demo.search_input.end(),
            .Delete, .PadDelete => {
                if (demo.search_input.deleteForward()) {
                    demo.state.selection = 0;
                    demo.state.scroll = 0;
                    demo.scroll_offset = 0;
                    demo.scroll_anchor = 0;
                    rebuildGuiFilters(demo);
                    updateCollections(demo, &demo.state);
                }
            },
            .Backspace => {
                if (demo.search_input.backspace()) {
                    demo.state.selection = 0;
                    demo.state.scroll = 0;
                    demo.scroll_offset = 0;
                    demo.scroll_anchor = 0;
                    rebuildGuiFilters(demo);
                    updateCollections(demo, &demo.state);
                }
            },
            else => {},
        }
        return;
    }
    if (demo.state.metadata_editing) {
        switch (key) {
            .Escape => {
                demo.state.metadata_editing = false;
                demo.metadata_song_id = -1;
            },
            .Tab, .Down, .J => demo.state.metadata_active_index = (demo.state.metadata_active_index + 1) % demo.metadata_fields.len,
            .Up, .K => demo.state.metadata_active_index = (demo.state.metadata_active_index + demo.metadata_fields.len - 1) % demo.metadata_fields.len,
            .Enter, .PadEnter => saveGuiMetadataEditor(demo),
            .Backspace => _ = demo.metadata_fields[demo.state.metadata_active_index].backspace(),
            .Delete, .PadDelete => _ = demo.metadata_fields[demo.state.metadata_active_index].deleteForward(),
            .Left => demo.metadata_fields[demo.state.metadata_active_index].moveLeft(),
            .Right => demo.metadata_fields[demo.state.metadata_active_index].moveRight(),
            .Home => demo.metadata_fields[demo.state.metadata_active_index].home(),
            .End => demo.metadata_fields[demo.state.metadata_active_index].end(),
            else => {},
        }
        return;
    }
    if (demo.state.context_menu_open) {
        switch (key) {
            .Escape, .V => demo.state.context_menu_open = false,
            .Up, .K => demo.state.context_menu_selection -|= 1,
            .Down, .J => demo.state.context_menu_selection = @min(demo.state.context_menu_selection + 1, 5),
            .Enter, .PadEnter => runGuiContextAction(demo),
            .Num1 => {
                demo.state.context_menu_selection = 0;
                runGuiContextAction(demo);
            },
            .Num2 => {
                demo.state.context_menu_selection = 1;
                runGuiContextAction(demo);
            },
            .Num3 => {
                demo.state.context_menu_selection = 2;
                runGuiContextAction(demo);
            },
            .Num4 => {
                demo.state.context_menu_selection = 3;
                runGuiContextAction(demo);
            },
            .Num5 => {
                demo.state.context_menu_selection = 4;
                runGuiContextAction(demo);
            },
            .Num6 => {
                demo.state.context_menu_selection = 5;
                runGuiContextAction(demo);
            },
            else => {},
        }
        return;
    }
    if (demo.state.scanning) {
        if (key == .Escape) demo.scan.cancelScan();
        return;
    }
    if (demo.health.status.load(.acquire) == 1) {
        if (key == .Escape) demo.health.requestCancel();
        return;
    }
    if (key == .Slash and guiSearchable(demo.state.screen)) {
        if (demo.search_screen != demo.state.screen) demo.search_input.setText("");
        demo.search_screen = demo.state.screen;
        demo.search_active = true;
        demo.ignore_search_trigger_char = true;
        demo.state.selection = 0;
        demo.state.scroll = 0;
        demo.scroll_offset = 0;
        demo.scroll_anchor = 0;
        rebuildGuiFilters(demo);
        updateCollections(demo, &demo.state);
        return;
    }
    if (demo.state.screen == .now_playing and key == .Z) {
        cycleVisualizer(demo);
        return;
    }
    if (demo.state.screen == .albums and key == .O) {
        cycleGuiAlbumSort(demo);
        return;
    }
    if (demo.state.screen == .playlists) {
        if (key == .N) {
            openPlaylistDialog(demo, .create, -1, "");
            return;
        }
        if (key == .F2) {
            if (demo.state.selection < demo.state.playlists.len) {
                const playlist = demo.state.playlists[demo.state.selection];
                openPlaylistDialog(demo, .rename, playlist.id, playlist.name);
            }
            return;
        }
        if (key == .Delete or key == .PadDelete) {
            if (demo.state.selection < demo.state.playlists.len) {
                const playlist = demo.state.playlists[demo.state.selection];
                openPlaylistDialog(demo, .delete, playlist.id, playlist.name);
                demo.playlist_modal_status = "This also removes its saved track list.";
            }
            return;
        }
    }
    if (demo.state.screen == .queue and key == .W) {
        openQueuePlaylistDialog(demo);
        return;
    }
    if (demo.state.screen == .playlist_detail) {
        if (key == .X) {
            removeGuiPlaylistTrack(demo);
            return;
        }
        if (key == .Left or key == .Right) {
            moveGuiPlaylistTrack(demo, if (key == .Left) -1 else 1);
            return;
        }
    }
    if (key == .E) {
        if (selectedGuiContextTrack(demo)) |track| _ = beginGuiMetadataEditor(demo, track.id);
        return;
    }
    if (key == .V) {
        _ = openGuiContextMenu(demo);
        return;
    }
    if (demo.state.screen == .settings and (key == .Left or key == .Right)) {
        adjustCrossfade(demo, if (key == .Right) 3 else -3);
        return;
    }
    if (demo.state.screen == .settings and key == .L) {
        beginSettingsField(demo, 0);
        return;
    }
    if (demo.state.screen == .playlists and (key == .M or key == .R or key == .S)) {
        const template = switch (key) {
            .M => .{ "Most played", db_mod.Database.SmartRule.most_played, "" },
            .R => .{ "Recently played", db_mod.Database.SmartRule.recently_played, "" },
            else => .{ "Short tracks", db_mod.Database.SmartRule.short_tracks, "300" },
        };
        createGuiSmartPlaylist(demo, template[0], template[1], template[2]);
        return;
    }
    if (demo.state.screen == .playlists and key == .F) {
        createGuiSmartPlaylist(demo, "Favorites", db_mod.Database.SmartRule.favorites, "");
        return;
    }
    if (demo.state.screen == .settings and key == .P) {
        _ = demo.app.config.nextPlaybackProfile();
        demo.app.engine.setGain(@as(f32, @floatFromInt(demo.app.config.getVolumePercent())) / 100.0);
        demo.app.saveConfig();
        demo.app.refreshNormalization();
        return;
    }
    if (demo.state.screen == .settings and key == .N) {
        demo.app.config.setNormalizationEnabled(!demo.app.config.getNormalizationEnabled());
        demo.app.saveConfig();
        demo.app.refreshNormalization();
        return;
    }
    if (demo.state.screen == .settings and key == .M) {
        demo.app.config.setNormalizationPolicy(if (demo.app.config.getNormalizationPolicy() == .track) .album else .track);
        demo.app.saveConfig();
        demo.app.refreshNormalization();
        return;
    }
    if (demo.state.screen == .settings and key == .R) {
        demo.scan.start(false) catch |err| std.log.err("could not start library scan: {}", .{err});
        return;
    }
    if (demo.state.screen == .settings and key == .H) {
        startHealth(demo);
        return;
    }
    if (demo.state.screen == .settings and key == .O) {
        const api_key = demo.app.config.getLastFmApiKey();
        const shared_secret = demo.app.config.getLastFmSharedSecret();
        if (api_key.len == 0 or shared_secret.len == 0) {
            demo.auth_status = "Set the Last.fm API key and secret first.";
        } else if (demo.auth_token.len > 0) {
            demo.auth_status = "Authorization is already waiting; approve the URL and press K.";
        } else {
            demo.auth.start(.begin, api_key, shared_secret, "") catch |err| {
                demo.auth_status = "Could not start Last.fm authorization.";
                std.log.err("Last.fm authorization start failed: {}", .{err});
                return;
            };
            demo.auth_status = "Requesting Last.fm authorization...";
        }
        return;
    }
    if (demo.state.screen == .settings and key == .K) {
        if (demo.auth_token.len == 0) {
            demo.auth_status = "Press O to begin authorization first.";
        } else {
            demo.auth.start(.finish, demo.app.config.getLastFmApiKey(), demo.app.config.getLastFmSharedSecret(), demo.auth_token) catch |err| {
                demo.auth_status = "Could not finish Last.fm authorization.";
                std.log.err("Last.fm authorization finish failed: {}", .{err});
                return;
            };
            demo.auth_status = "Finishing Last.fm authorization...";
        }
        return;
    }
    if (demo.state.screen == .queue) {
        if (key == .C) {
            demo.app.engine.stop();
            demo.app.play_queue.clear();
            demo.app.has_current_path = false;
            demo.state.selection = 0;
            return;
        }
        if (key == .X) {
            removeQueueSelection(demo);
            return;
        }
        if (key == .Left or key == .Right) {
            const size = demo.app.play_queue.size();
            if (size > 1) {
                const target = if (key == .Left) demo.state.selection -| 1 else @min(demo.state.selection + 1, size - 1);
                demo.app.play_queue.moveAt(demo.state.selection, target) catch {};
                demo.state.selection = target;
            }
            return;
        }
    }
    if (key == .A or key == .E) {
        const next = key == .E;
        switch (demo.state.screen) {
            .library => if (selectedLibrarySongId(demo)) |id| enqueueSong(demo, id, next),
            .albums => if (demo.state.selection < demo.state.albums.len) {
                loadAlbumTracks(demo, demo.state.albums[demo.state.selection].id);
                enqueueTracks(demo, demo.album_tracks.items, next);
            },
            .album_detail => enqueueTracks(demo, demo.album_tracks.items, next),
            .artist_detail => enqueueTracks(demo, demo.artist_tracks.items, next),
            .genre_detail => enqueueTracks(demo, demo.genre_tracks.items, next),
            .playlist_detail => enqueueTracks(demo, demo.playlist_tracks.items, next),
            else => {},
        }
        return;
    }
    if (actionForKey(key)) |action| {
        const display = demo.display orelse return;
        const frame = guiFrame(demo, display);
        if (handleGalleryKey(demo, key, frame)) return;
        const visible = frame.visibleRows();
        execute(demo, U.apply(&demo.state, action, visible));
    }
}

fn adjustCrossfade(demo: *Demo, delta: i16) void {
    const current: i16 = demo.app.config.getCrossfadeSeconds();
    const next: u8 = @intCast(@max(0, @min(30, current + delta)));
    if (next == current) return;
    demo.app.config.setCrossfadeSeconds(next);
    demo.app.engine.setCrossfadeSecs(@floatFromInt(next));
    demo.app.saveConfig();
}

fn selectPlaylistIndex(demo: *Demo, index: usize) void {
    demo.state.selection = index;
    const display = demo.display orelse {
        demo.state.scroll = index;
        return;
    };
    const layout = guiFrame(demo, display);
    const visible = layout.visibleRows();
    demo.state.scroll = index -| (visible -| 1);
    demo.scroll_offset = layout.offsetFromAnchor(demo.state.scroll);
    demo.scroll_anchor = demo.state.scroll;
}

fn selectGuiPlaylistId(demo: *Demo, id: i64) void {
    for (demo.state.playlists, 0..) |playlist, index| {
        if (playlist.id == id) {
            selectPlaylistIndex(demo, index);
            return;
        }
    }
    if (guiSearchQuery(demo, .playlists).len > 0) {
        demo.search_input.setText("");
        demo.search_active = false;
        rebuildGuiFilters(demo);
        updateCollections(demo, &demo.state);
        for (demo.state.playlists, 0..) |playlist, index| if (playlist.id == id) {
            selectPlaylistIndex(demo, index);
            return;
        };
    }
}

fn createGuiSmartPlaylist(demo: *Demo, name: []const u8, rule: db_mod.Database.SmartRule, value: []const u8) void {
    var found: ?i64 = null;
    for (demo.playlists.items) |playlist| {
        if (std.mem.eql(u8, playlist.name, name)) {
            if (!playlist.is_smart or playlist.smart_rule != @backingInt(rule)) {
                std.log.err("cannot create smart playlist '{s}': a playlist with that name already exists", .{name});
                return;
            }
            found = playlist.id;
            break;
        }
    }
    if (found) |id| {
        selectGuiPlaylistId(demo, id);
        return;
    }
    _ = demo.app.db.createSmartPlaylist(name, rule, value, 100) catch |err| {
        std.log.err("create smart playlist failed: {}", .{err});
        return;
    };
    refreshSnapshots(demo);
    updateCollections(demo, &demo.state);
    for (demo.playlists.items) |playlist| {
        if (std.mem.eql(u8, playlist.name, name)) {
            selectGuiPlaylistId(demo, playlist.id);
            break;
        }
    }
}

fn selectableCount(state: *const U.State) usize {
    return switch (state.screen) {
        .library => state.row_count,
        .albums => state.album_count,
        .album_detail => state.album_detail_count,
        .artists => state.artist_count,
        .artist_detail => state.artist_detail_count,
        .genres => state.genre_count,
        .genre_detail => state.genre_detail_count,
        .playlists => state.playlist_count,
        .playlist_detail => state.playlist_detail_count,
        .queue => state.queue_count,
        else => 0,
    };
}

fn scrollGui(demo: *Demo, layout: gui_render.Layout, delta: f32) void {
    const count = gui_layout.scrollCount(&demo.state);
    demo.scroll_offset = @max(0, @min(layout.maxScroll(count), demo.scroll_offset + delta));
    demo.state.scroll = layout.anchorFromOffset(demo.scroll_offset);
    demo.scroll_anchor = demo.state.scroll;
}

fn onMouseMotion(ctx: *anyopaque, x: f32, y: f32) void {
    const demo: *Demo = @ptrCast(@alignCast(ctx));
    const display = demo.display orelse return;
    const layout = guiFrame(demo, display);
    if (gui_layout.modalOpen(&demo.state) or demo.state.scanning) {
        demo.hover_nav = null;
        demo.hover_control = null;
        demo.hover_row = null;
        return;
    }
    if (demo.state.queue_dragging) demo.state.queue_drop_target = layout.rowAt(x, y, demo.scroll_offset, demo.state.queue_count);
    if (demo.volume_dragging) if (layout.volumeTrack()) |track| {
        demo.app.engine.setGain(@max(0.0, @min(1.0, (x - track.x) / @max(1, track.w))));
    };
    if (demo.seek_dragging) {
        const track = layout.seekTrack();
        const fraction = @max(0.0, @min(1.0, (x - track.x) / @max(1, track.w)));
        if (demo.state.duration > 0) demo.app.engine.setProgress(fraction * demo.state.duration);
    }
    if (demo.scrollbar_dragging) {
        if (gui_render.scrollbarGeometry(layout, &demo.state, demo.scroll_offset)) |geometry| if (geometry.thumb) |thumb| {
            const travel = @max(1, geometry.track.h - thumb.h);
            const fraction = @max(0, @min(1, (y - demo.scrollbar_drag_offset - geometry.track.y) / travel));
            const count = gui_layout.scrollCount(&demo.state);
            demo.scroll_offset = fraction * layout.maxScroll(count);
            scrollGui(demo, layout, 0);
        };
    }
    demo.hover_nav = layout.navScreen(x, y);
    demo.hover_control = switch (gui_input.hitTransport(layout, x, y)) {
        .control => |control| control,
        else => null,
    };
    demo.hover_row = layout.rowAt(x, y, demo.scroll_offset, selectableCount(&demo.state));
}

fn onMouseWheel(ctx: *anyopaque, x: f32, y: f32, dz: i32) void {
    const demo: *Demo = @ptrCast(@alignCast(ctx));
    const display = demo.display orelse return;
    const layout = guiFrame(demo, display);
    if (dz == 0) return;
    if (demo.state.playlist_picker_open) {
        moveGuiPlaylistPicker(demo, if (dz > 0) -1 else 1);
        return;
    }
    if (demo.state.metadata_editing) {
        demo.state.metadata_active_index = if (dz > 0) demo.state.metadata_active_index -| 1 else @min(7, demo.state.metadata_active_index + 1);
        return;
    }
    if (demo.state.context_menu_open) {
        demo.state.context_menu_selection = if (dz > 0) demo.state.context_menu_selection -| 1 else @min(5, demo.state.context_menu_selection + 1);
        return;
    }
    if (gui_layout.modalOpen(&demo.state) or demo.state.scanning or !layout.body.contains(x, y)) return;
    if (demo.state.screen == .settings) finishSettingsField(demo, false);
    scrollGui(demo, layout, -@as(f32, @floatFromInt(dz)) * gui_layout.row_height);
}

fn onMouseButton(ctx: *anyopaque, button: i32, pressed: bool, x: f32, y: f32) void {
    const demo: *Demo = @ptrCast(@alignCast(ctx));
    if (button == 2) {
        if (!pressed or demo.state.context_menu_open or demo.state.metadata_editing or demo.state.playlist_modal_open or demo.state.playlist_picker_open) return;
        const display = demo.display orelse return;
        const layout = guiFrame(demo, display);
        if (demo.state.screen == .now_playing) {
            _ = openGuiContextMenu(demo);
            return;
        }
        if (layout.rowAt(x, y, demo.scroll_offset, selectableCount(&demo.state))) |index| {
            demo.state.selection = index;
            _ = openGuiContextMenu(demo);
        }
        return;
    }
    if (button != 1) return;
    if (!pressed) {
        if (demo.pressed_control) |control| {
            if (demo.display) |display| {
                const frame = guiFrame(demo, display);
                const hit = gui_input.hitTransport(frame, x, y);
                if (!gui_layout.modalOpen(&demo.state) and hit == .control and hit.control == control) {
                    execute(demo, U.apply(&demo.state, switch (control) {
                        .previous => .prev,
                        .toggle_pause => .toggle_pause,
                        .next => .next,
                    }, frame.visibleRows()));
                }
            }
        }
        if (demo.state.queue_dragging) {
            const from = demo.queue_drag_from;
            const target = demo.state.queue_drop_target orelse from;
            demo.state.queue_dragging = false;
            demo.state.queue_drop_target = null;
            if (from != target and from < demo.app.play_queue.size() and target < demo.app.play_queue.size()) {
                demo.app.play_queue.moveAt(from, target) catch {};
                demo.state.selection = target;
                demo.queue_generation = std.math.maxInt(u64);
                updateQueueSnapshot(demo, &demo.state);
            }
        }
        demo.scrollbar_dragging = false;
        demo.seek_dragging = false;
        if (demo.volume_dragging) {
            demo.app.config.setVolumePercent(@intFromFloat(demo.app.engine.getGain() * 100.0));
            demo.app.saveConfig();
        }
        demo.volume_dragging = false;
        demo.pressed_control = null;
        return;
    }
    const display = demo.display orelse return;
    const layout = guiFrame(demo, display);
    if (demo.state.playlist_picker_open) {
        if (gui_render.playlistPickerDoneRect(layout).contains(x, y)) {
            demo.state.playlist_picker_open = false;
        } else if (gui_render.playlistPickerRowAt(layout, x, y, demo.state.playlist_picker_scroll)) |index| {
            if (index < demo.state.playlists.len) {
                demo.state.playlist_picker_selection = index;
                addGuiSongToSelectedPlaylist(demo);
            }
        }
        return;
    }
    if (demo.state.playlist_modal_open) {
        if (gui_render.playlistModalSaveRect(layout).contains(x, y)) {
            submitPlaylistModal(demo);
        } else if (gui_render.playlistModalCancelRect(layout).contains(x, y)) {
            demo.state.playlist_modal_open = false;
        } else if (gui_render.playlistModalInputRect(layout).contains(x, y)) {
            const input_rect = gui_render.playlistModalInputRect(layout);
            demo.playlist_name_input.setCursorFraction((x - input_rect.x - 16) / @max(1, input_rect.w - 32));
        }
        return;
    }
    if (demo.state.metadata_editing) {
        if (gui_render.metadataEditorSaveRect(layout).contains(x, y)) {
            saveGuiMetadataEditor(demo);
        } else if (gui_render.metadataEditorCancelRect(layout).contains(x, y)) {
            demo.state.metadata_editing = false;
            demo.metadata_song_id = -1;
        } else if (gui_render.metadataEditorFieldAt(layout, x, y, demo.state.metadata_active_index)) |index| {
            demo.state.metadata_active_index = index;
            const field = gui_render.metadataEditorFieldRect(layout, index, demo.state.metadata_active_index);
            demo.metadata_fields[index].setCursorFraction((x - field.x - 8) / @max(1, field.w - 16));
        }
        return;
    }
    if (demo.state.context_menu_open) {
        if (gui_render.contextMenuActionAt(layout, x, y, demo.state.context_menu_selection)) |index| {
            demo.state.context_menu_selection = index;
            runGuiContextAction(demo);
        } else if (!gui_render.contextMenuCard(layout).contains(x, y)) {
            demo.state.context_menu_open = false;
        }
        return;
    }
    if (demo.state.scanning) return;
    if (gui_framework.containsPoint(layout.inspectorToggle(), x, y)) {
        demo.inspector_open = !demo.inspector_open;
        demo.app.config.setInt("gallery", "inspector", @intFromBool(demo.inspector_open));
        demo.app.saveConfig();
        demo.hover_row = null;
        return;
    }
    if (gui_framework.containsPoint(layout.playerArt(), x, y)) {
        demo.state.screen = .now_playing;
        demo.state.selection = 0;
        demo.state.scroll = 0;
        return;
    }
    if (layout.inspector.w > 0) {
        for (0..2) |i| if (gui_framework.containsPoint(layout.inspectorTab(i), x, y)) {
            demo.inspector_lyrics = i == 1;
            return;
        };
        if (!demo.inspector_lyrics) if (gui_framework.containsPoint(layout.inspectorRows(), x, y)) {
            const first = (demo.state.queue_current_index orelse 0) -| 1;
            if (layout.inspectorRowAt(x, y, first, demo.state.queue.len)) |index| _ = demo.app.playQueueIndex(index) catch {};
            return;
        };
    }
    if (demo.state.screen == .album_detail and gui_framework.containsPoint(layout.albumPlay(), x, y)) {
        _ = demo.app.playAlbum(demo.state.album_detail_id);
        return;
    }
    if (layout.navScreen(x, y)) |screen| {
        finishSettingsField(demo, false);
        demo.search_active = false;
        demo.last_click_index = null;
        demo.hover_row = null;
        demo.state.screen = screen;
        demo.state.selection = 0;
        demo.state.scroll = 0;
        demo.scroll_offset = 0;
        demo.scroll_anchor = 0;
        return;
    }
    {
        if (gui_render.scrollbarGeometry(layout, &demo.state, demo.scroll_offset)) |geometry| {
            switch (gui_input.hitScrollbar(geometry.track, geometry.thumb, x, y)) {
                .thumb => {
                    if (demo.state.screen == .settings) finishSettingsField(demo, false);
                    demo.scrollbar_dragging = true;
                    demo.scrollbar_drag_offset = if (geometry.thumb) |thumb| y - thumb.y else 0;
                    return;
                },
                .page_up, .page_down => {
                    const direction: f32 = if (gui_input.hitScrollbar(geometry.track, geometry.thumb, x, y) == .page_up) -1 else 1;
                    if (demo.state.screen == .settings) finishSettingsField(demo, false);
                    scrollGui(demo, layout, direction * layout.body.h);
                    return;
                },
                .none => {},
            }
        }
    }
    if (gui_render.volumeTrack(layout)) |track| {
        const hit_area = ui.Rect{ .x = track.x - 8, .y = track.y - 12, .w = track.w + 16, .h = track.h + 24 };
        if (hit_area.contains(x, y)) {
            demo.volume_dragging = true;
            demo.app.engine.setGain(@max(0.0, @min(1.0, (x - track.x) / @max(1.0, track.w))));
            return;
        }
    }
    switch (gui_input.hitTransport(layout, x, y)) {
        .seek => |fraction| {
            demo.seek_dragging = true;
            if (demo.state.duration > 0) demo.app.engine.setProgress(fraction * demo.state.duration);
            return;
        },
        .control => |control| {
            demo.pressed_control = control;
            return;
        },
        .none, .row => {},
    }
    if (demo.state.screen == .now_playing) {
        for (0..2) |index| if (gui_framework.containsPoint(layout.visualizerButton(index), x, y)) {
            cycleVisualizer(demo);
            return;
        };
    }
    if (layout.toolbarButton().contains(x, y)) {
        // Leave text focus before invoking the existing semantic operations.
        finishSettingsField(demo, false);
        demo.search_active = false;
        switch (demo.state.screen) {
            .albums => cycleGuiAlbumSort(demo),
            .playlists => openPlaylistDialog(demo, .create, -1, ""),
            .queue => openQueuePlaylistDialog(demo),
            .settings => onKeyDown(ctx, .R),
            .now_playing, .library => _ = openGuiContextMenu(demo),
            else => execute(demo, U.apply(&demo.state, .back, layout.visibleRows())),
        }
        return;
    }
    if (guiSearchable(demo.state.screen) and layout.searchRect().contains(x, y)) {
        if (demo.search_screen != demo.state.screen) demo.search_input.setText("");
        demo.search_screen = demo.state.screen;
        demo.search_active = true;
        demo.ignore_search_trigger_char = false;
        rebuildGuiFilters(demo);
        updateCollections(demo, &demo.state);
        return;
    }
    demo.search_active = false;
    if (demo.state.screen == .settings) {
        const index = layout.rowAt(x, y, demo.scroll_offset, gui_layout.scrollCount(&demo.state)) orelse return;
        if (index >= 6 and index < 9) {
            beginSettingsField(demo, index - 6);
            const r = layout.rowRect(index, demo.scroll_offset);
            demo.settings_fields[index - 6].setCursorFraction((x - r.x - 8) / @max(1, r.w - 16));
        } else {
            finishSettingsField(demo, false);
            switch (index) {
                1 => onKeyDown(ctx, .P),
                2 => onKeyDown(ctx, .N),
                3 => onKeyDown(ctx, .M),
                4 => adjustCrossfade(demo, if (x < layout.body.x + layout.body.w / 2) -3 else 3),
                9 => onKeyDown(ctx, .O),
                10 => onKeyDown(ctx, .K),
                11 => onKeyDown(ctx, .H),
                else => {},
            }
        }
        return;
    }
    const index = layout.rowAt(x, y, demo.scroll_offset, selectableCount(&demo.state)) orelse return;
    demo.state.selection = index;
    if (demo.state.screen == .library or demo.state.screen == .album_detail or demo.state.screen == .artist_detail or demo.state.screen == .genre_detail or demo.state.screen == .playlist_detail or demo.state.screen == .queue) {
        if (gui_framework.containsPoint(layout.rowAction(index, demo.scroll_offset), x, y)) {
            _ = openGuiContextMenu(demo);
            return;
        }
    }
    if (demo.state.screen == .albums) {
        if (gui_framework.containsPoint(layout.galleryAction(index, demo.scroll_offset, false), x, y)) {
            _ = demo.app.playAlbum(demo.state.albums[index].id);
        } else if (gui_framework.containsPoint(layout.galleryAction(index, demo.scroll_offset, true), x, y)) {
            _ = openGuiContextMenu(demo);
        } else {
            execute(demo, U.apply(&demo.state, .enter, layout.visibleRows()));
        }
        demo.last_click_index = null;
        return;
    }
    if (demo.state.screen == .queue and x < layout.body.x + 28) {
        demo.queue_drag_from = index;
        demo.state.queue_dragging = true;
        demo.state.queue_drop_target = index;
        return;
    }
    const now = al.time.getTime();
    const activate = demo.last_click_screen == demo.state.screen and demo.last_click_index != null and demo.last_click_index.? == index and now - demo.last_click_time < 0.35;
    demo.last_click_index = index;
    demo.last_click_screen = demo.state.screen;
    demo.last_click_time = now;
    if (activate) {
        demo.last_click_index = null;
        execute(demo, U.apply(&demo.state, .enter, layout.visibleRows()));
    }
}

fn shouldQuit(ctx: *anyopaque) bool {
    return @as(*Demo, @ptrCast(@alignCast(ctx))).quit;
}

fn cycleVisualizer(demo: *Demo) void {
    demo.visualizer_mode = demo.visualizer_mode.next();
    demo.app.config.setInt("visualizer", "mode", @backingInt(demo.visualizer_mode));
    demo.app.saveConfig();
}

fn onInitDisplay(ctx: *anyopaque, display: *al.Display) void {
    const demo: *Demo = @ptrCast(@alignCast(ctx));
    demo.display = display;
    _ = display.setWindowConstraints(360, 300, 0, 0);
    display.applyWindowConstraints(true);
    demo.visualizer = gui_visualizer.Visualizer.init(demo.app.allocator) catch |err| failed: {
        std.log.warn("GPU visualization unavailable: {}", .{err});
        break :failed .{};
    };
}

fn onDeinitDisplay(ctx: *anyopaque) void {
    const demo: *Demo = @ptrCast(@alignCast(ctx));
    demo.visualizer.deinit();
    demo.covers.reset();
    demo.fonts.deinit();
    demo.display_resources_released = true;
    demo.display = null;
}

fn onFocusLost(ctx: *anyopaque) void {
    const demo: *Demo = @ptrCast(@alignCast(ctx));
    demo.scrollbar_dragging = false;
    demo.seek_dragging = false;
    demo.volume_dragging = false;
    demo.pressed_control = null;
    demo.hover_control = null;
    demo.hover_nav = null;
    demo.hover_row = null;
    demo.state.queue_dragging = false;
    demo.state.queue_drop_target = null;
    demo.last_click_index = null;
    demo.ignore_text_trigger = null;
}

fn onAudioStreamFinished(ctx: *anyopaque) void {
    const demo: *Demo = @ptrCast(@alignCast(ctx));
    demo.app.engine.handleAudioStreamFinishedFromEvent() catch |e| std.log.err("auto-advance failed: {}", .{e});
}

fn persistWindowSize(demo: *Demo) void {
    if (demo.display) |display| {
        demo.app.config.setInt("display", "width", display.getWidth());
        demo.app.config.setInt("display", "height", display.getHeight());
        demo.app.saveConfig();
    }
}

fn onDisplayClose(ctx: *anyopaque) bool {
    persistWindowSize(@ptrCast(@alignCast(ctx)));
    return true;
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var app = try app_mod.App.createDeferred(allocator, null, null);
    defer app.destroy();
    var control_server = player_control.Server.init();
    defer if (control_server) |*server| server.deinit();

    var queue = try al.EventQueue.create();
    defer {
        app.engine.event_queue = null;
        queue.destroy();
    }
    app.engine.event_queue = &queue;

    app.engine.setGain(@as(f32, @floatFromInt(app.config.getVolumePercent())) / 100.0);

    var demo = Demo{
        .app = app,
        .control = if (control_server) |*server| server else null,
        .scan = .{ .app = app, .allocator = allocator },
        .health = .{ .allocator = allocator },
        .auth = .{ .allocator = allocator },
        .fonts = gui_fonts.FontSet.load(allocator),
        .covers = .{ .allocator = allocator },
        .inspector_open = app.config.getInt("gallery", "inspector", 1) != 0,
        .detail_arena = std.heap.ArenaAllocator.init(allocator),
        .snapshot_arena = std.heap.ArenaAllocator.init(allocator),
        .queue_arena = std.heap.ArenaAllocator.init(allocator),
        .current_arena = std.heap.ArenaAllocator.init(allocator),
        .analyzer = spectrum.Analyzer.init(spectrum.default_sample_rate, .a_weight),
        .visualizer_mode = gui_visualizer.Mode.fromConfig(app.config.getInt("visualizer", "mode", 0)),
    };
    defer demo.scan.deinit();
    defer demo.health.deinit();
    defer demo.auth.deinit();
    defer if (demo.auth_token.len > 0) allocator.free(demo.auth_token);
    defer if (demo.auth_url.len > 0) allocator.free(demo.auth_url);
    defer demo.covers.reset();
    defer if (!demo.display_resources_released) demo.fonts.deinit();
    defer demo.detail_arena.deinit();
    defer demo.snapshot_arena.deinit();
    defer demo.queue_arena.deinit();
    defer demo.current_arena.deinit();
    defer demo.library_titles.deinit(allocator);
    defer demo.library_rows.deinit(allocator);
    defer demo.filtered_library_rows.deinit(allocator);
    defer demo.filtered_library_titles.deinit(allocator);
    defer demo.filtered_library_indices.deinit(allocator);
    defer demo.filtered_albums.deinit(allocator);
    defer demo.filtered_artists.deinit(allocator);
    defer demo.filtered_genres.deinit(allocator);
    defer demo.filtered_playlists.deinit(allocator);
    defer demo.albums.deinit(allocator);
    defer demo.album_tracks.deinit(allocator);
    defer demo.artists.deinit(allocator);
    defer demo.genres.deinit(allocator);
    defer demo.playlists.deinit(allocator);
    defer demo.artist_tracks.deinit(allocator);
    defer demo.genre_tracks.deinit(allocator);
    defer demo.playlist_tracks.deinit(allocator);
    defer demo.queue_rows.deinit(allocator);
    demo.settings_fields[0].setText(app.config.getLastFmApiKey());
    demo.settings_fields[1].setText(app.config.getLastFmSharedSecret());
    demo.settings_fields[2].setText(app.config.getLastFmSessionKey());
    refreshSnapshots(&demo);
    demo.scan.start(true) catch |err| {
        std.log.err("could not start initial library scan: {}", .{err});
        _ = app.startFirstSong();
    };
    try bootstrap.run(&queue, .{
        .width = app.config.getDisplayWidth(),
        .height = app.config.getDisplayHeight(),
        .resizable = true,
        .programmable_pipeline = true,
        // Keep input/render cadence at display rates. 30 Hz made pointer and
        // row selection updates visibly laggy even when rendering itself was
        // within budget; the timer is also the GUI's frame scheduler.
        .tick_interval_secs = 1.0 / 60.0,
    }, .{
        .ctx = &demo,
        .on_tick = onTick,
        .on_render = onRender,
        .on_init_display = onInitDisplay,
        .on_deinit_display = onDeinitDisplay,
        .on_audio_stream_finished = onAudioStreamFinished,
        .on_display_close = onDisplayClose,
        .on_key_down = onKeyDown,
        .on_key_char = onKeyChar,
        .on_focus_lost = onFocusLost,
        .on_mouse_motion = onMouseMotion,
        .on_mouse_wheel = onMouseWheel,
        .on_mouse_button = onMouseButton,
        .should_quit = shouldQuit,
    });
}
