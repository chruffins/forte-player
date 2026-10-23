//! Shared application composition root for the GUI (`main.zig`) and TUI
//! (`tui_main.zig`) frontends.
//!
//! `App` owns the lifetime of everything a frontend needs on top of the audio
//! engine: persisted config, the scanned SQLite database + in-memory library,
//! the play queue, and the engine hooks that map queue ids <-> file paths and
//! record playback state. The two frontends previously duplicated this wiring;
//! both now just build an `App` and drive their own loop over
//! `app.engine` / `app.lib`.
//!
//! Frontends can extend playback with their own per-song work (e.g. Discord
//! presence + cover resolution in the TUI) via the optional `song_changed`
//! hook, while still getting the shared `markPlayed` bookkeeping.

const std = @import("std");
const allegro_init = @import("core/allegro_init.zig");
const config_mod = @import("core/config.zig");
const RealEngine = @import("core/music_engine.zig").RealEngine;
const PlayQueue = @import("music/play_queue.zig").PlayQueue;
const ShuffleMetadata = @import("music/play_queue.zig").ShuffleMetadata;
const RepeatMode = @import("music/play_queue.zig").RepeatMode;
const PlaybackContextType = @import("music/play_queue.zig").PlaybackContextType;
const db_mod = @import("music/database.zig");
const lib_mod = @import("music/library.zig");
const scanner = @import("music/scanner.zig");
const taglib_meta = @import("music/taglib_meta.zig");
const loudness = @import("music/loudness.zig");

/// Current wall-clock time in unix seconds (std.Io.Clock; no C imports).
fn unixSeconds() i64 {
    return std.Io.Clock.real.now(std.Io.Threaded.global_single_threaded.io()).toSeconds();
}

/// Frontend-supplied per-song hook (Discord presence, cover lookups, ...).
/// `ctx` is the `user` pointer the frontend passed to `App.create`.
pub const SongChangedFn = *const fn (ctx: *anyopaque, path: [:0]const u8) void;

/// Shared context threaded through the engine's hooks.
pub const EngineCtx = struct {
    lib: *lib_mod.Library,
    db: *db_mod.Database,
    play_queue: *PlayQueue,
    /// The currently-playing path, kept in sync on every song change.
    current_path: *[:0]const u8,
    has_current_path: *bool,
    engine: *RealEngine,
    config: *config_mod.Config,
    user: ?*anyopaque = null,
    song_changed: ?SongChangedFn = null,

    fn applyNormalization(self: *EngineCtx, id: i64) void {
        const measurement = self.db.getSongReplayGain(id) catch null orelse loudness.Measurement{};
        self.engine.setNormalizationGain(loudness.effectiveGain(
            measurement,
            self.config.getNormalizationEnabled(),
            self.config.getNormalizationPolicy(),
            0.98,
        ));
    }
};

fn resolveSong(id: i32, ctx: *anyopaque) ?[:0]const u8 {
    const p: *EngineCtx = @ptrCast(@alignCast(ctx));
    return p.lib.songPath(@intCast(id));
}

fn restoreSavedQueue(queue: *PlayQueue, lib: *lib_mod.Library, config: *const config_mod.Config, allocator: std.mem.Allocator) void {
    const encoded = config.getStr("queue", "ids", "");
    if (encoded.len == 0) return;
    var ids = std.ArrayList(i32).empty;
    defer ids.deinit(allocator);
    var parts = std.mem.splitScalar(u8, encoded, ',');
    while (parts.next()) |part| {
        const id = std.fmt.parseInt(i64, part, 10) catch continue;
        if (id < std.math.minInt(i32) or id > std.math.maxInt(i32)) continue;
        if (lib.songPath(id)) |_| ids.append(allocator, @intCast(id)) catch return;
    }
    if (ids.items.len == 0) return;
    const context_type: PlaybackContextType = switch (config.getInt("queue", "context_type", 0)) {
        1 => .Album,
        2 => .Playlist,
        3 => .Artist,
        4 => .Genre,
        else => .Individual,
    };
    const context_id_value = config.getInt("queue", "context_id", -1);
    const context_id: i32 = if (context_id_value < std.math.minInt(i32) or context_id_value > std.math.maxInt(i32)) -1 else @intCast(context_id_value);
    queue.replace(ids.items, context_type, context_id) catch return;
    const start = @as(usize, @intCast(@max(@as(i64, 0), config.getInt("queue", "current_index", 0))));
    queue.setStartIndex(@min(start, ids.items.len - 1)) catch return;
    const repeat_value = config.getInt("queue", "repeat", 0);
    queue.setRepeatMode(switch (repeat_value) {
        1 => .All,
        2 => .One,
        else => .None,
    });
    queue.setShuffled(config.getInt("queue", "shuffle", 0) != 0) catch {};
}

fn populateShuffleMetadata(queue: *PlayQueue, lib: *lib_mod.Library, db: *db_mod.Database, allocator: std.mem.Allocator) !void {
    queue.clearShuffleMetadata();
    var album_artist = std.AutoHashMap(i64, i64).init(allocator);
    defer album_artist.deinit();
    for (lib.order.items) |song_id| {
        if (song_id < std.math.minInt(i32) or song_id > std.math.maxInt(i32)) continue;
        const song = lib.getSongById(song_id) orelse continue;
        var artist_id: i64 = -1;
        if (song.album_id >= 0) {
            if (album_artist.get(song.album_id)) |cached| {
                artist_id = cached;
            } else {
                artist_id = if (try db.getAlbumById(song.album_id)) |album| album.artist_id else -1;
                try album_artist.put(song.album_id, artist_id);
            }
        }
        try queue.setShuffleMetadata(@intCast(song_id), .{
            .artist_id = artist_id,
            .album_id = song.album_id,
            .play_count = song.play_count,
            .last_played = song.last_played,
            .favorite = song.favorite != 0,
        });
    }
}

fn onSongChanged(path: [:0]const u8, ctx: *anyopaque) void {
    const p: *EngineCtx = @ptrCast(@alignCast(ctx));
    p.current_path.* = path;
    p.has_current_path.* = true;
    if (p.lib.songIdByPath(path)) |id| {
        const played_at = unixSeconds();
        p.db.markPlayed(@intCast(id), played_at) catch |e| std.log.err("failed to record play for song {d}: {}", .{ id, e });
        p.lib.recordPlayed(id, played_at);
        if (id >= std.math.minInt(i32) and id <= std.math.maxInt(i32)) p.play_queue.recordShufflePlay(@intCast(id), played_at);
        p.applyNormalization(id);
    } else {
        p.engine.setNormalizationGain(1.0);
    }
    if (p.song_changed) |cb| {
        if (p.user) |u| cb(u, path);
    }
}

pub const App = struct {
    allocator: std.mem.Allocator,
    config: config_mod.Config,
    lib: *lib_mod.Library,
    db: db_mod.Database,
    engine: *RealEngine,
    play_queue: PlayQueue,
    scan: scanner.ScanResult = .{},

    /// Path of the currently-playing song (borrowed from the library arena).
    current_path: [:0]const u8 = undefined,
    has_current_path: bool = false,
    ctx: EngineCtx = undefined,

    /// Set up Allegro, persisted config, the scanned DB + in-memory library,
    /// the engine + queue, and the engine's library hooks. `user`/`song_changed`
    /// are optional frontend extensions (pass both or neither).
    pub fn create(allocator: std.mem.Allocator, user: ?*anyopaque, song_changed: ?SongChangedFn) !*App {
        return createImpl(allocator, user, song_changed, true, true);
    }

    /// Build the application without walking the music directory. Frontends
    /// with an event loop can start a background scan immediately, avoiding a
    /// blocking startup while keeping the existing synchronous API available
    /// for non-interactive callers.
    pub fn createDeferred(allocator: std.mem.Allocator, user: ?*anyopaque, song_changed: ?SongChangedFn) !*App {
        return createImpl(allocator, user, song_changed, false, true);
    }

    /// TUI startup uses terminal input instead of Allegro's native input
    /// sources, which are not safe to install without an AppKit context.
    pub fn createTui(allocator: std.mem.Allocator, user: ?*anyopaque, song_changed: ?SongChangedFn) !*App {
        return createImpl(allocator, user, song_changed, true, false);
    }

    fn createImpl(allocator: std.mem.Allocator, user: ?*anyopaque, song_changed: ?SongChangedFn, initial_scan: bool, with_input: bool) !*App {
        const self = try allocator.create(App);
        errdefer allocator.destroy(self);
        self.* = undefined;

        try allegro_init.initializeWithInput(with_input);
        config_mod.initAppIdentity();

        const config_path = try config_mod.configFilePath(allocator);
        defer allocator.free(config_path);
        var config = config_mod.Config.create();
        errdefer config.destroy();
        try config.loadOrCreate(config_path);

        const db_path = try config_mod.databasePath(allocator);
        defer allocator.free(db_path);

        self.lib = try lib_mod.Library.create(allocator);
        errdefer self.lib.destroy();
        self.db = try db_mod.Database.open(self.lib.arena.allocator(), db_path);
        errdefer self.db.deinit();

        if (initial_scan) {
            self.scan = scanner.scanDirectory(&self.db, allocator, config.getMusicDirectory(), taglib_meta.extractor) catch |e| blk: {
                std.log.err("scan failed: {}", .{e});
                break :blk .{};
            };
        } else self.scan = .{};
        try self.lib.load(&self.db);

        self.engine = try RealEngine.create(allocator);
        errdefer self.engine.destroy();

        self.play_queue = PlayQueue.init(allocator);
        var qi: usize = 0;
        while (qi < self.lib.count()) : (qi += 1) try self.play_queue.enqueue(@intCast(self.lib.songIdAt(qi)));
        try populateShuffleMetadata(&self.play_queue, self.lib, &self.db, allocator);
        restoreSavedQueue(&self.play_queue, self.lib, &config, allocator);

        self.config = config;
        self.allocator = allocator;
        self.ctx = .{
            .lib = self.lib,
            .db = &self.db,
            .play_queue = &self.play_queue,
            .current_path = &self.current_path,
            .has_current_path = &self.has_current_path,
            .engine = self.engine,
            .config = &self.config,
            .user = user,
            .song_changed = song_changed,
        };
        self.engine.setCrossfadeSecs(@floatFromInt(self.config.getCrossfadeSeconds()));
        self.engine.setPlayQueue(&self.play_queue);
        self.engine.resolve_song = resolveSong;
        self.engine.on_song_changed = onSongChanged;
        self.engine.user_context = &self.ctx;
        self.engine.enableCapture(true);
        return self;
    }

    fn saveQueue(self: *App) void {
        var encoded: [32768:0]u8 = undefined;
        var len: usize = 0;
        for (self.play_queue.items(), 0..) |id, i| {
            const prefix: []const u8 = if (i == 0) "" else ",";
            const part = std.fmt.bufPrint(encoded[len..], "{s}{d}", .{ prefix, id }) catch break;
            len += part.len;
        }
        encoded[len] = 0;
        self.config.setStr("queue", "ids", encoded[0..len :0]);
        self.config.setInt("queue", "current_index", @intCast(self.play_queue.currentIndex()));
        self.config.setInt("queue", "repeat", @intCast(@backingInt(self.play_queue.getRepeatMode())));
        self.config.setInt("queue", "shuffle", @intFromBool(self.play_queue.isShuffled()));
        self.config.setInt("queue", "context_type", @intCast(@backingInt(self.play_queue.context_type)));
        self.config.setInt("queue", "context_id", self.play_queue.context_id);
    }

    /// Re-apply the persisted queue after a deferred initial scan reloads the
    /// library and filters out entries that no longer exist.
    pub fn restoreSavedQueueState(self: *App) void {
        restoreSavedQueue(&self.play_queue, self.lib, &self.config, self.allocator);
    }

    /// Reload the in-memory library after on-disk tag edits, preserving the
    /// current stream path and refreshing the queue's smart-shuffle metadata.
    pub fn reloadLibrary(self: *App) !void {
        var previous_path: ?[]u8 = null;
        if (self.has_current_path) previous_path = try self.allocator.dupe(u8, self.current_path);
        defer if (previous_path) |path| self.allocator.free(path);
        try self.lib.load(&self.db);
        try populateShuffleMetadata(&self.play_queue, self.lib, &self.db, self.allocator);
        self.has_current_path = false;
        if (previous_path) |path| if (self.lib.songIdByPath(path)) |id| {
            if (self.lib.songPath(id)) |current| {
                self.current_path = current;
                self.has_current_path = true;
            }
        };
    }

    /// Re-apply settings to the current stream after a normalization preference changes.
    pub fn refreshNormalization(self: *App) void {
        if (self.has_current_path) {
            if (self.lib.songIdByPath(self.current_path)) |id| {
                self.ctx.applyNormalization(id);
                return;
            }
        }
        self.engine.setNormalizationGain(1.0);
    }

    pub fn saveConfig(self: *App) void {
        const path = config_mod.configFilePath(self.allocator) catch |e| {
            std.log.err("config path failed: {}", .{e});
            return;
        };
        defer self.allocator.free(path);
        if (!self.config.save(path)) std.log.err("failed to save config", .{});
    }

    /// Apply a completed scan on the main thread. The scanner itself may run
    /// on a worker, but library/queue/engine state remains single-threaded.
    pub fn finishRescan(self: *App, result: scanner.ScanResult, previous_path: []const u8) !void {
        self.engine.stop();
        try self.lib.load(&self.db);
        try populateShuffleMetadata(&self.play_queue, self.lib, &self.db, self.allocator);
        // Library.load resets the arena that backs current_path. Do not expose
        // the old slice while deciding whether the previous track survived.
        self.has_current_path = false;
        self.play_queue.clear();
        var i: usize = 0;
        while (i < self.lib.count()) : (i += 1) {
            try self.play_queue.enqueue(@intCast(self.lib.songIdAt(i)));
        }
        if (previous_path.len > 0) {
            if (self.lib.songIdByPath(previous_path)) |id| {
                _ = self.playSongId(id) catch {};
            }
        }
        self.scan = result;
    }

    /// Rescan synchronously for non-interactive callers.
    pub fn rescan(self: *App) !scanner.ScanResult {
        var previous_path: ?[]u8 = null;
        if (self.has_current_path) previous_path = try self.allocator.dupe(u8, self.current_path);
        defer if (previous_path) |p| self.allocator.free(p);

        const result = try scanner.scanDirectory(&self.db, self.allocator, self.config.getMusicDirectory(), taglib_meta.extractor);
        try self.finishRescan(result, previous_path orelse "");
        return result;
    }

    pub fn destroy(self: *App) void {
        const allocator = self.allocator;
        self.saveQueue();
        self.saveConfig();
        self.engine.destroy();
        self.play_queue.deinit();
        self.db.deinit();
        self.lib.destroy();
        self.config.destroy();
        allocator.destroy(self);
    }

    /// Start a library song while keeping the queue cursor and navigation
    /// history synchronized with the stream. A failed load restores the queue
    /// cursor, leaving the currently playing stream untouched.
    pub fn playSongId(self: *App, id: i64) ![:0]const u8 {
        const path = self.lib.songPath(id) orelse return error.SongNotFound;
        const cursor = self.play_queue.cursor();
        try self.play_queue.selectSong(@intCast(id));
        self.engine.playSound(path) catch |err| {
            self.play_queue.restore(cursor);
            return err;
        };
        return path;
    }

    /// Play the exact queue occurrence at `index`; unlike playSongId this
    /// remains unambiguous when a queue contains duplicate song ids.
    pub fn playQueueIndex(self: *App, index: usize) ![:0]const u8 {
        if (index >= self.play_queue.size()) return error.IndexOutOfBounds;
        const id = self.play_queue.items()[index];
        const path = self.lib.songPath(@intCast(id)) orelse return error.SongNotFound;
        const cursor = self.play_queue.cursor();
        try self.play_queue.selectIndex(index);
        self.engine.playSound(path) catch |err| {
            self.play_queue.restore(cursor);
            return err;
        };
        return path;
    }

    /// Start the first playable song, preferring non-MP3 files first (this
    /// Allegro build may lack an MP3 codec) and falling back to MP3. Returns
    /// the chosen path, or null if nothing in the library is playable.
    pub fn startFirstSong(self: *App) ?[:0]const u8 {
        // Resume the saved queue cursor when one exists; the default queue also
        // starts at its first library entry, so this preserves first-run behavior.
        if (self.play_queue.current()) |id| {
            if (self.playSongId(@intCast(id))) |started| return started else |_| {}
        }
        // Try every candidate; the old arbitrary 80-song cap could report an
        // empty library even when a playable song existed later in the scan.
        for ([_]bool{ false, true }) |want_mp3| {
            var i: usize = 0;
            while (i < self.lib.count()) : (i += 1) {
                const id = self.lib.songIdAt(i);
                const path = self.lib.songPath(id) orelse continue;
                const is_mp3 = std.mem.endsWith(u8, path, ".mp3");
                if (is_mp3 != want_mp3) continue;
                if (self.playSongId(id)) |started| return started else |_| {}
            }
        }
        return null;
    }

    /// Play every song in an album from its first track (see playAlbumFromIndex).
    pub fn playAlbum(self: *App, album_id: i64) ?[:0]const u8 {
        return self.playAlbumFromIndex(album_id, 0);
    }

    /// Replace the queue and start one item, restoring the old queue if stream
    /// loading fails. Album, playlist, artist, and genre playback all use this
    /// transaction so their failure behavior cannot drift apart.
    /// Transactionally replace playback with an arbitrary song set.
    /// Frontends use this for artist/genre contexts without duplicating queue
    /// rollback and stream-loading logic.
    pub fn playSongIdsInContext(self: *App, song_ids: []const i64, context: PlaybackContextType, context_id: i64, start_index: usize) ?[:0]const u8 {
        if (song_ids.len == 0 or start_index >= song_ids.len) return null;
        const path = self.lib.songPath(song_ids[start_index]) orelse return null;
        var queue_ids = std.ArrayList(i32).empty;
        defer queue_ids.deinit(self.allocator);
        for (song_ids) |id| {
            if (id < std.math.minInt(i32) or id > std.math.maxInt(i32)) return null;
            queue_ids.append(self.allocator, @intCast(id)) catch return null;
        }
        var rollback = self.play_queue.snapshot() catch return null;
        defer rollback.deinit();
        self.play_queue.replace(queue_ids.items, context, @intCast(context_id)) catch return null;
        self.play_queue.setStartIndex(start_index) catch {
            self.play_queue.restoreSnapshot(&rollback);
            return null;
        };
        self.engine.playSound(path) catch {
            self.play_queue.restoreSnapshot(&rollback);
            return null;
        };
        return path;
    }

    /// Play an album starting at `start_index`: rebuild the queue as an Album
    /// context so next/prev/auto-advance remain inside this album.
    pub fn playAlbumFromIndex(self: *App, album_id: i64, start_index: usize) ?[:0]const u8 {
        var query_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer query_arena.deinit();
        const songs = self.db.getSongsByAlbumWithAllocator(query_arena.allocator(), album_id) catch return null;
        var ids = std.ArrayList(i64).empty;
        defer ids.deinit(self.allocator);
        for (songs) |song| ids.append(self.allocator, song.id) catch return null;
        return self.playSongIdsInContext(ids.items, .Album, album_id, start_index);
    }

    /// Load and play every song in a saved playlist.
    pub fn playPlaylist(self: *App, playlist_id: i64, start_index: usize) ?[:0]const u8 {
        var query_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer query_arena.deinit();
        const song_ids = self.db.getPlaylistSongIdsWithAllocator(query_arena.allocator(), playlist_id) catch return null;
        return self.playSongIdsInContext(song_ids, .Playlist, playlist_id, start_index);
    }
};
