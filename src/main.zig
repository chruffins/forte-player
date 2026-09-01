//! GUI frontend for Forte Player.
//!
//! The GUI uses the same pure State/reducer/view pipeline as the TUI. The
//! backend only interprets flat draw commands and maps Allegro events to
//! semantic actions; it does not retain a tree of widgets or event handlers.

const std = @import("std");
const al = @import("allegro");
const app_mod = @import("app.zig");
const entity = @import("music/entity.zig");
const PlaybackContextType = @import("music/play_queue.zig").PlaybackContextType;
const gui_jobs = @import("ui/gui_jobs.zig");
const bootstrap = @import("core/bootstrap.zig");
const gui_render = @import("ui/gui_render.zig");
const gui_fonts = @import("ui/gui_fonts.zig");
const gui_input = @import("ui/gui_input.zig");
const gui_framework = @import("ui/gui_framework.zig");
const gui_icons = @import("ui/gui_icons.zig");
const cover_art = @import("ui/cover_art.zig");
const spectrum = @import("dsp/spectrum.zig");
const U = @import("ui/ui_state.zig");
const view = @import("ui/ui_view.zig");

const ScanJob = gui_jobs.ScanJob;
const AuthJob = gui_jobs.AuthJob;
const AuthOp = gui_jobs.AuthOp;

const Demo = struct {
    app: *app_mod.App,
    scan: ScanJob,
    auth: AuthJob,
    fonts: gui_fonts.FontSet,
    icons: gui_icons.Icons,
    display: ?*al.Display = null,
    state: U.State = .{},
    commands: view.CmdList = .{},
    quit: bool = false,
    snapshot_arena: std.heap.ArenaAllocator,
    detail_arena: std.heap.ArenaAllocator,
    queue_arena: std.heap.ArenaAllocator,
    current_arena: std.heap.ArenaAllocator,
    library_titles: std.ArrayList([]const u8) = .{ .items = &.{}, .capacity = 0 },
    albums: std.ArrayList(U.AlbumRow) = .{ .items = &.{}, .capacity = 0 },
    album_tracks: std.ArrayList(U.AlbumTrackRow) = .{ .items = &.{}, .capacity = 0 },
    artists: std.ArrayList(U.ArtistRow) = .{ .items = &.{}, .capacity = 0 },
    genres: std.ArrayList(U.GenreRow) = .{ .items = &.{}, .capacity = 0 },
    playlists: std.ArrayList(U.PlaylistRow) = .{ .items = &.{}, .capacity = 0 },
    artist_tracks: std.ArrayList(U.AlbumTrackRow) = .{ .items = &.{}, .capacity = 0 },
    genre_tracks: std.ArrayList(U.AlbumTrackRow) = .{ .items = &.{}, .capacity = 0 },
    playlist_tracks: std.ArrayList(U.AlbumTrackRow) = .{ .items = &.{}, .capacity = 0 },
    queue_rows: std.ArrayList(U.QueueRow) = .{ .items = &.{}, .capacity = 0 },
    queue_generation: u64 = std.math.maxInt(u64),
    current_song_id: i64 = -1,
    current_artist: []const u8 = "",
    current_album: []const u8 = "",
    art_cells: [64 * 32]U.ArtCell = undefined,
    art_bitmap: ?al.graphics.Bitmap = null,
    art_w: u16 = 0,
    art_h: u16 = 0,
    analyzer: spectrum.Analyzer,
    smoother: spectrum.Smoother = .{},
    audio_samples: [spectrum.n_samples]f32 = undefined,
    spectrum_bands: [spectrum.n_bands]f32 = undefined,
    auth_token: []u8 = &.{},
    auth_url: []u8 = &.{},
    auth_status: []const u8 = "",
    hover_nav: ?U.Screen = null,
    hover_control: ?gui_input.Control = null,
    pressed_control: ?gui_input.Control = null,
    hover_cell_y: ?u16 = null,
    settings_fields: [3]gui_framework.TextInput = .{ .{}, .{}, .{} },
    settings_active_field: ?usize = null,
    scroll_offset: f32 = 0,
    scroll_anchor: usize = 0,
    scrollbar_dragging: bool = false,
    scrollbar_drag_offset: f32 = 0,
    seek_dragging: bool = false,
};

fn refreshSnapshots(demo: *Demo) void {
    const allocator = demo.app.allocator;
    // Snapshot rows are rebuilt after a rescan. Keep their string storage in a
    // separate arena so refreshes reclaim old metadata instead of accumulating
    // every historical library view.
    _ = demo.snapshot_arena.reset(.retain_capacity);
    const strings = demo.snapshot_arena.allocator();
    demo.library_titles.clearRetainingCapacity();
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
            demo.library_titles.append(allocator, title) catch break;
        }
    } else |_| {}
    if (demo.app.db.getAlbumsWithAllocator(strings, .by_name)) |rows| {
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
        }) catch break;
    } else |_| {}
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
    if (!demo.state.scanning) return false;
    demo.scan.join();
    if (status == 2) {
        demo.app.finishRescan(demo.scan.result, demo.scan.previous_path) catch |err| std.log.err("rescan reconciliation failed: {}", .{err});
        if (demo.scan.startup) {
            demo.app.restoreSavedQueueState();
            if (!demo.app.has_current_path) _ = demo.app.startFirstSong();
        }
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

fn clearArt(demo: *Demo) void {
    if (demo.art_bitmap) |*bitmap| bitmap.destroy();
    demo.art_bitmap = null;
    demo.art_w = 0;
    demo.art_h = 0;
}

fn loadCoverBitmap(demo: *Demo, mime: []const u8, bytes: []const u8) void {
    if (bytes.len == 0) return;
    var file = al.file.File.openMemFile(bytes.ptr, @intCast(bytes.len), "r") catch return;
    defer _ = file.close();
    const ident: [:0]const u8 = if (std.mem.indexOf(u8, mime, "png") != null) ".png" else if (std.mem.indexOf(u8, mime, "webp") != null) ".webp" else ".jpg";
    demo.art_bitmap = al.graphics.Bitmap.loadFromFile(&file, ident) catch null;
}

fn updateCurrentTrack(demo: *Demo, state: *U.State) void {
    state.path = if (demo.app.has_current_path) demo.app.current_path else "";
    state.title = "No track";
    state.artist = demo.current_artist;
    state.album = demo.current_album;
    state.favorite = false;
    if (!demo.app.has_current_path) {
        demo.current_song_id = -1;
        demo.current_artist = "";
        demo.current_album = "";
        clearArt(demo);
    } else if (demo.app.lib.songIdByPath(demo.app.current_path)) |id| {
        if (demo.app.lib.getSongById(id)) |song| {
            state.title = song.title;
            state.favorite = song.favorite != 0;
            if (demo.current_song_id != id) {
                demo.current_song_id = id;
                demo.current_artist = "";
                demo.current_album = "";
                _ = demo.current_arena.reset(.retain_capacity);
                if (demo.app.db.getSongContextWithAllocator(demo.current_arena.allocator(), id) catch null) |context| {
                    demo.current_artist = context.artist;
                    demo.current_album = context.album;
                }
                clearArt(demo);
                if (song.album_id >= 0) if (demo.app.db.getAlbumCoverWithAllocator(demo.current_arena.allocator(), song.album_id) catch null) |cover| {
                    const aw: usize = 24;
                    const ah: usize = 12;
                    if (cover.bytes.len > 0 and cover_art.renderCover(cover.bytes, aw, ah, &demo.art_cells)) {
                        demo.art_w = @intCast(aw);
                        demo.art_h = @intCast(ah);
                    }
                    loadCoverBitmap(demo, cover.mime, cover.bytes);
                };
                state.artist = demo.current_artist;
                state.album = demo.current_album;
            }
        }
    }
    state.artist = demo.current_artist;
    state.album = demo.current_album;
    state.art = if (demo.art_w > 0) .{ .w = demo.art_w, .h = demo.art_h, .cells = demo.art_cells[0 .. @as(usize, demo.art_w) * demo.art_h] } else .{};
    state.art_status = if (demo.art_w > 0) .ready else .none;
}

fn updateSpectrum(demo: *Demo, state: *U.State) void {
    const captured = demo.app.engine.copyRecentMono(spectrum.n_samples, &demo.audio_samples);
    if (captured == 0) {
        state.spectrum = &.{};
        return;
    }
    demo.analyzer.compute(demo.audio_samples[0..captured], &demo.spectrum_bands);
    demo.smoother.update(&demo.spectrum_bands);
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
    state.row_count = demo.library_titles.items.len;
    state.playing_index = if (demo.app.has_current_path) if (demo.app.lib.songIdByPath(demo.app.current_path)) |id| demo.app.lib.indexOfId(id) else null else null;
    state.albums = demo.albums.items;
    state.album_count = demo.albums.items.len;
    state.album_detail_tracks = demo.album_tracks.items;
    state.album_detail_count = demo.album_tracks.items.len;
    state.artists = demo.artists.items;
    state.artist_count = demo.artists.items.len;
    state.artist_detail_tracks = demo.artist_tracks.items;
    state.artist_detail_count = demo.artist_tracks.items.len;
    for (demo.artists.items) |artist| if (artist.id == state.artist_detail_id) {
        state.artist_detail_name = artist.name;
        break;
    };
    state.genres = demo.genres.items;
    state.genre_count = demo.genres.items.len;
    state.genre_detail_tracks = demo.genre_tracks.items;
    state.genre_detail_count = demo.genre_tracks.items.len;
    for (demo.genres.items) |genre| if (genre.id == state.genre_detail_id) {
        state.genre_detail_name = genre.name;
        break;
    };
    state.playlists = demo.playlists.items;
    state.playlist_count = demo.playlists.items.len;
    state.playlist_detail_tracks = demo.playlist_tracks.items;
    state.playlist_detail_count = demo.playlist_tracks.items.len;
    for (demo.playlists.items) |playlist| if (playlist.id == state.playlist_detail_id) {
        state.playlist_detail_name = playlist.name;
        break;
    };
    state.playing_album_id = if (demo.app.play_queue.context_type == .Album) @as(i64, demo.app.play_queue.context_id) else -1;
    state.settings_music_directory = demo.app.config.getMusicDirectory();
    state.settings_api_key = demo.settings_fields[0].text();
    state.settings_shared_secret = demo.settings_fields[1].text();
    state.settings_session_key = demo.settings_fields[2].text();
    state.settings_lastfm_enabled = state.settings_session_key.len > 0;
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
    demo.app.engine.update();
    pollAuth(demo);
    if (pollScan(demo)) return;
    const state = &demo.state;
    updateCurrentTrack(demo, state);
    updateSpectrum(demo, state);
    state.position = demo.app.engine.getTime();
    state.duration = demo.app.engine.getDuration();
    state.playing = demo.app.engine.isPlaying();
    state.volume = demo.app.engine.getGain();
    state.shuffle = demo.app.engine.isShuffled();
    state.repeat_mode = demo.app.engine.getRepeatMode();
    updateCollections(demo, state);
    updateQueueSnapshot(demo, state);
    updateAlbumPlaying(demo, state);
}

fn onRender(ctx: *anyopaque) void {
    const demo: *Demo = @ptrCast(@alignCast(ctx));
    const display = demo.display orelse return;
    const layout = gui_render.Layout.fromSize(@floatFromInt(display.getWidth()), @floatFromInt(display.getHeight()));
    if (!demo.scrollbar_dragging and demo.state.scroll != demo.scroll_anchor) {
        demo.scroll_offset = @as(f32, @floatFromInt(demo.state.scroll)) * layout.cell_h;
        demo.scroll_anchor = demo.state.scroll;
    }
    demo.commands = .{};
    // The GUI has a persistent transport panel, so the terminal footer would
    // duplicate controls and collide with content in compact windows.
    view.emitContent(&demo.state, &demo.commands, layout.columns, layout.rows + view.footer_rows, demo.library_titles.items);
    const art_bitmap = if (demo.art_bitmap) |*bitmap| bitmap else null;
    gui_render.render(display, &demo.fonts, &demo.icons, &demo.state, art_bitmap, demo.hover_nav, demo.hover_control, demo.pressed_control, demo.hover_cell_y, demo.scroll_offset, demo.commands.slice());
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

fn appendTrackRows(demo: *Demo, out: *std.ArrayList(U.AlbumTrackRow), songs: []const entity.Song, query_allocator: std.mem.Allocator) void {
    const strings = demo.detail_arena.allocator();
    for (songs) |song| {
        const context = demo.app.db.getSongContextWithAllocator(query_allocator, song.id) catch null;
        const artist_source = if (context) |value| value.artist else "Unknown Artist";
        const title = strings.dupe(u8, song.title) catch return;
        const artist = strings.dupe(u8, artist_source) catch return;
        out.append(demo.app.allocator, .{
            .title = title,
            .artist = artist,
            .track = song.track,
            .disc_number = song.disc_number,
            .duration = song.duration,
            .song_id = song.id,
        }) catch return;
    }
}

fn loadAlbumTracks(demo: *Demo, album_id: i64) void {
    beginDetailLoad(demo);
    var query_arena = std.heap.ArenaAllocator.init(demo.app.allocator);
    defer query_arena.deinit();
    const songs = demo.app.db.getSongsByAlbumWithAllocator(query_arena.allocator(), album_id) catch return;
    appendTrackRows(demo, &demo.album_tracks, songs, query_arena.allocator());
}

fn loadArtistTracks(demo: *Demo, artist_id: i64) void {
    beginDetailLoad(demo);
    var query_arena = std.heap.ArenaAllocator.init(demo.app.allocator);
    defer query_arena.deinit();
    const songs = demo.app.db.getSongsByArtistWithAllocator(query_arena.allocator(), artist_id) catch return;
    appendTrackRows(demo, &demo.artist_tracks, songs, query_arena.allocator());
}

fn loadGenreTracks(demo: *Demo, genre_id: i64) void {
    beginDetailLoad(demo);
    var query_arena = std.heap.ArenaAllocator.init(demo.app.allocator);
    defer query_arena.deinit();
    const songs = demo.app.db.getSongsByGenreWithAllocator(query_arena.allocator(), genre_id) catch return;
    appendTrackRows(demo, &demo.genre_tracks, songs, query_arena.allocator());
}

fn loadPlaylistTracks(demo: *Demo, playlist_id: i64) void {
    beginDetailLoad(demo);
    var query_arena = std.heap.ArenaAllocator.init(demo.app.allocator);
    defer query_arena.deinit();
    const songs = demo.app.db.getPlaylistTracksWithAllocator(query_arena.allocator(), playlist_id) catch return;
    appendTrackRows(demo, &demo.playlist_tracks, songs, query_arena.allocator());
}

fn playSongSet(demo: *Demo, tracks: []const U.AlbumTrackRow, context: PlaybackContextType, context_id: i64, start: usize) bool {
    if (tracks.len == 0 or start >= tracks.len) return false;
    var ids = std.ArrayList(i64){ .items = &.{}, .capacity = 0 };
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
        .vol_up => engine.setGain(@min(engine.getGain() + 0.05, 1.0)),
        .vol_down => engine.setGain(@max(engine.getGain() - 0.05, 0.0)),
        .toggle_shuffle => engine.setShuffled(!engine.isShuffled()) catch {},
        .cycle_repeat => engine.cycleRepeatMode(),
        .seek => |value| engine.setProgress(value),
        .play_index => |index| {
            const id = demo.app.lib.songIdAt(index);
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
        .play_playlist_track => |index| _ = demo.app.playPlaylist(demo.state.playlist_detail_id, index),
        .play_playlist => |playlist_id| _ = demo.app.playPlaylist(playlist_id, 0),
        .play_queue_index => |index| _ = demo.app.playQueueIndex(index) catch {},
        .toggle_favorite => if (demo.app.has_current_path) if (demo.app.lib.songIdByPath(demo.app.current_path)) |id| {
            const current = if (demo.app.lib.getSongById(id)) |song| song.favorite != 0 else false;
            demo.app.db.setFavorite(id, @intFromBool(!current)) catch {};
            demo.app.lib.setFavorite(id, !current);
        },
    }
}

fn enqueueSong(demo: *Demo, song_id: i64, next: bool) void {
    if (song_id < std.math.minInt(i32) or song_id > std.math.maxInt(i32)) return;
    if (next) demo.app.play_queue.enqueueNext(@intCast(song_id)) catch {} else demo.app.play_queue.enqueue(@intCast(song_id)) catch {};
}

fn enqueueTracks(demo: *Demo, tracks: []const U.AlbumTrackRow, next: bool) void {
    if (tracks.len == 0) return;
    if (next) {
        enqueueSong(demo, tracks[0].song_id, true);
        return;
    }
    var ids = std.ArrayList(i32){ .items = &.{}, .capacity = 0 };
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
    const index = demo.settings_active_field orelse return;
    if (demo.settings_fields[index].insertCodepoint(codepoint)) saveSettingsField(demo, index);
}

fn onKeyDown(ctx: *anyopaque, key: al.KeyCode) void {
    const demo: *Demo = @ptrCast(@alignCast(ctx));
    if (key == .Q and demo.settings_active_field == null) {
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
    if (demo.state.scanning) {
        if (key == .Escape) demo.scan.cancelScan();
        return;
    }
    if (demo.state.screen == .settings and key == .L) {
        beginSettingsField(demo, 0);
        return;
    }
    if (demo.state.screen == .settings and key == .R) {
        demo.scan.start(false) catch |err| std.log.err("could not start library scan: {}", .{err});
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
            .library => if (demo.state.selection < demo.app.lib.count()) enqueueSong(demo, demo.app.lib.songIdAt(demo.state.selection), next),
            .albums => if (demo.state.selection < demo.albums.items.len) {
                loadAlbumTracks(demo, demo.albums.items[demo.state.selection].id);
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
        const visible = guiVisible(gui_render.Layout.fromSize(@floatFromInt(display.getWidth()), @floatFromInt(display.getHeight())).rows);
        execute(demo, U.apply(&demo.state, action, visible));
    }
}

fn guiVisible(rows: u16) usize {
    // emitContent omits the terminal footer, so reclaim those rows for GUI
    // content while retaining the shared view's header-aware calculation.
    return view.libraryVisible(rows + view.footer_rows);
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

fn onMouseMotion(ctx: *anyopaque, x: f32, y: f32) void {
    const demo: *Demo = @ptrCast(@alignCast(ctx));
    const display = demo.display orelse return;
    const layout = gui_render.Layout.fromSize(@floatFromInt(display.getWidth()), @floatFromInt(display.getHeight()));
    if (demo.seek_dragging) {
        const left = layout.player.x + 22;
        const width = @max(1.0, layout.player.w - 44);
        const fraction = @max(0.0, @min(1.0, (x - left) / width));
        if (demo.state.duration > 0) demo.app.engine.setProgress(fraction * demo.state.duration);
    }
    if (demo.scrollbar_dragging) {
        if (gui_render.scrollbarGeometry(layout, &demo.state, demo.scroll_offset)) |geometry| if (geometry.thumb) |thumb| {
            const travel = @max(1.0, geometry.track.h - thumb.h);
            const thumb_top = @max(geometry.track.y, @min(y - demo.scrollbar_drag_offset, geometry.track.bottom() - thumb.h));
            const fraction = (thumb_top - geometry.track.y) / travel;
            const visible = guiVisible(layout.rows);
            const count = selectableCount(&demo.state);
            const max_offset = @as(f32, @floatFromInt(count - visible)) * layout.cell_h;
            demo.scroll_offset = fraction * max_offset;
            demo.state.scroll = @intFromFloat(demo.scroll_offset / layout.cell_h);
            demo.scroll_anchor = demo.state.scroll;
        };
    }
    demo.hover_nav = layout.navScreen(x, y);
    demo.hover_control = switch (gui_input.hitTransport(layout.player, x, y)) {
        .control => |control| control,
        else => null,
    };
    demo.hover_cell_y = if (layout.pointToCell(x, y)) |cell| cell.y else null;
}

fn onMouseWheel(ctx: *anyopaque, x: f32, y: f32, dz: i32) void {
    const demo: *Demo = @ptrCast(@alignCast(ctx));
    const display = demo.display orelse return;
    const layout = gui_render.Layout.fromSize(@floatFromInt(display.getWidth()), @floatFromInt(display.getHeight()));
    if (layout.player.contains(x, y) or layout.pointToCell(x, y) == null) return;
    const visible = guiVisible(layout.rows);
    const count = selectableCount(&demo.state);
    if (count <= visible or visible == 0) return;
    const max_offset = @as(f32, @floatFromInt(count - visible)) * layout.cell_h;
    demo.scroll_offset = @max(0, @min(max_offset, demo.scroll_offset + (if (dz > 0) -layout.cell_h else layout.cell_h)));
    demo.state.scroll = @intFromFloat(demo.scroll_offset / layout.cell_h);
    demo.scroll_anchor = demo.state.scroll;
}

fn onMouseButton(ctx: *anyopaque, button: i32, pressed: bool, x: f32, y: f32) void {
    if (button != 1) return;
    const demo: *Demo = @ptrCast(@alignCast(ctx));
    if (!pressed) {
        demo.scrollbar_dragging = false;
        demo.seek_dragging = false;
        demo.pressed_control = null;
        return;
    }
    const display = demo.display orelse return;
    const layout = gui_render.Layout.fromSize(@floatFromInt(display.getWidth()), @floatFromInt(display.getHeight()));
    if (layout.navScreen(x, y)) |screen| {
        demo.state.screen = screen;
        demo.state.selection = 0;
        demo.state.scroll = 0;
        demo.scroll_offset = 0;
        demo.scroll_anchor = 0;
        return;
    }
    if (selectableCount(&demo.state) > guiVisible(layout.rows)) {
        if (gui_render.scrollbarGeometry(layout, &demo.state, demo.scroll_offset)) |geometry| {
            switch (gui_input.hitScrollbar(geometry.track, geometry.thumb, x, y)) {
                .thumb => {
                    demo.scrollbar_dragging = true;
                    demo.scrollbar_drag_offset = if (geometry.thumb) |thumb| y - thumb.y else 0;
                    return;
                },
                .page_up, .page_down => {
                    const direction: f32 = if (gui_input.hitScrollbar(geometry.track, geometry.thumb, x, y) == .page_up) -1 else 1;
                    demo.scroll_offset += direction * @as(f32, @floatFromInt(guiVisible(layout.rows))) * layout.cell_h;
                    const visible = guiVisible(layout.rows);
                    const count = selectableCount(&demo.state);
                    const max_offset = @as(f32, @floatFromInt(count - visible)) * layout.cell_h;
                    demo.scroll_offset = @max(0, @min(max_offset, demo.scroll_offset));
                    demo.state.scroll = @intFromFloat(demo.scroll_offset / layout.cell_h);
                    demo.scroll_anchor = demo.state.scroll;
                    return;
                },
                .none => {},
            }
        }
    }
    switch (gui_input.hitTransport(layout.player, x, y)) {
        .seek => |fraction| {
            demo.seek_dragging = true;
            if (demo.state.duration > 0) demo.app.engine.setProgress(fraction * demo.state.duration);
            return;
        },
        .control => |control| {
            demo.pressed_control = control;
            const action: U.Action = switch (control) {
                .previous => .prev,
                .toggle_pause => .toggle_pause,
                .next => .next,
            };
            const visible = guiVisible(layout.rows);
            execute(demo, U.apply(&demo.state, action, visible));
            return;
        },
        .none, .row => {},
    }
    const cell = layout.pointToCell(x, y) orelse return;
    if (demo.state.screen == .settings) {
        const field = switch (cell.y) {
            10, 11 => @as(?usize, 0),
            13, 14 => @as(?usize, 1),
            16, 17 => @as(?usize, 2),
            else => null,
        };
        if (field) |index| {
            beginSettingsField(demo, index);
            const left = layout.cellRect(2, 0, 1, 1).x + 12;
            const width = @max(1.0, layout.content.right() - left - 16);
            demo.settings_fields[index].setCursorFraction((x - left) / width);
            return;
        }
    }
    const hit = gui_input.hitTest(layout.columns, layout.rows + view.footer_rows, cell.x, cell.y);
    switch (hit) {
        .seek => |fraction| {
            if (demo.state.duration > 0) demo.app.engine.setProgress(fraction * demo.state.duration);
            return;
        },
        .row => |visible_index| {
            const index = demo.state.scroll + visible_index;
            const count = switch (demo.state.screen) {
                .library => demo.state.row_count,
                .albums => demo.state.album_count,
                .album_detail => demo.state.album_detail_count,
                .artists => demo.state.artist_count,
                .artist_detail => demo.state.artist_detail_count,
                .genres => demo.state.genre_count,
                .genre_detail => demo.state.genre_detail_count,
                .playlists => demo.state.playlist_count,
                .playlist_detail => demo.state.playlist_detail_count,
                .queue => demo.state.queue_count,
                else => 0,
            };
            if (index < count) {
                const activate = demo.state.selection == index;
                demo.state.selection = index;
                if (activate) {
                    const visible = guiVisible(layout.rows);
                    execute(demo, U.apply(&demo.state, .enter, visible));
                }
            }
        },
        .none, .control => {},
    }
}

fn shouldQuit(ctx: *anyopaque) bool {
    return @as(*Demo, @ptrCast(@alignCast(ctx))).quit;
}

fn onInitDisplay(ctx: *anyopaque, display: *al.Display) void {
    @as(*Demo, @ptrCast(@alignCast(ctx))).display = display;
}

fn onAudioStreamFinished(ctx: *anyopaque) void {
    const demo: *Demo = @ptrCast(@alignCast(ctx));
    demo.app.engine.handleAudioStreamFinished() catch |e| std.log.err("auto-advance failed: {}", .{e});
}

fn onDisplayClose(_: *anyopaque) bool {
    return true;
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var app = try app_mod.App.createDeferred(allocator, null, null);
    defer app.destroy();

    var queue = try al.EventQueue.create();
    defer {
        app.engine.event_queue = null;
        queue.destroy();
    }
    app.engine.event_queue = &queue;

    app.engine.setGain(@as(f32, @floatFromInt(app.config.getVolumePercent())) / 100.0);

    var demo = Demo{
        .app = app,
        .scan = .{ .app = app, .allocator = allocator },
        .auth = .{ .allocator = allocator },
        .fonts = gui_fonts.FontSet.load(allocator),
        .icons = gui_icons.Icons.load(allocator),
        .detail_arena = std.heap.ArenaAllocator.init(allocator),
        .snapshot_arena = std.heap.ArenaAllocator.init(allocator),
        .queue_arena = std.heap.ArenaAllocator.init(allocator),
        .current_arena = std.heap.ArenaAllocator.init(allocator),
        .analyzer = spectrum.Analyzer.init(spectrum.default_sample_rate, .a_weight),
    };
    defer demo.scan.deinit();
    defer demo.auth.deinit();
    defer if (demo.auth_token.len > 0) allocator.free(demo.auth_token);
    defer if (demo.auth_url.len > 0) allocator.free(demo.auth_url);
    defer if (demo.art_bitmap) |*bitmap| bitmap.destroy();
    defer demo.fonts.deinit();
    defer demo.icons.deinit();
    defer demo.detail_arena.deinit();
    defer demo.snapshot_arena.deinit();
    defer demo.queue_arena.deinit();
    defer demo.current_arena.deinit();
    defer demo.library_titles.deinit(allocator);
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
        .tick_interval_secs = 1.0 / 30.0,
    }, .{
        .ctx = &demo,
        .on_tick = onTick,
        .on_render = onRender,
        .on_init_display = onInitDisplay,
        .on_audio_stream_finished = onAudioStreamFinished,
        .on_display_close = onDisplayClose,
        .on_key_down = onKeyDown,
        .on_key_char = onKeyChar,
        .on_mouse_motion = onMouseMotion,
        .on_mouse_wheel = onMouseWheel,
        .on_mouse_button = onMouseButton,
        .should_quit = shouldQuit,
    });
}
