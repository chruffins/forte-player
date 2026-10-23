//! TUI frontend wired onto the shared UI pipeline:
//!   App(engine/library) -> State snapshot -> (keys -> Action -> apply -> Cmd -> engine)
//!                                              -> view.emit -> CmdList -> render
//!
//! Shared startup (config, DB+library scan, engine+queue+hooks) lives in
//! `App`; this file only adds the TUI-specific bits (Discord presence, album
//! cover resolution, the terminal render loop). The `ui/ui_*.zig` core is pure;
//! this is the thin, partially-impure glue.

const std = @import("std");
const al = @import("allegro");
const app_mod = @import("app.zig");
const lyrics_mod = @import("music/lyrics.zig");
const config_mod = @import("core/config.zig");
const cover_resolver = @import("integrations/cover_resolver.zig");
const cover_art = @import("ui/cover_art.zig");
const discord_rpc = @import("integrations/discord_rpc.zig");
const lastfm = @import("integrations/lastfm.zig");
const spectrum = @import("dsp/spectrum.zig");
const db_mod = @import("music/database.zig");
const scanner = @import("music/scanner.zig");
const taglib_meta = @import("music/taglib_meta.zig");
const gui_jobs = @import("ui/gui_jobs.zig");
const metadata_edit = @import("music/metadata_edit.zig");
const PlaybackContextType = @import("music/play_queue.zig").PlaybackContextType;
const player_control = @import("integrations/player_control.zig");

const U = @import("ui/ui_state.zig");
const view = @import("ui/ui_view.zig");
const render = @import("ui/tui_render.zig");
const theme = @import("ui/theme.zig");

/// Drawing is paced by an Allegro timer rather than a fixed sleep: the timer
/// ticks every `timer_interval_secs`, and we only render once the event queue
/// is drained. That gives consistent ~20 FPS for the spectrum, and lets a
/// slow frame drop instead of backing up behind the tick rate.
const timer_interval_secs: f64 = 1.0 / 60.0; // 60 ticks/sec for smooth spectrum/rendering
/// How often we wake while idle to poll raw terminal keys. stdin has no
/// Allegro event source headless, so keys are read directly, not from the queue.
const input_poll_secs: f32 = 0.01;

/// TUI-specific per-song extras on top of the shared `App`. `App` owns the
/// library/db/engine/current_path bookkeeping; this hooks Discord presence +
/// cover resolution onto song changes.
const SongContextCache = struct {
    id: i64 = -1,
    artist: []const u8 = "",
    album_artist: []const u8 = "",
    album: []const u8 = "",
    lyrics_id: i64 = -1,
    lyrics: []const lyrics_mod.Line = &.{},
};

const TuiUser = struct {
    app: *app_mod.App,
    song_context: *SongContextCache,
    discord: *discord_rpc.Client,
    resolver: *cover_resolver.CoverResolver,
    scrobbler: ?*lastfm.Scrobbler,
    details_format: config_mod.DetailsFormat,
};

fn onSongChanged(user_ctx: *anyopaque, path: [:0]const u8) void {
    const u: *TuiUser = @ptrCast(@alignCast(user_ctx));
    const app = u.app;
    const id = app.lib.songIdByPath(path) orelse return;

    var title: []const u8 = "";
    var artist: []const u8 = "";
    var album_artist: []const u8 = "";
    var album: []const u8 = "";
    var album_id: i64 = -1;
    if (app.lib.getSongById(id)) |song| {
        title = song.title;
        album_id = song.album_id;
    }
    if (app.db.getSongContext(id) catch null) |cctx| {
        u.song_context.* = .{ .id = id, .artist = cctx.artist, .album_artist = cctx.album_artist, .album = cctx.album };
        artist = cctx.artist;
        album_artist = cctx.album_artist;
        album = cctx.album;
    } else {
        u.song_context.id = -1;
    }

    // Queue a MusicBrainz cover lookup; the resolver worker performs the HTTP request.
    u.resolver.enqueue(album_id, album, album_artist);
    // Record the track start for Last.fm scrobbling (submits once eligible).
    if (u.scrobbler) |s| s.onSongStarted(id, artist, title, album);
    pushPresence(u, title, artist, album, album_id, app.engine.getDuration());
}

/// Render the configured presence details format. `fmt` is a `DetailsFormat`
/// preset; each variant's format string is comptime-known (via `format()`), so
/// std.fmt.bufPrint compiles it as a literal with the `{[song]s}`/`{[artist]s}`/
/// `{[album]s}` named args. On buffer overflow the details are truncated to
/// empty rather than panicking.
fn formatDetails(fmt: config_mod.DetailsFormat, song: []const u8, artist: []const u8, album: []const u8, buf: []u8) []const u8 {
    return switch (fmt) {
        inline else => |preset| preset.format(song, artist, album, buf),
    };
}

/// Push the current song to Discord presence (best-effort).
fn pushPresence(u: *TuiUser, title: []const u8, artist: []const u8, album: []const u8, album_id: i64, duration: f64) void {
    var buf: [512]u8 = undefined;
    const details = formatDetails(u.details_format, title, artist, album, &buf);
    u.discord.setPresence(.{
        .details = details, // e.g. "song - artist" (driven by the details_format config)
        .state = artist, // secondary line, or the status text if status_display_type = 1
        .status_display_type = 2, // 0 = app name, 1 = state, 2 = details
        .duration_secs = duration,
        // Assets mirroring the C++ prototype's ActivityAssets.
        .large_image = u.resolver.coverUrlFor(album_id), // cover/news art
        .large_text = album, // tooltip: album name
        .small_image = "logo", // app badge
        .small_text = "∫orte player",
        .small_url = "https://www.github.com/chruffins",
    });
}

fn runCmd(app: *app_mod.App, cmd: U.Cmd) void {
    const engine = app.engine;
    const lib = app.lib;
    const db = &app.db;
    const current_path = app.current_path;
    switch (cmd) {
        .none => {},
        .toggle_pause => {
            if (engine.isPlaying()) engine.pause() else engine.resumePlayback();
        },
        .toggle_favorite => {
            const id = lib.songIdByPath(current_path) orelse return;
            const cur = if (lib.getSongById(id)) |sg| sg.favorite != 0 else false;
            const nv = !cur;
            db.setFavorite(id, @intFromBool(nv)) catch return;
            lib.setFavorite(id, nv);
            if (id >= std.math.minInt(i32) and id <= std.math.maxInt(i32)) app.play_queue.setShuffleFavorite(@intCast(id), nv);
        },
        .seek => |target| engine.setProgress(target),
        .next => _ = engine.playNext() catch |e| std.log.err("next track failed: {}", .{e}),
        .prev => engine.playPrevious() catch |e| std.log.err("previous track failed: {}", .{e}),
        .vol_up => {
            engine.setGain(@min(engine.getGain() + 0.05, 1.0));
            app.config.setVolumePercent(@intFromFloat(engine.getGain() * 100.0));
            app.saveConfig();
        },
        .vol_down => {
            engine.setGain(@max(engine.getGain() - 0.05, 0.0));
            app.config.setVolumePercent(@intFromFloat(engine.getGain() * 100.0));
            app.saveConfig();
        },
        .toggle_shuffle => engine.setShuffled(!engine.isShuffled()) catch |e| std.log.err("toggle shuffle failed: {}", .{e}),
        .cycle_repeat => engine.cycleRepeatMode(),
        .play_index => |i| {
            const id = lib.songIdAt(i);
            if (id < 0) return;
            // Keep the queue cursor/history synchronized with manual library
            // selection; calling engine.playSound() directly bypassed it.
            _ = app.playSongId(id) catch |e| std.log.err("play selected song failed: {}", .{e});
        },
        // Album-detail commands are pre-handled in the main key loop (they need
        // the album track list + state), so they are no-ops here to keep the
        // switch exhaustive.
        .open_album_detail, .play_track_in_album, .play_artist, .play_genre, .open_artist_detail, .play_artist_track, .open_genre_detail, .play_genre_track, .open_playlist_detail, .play_playlist_track, .play_playlist, .play_queue_index => {},
    }
}

/// Keep the UI's transient snapshot in sync with the engine + library.
fn fillState(st: *U.State, app: *app_mod.App, context_cache: *SongContextCache, albums: []const U.AlbumRow, album_tracks: []const U.AlbumTrackRow, artist_tracks: []const U.AlbumTrackRow, genre_tracks: []const U.AlbumTrackRow, playlist_tracks: []const U.AlbumTrackRow, album_sort_label: []const u8) void {
    const engine = app.engine;
    const lib = app.lib;
    const db = &app.db;
    const current_path = app.current_path;
    st.title = if (app.has_current_path) current_path else "No track";
    st.artist = "";
    st.album = "";
    st.favorite = false;
    st.playing_index = null;
    st.playing_album_id = -1;
    st.album_detail_playing = null;
    if (app.has_current_path) {
        if (lib.songIdByPath(current_path)) |id| {
            if (lib.getSongById(id)) |song| {
                st.title = song.title;
                st.favorite = song.favorite != 0;
                st.playing_album_id = song.album_id;
            }
            if (context_cache.id == id) {
                st.artist = context_cache.artist;
                st.album = context_cache.album;
            } else if (db.getSongContext(id) catch null) |ctx| {
                context_cache.id = id;
                context_cache.artist = ctx.artist;
                context_cache.album_artist = ctx.album_artist;
                context_cache.album = ctx.album;
                st.artist = ctx.artist;
                st.album = ctx.album;
            }
            st.playing_index = lib.indexOfId(id);
            // Which track of the open album is playing (if it's this album).
            if (st.album_detail_id >= 0) {
                for (album_tracks, 0..) |t, idx| {
                    if (t.song_id == id) {
                        st.album_detail_playing = idx;
                        break;
                    }
                }
            }
        }
    }
    st.path = if (app.has_current_path) current_path else "";
    st.position = engine.getTime();
    st.duration = engine.getDuration();
    st.playing = engine.isPlaying();
    st.volume = engine.getGain();
    st.shuffle = engine.isShuffled();
    st.repeat_mode = engine.getRepeatMode();
    st.row_count = lib.count();
    st.albums = albums;
    st.album_count = albums.len;
    st.album_sort_label = album_sort_label;
    st.album_detail_tracks = album_tracks;
    st.album_detail_count = album_tracks.len;
    st.artist_detail_tracks = artist_tracks;
    st.artist_detail_count = artist_tracks.len;
    st.genre_detail_tracks = genre_tracks;
    st.genre_detail_count = genre_tracks.len;
    st.playlist_detail_tracks = playlist_tracks;
    st.playlist_detail_count = playlist_tracks.len;
    st.queue_current_index = if (app.play_queue.size() > 0) app.play_queue.currentIndex() else null;
    st.queue_context_label = switch (app.play_queue.context_type) {
        .Album => "Album queue",
        .Playlist => "Playlist queue",
        .Artist => "Artist queue",
        .Genre => "Genre queue",
        .Individual => "Queue",
    };
}

/// Reload the album browser rows from the DB under `sort`.
fn rebuildTitles(app: *app_mod.App, out: *std.ArrayList([]const u8), arena: *std.heap.ArenaAllocator) void {
    out.clearRetainingCapacity();
    _ = arena.reset(.retain_capacity);
    var query_arena = std.heap.ArenaAllocator.init(app.allocator);
    defer query_arena.deinit();
    const displays = app.db.getAllSongDisplaysWithAllocator(query_arena.allocator()) catch return;
    for (displays) |d| {
        const title = std.fmt.allocPrint(arena.allocator(), "{s}  —  {s}  [{s}]", .{ d.title, d.artist, d.album }) catch break;
        out.append(app.allocator, title) catch break;
    }
}

fn startsWithLetter(item: []const u8, letter: u8) bool {
    var start: usize = 0;
    while (start < item.len and switch (item[start]) {
        ' ', '\t', '"', '\'', '(', '[', '{' => true,
        else => false,
    }) : (start += 1) {}
    return start < item.len and std.ascii.toLower(item[start]) == std.ascii.toLower(letter);
}

fn firstLetterIndex(items: []const []const u8, letter: u8) ?usize {
    for (items, 0..) |item, index| {
        if (startsWithLetter(item, letter)) return index;
    }
    return null;
}

test "TUI letter jump ignores leading punctuation and case" {
    const items = [_][]const u8{ "  #intro", "'Alpha", "beta" };
    try std.testing.expectEqual(@as(?usize, 1), firstLetterIndex(&items, 'a'));
    try std.testing.expectEqual(@as(?usize, 2), firstLetterIndex(&items, 'B'));
    try std.testing.expect(firstLetterIndex(&items, 'z') == null);
}

fn jumpToLetter(
    st: *U.State,
    letter: u8,
    library_titles: []const []const u8,
    albums: []const U.AlbumRow,
    artists: []const U.ArtistRow,
    genres: []const U.GenreRow,
    playlists: []const U.PlaylistRow,
    queue: []const U.QueueRow,
) bool {
    const index = switch (st.screen) {
        .library => firstLetterIndex(library_titles, letter),
        .albums => blk: {
            for (albums, 0..) |row, i| {
                if (startsWithLetter(row.title, letter)) break :blk i;
            }
            break :blk null;
        },
        .artists => blk: {
            for (artists, 0..) |row, i| {
                if (startsWithLetter(row.name, letter)) break :blk i;
            }
            break :blk null;
        },
        .genres => blk: {
            for (genres, 0..) |row, i| {
                if (startsWithLetter(row.name, letter)) break :blk i;
            }
            break :blk null;
        },
        .playlists => blk: {
            for (playlists, 0..) |row, i| {
                if (startsWithLetter(row.name, letter)) break :blk i;
            }
            break :blk null;
        },
        .queue => blk: {
            for (queue, 0..) |row, i| {
                if (startsWithLetter(row.title, letter)) break :blk i;
            }
            break :blk null;
        },
        else => null,
    };
    if (index) |i| {
        st.selection = i;
        st.scroll = i;
        return true;
    }
    return false;
}

fn rebuildLibraryView(all_titles: []const []const u8, out_titles: *std.ArrayList([]const u8), out_indices: *std.ArrayList(usize), allocator: std.mem.Allocator, filter: []const u8) void {
    out_titles.clearRetainingCapacity();
    out_indices.clearRetainingCapacity();
    for (all_titles, 0..) |title, index| {
        if (filter.len > 0 and std.ascii.findIgnoreCase(title, filter) == null) continue;
        out_titles.append(allocator, title) catch break;
        out_indices.append(allocator, index) catch break;
    }
}

fn clearAlbumRows(rows: *std.ArrayList(U.AlbumRow), allocator: std.mem.Allocator) void {
    for (rows.items) |row| {
        allocator.free(row.title);
        allocator.free(row.artist);
    }
    rows.clearRetainingCapacity();
}

fn clearPlaylistRows(rows: *std.ArrayList(U.PlaylistRow), allocator: std.mem.Allocator) void {
    for (rows.items) |row| {
        allocator.free(row.name);
        allocator.free(row.description);
    }
    rows.clearRetainingCapacity();
}

fn clearArtistRows(rows: *std.ArrayList(U.ArtistRow), allocator: std.mem.Allocator) void {
    for (rows.items) |row| allocator.free(row.name);
    rows.clearRetainingCapacity();
}

fn clearGenreRows(rows: *std.ArrayList(U.GenreRow), allocator: std.mem.Allocator) void {
    for (rows.items) |row| allocator.free(row.name);
    rows.clearRetainingCapacity();
}

fn rebuildArtistRows(app: *app_mod.App, rows: *std.ArrayList(U.ArtistRow), allocator: std.mem.Allocator, filter: []const u8) void {
    clearArtistRows(rows, allocator);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const all = app.db.getArtistsWithAllocator(arena.allocator()) catch return;
    for (all) |a| {
        if (filter.len > 0 and std.ascii.findIgnoreCase(a.name, filter) == null) continue;
        const name = allocator.dupe(u8, a.name) catch break;
        rows.append(allocator, .{ .id = a.id, .name = name, .song_count = a.song_count, .album_count = a.album_count }) catch {
            allocator.free(name);
            break;
        };
    }
}

fn rebuildGenreRows(app: *app_mod.App, rows: *std.ArrayList(U.GenreRow), allocator: std.mem.Allocator, filter: []const u8) void {
    clearGenreRows(rows, allocator);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const all = app.db.getGenresWithAllocator(arena.allocator()) catch return;
    for (all) |g| {
        if (filter.len > 0 and std.ascii.findIgnoreCase(g.name, filter) == null) continue;
        const name = allocator.dupe(u8, g.name) catch break;
        rows.append(allocator, .{ .id = g.id, .name = name, .song_count = g.song_count }) catch {
            allocator.free(name);
            break;
        };
    }
}

fn filterAlbumRows(source: []const U.AlbumRow, rows: *std.ArrayList(U.AlbumRow), allocator: std.mem.Allocator, filter: []const u8) void {
    clearAlbumRows(rows, allocator);
    for (source) |a| {
        if (filter.len > 0 and std.ascii.findIgnoreCase(a.title, filter) == null and std.ascii.findIgnoreCase(a.artist, filter) == null) continue;
        const title = allocator.dupe(u8, a.title) catch break;
        const artist = allocator.dupe(u8, a.artist) catch {
            allocator.free(title);
            break;
        };
        rows.append(allocator, .{ .id = a.id, .title = title, .artist = artist, .year = a.year, .track_count = a.track_count, .has_cover = a.has_cover }) catch {
            allocator.free(title);
            allocator.free(artist);
            break;
        };
    }
}

fn filterArtistRows(source: []const U.ArtistRow, rows: *std.ArrayList(U.ArtistRow), allocator: std.mem.Allocator, filter: []const u8) void {
    clearArtistRows(rows, allocator);
    for (source) |a| {
        if (filter.len > 0 and std.ascii.findIgnoreCase(a.name, filter) == null) continue;
        const name = allocator.dupe(u8, a.name) catch break;
        rows.append(allocator, .{ .id = a.id, .name = name, .song_count = a.song_count, .album_count = a.album_count }) catch {
            allocator.free(name);
            break;
        };
    }
}

fn filterGenreRows(source: []const U.GenreRow, rows: *std.ArrayList(U.GenreRow), allocator: std.mem.Allocator, filter: []const u8) void {
    clearGenreRows(rows, allocator);
    for (source) |g| {
        if (filter.len > 0 and std.ascii.findIgnoreCase(g.name, filter) == null) continue;
        const name = allocator.dupe(u8, g.name) catch break;
        rows.append(allocator, .{ .id = g.id, .name = name, .song_count = g.song_count }) catch {
            allocator.free(name);
            break;
        };
    }
}

fn rebuildPlaylistRows(app: *app_mod.App, rows: *std.ArrayList(U.PlaylistRow), allocator: std.mem.Allocator) void {
    clearPlaylistRows(rows, allocator);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const playlists = app.db.getPlaylistsWithAllocator(arena.allocator()) catch return;
    for (playlists) |p| {
        const name = allocator.dupe(u8, p.name) catch break;
        const description = allocator.dupe(u8, p.description) catch {
            allocator.free(name);
            break;
        };
        rows.append(allocator, .{ .id = p.id, .name = name, .description = description, .song_count = p.song_count, .is_smart = p.is_smart }) catch {
            allocator.free(name);
            allocator.free(description);
            break;
        };
    }
}

fn clearAlbumTracks(rows: *std.ArrayList(U.AlbumTrackRow), allocator: std.mem.Allocator) void {
    for (rows.items) |row| {
        allocator.free(row.title);
        allocator.free(row.artist);
    }
    rows.clearRetainingCapacity();
}

fn rebuildAlbumRows(app: *app_mod.App, rows: *std.ArrayList(U.AlbumRow), allocator: std.mem.Allocator, sort: db_mod.Database.AlbumSort, filter: []const u8) void {
    clearAlbumRows(rows, allocator);
    var query_arena = std.heap.ArenaAllocator.init(allocator);
    defer query_arena.deinit();
    const albums = app.db.getAlbumsWithAllocator(query_arena.allocator(), sort) catch return;
    for (albums) |a| {
        if (filter.len > 0 and std.ascii.findIgnoreCase(a.name, filter) == null and std.ascii.findIgnoreCase(a.artist, filter) == null) continue;
        const title = allocator.dupe(u8, a.name) catch break;
        const artist = allocator.dupe(u8, a.artist) catch {
            allocator.free(title);
            break;
        };
        rows.append(allocator, .{
            .id = a.id,
            .title = title,
            .artist = artist,
            .year = a.year,
            .track_count = a.track_count,
            .has_cover = a.has_cover,
        }) catch {
            allocator.free(title);
            allocator.free(artist);
            break;
        };
    }
}

/// Load a chosen album's tracks into the detail list.
fn clearQueueRows(rows: *std.ArrayList(U.QueueRow), allocator: std.mem.Allocator) void {
    for (rows.items) |row| allocator.free(row.artist);
    rows.clearRetainingCapacity();
}

fn rebuildQueueRows(app: *app_mod.App, out: *std.ArrayList(U.QueueRow), allocator: std.mem.Allocator, arena: std.mem.Allocator) void {
    clearQueueRows(out, allocator);
    for (app.play_queue.items()) |raw_id| {
        const id: i64 = raw_id;
        // Keep one row per queue entry, even if a stale id remains after a
        // library change. Dropping rows makes displayed indices disagree with
        // the actual queue and causes remove/move/play to target the wrong item.
        const song = app.lib.getSongById(id);
        const title = if (song) |s| s.title else "[missing song]";
        const artist = if (song != null) (if (app.db.getSongContextWithAllocator(arena, id) catch null) |ctx|
            allocator.dupe(u8, ctx.artist) catch break
        else
            allocator.dupe(u8, "") catch break) else allocator.dupe(u8, "") catch break;
        out.append(allocator, .{ .song_id = id, .title = title, .artist = artist }) catch {
            allocator.free(artist);
            break;
        };
    }
}

fn loadAlbumTracks(app: *app_mod.App, out: *std.ArrayList(U.AlbumTrackRow), allocator: std.mem.Allocator, album_id: i64) void {
    clearAlbumTracks(out, allocator);
    var query_arena = std.heap.ArenaAllocator.init(allocator);
    defer query_arena.deinit();
    const listings = app.db.getTrackListingsByAlbumWithAllocator(query_arena.allocator(), album_id) catch return;
    appendTrackRows(out, allocator, listings);
}

fn loadArtistTracks(app: *app_mod.App, out: *std.ArrayList(U.AlbumTrackRow), allocator: std.mem.Allocator, artist_id: i64) void {
    clearAlbumTracks(out, allocator);
    var query_arena = std.heap.ArenaAllocator.init(allocator);
    defer query_arena.deinit();
    const listings = app.db.getTrackListingsByArtistWithAllocator(query_arena.allocator(), artist_id) catch return;
    appendTrackRows(out, allocator, listings);
}

fn loadGenreTracks(app: *app_mod.App, out: *std.ArrayList(U.AlbumTrackRow), allocator: std.mem.Allocator, genre_id: i64) void {
    clearAlbumTracks(out, allocator);
    var query_arena = std.heap.ArenaAllocator.init(allocator);
    defer query_arena.deinit();
    const listings = app.db.getTrackListingsByGenreWithAllocator(query_arena.allocator(), genre_id) catch return;
    appendTrackRows(out, allocator, listings);
}

fn loadPlaylistTracks(app: *app_mod.App, out: *std.ArrayList(U.AlbumTrackRow), allocator: std.mem.Allocator, playlist_id: i64) void {
    clearAlbumTracks(out, allocator);
    var query_arena = std.heap.ArenaAllocator.init(allocator);
    defer query_arena.deinit();
    const listings = if (app.db.isSmartPlaylist(playlist_id))
        app.db.getTrackListingsBySmartPlaylistWithAllocator(query_arena.allocator(), playlist_id) catch return
    else
        app.db.getTrackListingsByPlaylistWithAllocator(query_arena.allocator(), playlist_id) catch return;
    appendTrackRows(out, allocator, listings);
}

fn appendTrackRows(out: *std.ArrayList(U.AlbumTrackRow), allocator: std.mem.Allocator, listings: []const db_mod.Database.TrackListing) void {
    for (listings) |listing| {
        const title = allocator.dupe(u8, listing.title) catch break;
        const artist = allocator.dupe(u8, if (listing.artist.len > 0) listing.artist else "Unknown Artist") catch {
            allocator.free(title);
            break;
        };
        out.append(allocator, .{ .title = title, .artist = artist, .track = listing.track, .disc_number = listing.disc_number, .duration = listing.duration, .song_id = listing.id }) catch {
            allocator.free(title);
            allocator.free(artist);
            break;
        };
    }
}

fn playSongSet(app: *app_mod.App, ids: []const i64, context_type: PlaybackContextType, context_id: i64, start_index: usize) bool {
    return app.playSongIdsInContext(ids, context_type, context_id, start_index) != null;
}

const ContextTrack = struct {
    id: i64,
    title: []const u8,
    artist: []const u8,
    favorite: bool,
};

fn contextTrack(app: *app_mod.App, id: i64, title: []const u8, artist: []const u8) ?ContextTrack {
    const song = app.lib.getSongById(id) orelse return null;
    return .{
        .id = id,
        .title = if (title.len > 0) title else song.title,
        .artist = artist,
        .favorite = song.favorite != 0,
    };
}

fn selectedContextTrack(app: *app_mod.App, state: *const U.State, library_indices: []const usize, album_tracks: []const U.AlbumTrackRow, artist_tracks: []const U.AlbumTrackRow, genre_tracks: []const U.AlbumTrackRow, playlist_tracks: []const U.AlbumTrackRow, queue_rows: []const U.QueueRow) ?ContextTrack {
    switch (state.screen) {
        .now_playing => {
            if (!app.has_current_path) return null;
            const id = app.lib.songIdByPath(app.current_path) orelse return null;
            return contextTrack(app, id, state.title, state.artist);
        },
        .library => {
            if (state.selection >= library_indices.len) return null;
            const id = app.lib.songIdAt(library_indices[state.selection]);
            const song = app.lib.getSongById(id) orelse return null;
            const context = app.db.getSongContext(id) catch null;
            return contextTrack(app, id, song.title, if (context) |value| value.artist else "Unknown Artist");
        },
        .album_detail => if (state.selection < album_tracks.len) {
            const track = album_tracks[state.selection];
            return contextTrack(app, track.song_id, track.title, track.artist);
        } else return null,
        .artist_detail => if (state.selection < artist_tracks.len) {
            const track = artist_tracks[state.selection];
            return contextTrack(app, track.song_id, track.title, track.artist);
        } else return null,
        .genre_detail => if (state.selection < genre_tracks.len) {
            const track = genre_tracks[state.selection];
            return contextTrack(app, track.song_id, track.title, track.artist);
        } else return null,
        .playlist_detail => if (state.selection < playlist_tracks.len) {
            const track = playlist_tracks[state.selection];
            return contextTrack(app, track.song_id, track.title, track.artist);
        } else return null,
        .queue => if (state.selection < queue_rows.len) {
            const track = queue_rows[state.selection];
            return contextTrack(app, track.song_id, track.title, track.artist);
        } else return null,
        else => return null,
    }
}

fn runContextAction(app: *app_mod.App, track_id: i64, selected: usize, metadata_editor: *MetadataEditor) void {
    switch (selected) {
        0 => _ = app.playSongId(track_id) catch |e| std.log.err("play context track failed: {}", .{e}),
        1 => if (!addQueueSong(app, track_id, false)) std.log.err("add context track to queue failed", .{}),
        2 => if (!addQueueSong(app, track_id, true)) std.log.err("play context track next failed", .{}),
        3 => {
            const current = if (app.lib.getSongById(track_id)) |song| song.favorite != 0 else false;
            const next = !current;
            app.db.setFavorite(track_id, @intFromBool(next)) catch |e| {
                std.log.err("toggle context favorite failed: {}", .{e});
                return;
            };
            app.lib.setFavorite(track_id, next);
            if (track_id >= std.math.minInt(i32) and track_id <= std.math.maxInt(i32)) app.play_queue.setShuffleFavorite(@intCast(track_id), next);
        },
        4 => metadata_editor.start(app, track_id),
        else => {},
    }
}

fn addQueueSong(app: *app_mod.App, id: i64, next: bool) bool {
    if (id < std.math.minInt(i32) or id > std.math.maxInt(i32)) return false;
    if (next) {
        app.play_queue.enqueueNext(@intCast(id)) catch return false;
    } else {
        app.play_queue.enqueue(@intCast(id)) catch return false;
    }
    return true;
}

fn addQueueTracks(app: *app_mod.App, tracks: []const U.AlbumTrackRow, next: bool) bool {
    if (tracks.len == 0) return false;
    if (next) return addQueueSong(app, tracks[0].song_id, true);
    var ids = std.ArrayList(i32).empty;
    defer ids.deinit(app.allocator);
    for (tracks) |track| {
        if (track.song_id < std.math.minInt(i32) or track.song_id > std.math.maxInt(i32)) continue;
        ids.append(app.allocator, @intCast(track.song_id)) catch return false;
    }
    app.play_queue.enqueueMany(ids.items) catch return false;
    return ids.items.len > 0;
}

fn playTrackRows(app: *app_mod.App, tracks: []const U.AlbumTrackRow, start_index: usize, context_type: PlaybackContextType, context_id: i64) bool {
    if (start_index >= tracks.len) return false;
    var ids = std.ArrayList(i64).empty;
    defer ids.deinit(app.allocator);
    for (tracks) |track| ids.append(app.allocator, track.song_id) catch return false;
    return playSongSet(app, ids.items, context_type, context_id, start_index);
}

fn playArtist(app: *app_mod.App, artist_id: i64) bool {
    var arena = std.heap.ArenaAllocator.init(app.allocator);
    defer arena.deinit();
    const songs = app.db.getSongsByArtistWithAllocator(arena.allocator(), artist_id) catch return false;
    var ids = std.ArrayList(i64).empty;
    defer ids.deinit(app.allocator);
    for (songs) |s| ids.append(app.allocator, s.id) catch return false;
    return playSongSet(app, ids.items, .Artist, artist_id, 0);
}

fn playGenre(app: *app_mod.App, genre_id: i64) bool {
    var arena = std.heap.ArenaAllocator.init(app.allocator);
    defer arena.deinit();
    const songs = app.db.getSongsByGenreWithAllocator(arena.allocator(), genre_id) catch return false;
    var ids = std.ArrayList(i64).empty;
    defer ids.deinit(app.allocator);
    for (songs) |s| ids.append(app.allocator, s.id) catch return false;
    return playSongSet(app, ids.items, .Genre, genre_id, 0);
}

const AlbumSort = db_mod.Database.AlbumSort;

const SearchEdit = enum { unchanged, changed, finished };
const ArtState = enum { unknown, waiting_resolver, ready, failed };
const ArtTarget = enum { none, now_playing };

const ScanJob = struct {
    allocator: std.mem.Allocator,
    app: *app_mod.App,
    music_directory: []u8 = &.{},
    previous_path: []u8 = &.{},
    thread: ?std.Thread = null,
    cancel: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    status: std.atomic.Value(u8) = std.atomic.Value(u8).init(0), // 0 idle, 1 running, 2 done, 3 failed
    result: scanner.ScanResult = .{},
    scanned: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    imported: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    updated: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    removed: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    fn join(self: *ScanJob) void {
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
    }

    fn reset(self: *ScanJob) void {
        self.join();
        if (self.music_directory.len > 0) self.allocator.free(self.music_directory);
        if (self.previous_path.len > 0) self.allocator.free(self.previous_path);
        self.music_directory = &.{};
        self.previous_path = &.{};
        self.status.store(0, .release);
    }

    fn deinit(self: *ScanJob) void {
        self.reset();
    }

    fn progress(ctx: *anyopaque, result: *const scanner.ScanResult) void {
        const self: *ScanJob = @ptrCast(@alignCast(ctx));
        self.scanned.store(result.scanned, .release);
        self.imported.store(result.imported, .release);
        self.updated.store(result.updated, .release);
        self.removed.store(result.removed, .release);
    }

    fn shouldCancel(ctx: *anyopaque) bool {
        const self: *ScanJob = @ptrCast(@alignCast(ctx));
        return self.cancel.load(.acquire);
    }

    fn worker(self: *ScanJob) void {
        const result = scanner.scanDirectoryWithOptions(
            &self.app.db,
            self.allocator,
            self.music_directory,
            taglib_meta.extractor,
            .{ .ctx = self, .on_progress = progress, .should_cancel = shouldCancel },
        ) catch {
            self.status.store(3, .release);
            return;
        };
        self.result = result;
        self.scanned.store(result.scanned, .release);
        self.imported.store(result.imported, .release);
        self.updated.store(result.updated, .release);
        self.removed.store(result.removed, .release);
        self.status.store(2, .release);
    }

    fn start(self: *ScanJob) !void {
        self.music_directory = try self.allocator.dupe(u8, self.app.config.getMusicDirectory());
        errdefer {
            self.allocator.free(self.music_directory);
            self.music_directory = &.{};
        }
        if (self.app.has_current_path) self.previous_path = try self.allocator.dupe(u8, self.app.current_path);
        errdefer {
            if (self.previous_path.len > 0) self.allocator.free(self.previous_path);
            self.previous_path = &.{};
        }
        self.cancel.store(false, .release);
        self.result = .{};
        self.scanned.store(0, .release);
        self.imported.store(0, .release);
        self.updated.store(0, .release);
        self.removed.store(0, .release);
        self.status.store(1, .release);
        self.thread = std.Thread.spawn(.{}, worker, .{self}) catch |err| {
            self.status.store(0, .release);
            return err;
        };
    }
};

const SearchBuffer = struct {
    storage: [512]u8 = undefined,
    len: usize = 0,
    active: bool = false,
    truncated: bool = false,

    fn slice(self: *const SearchBuffer) []const u8 {
        return self.storage[0..self.len];
    }

    fn begin(self: *SearchBuffer) void {
        self.len = 0;
        self.active = true;
    }

    fn clear(self: *SearchBuffer) void {
        self.len = 0;
        self.active = false;
        self.truncated = false;
    }

    fn backspace(self: *SearchBuffer) void {
        if (self.len == 0) return;
        self.len -= 1;
        while (self.len > 0 and (self.storage[self.len] & 0xc0) == 0x80) self.len -= 1;
        if (self.len == 0) self.truncated = false;
    }

    fn handle(self: *SearchBuffer, key: u8) SearchEdit {
        if (key == 27 or key == '\n' or key == '\r') {
            self.active = false;
            return .finished;
        }
        if (key == 8 or key == 127) {
            if (self.len == 0) return .unchanged;
            self.backspace();
            return .changed;
        }
        if (key >= 32 and key != 127 and self.len < self.storage.len) {
            self.storage[self.len] = key;
            self.len += 1;
            return .changed;
        }
        return .unchanged;
    }
};

const MetadataEditor = struct {
    const field_names = [_][]const u8{ "title", "artist", "album", "genre", "comment", "year", "track", "disc" };
    active: bool = false,
    song_id: i64 = -1,
    index: usize = 0,
    fields: [8]SearchBuffer = .{ SearchBuffer{}, SearchBuffer{}, SearchBuffer{}, SearchBuffer{}, SearchBuffer{}, SearchBuffer{}, SearchBuffer{}, SearchBuffer{} },

    fn start(self: *MetadataEditor, app: *app_mod.App, song_id: i64) void {
        self.* = .{ .active = true, .song_id = song_id };
        const song = app.db.getSongById(song_id) catch null orelse {
            self.active = false;
            return;
        };
        const ctx = app.db.getSongContext(song_id) catch null;
        self.set(0, song.title);
        self.set(1, if (ctx) |c| c.artist else "");
        self.set(2, if (ctx) |c| c.album else "");
        self.set(3, app.db.getSongGenreStringWithAllocator(app.allocator, song_id) catch "");
        self.set(4, song.comment);
        var year: i64 = 0;
        if (song.album_id >= 0) {
            if (app.db.getAlbumById(song.album_id) catch null) |album| {
                year = album.year;
            }
        }
        self.setInt(5, year);
        self.setInt(6, song.track);
        self.setInt(7, song.disc_number);
    }

    fn set(self: *MetadataEditor, index: usize, value: []const u8) void {
        if (index >= self.fields.len) return;
        var n = @min(value.len, self.fields[index].storage.len);
        while (n > 0 and !std.unicode.utf8ValidateSlice(value[0..n])) n -= 1;
        @memcpy(self.fields[index].storage[0..n], value[0..n]);
        self.fields[index].len = n;
        self.fields[index].truncated = n < value.len;
    }

    fn setInt(self: *MetadataEditor, index: usize, value: i64) void {
        var buf: [32]u8 = undefined;
        self.set(index, std.fmt.bufPrint(&buf, "{d}", .{value}) catch "0");
    }

    fn current(self: *const MetadataEditor) []const u8 {
        return self.fields[self.index].slice();
    }
    fn fieldName(self: *const MetadataEditor) []const u8 {
        return field_names[self.index];
    }

    fn advance(self: *MetadataEditor) bool {
        if (self.index + 1 >= self.fields.len) return true;
        self.index += 1;
        return false;
    }

    fn save(self: *const MetadataEditor, app: *app_mod.App) !void {
        for (self.fields) |field| {
            if (field.truncated) return error.MetadataFieldTooLong;
        }
        const parse = struct {
            fn get(s: []const u8) ?u32 {
                return std.fmt.parseInt(u32, std.mem.trim(u8, s, " \t\r\n"), 10) catch null;
            }
        }.get;
        for (self.fields[5..8]) |field| {
            if (field.len > 0 and parse(field.slice()) == null) return error.InvalidNumericMetadata;
        }
        try metadata_edit.editSong(&app.db, app.allocator, self.song_id, .{
            .title = self.fields[0].slice(),
            .artist = self.fields[1].slice(),
            .album = self.fields[2].slice(),
            .genre = self.fields[3].slice(),
            .comment = self.fields[4].slice(),
            .year = parse(self.fields[5].slice()),
            .track = parse(self.fields[6].slice()),
            .disc = parse(self.fields[7].slice()),
        });
    }
};

const SettingsEditor = struct {
    const field_names = [_][]const u8{ "api_key", "shared_secret", "session_key" };
    active: bool = false,
    index: usize = 0,
    fields: [3]SearchBuffer = .{ SearchBuffer{}, SearchBuffer{}, SearchBuffer{} },

    fn start(self: *SettingsEditor, app: *app_mod.App) void {
        self.* = .{ .active = true };
        self.set(0, app.config.getLastFmApiKey());
        self.set(1, app.config.getLastFmSharedSecret());
        self.set(2, app.config.getLastFmSessionKey());
    }

    fn set(self: *SettingsEditor, index: usize, value: []const u8) void {
        const n = @min(value.len, self.fields[index].storage.len);
        @memcpy(self.fields[index].storage[0..n], value[0..n]);
        self.fields[index].len = n;
    }

    fn current(self: *const SettingsEditor) []const u8 {
        return self.fields[self.index].slice();
    }
    fn fieldName(self: *const SettingsEditor) []const u8 {
        return field_names[self.index];
    }

    fn advance(self: *SettingsEditor) bool {
        if (self.index + 1 >= self.fields.len) return true;
        self.index += 1;
        return false;
    }

    fn save(self: *const SettingsEditor, app: *app_mod.App) void {
        const keys = [_][:0]const u8{ "api_key", "shared_secret", "session_key" };
        for (self.fields, 0..) |field, i| {
            var value: [129:0]u8 = undefined;
            const n = @min(field.len, value.len - 1);
            @memcpy(value[0..n], field.slice()[0..n]);
            value[n] = 0;
            app.config.setStr("lastfm", keys[i], value[0..n :0]);
        }
        app.saveConfig();
    }
};

fn nextSort(s: AlbumSort) AlbumSort {
    return switch (s) {
        .by_name => .by_year,
        .by_year => .by_artist,
        .by_artist => .by_name,
    };
}

fn sortLabel(s: AlbumSort) []const u8 {
    return switch (s) {
        .by_name => "name",
        .by_year => "year",
        .by_artist => "artist",
    };
}

pub fn main(process: std.process.Init) !void {
    // Vaxis initializes the platform TTY (POSIX termios or Windows Console)
    // and its asynchronous input loop. Non-interactive launches exit cleanly.
    if (!try render.init(process)) return;
    defer render.deinit();

    const allocator = std.heap.page_allocator;

    var app = try app_mod.App.createTui(allocator, null, null);
    defer app.destroy();
    var control_server = player_control.Server.init();
    defer if (control_server) |*server| server.deinit();
    // Live audio capture for the TUI spectrum (ring fed by the mixer callback).
    app.engine.setSampleBufferCapacity(8192) catch |e| std.log.warn("sample capture resize failed: {}", .{e});

    const cfg_app_id = app.config.getDiscordApplicationId();
    var discord = discord_rpc.Client.init(if (cfg_app_id > 0) cfg_app_id else discord_rpc.default_app_id);
    defer discord.deinit();
    var resolver = cover_resolver.CoverResolver.init(allocator, &app.db) catch |e| {
        std.debug.print("cover resolver init failed: {}\n", .{e});
        return;
    };
    defer resolver.destroy();

    // Last.fm scrobbling (best-effort; disabled unless credentials are set).
    const scrobbler = lastfm.Scrobbler.init(
        allocator,
        app.config.getLastFmApiKey(),
        app.config.getLastFmSharedSecret(),
        app.config.getLastFmSessionKey(),
    );
    defer if (scrobbler) |s| s.destroy();

    var context_cache = SongContextCache{};
    defer {
        for (context_cache.lyrics) |line| allocator.free(line.text);
        if (context_cache.lyrics.len > 0) allocator.free(context_cache.lyrics);
    }
    var tui_user = TuiUser{
        .app = app,
        .song_context = &context_cache,
        .discord = &discord,
        .resolver = resolver,
        .scrobbler = scrobbler,
        .details_format = app.config.getDiscordDetailsFormat(),
    };
    // Wire the TUI-specific per-song work (presence + cover lookup) in.
    app.ctx.user = &tui_user;
    app.ctx.song_changed = onSongChanged;

    if (app.startFirstSong() == null) {
        std.debug.print("no playable songs\n", .{});
        return;
    }
    app.engine.setGain(@as(f32, @floatFromInt(app.config.getVolumePercent())) / 100.0);

    // Library display rows include the track artist and album. This makes
    // featured tracks and compilations understandable without opening detail.
    var title_arena = std.heap.ArenaAllocator.init(allocator);
    defer title_arena.deinit();
    var titles = std.ArrayList([]const u8).empty;
    defer titles.deinit(allocator);
    rebuildTitles(app, &titles, &title_arena);

    var library_search = SearchBuffer{};
    var playlist_editor = SearchBuffer{};
    var playlist_edit_id: i64 = -1;
    var library_view_titles = std.ArrayList([]const u8).empty;
    defer library_view_titles.deinit(allocator);
    var library_view_indices = std.ArrayList(usize).empty;
    defer library_view_indices.deinit(allocator);
    rebuildLibraryView(titles.items, &library_view_titles, &library_view_indices, allocator, "");

    // Album browser rows (parallel to the DB's album listing) + sort state.
    var album_sort: AlbumSort = .by_name;
    var album_search = SearchBuffer{};
    var album_rows = std.ArrayList(U.AlbumRow).empty;
    defer {
        clearAlbumRows(&album_rows, allocator);
        album_rows.deinit(allocator);
    }
    var all_album_rows = std.ArrayList(U.AlbumRow).empty;
    defer {
        clearAlbumRows(&all_album_rows, allocator);
        all_album_rows.deinit(allocator);
    }
    rebuildAlbumRows(app, &all_album_rows, allocator, album_sort, "");
    filterAlbumRows(all_album_rows.items, &album_rows, allocator, "");
    var artist_search = SearchBuffer{};
    var genre_search = SearchBuffer{};
    var artist_rows = std.ArrayList(U.ArtistRow).empty;
    defer {
        clearArtistRows(&artist_rows, allocator);
        artist_rows.deinit(allocator);
    }
    var all_artist_rows = std.ArrayList(U.ArtistRow).empty;
    defer {
        clearArtistRows(&all_artist_rows, allocator);
        all_artist_rows.deinit(allocator);
    }
    var genre_rows = std.ArrayList(U.GenreRow).empty;
    defer {
        clearGenreRows(&genre_rows, allocator);
        genre_rows.deinit(allocator);
    }
    var all_genre_rows = std.ArrayList(U.GenreRow).empty;
    defer {
        clearGenreRows(&all_genre_rows, allocator);
        all_genre_rows.deinit(allocator);
    }
    rebuildArtistRows(app, &all_artist_rows, allocator, "");
    rebuildGenreRows(app, &all_genre_rows, allocator, "");
    filterArtistRows(all_artist_rows.items, &artist_rows, allocator, "");
    filterGenreRows(all_genre_rows.items, &genre_rows, allocator, "");
    var playlist_rows = std.ArrayList(U.PlaylistRow).empty;
    defer {
        clearPlaylistRows(&playlist_rows, allocator);
        playlist_rows.deinit(allocator);
    }
    rebuildPlaylistRows(app, &playlist_rows, allocator);
    var queue_rows = std.ArrayList(U.QueueRow).empty;
    defer {
        clearQueueRows(&queue_rows, allocator);
        queue_rows.deinit(allocator);
    }
    var queue_revision: u64 = std.math.maxInt(u64);
    // Tracks of the album currently open in the detail view.
    var album_tracks = std.ArrayList(U.AlbumTrackRow).empty;
    defer {
        clearAlbumTracks(&album_tracks, allocator);
        album_tracks.deinit(allocator);
    }
    var artist_detail_tracks = std.ArrayList(U.AlbumTrackRow).empty;
    defer {
        clearAlbumTracks(&artist_detail_tracks, allocator);
        artist_detail_tracks.deinit(allocator);
    }
    var genre_detail_tracks = std.ArrayList(U.AlbumTrackRow).empty;
    defer {
        clearAlbumTracks(&genre_detail_tracks, allocator);
        genre_detail_tracks.deinit(allocator);
    }
    var playlist_tracks = std.ArrayList(U.AlbumTrackRow).empty;
    defer {
        clearAlbumTracks(&playlist_tracks, allocator);
        playlist_tracks.deinit(allocator);
    }
    var metadata_editor = MetadataEditor{};
    var settings_editor = SettingsEditor{};
    var auth_ticket: ?lastfm.AuthTicket = null;
    defer if (auth_ticket) |*ticket| ticket.deinit();
    var auth_status: []const u8 = "";

    defer render.restoreRaw();

    // theme: config override or auto-detect (dark vs light terminal)
    const theme_setting = app.config.getStr("ui", "theme", "auto");
    var scheme = theme.Scheme.dark;
    var auto = true;
    if (std.mem.eql(u8, theme_setting, "dark")) {
        scheme = .dark;
        auto = false;
    } else if (std.mem.eql(u8, theme_setting, "light")) {
        scheme = .light;
        auto = false;
    }
    render.setPalette(render.detectScheme(scheme, auto));

    var win = render.size();
    var width: u16 = win.w;
    var height: u16 = win.h;
    var st = U.State{};
    // Transient database query results live only for the current frame.
    var query_arena = std.heap.ArenaAllocator.init(allocator);
    defer query_arena.deinit();
    // Spectrum scratch (persist across frames so the smoother keeps state).
    var sample_buf: [spectrum.n_samples]f32 = undefined;
    var raw_bands: [spectrum.n_bands]f32 = undefined;
    var analyzer = spectrum.Analyzer.init(spectrum.default_sample_rate, .a_weight);
    var smoother = spectrum.Smoother{};
    var last_capture_sequence: u64 = std.math.maxInt(u64);
    var spectrum_ticks: u8 = 0;
    // Album art scratch (persist so we fetch/decode once per album).
    const art_max_w: usize = 32;
    const art_max_h: usize = 17;
    var art_cells: [art_max_w * art_max_h]U.ArtCell = undefined;
    var art_for_album: i64 = -1;
    var art_target: ArtTarget = .none;
    var art_state: ArtState = .unknown;
    var art_w: u16 = 0;
    var art_h: u16 = 0;

    // Pace drawing with an Allegro timer (event-driven, headless-safe).
    var ticker = try al.Timer.create(timer_interval_secs);
    defer ticker.destroy();
    var tqueue = try al.EventQueue.create();
    defer tqueue.destroy();
    tqueue.registerTimer(&ticker);
    ticker.start();
    defer ticker.stop();

    var ev: al.Event = undefined;
    var frame_due = false;
    var auto_advance_handled = false;
    var scan_job = ScanJob{ .allocator = allocator, .app = app };
    var scan_running = false;
    var health_job = gui_jobs.HealthJob{ .allocator = allocator };
    var health_running = false;
    defer {
        if (scan_running) scan_job.cancel.store(true, .release);
        if (health_running) health_job.requestCancel();
        scan_job.deinit();
        health_job.deinit();
    }
    var quitting = false;
    var jump_pending = false;
    while (!quitting) {
        if (control_server) |*server| server.poll(app);
        // Wait for a timer tick, or the poll timeout so we can service stdin.
        if (tqueue.waitForEventTimed(&ev, input_poll_secs)) {
            if (al.eventType(ev) == .timer) frame_due = true;
        }

        // Raw terminal keys: no Allegro event source headless, so poll stdin
        // directly on every wake.
        while (render.pollKey()) |k| {
            // Handle quit before screen-specific key bindings. In particular,
            // queue/playlist handlers may otherwise consume a key and keep the
            // input loop running for another frame.
            if (k == 'q' and !settings_editor.active and !metadata_editor.active and !playlist_editor.active) {
                quitting = true;
                break;
            }
            if (st.help_visible) {
                if (k == '?' or k == 27) st.help_visible = false;
                continue;
            }
            if (scan_running) {
                if (k == 27) scan_job.cancel.store(true, .release);
                continue;
            }
            if (health_running) {
                if (k == 27) health_job.requestCancel();
                continue;
            }
            if (jump_pending) {
                jump_pending = false;
                if (k >= 32 and k < 127) {
                    _ = jumpToLetter(&st, k, library_view_titles.items, album_rows.items, artist_rows.items, genre_rows.items, playlist_rows.items, queue_rows.items);
                }
                continue;
            }
            if (settings_editor.active) {
                if (k == 27) {
                    settings_editor.active = false;
                    continue;
                }
                if (k == 8 or k == 127) {
                    settings_editor.fields[settings_editor.index].backspace();
                    continue;
                }
                if (k == '\n' or k == '\r') {
                    if (settings_editor.advance()) {
                        settings_editor.save(app);
                        settings_editor.active = false;
                    }
                    continue;
                }
                if (k >= 32 and k != 127 and settings_editor.fields[settings_editor.index].len < settings_editor.fields[settings_editor.index].storage.len) {
                    const field = &settings_editor.fields[settings_editor.index];
                    field.storage[field.len] = k;
                    field.len += 1;
                }
                continue;
            }
            if (metadata_editor.active) {
                if (k == 27) {
                    metadata_editor.active = false;
                    continue;
                }
                if (k == '\t' or k == 14) {
                    metadata_editor.index = (metadata_editor.index + 1) % metadata_editor.fields.len;
                    continue;
                }
                if (k == 16) {
                    metadata_editor.index = (metadata_editor.index + metadata_editor.fields.len - 1) % metadata_editor.fields.len;
                    continue;
                }
                if (k == 21) {
                    metadata_editor.fields[metadata_editor.index].clear();
                    continue;
                }
                if (k == 8 or k == 127) {
                    metadata_editor.fields[metadata_editor.index].backspace();
                    continue;
                }
                if (k == '\n' or k == '\r') {
                    if (metadata_editor.advance()) {
                        metadata_editor.save(app) catch |e| {
                            std.log.err("metadata save failed: {}", .{e});
                            continue;
                        };
                        const current_id = if (app.has_current_path) app.lib.songIdByPath(app.current_path) else null;
                        app.has_current_path = false;
                        app.lib.load(&app.db) catch |e| std.log.err("library reload failed: {}", .{e});
                        if (current_id) |id| {
                            if (app.lib.songPath(id)) |p| {
                                app.current_path = p;
                                app.has_current_path = true;
                            }
                        }
                        rebuildAlbumRows(app, &all_album_rows, allocator, album_sort, "");
                        filterAlbumRows(all_album_rows.items, &album_rows, allocator, album_search.slice());
                        rebuildArtistRows(app, &all_artist_rows, allocator, "");
                        filterArtistRows(all_artist_rows.items, &artist_rows, allocator, artist_search.slice());
                        rebuildGenreRows(app, &all_genre_rows, allocator, "");
                        filterGenreRows(all_genre_rows.items, &genre_rows, allocator, genre_search.slice());
                        rebuildPlaylistRows(app, &playlist_rows, allocator);
                        if (st.album_detail_id >= 0) loadAlbumTracks(app, &album_tracks, allocator, st.album_detail_id);
                        if (st.artist_detail_id >= 0) loadArtistTracks(app, &artist_detail_tracks, allocator, st.artist_detail_id);
                        if (st.genre_detail_id >= 0) loadGenreTracks(app, &genre_detail_tracks, allocator, st.genre_detail_id);
                        if (st.playlist_detail_id >= 0) loadPlaylistTracks(app, &playlist_tracks, allocator, st.playlist_detail_id);
                        rebuildTitles(app, &titles, &title_arena);
                        rebuildLibraryView(titles.items, &library_view_titles, &library_view_indices, allocator, library_search.slice());
                        queue_revision = std.math.maxInt(u64);
                        context_cache.id = -1;
                        art_for_album = -1;
                        art_state = .unknown;
                        metadata_editor.active = false;
                    }
                    continue;
                }
                if (k >= 32 and k != 127 and metadata_editor.fields[metadata_editor.index].len < metadata_editor.fields[metadata_editor.index].storage.len) {
                    const field = &metadata_editor.fields[metadata_editor.index];
                    field.storage[field.len] = k;
                    field.len += 1;
                }
                continue;
            }
            if (playlist_editor.active) {
                const edit = playlist_editor.handle(k);
                if (edit == .finished) {
                    if (playlist_editor.len > 0) {
                        if (playlist_edit_id >= 0) {
                            app.db.renamePlaylist(playlist_edit_id, playlist_editor.slice()) catch |e| std.log.err("rename playlist failed: {}", .{e});
                        } else {
                            _ = app.db.createPlaylist(playlist_editor.slice()) catch |e| std.log.err("create playlist failed: {}", .{e});
                        }
                        rebuildPlaylistRows(app, &playlist_rows, allocator);
                    }
                    playlist_edit_id = -1;
                    playlist_editor.clear();
                }
                continue;
            }
            if (st.context_menu_open) {
                if (k == 27 or k == 'v') {
                    st.context_menu_open = false;
                    continue;
                }
                if (k == '?') {
                    st.context_menu_open = false;
                    st.help_visible = true;
                    continue;
                }
                if (k == 'j') st.context_menu_selection = @min(st.context_menu_selection + 1, 4);
                if (k == 'k') st.context_menu_selection -|= 1;
                if ((k == '\n' or k == '\r') and st.context_menu_song_id >= 0) {
                    runContextAction(app, st.context_menu_song_id, st.context_menu_selection, &metadata_editor);
                    st.context_menu_open = false;
                } else if (k >= '1' and k <= '5' and st.context_menu_song_id >= 0) {
                    st.context_menu_selection = @intCast(k - '1');
                    runContextAction(app, st.context_menu_song_id, st.context_menu_selection, &metadata_editor);
                    st.context_menu_open = false;
                }
                continue;
            }
            if (k == 'v') {
                if (selectedContextTrack(app, &st, library_view_indices.items, album_tracks.items, artist_detail_tracks.items, genre_detail_tracks.items, playlist_tracks.items, queue_rows.items)) |track| {
                    st.context_menu_song_id = track.id;
                    st.context_menu_title = track.title;
                    st.context_menu_artist = track.artist;
                    st.context_menu_favorite = track.favorite;
                    _ = U.apply(&st, .toggle_context_menu, 0);
                }
                continue;
            }
            if (k == 'n' and st.screen == .playlists) {
                playlist_edit_id = -1;
                playlist_editor.begin();
                continue;
            }
            if (st.screen == .playlists and (k == 'm' or k == 'M' or k == 'R' or k == 'S')) {
                const template = switch (k) {
                    'm' => .{ "Favorites", db_mod.Database.SmartRule.favorites, "" },
                    'M' => .{ "Most played", db_mod.Database.SmartRule.most_played, "" },
                    'R' => .{ "Recently played", db_mod.Database.SmartRule.recently_played, "" },
                    else => .{ "Short tracks", db_mod.Database.SmartRule.short_tracks, "300" },
                };
                var exists = false;
                for (playlist_rows.items) |row| if (std.mem.eql(u8, row.name, template[0])) {
                    exists = true;
                    break;
                };
                if (!exists) _ = app.db.createSmartPlaylist(template[0], template[1], template[2], 100) catch |e| std.log.err("create smart playlist failed: {}", .{e});
                rebuildPlaylistRows(app, &playlist_rows, allocator);
                continue;
            }
            if (k == 'r' and st.screen == .playlists and st.selection < playlist_rows.items.len) {
                playlist_edit_id = playlist_rows.items[st.selection].id;
                playlist_editor.begin();
                continue;
            }
            if (k == 'a' and (st.screen == .playlists or st.screen == .playlist_detail) and (if (st.screen == .playlist_detail) st.playlist_detail_id >= 0 else st.selection < playlist_rows.items.len)) {
                const playlist_id = if (st.screen == .playlist_detail) st.playlist_detail_id else playlist_rows.items[st.selection].id;
                if (app.has_current_path) if (app.lib.songIdByPath(app.current_path)) |song_id| {
                    app.db.addSongToPlaylist(playlist_id, song_id) catch |e| std.log.err("add song to playlist failed: {}", .{e});
                    if (st.screen == .playlist_detail) loadPlaylistTracks(app, &playlist_tracks, allocator, playlist_id);
                    rebuildPlaylistRows(app, &playlist_rows, allocator);
                };
                continue;
            }
            if (k == 'x' and st.screen == .playlist_detail and st.selection < playlist_tracks.items.len) {
                app.db.removePlaylistTrackAt(st.playlist_detail_id, st.selection) catch |e| std.log.err("remove playlist song failed: {}", .{e});
                loadPlaylistTracks(app, &playlist_tracks, allocator, st.playlist_detail_id);
                st.selection = @min(st.selection, playlist_tracks.items.len -| 1);
                rebuildPlaylistRows(app, &playlist_rows, allocator);
                continue;
            }
            if ((k == '<' or k == '>') and st.screen == .playlist_detail and playlist_tracks.items.len > 1) {
                const from = st.selection;
                const to = if (k == '<') from -| 1 else @min(from + 1, playlist_tracks.items.len - 1);
                if (from != to) {
                    var ids = std.ArrayList(i64).empty;
                    defer ids.deinit(allocator);
                    for (playlist_tracks.items) |t| ids.append(allocator, t.song_id) catch break;
                    if (ids.items.len == playlist_tracks.items.len) {
                        const tmp = ids.items[from];
                        ids.items[from] = ids.items[to];
                        ids.items[to] = tmp;
                        app.db.reorderPlaylist(st.playlist_detail_id, ids.items) catch |e| std.log.err("reorder playlist failed: {}", .{e});
                        loadPlaylistTracks(app, &playlist_tracks, allocator, st.playlist_detail_id);
                        st.selection = to;
                    }
                }
                continue;
            }
            if (k == 'x' and st.screen == .playlists and st.selection < playlist_rows.items.len) {
                const id = playlist_rows.items[st.selection].id;
                app.db.deletePlaylist(id) catch |e| std.log.err("delete playlist failed: {}", .{e});
                rebuildPlaylistRows(app, &playlist_rows, allocator);
                st.selection = @min(st.selection, playlist_rows.items.len -| 1);
                continue;
            }
            if (k == 'x' and st.screen == .queue and st.selection < app.play_queue.size()) {
                const removed = st.selection;
                const removing_current = removed == app.play_queue.currentIndex();
                if (removing_current and app.play_queue.size() > 1) {
                    // Start the replacement while the old queue is intact. If
                    // loading fails, the old cursor and stream remain valid.
                    const replacement = if (removed + 1 < app.play_queue.size()) removed + 1 else removed - 1;
                    if (app.playQueueIndex(replacement)) |_| {
                        app.play_queue.removeAt(removed) catch |e| std.log.err("remove queue item failed: {}", .{e});
                    } else |e| {
                        std.log.err("play replacement queue item failed: {}", .{e});
                        app.play_queue.removeAt(removed) catch |remove_err| std.log.err("remove queue item failed: {}", .{remove_err});
                        app.engine.stop();
                        app.has_current_path = false;
                    }
                } else {
                    app.play_queue.removeAt(removed) catch |e| std.log.err("remove queue item failed: {}", .{e});
                    if (removing_current) {
                        app.engine.stop();
                        app.has_current_path = false;
                    }
                }
                st.selection = @min(removed, app.play_queue.size() -| 1);
                continue;
            }
            if (k == 'C' and st.screen == .queue) {
                app.engine.stop();
                app.play_queue.clear();
                app.has_current_path = false;
                st.selection = 0;
                continue;
            }
            if ((k == '<' or k == '>') and st.screen == .queue and app.play_queue.size() > 1) {
                const target = if (k == '<') st.selection -| 1 else @min(st.selection + 1, app.play_queue.size() - 1);
                app.play_queue.moveAt(st.selection, target) catch |e| std.log.err("move queue item failed: {}", .{e});
                st.selection = target;
                continue;
            }
            if ((k == 'a' or k == 'A') and st.screen == .library and st.selection < library_view_indices.items.len) {
                const id = app.lib.songIdAt(library_view_indices.items[st.selection]);
                if (!addQueueSong(app, id, k == 'A')) std.log.err("failed to add library song to queue", .{});
                continue;
            }
            if ((k == 'a' or k == 'A') and st.screen == .album_detail) {
                if (k == 'A' and st.selection < album_tracks.items.len) {
                    if (!addQueueSong(app, album_tracks.items[st.selection].song_id, true)) std.log.err("failed to queue album track next", .{});
                } else if (!addQueueTracks(app, album_tracks.items, false)) {
                    std.log.err("failed to add album tracks to queue", .{});
                }
                continue;
            }
            if ((k == 'a' or k == 'A') and st.screen == .artist_detail) {
                if (k == 'A' and st.selection < artist_detail_tracks.items.len) {
                    if (!addQueueSong(app, artist_detail_tracks.items[st.selection].song_id, true)) std.log.err("failed to queue artist track next", .{});
                } else if (!addQueueTracks(app, artist_detail_tracks.items, false)) {
                    std.log.err("failed to add artist tracks to queue", .{});
                }
                continue;
            }
            if ((k == 'a' or k == 'A') and st.screen == .genre_detail) {
                if (k == 'A' and st.selection < genre_detail_tracks.items.len) {
                    if (!addQueueSong(app, genre_detail_tracks.items[st.selection].song_id, true)) std.log.err("failed to queue genre track next", .{});
                } else if (!addQueueTracks(app, genre_detail_tracks.items, false)) {
                    std.log.err("failed to add genre tracks to queue", .{});
                }
                continue;
            }
            if (k == 'g' and !album_search.active and !library_search.active and !artist_search.active and !genre_search.active and
                (st.screen == .library or st.screen == .albums or st.screen == .artists or st.screen == .genres or st.screen == .playlists or st.screen == .queue))
            {
                jump_pending = true;
                continue;
            }
            if (album_search.active) {
                const edit = album_search.handle(k);
                if (edit == .changed) {
                    filterAlbumRows(all_album_rows.items, &album_rows, allocator, album_search.slice());
                    st.selection = 0;
                    st.scroll = 0;
                }
                continue;
            }
            if (library_search.active) {
                const edit = library_search.handle(k);
                if (edit == .changed) {
                    rebuildLibraryView(titles.items, &library_view_titles, &library_view_indices, allocator, library_search.slice());
                    st.selection = 0;
                    st.scroll = 0;
                }
                continue;
            }
            if (k == '/' and st.screen == .library) {
                library_search.begin();
                rebuildLibraryView(titles.items, &library_view_titles, &library_view_indices, allocator, "");
                st.selection = 0;
                st.scroll = 0;
                continue;
            }
            if (k == 'c' and st.screen == .library and library_search.len > 0) {
                library_search.clear();
                rebuildLibraryView(titles.items, &library_view_titles, &library_view_indices, allocator, "");
                st.selection = 0;
                st.scroll = 0;
                continue;
            }
            if (k == '/' and st.screen == .albums) {
                album_search.begin();
                filterAlbumRows(all_album_rows.items, &album_rows, allocator, "");
                st.selection = 0;
                st.scroll = 0;
                continue;
            }
            if (k == 'c' and st.screen == .albums and album_search.len > 0) {
                album_search.clear();
                filterAlbumRows(all_album_rows.items, &album_rows, allocator, "");
                st.selection = 0;
                st.scroll = 0;
                continue;
            }
            if (artist_search.active) {
                const edit = artist_search.handle(k);
                if (edit == .changed) {
                    filterArtistRows(all_artist_rows.items, &artist_rows, allocator, artist_search.slice());
                    st.selection = 0;
                    st.scroll = 0;
                }
                continue;
            }
            if (genre_search.active) {
                const edit = genre_search.handle(k);
                if (edit == .changed) {
                    filterGenreRows(all_genre_rows.items, &genre_rows, allocator, genre_search.slice());
                    st.selection = 0;
                    st.scroll = 0;
                }
                continue;
            }
            if (k == '/' and st.screen == .artists) {
                artist_search.begin();
                st.selection = 0;
                st.scroll = 0;
                continue;
            }
            if (k == 'c' and st.screen == .artists and artist_search.len > 0) {
                artist_search.clear();
                filterArtistRows(all_artist_rows.items, &artist_rows, allocator, "");
                st.selection = 0;
                st.scroll = 0;
                continue;
            }
            if (k == '/' and st.screen == .genres) {
                genre_search.begin();
                st.selection = 0;
                st.scroll = 0;
                continue;
            }
            if (k == 'c' and st.screen == .genres and genre_search.len > 0) {
                genre_search.clear();
                filterGenreRows(all_genre_rows.items, &genre_rows, allocator, "");
                st.selection = 0;
                st.scroll = 0;
                continue;
            }
            if (k == 'p' and st.screen == .settings) {
                _ = app.config.nextPlaybackProfile();
                app.engine.setGain(@as(f32, @floatFromInt(app.config.getVolumePercent())) / 100.0);
                app.saveConfig();
                app.refreshNormalization();
                continue;
            }
            if (k == 'n' and st.screen == .settings) {
                app.config.setNormalizationEnabled(!app.config.getNormalizationEnabled());
                app.saveConfig();
                app.refreshNormalization();
                continue;
            }
            if (k == 'm' and st.screen == .settings) {
                app.config.setNormalizationPolicy(if (app.config.getNormalizationPolicy() == .track) .album else .track);
                app.saveConfig();
                app.refreshNormalization();
                continue;
            }
            if (k == 'x' and st.screen == .settings) {
                const current = app.config.getCrossfadeSeconds();
                const next: u8 = switch (current) {
                    0 => 3,
                    3 => 6,
                    6 => 10,
                    else => 0,
                };
                app.config.setCrossfadeSeconds(next);
                app.engine.setCrossfadeSecs(@floatFromInt(next));
                app.saveConfig();
                continue;
            }
            if (k == 'l' and st.screen == .settings) {
                settings_editor.start(app);
                continue;
            }
            if (k == 'o' and st.screen == .settings) {
                if (app.config.getLastFmApiKey().len == 0 or app.config.getLastFmSharedSecret().len == 0) {
                    auth_status = "Set API key and shared secret first (press l).";
                } else if (auth_ticket != null) {
                    auth_status = "Authorization is already waiting; open the URL and press k.";
                } else {
                    auth_status = "Requesting Last.fm authorization...";
                    auth_ticket = lastfm.beginAuth(allocator, app.config.getLastFmApiKey(), app.config.getLastFmSharedSecret()) catch null;
                    auth_status = if (auth_ticket != null) "Open the URL, approve access, then press k." else "Last.fm authorization request failed.";
                }
                continue;
            }
            if (k == 'k' and st.screen == .settings) {
                if (auth_ticket) |*ticket| {
                    const session = lastfm.finishAuth(allocator, app.config.getLastFmApiKey(), app.config.getLastFmSharedSecret(), ticket.token) catch null;
                    if (session) |key| {
                        defer allocator.free(key);
                        app.config.setLastFmSessionKey(key);
                        app.saveConfig();
                        ticket.deinit();
                        auth_ticket = null;
                        auth_status = "Last.fm connected. Restart forte-player to enable scrobbling.";
                    } else {
                        auth_status = "Authorization was not completed; approve the URL and try k again.";
                    }
                } else {
                    auth_status = "Press o to begin Last.fm authorization.";
                }
                continue;
            }
            if (k == 'e') {
                const song_id = if (st.screen == .library and st.selection < library_view_indices.items.len)
                    app.lib.songIdAt(library_view_indices.items[st.selection])
                else if (app.has_current_path) app.lib.songIdByPath(app.current_path) orelse -1 else -1;
                if (song_id >= 0) metadata_editor.start(app, song_id);
                continue;
            }
            if (k == 'H' and st.screen == .settings) {
                health_job.reset();
                st.health_findings = &.{};
                st.health_status = "Library health report running (read-only)...";
                var health_arena = std.heap.ArenaAllocator.init(allocator);
                defer health_arena.deinit();
                const known_rows = app.db.getAllSongPathsWithAllocator(health_arena.allocator()) catch {
                    st.health_status = "Could not read library paths; no report was run.";
                    continue;
                };
                const known = health_arena.allocator().alloc([]const u8, known_rows.len) catch continue;
                for (known_rows, 0..) |row, index| known[index] = row.path;
                health_job.start(app.config.getMusicDirectory(), known) catch {
                    st.health_status = "Could not start library health report.";
                    continue;
                };
                health_running = true;
                continue;
            }
            if (k == 'R' and st.screen == .settings) {
                app.engine.stop();
                scan_job.start() catch |e| {
                    std.log.err("could not start library scan: {}", .{e});
                    if (app.has_current_path) {
                        if (app.lib.songIdByPath(app.current_path)) |id| {
                            _ = app.playSongId(id) catch {};
                        }
                    }
                };
                if (scan_job.status.load(.acquire) == 1) scan_running = true;
                continue;
            }
            if (k == 't' and st.screen == .settings) {
                const current = app.config.getStr("ui", "theme", "auto");
                const next: [:0]const u8 = if (std.mem.eql(u8, current, "dark")) "light" else if (std.mem.eql(u8, current, "light")) "auto" else "dark";
                app.config.setStr("ui", "theme", next);
                app.saveConfig();
                render.setPalette(if (std.mem.eql(u8, next, "light")) .light else if (std.mem.eql(u8, next, "dark")) .dark else render.detectScheme(.dark, true));
                continue;
            }
            if (k == 'q') {
                quitting = true;
                continue;
            }
            // 'a' on the album list cycles the sort and reloads the rows.
            if (k == 'a' and st.screen == .albums) {
                album_sort = nextSort(album_sort);
                rebuildAlbumRows(app, &all_album_rows, allocator, album_sort, "");
                filterAlbumRows(all_album_rows.items, &album_rows, allocator, album_search.slice());
                st.selection = 0;
                st.scroll = 0;
                continue;
            }
            if (U.keyToAction(k)) |a| {
                const visible = view.libraryVisible(height);
                const cmd = U.apply(&st, a, visible);
                switch (cmd) {
                    // Album-detail commands need the track list + state in scope.
                    .open_album_detail => |album_id| {
                        loadAlbumTracks(app, &album_tracks, allocator, album_id);
                        for (album_rows.items) |row| {
                            if (row.id == album_id) {
                                resolver.enqueue(row.id, row.title, row.artist);
                                break;
                            }
                        }
                    },
                    .play_track_in_album => |i| if (app.playAlbumFromIndex(st.album_detail_id, i) == null) std.log.err("failed to play album track {d}", .{i}),
                    .play_artist => |id| if (!playArtist(app, id)) std.log.err("failed to play artist {d}", .{id}),
                    .play_genre => |id| if (!playGenre(app, id)) std.log.err("failed to play genre {d}", .{id}),
                    .open_artist_detail => |id| loadArtistTracks(app, &artist_detail_tracks, allocator, id),
                    .play_artist_track => |i| if (!playTrackRows(app, artist_detail_tracks.items, i, .Artist, st.artist_detail_id)) std.log.err("failed to play artist track {d}", .{i}),
                    .open_genre_detail => |id| loadGenreTracks(app, &genre_detail_tracks, allocator, id),
                    .play_genre_track => |i| if (!playTrackRows(app, genre_detail_tracks.items, i, .Genre, st.genre_detail_id)) std.log.err("failed to play genre track {d}", .{i}),
                    .open_playlist_detail => |id| {
                        loadPlaylistTracks(app, &playlist_tracks, allocator, id);
                        st.playlist_detail_id = id;
                        for (playlist_rows.items) |row| {
                            if (row.id == id) st.playlist_detail_name = row.name;
                        }
                    },
                    .play_playlist_track => |i| {
                        const played = if (app.db.isSmartPlaylist(st.playlist_detail_id))
                            playTrackRows(app, playlist_tracks.items, i, .Playlist, st.playlist_detail_id)
                        else
                            app.playPlaylist(st.playlist_detail_id, i) != null;
                        if (!played) std.log.err("failed to play playlist track {d}", .{i});
                    },
                    .play_index => |i| if (i < library_view_indices.items.len) {
                        const full_index = library_view_indices.items[i];
                        const id = app.lib.songIdAt(full_index);
                        _ = app.playSongId(id) catch |e| std.log.err("play selected song failed: {}", .{e});
                    },
                    .play_playlist => |playlist_id| {
                        if (app.db.isSmartPlaylist(playlist_id)) {
                            loadPlaylistTracks(app, &playlist_tracks, allocator, playlist_id);
                            if (!playTrackRows(app, playlist_tracks.items, 0, .Playlist, playlist_id)) std.log.err("failed to play smart playlist {d}", .{playlist_id});
                        } else if (app.playPlaylist(playlist_id, 0) == null) std.log.err("failed to play playlist {d}", .{playlist_id});
                    },
                    .play_queue_index => |i| if (i < app.play_queue.items().len) {
                        _ = app.playQueueIndex(i) catch |e| std.log.err("play queue item failed: {}", .{e});
                    },
                    else => runCmd(app, cmd),
                }
            }
        }

        if (health_running and health_job.status.load(.acquire) != 1) {
            health_job.join();
            health_running = false;
        }

        if (scan_running and scan_job.status.load(.acquire) != 1) {
            scan_job.join();
            const scan_status = scan_job.status.load(.acquire);
            const previous_path = scan_job.previous_path;
            if (scan_status == 2) {
                const result = scan_job.result;
                app.finishRescan(result, previous_path) catch |e| std.log.err("failed to apply library scan: {}", .{e});
                rebuildAlbumRows(app, &all_album_rows, allocator, album_sort, "");
                filterAlbumRows(all_album_rows.items, &album_rows, allocator, album_search.slice());
                rebuildArtistRows(app, &all_artist_rows, allocator, "");
                filterArtistRows(all_artist_rows.items, &artist_rows, allocator, artist_search.slice());
                rebuildGenreRows(app, &all_genre_rows, allocator, "");
                filterGenreRows(all_genre_rows.items, &genre_rows, allocator, genre_search.slice());
                rebuildPlaylistRows(app, &playlist_rows, allocator);
                rebuildTitles(app, &titles, &title_arena);
                rebuildLibraryView(titles.items, &library_view_titles, &library_view_indices, allocator, library_search.slice());
                queue_revision = std.math.maxInt(u64);
                context_cache.id = -1;
                art_for_album = -1;
                art_state = .unknown;
            } else if (previous_path.len > 0) {
                if (app.lib.songIdByPath(previous_path)) |id| {
                    _ = app.playSongId(id) catch |e| std.log.err("failed to resume after cancelled scan: {}", .{e});
                }
            } else {
                app.has_current_path = false;
            }
            scan_job.reset();
            scan_running = false;
        }

        // Only draw when a tick is due AND the queue is drained: if rendering
        // is slower than the timer, extra ticks pile up here and we skip them
        // (frame-dropping) rather than re-render the stale backlog.
        if (frame_due and tqueue.isEmpty()) {
            frame_due = false;
            if (scan_running) {
                st.scanning = true;
                st.playing = false;
                st.scan_scanned = scan_job.scanned.load(.acquire);
                st.scan_imported = scan_job.imported.load(.acquire);
                st.scan_updated = scan_job.updated.load(.acquire);
                st.scan_removed = scan_job.removed.load(.acquire);
                var scan_cmds = view.CmdList{};
                view.emit(&st, &scan_cmds, width, height, library_view_titles.items);
                render.render(scan_cmds.slice(), width, height);
                continue;
            }
            st.scanning = false;
            const resized = render.size();
            if (resized.w != width or resized.h != height) {
                win = resized;
                width = win.w;
                height = win.h;
                art_for_album = -1;
                art_state = .unknown;
            }

            // auto-advance when a track ends
            app.engine.update();
            if (app.engine.isPlaying()) auto_advance_handled = false;
            if (!auto_advance_handled and !app.engine.isPlaying() and app.engine.getDuration() > 0 and app.engine.getTime() >= app.engine.getDuration()) {
                auto_advance_handled = true;
                app.engine.handleAudioStreamFinished() catch |e| std.log.err("auto-advance failed: {}", .{e});
            }

            // Frame-local DB rows (contexts, queue metadata, and cover bytes)
            // should not keep the largest observed allocation resident for the
            // entire TUI session. The persistent snapshots have their own
            // arenas; release this scratch arena before rebuilding each frame.
            _ = query_arena.reset(.free_all);
            fillState(&st, app, &context_cache, album_rows.items, album_tracks.items, artist_detail_tracks.items, genre_detail_tracks.items, playlist_tracks.items, sortLabel(album_sort));
            const lyric_id = if (st.path.len > 0) app.lib.songIdByPath(st.path) orelse -1 else -1;
            if (context_cache.lyrics_id != lyric_id) {
                for (context_cache.lyrics) |line| allocator.free(line.text);
                if (context_cache.lyrics.len > 0) allocator.free(context_cache.lyrics);
                context_cache.lyrics = &.{};
                context_cache.lyrics_id = lyric_id;
                if (lyric_id >= 0) {
                    if (lyrics_mod.loadSidecar(allocator, st.path) catch null) |found| context_cache.lyrics = found.lines;
                }
            }
            st.lyrics = context_cache.lyrics;
            st.active_lyric = (lyrics_mod.Lyrics{ .lines = st.lyrics }).activeLine(st.position);
            st.album_filter = album_search.slice();
            st.album_searching = album_search.active;
            st.library_filter = library_search.slice();
            st.library_searching = library_search.active;
            st.artists = artist_rows.items;
            st.artist_count = artist_rows.items.len;
            st.genres = genre_rows.items;
            st.genre_count = genre_rows.items.len;
            st.filter = if (st.screen == .artists) artist_search.slice() else if (st.screen == .genres) genre_search.slice() else "";
            st.searching = if (st.screen == .artists) artist_search.active else if (st.screen == .genres) genre_search.active else false;
            if (queue_revision != app.play_queue.revision()) {
                rebuildQueueRows(app, &queue_rows, allocator, query_arena.allocator());
                queue_revision = app.play_queue.revision();
            }
            st.playlists = playlist_rows.items;
            st.playlist_count = playlist_rows.items.len;
            st.queue = queue_rows.items;
            st.queue_count = queue_rows.items.len;
            st.metadata_editing = metadata_editor.active;
            st.metadata_field = if (metadata_editor.active) metadata_editor.fieldName() else "";
            st.metadata_value = if (metadata_editor.active) metadata_editor.current() else "";
            var metadata_rows: [MetadataEditor.field_names.len]U.MetadataField = undefined;
            if (metadata_editor.active) {
                for (MetadataEditor.field_names, metadata_editor.fields, 0..) |name, field, index| {
                    metadata_rows[index] = .{ .name = name, .value = field.slice() };
                }
                st.metadata_fields = &metadata_rows;
                st.metadata_active_index = metadata_editor.index;
            } else {
                st.metadata_fields = &.{};
            }
            st.metadata_song_title = "";
            if (metadata_editor.active) {
                if (app.db.getSongById(metadata_editor.song_id) catch null) |edited_song| {
                    st.metadata_song_title = edited_song.title;
                }
            }
            st.settings_music_directory = app.config.getMusicDirectory();
            st.settings_lastfm_enabled = app.config.getLastFmApiKey().len > 0 and app.config.getLastFmSessionKey().len > 0;
            st.settings_normalization_enabled = app.config.getNormalizationEnabled();
            st.settings_normalization_album = app.config.getNormalizationPolicy() == .album;
            st.settings_playback_profile = @tagName(app.config.getPlaybackProfile());
            st.settings_crossfade_seconds = app.config.getCrossfadeSeconds();
            st.settings_editing = settings_editor.active;
            st.settings_field = if (settings_editor.active) settings_editor.fieldName() else "";
            st.settings_value = if (settings_editor.active) settings_editor.current() else "";
            st.settings_auth_status = auth_status;
            st.settings_auth_url = if (auth_ticket) |ticket| ticket.url else "";
            st.health_running = health_running;
            st.health_scanned = health_job.scanned.load(.acquire);
            const health_status = health_job.status.load(.acquire);
            if (health_status == 2) health_job.join();
            st.health_findings = if (health_status == 2) blk: {
                if (health_job.report) |*report| break :blk report.findings.items;
                break :blk &.{};
            } else &.{};
            st.health_status = if (health_running) "Library health report running (read-only)..." else switch (health_status) {
                2 => "Health report complete (read-only).",
                3 => "Health report failed: root/file inaccessible or traversal incomplete; missing-file results withheld.",
                4 => "Health report cancelled; partial findings discarded.",
                else => st.health_status,
            };
            st.row_count = library_view_titles.items.len;
            st.playing_index = null;
            if (app.lib.songIdByPath(st.path)) |current_id| {
                if (app.lib.indexOfId(current_id)) |full_index| {
                    st.playing_index = U.sortedIndexOf(library_view_indices.items, full_index);
                }
            }

            // Last.fm: submit the current track the moment it's played enough.
            if (scrobbler) |s| s.tick(st.playing, st.position, st.duration);

            // Refresh the spectrum only while visible and only when the audio
            // callback published a newer sample block.
            if (st.screen == .now_playing) {
                // Render at 60 Hz, but update the analyzer at 20 Hz. This is
                // sufficient for a smooth visualizer and leaves more CPU for
                // terminal drawing and input processing.
                spectrum_ticks += 1;
                if (spectrum_ticks >= 3) {
                    spectrum_ticks = 0;
                    const sequence = app.engine.captureSequence();
                    if (sequence != last_capture_sequence) {
                        last_capture_sequence = sequence;
                        const got = app.engine.copyRecentMono(sample_buf.len, &sample_buf);
                        if (got > 0) {
                            analyzer.compute(sample_buf[0..got], &raw_bands);
                            smoother.update(&raw_bands);
                        }
                    }
                }
                st.spectrum = smoother.levels[0..];
            } else {
                st.spectrum = &.{};
            }

            // Album art: use the open album while browsing its detail view;
            // otherwise use the currently playing album. Embedded/folder art is
            // instant, while resolved CAA art remains a background fallback.
            const desired_target: ArtTarget = if (st.screen == .now_playing) .now_playing else .none;
            var desired_album_id: i64 = -1;
            if (desired_target == .now_playing) {
                if (app.lib.songIdByPath(st.path)) |sid| {
                    if (app.lib.getSongById(sid)) |song| desired_album_id = song.album_id;
                }
            }
            if (desired_target != art_target) {
                art_target = desired_target;
                art_for_album = -1;
                art_state = .unknown;
            }
            if (desired_album_id >= 0) {
                if (desired_album_id != art_for_album) {
                    art_for_album = desired_album_id;
                    art_state = .unknown;
                }
                if (art_state == .unknown or art_state == .waiting_resolver) {
                    // Terminal cells are typically about twice as tall as
                    // they are wide. Since each cell contains two half-block
                    // pixels, a visually square cover uses roughly 2 columns
                    // per row (32x16, not 16x16).
                    const aw_limit: usize = if (st.screen == .album_detail) @max(@as(usize, 8), width / 3) else width -| 52;
                    const ah_limit: usize = height -| 7;
                    const ah = @min(@min(art_max_h, ah_limit), aw_limit / 2);
                    // The cover buffer is only art_max_w cells wide, so cap
                    // before multiplying rather than testing against usize's
                    // maximum (which can trigger a checked-overflow trap on
                    // some Zig 0.16 targets).
                    const width_from_height = if (ah > art_max_w / 2) art_max_w else ah * 2;
                    const aw = @min(@min(art_max_w, aw_limit), width_from_height);
                    if (aw >= 8 and ah >= 4 and aw <= art_cells.len / ah) {
                        // Query/decode local art once. Missing or failed local art
                        // transitions to a resolver state instead of retrying
                        // SQLite and image decoding every frame.
                        const cell_count = art_cells.len;
                        if (art_state == .unknown) {
                            if (app.db.getAlbumCoverWithAllocator(query_arena.allocator(), desired_album_id) catch null) |cover| {
                                if (cover.bytes.len > 0) {
                                    art_w = @intCast(aw);
                                    art_h = @intCast(ah);
                                    if (cover_art.renderCover(cover.bytes, aw, ah, art_cells[0..cell_count])) {
                                        art_state = .ready;
                                    } else {
                                        art_state = .failed;
                                    }
                                } else {
                                    art_state = .failed;
                                }
                            } else {
                                art_state = .failed;
                            }
                            if (art_state == .failed and resolver.coverUrlFor(desired_album_id) != null) art_state = .waiting_resolver;
                        }
                        if (art_state == .waiting_resolver) {
                            if (resolver.coverImageBytes(desired_album_id)) |bytes| {
                                if (bytes.len > 0) {
                                    art_w = @intCast(aw);
                                    art_h = @intCast(ah);
                                    art_state = if (cover_art.renderCover(bytes, aw, ah, art_cells[0..cell_count])) .ready else .failed;
                                }
                            }
                        }
                    }
                }
            }
            const rendered_art = if (art_state == .ready) U.Art{ .w = art_w, .h = art_h, .cells = art_cells[0..] } else U.Art{};
            const rendered_status: U.ArtStatus = switch (art_state) {
                .unknown => .loading,
                .waiting_resolver => .loading,
                .ready => .ready,
                .failed => .unavailable,
            };
            st.art = .{};
            st.art_status = .none;
            st.album_art = .{};
            st.album_art_status = .none;
            if (desired_target == .now_playing) {
                st.art = rendered_art;
                st.art_status = if (desired_album_id >= 0) rendered_status else .none;
            }

            // Apply completed background cover results. Network requests are
            // rate-limited by the resolver worker, never performed in this loop
            // or inside the song-change hook. Refresh presence when the current
            // album resolves.
            if (resolver.tick()) {
                if (art_state == .failed and art_for_album >= 0 and resolver.coverUrlFor(art_for_album) != null) art_state = .waiting_resolver;
                if (app.lib.songIdByPath(st.path)) |sid| {
                    if (app.lib.getSongById(sid)) |song| {
                        if (resolver.coverUrlFor(song.album_id) != null) {
                            pushPresence(&tui_user, st.title, st.artist, st.album, song.album_id, st.duration);
                        }
                    }
                }
            }
            if (resolver.takeFailure()) |failure| {
                std.log.warn("cover lookup failed for album {d}: {s}", .{ failure.album_id, @tagName(failure.kind) });
            }

            var cl = view.CmdList{};
            view.emit(&st, &cl, width, height, library_view_titles.items);
            render.render(cl.slice(), width, height);
        }
    }

    render.restoreRaw();
    std.debug.print("bye.\n", .{});
}
