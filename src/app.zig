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
const db_mod = @import("music/database.zig");
const lib_mod = @import("music/library.zig");
const scanner = @import("music/scanner.zig");
const taglib_meta = @import("music/taglib_meta.zig");

const c_time = @cImport({ @cInclude("time.h"); });
fn unixSeconds() i64 {
    return @intCast(c_time.time(null));
}

/// Frontend-supplied per-song hook (Discord presence, cover lookups, ...).
/// `ctx` is the `user` pointer the frontend passed to `App.create`.
pub const SongChangedFn = *const fn (ctx: *anyopaque, path: [:0]const u8) void;

/// Shared context threaded through the engine's hooks.
pub const EngineCtx = struct {
    lib: *lib_mod.Library,
    db: *db_mod.Database,
    /// The currently-playing path, kept in sync on every song change.
    current_path: *[:0]const u8,
    engine: *RealEngine,
    user: ?*anyopaque = null,
    song_changed: ?SongChangedFn = null,
};

fn resolveSong(id: i32, ctx: *anyopaque) ?[:0]const u8 {
    const p: *EngineCtx = @ptrCast(@alignCast(ctx));
    return p.lib.songPath(@intCast(id));
}

fn onSongChanged(path: [:0]const u8, ctx: *anyopaque) void {
    const p: *EngineCtx = @ptrCast(@alignCast(ctx));
    p.current_path.* = path;
    if (p.lib.songIdByPath(path)) |id| {
        p.db.markPlayed(@intCast(id), unixSeconds()) catch {};
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
    ctx: EngineCtx = undefined,

    /// Set up Allegro, persisted config, the scanned DB + in-memory library,
    /// the engine + queue, and the engine's library hooks. `user`/`song_changed`
    /// are optional frontend extensions (pass both or neither).
    pub fn create(allocator: std.mem.Allocator, user: ?*anyopaque, song_changed: ?SongChangedFn) !*App {
        const self = try allocator.create(App);
        errdefer allocator.destroy(self);
        self.* = undefined;

        try allegro_init.initialize();
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

        self.scan = scanner.scanDirectory(&self.db, allocator, config.getMusicDirectory(), taglib_meta.extractor) catch |e| blk: {
            std.debug.print("app: scan failed: {}\n", .{e});
            break :blk .{};
        };
        try self.lib.load(&self.db);

        self.engine = try RealEngine.create(allocator);
        errdefer self.engine.destroy();

        self.play_queue = PlayQueue.init(allocator);
        var qi: usize = 0;
        while (qi < self.lib.count()) : (qi += 1) try self.play_queue.enqueue(@intCast(self.lib.songIdAt(qi)));

        self.config = config;
        self.allocator = allocator;
        self.ctx = .{
            .lib = self.lib,
            .db = &self.db,
            .current_path = &self.current_path,
            .engine = self.engine,
            .user = user,
            .song_changed = song_changed,
        };
        self.engine.setPlayQueue(&self.play_queue);
        self.engine.resolve_song = resolveSong;
        self.engine.on_song_changed = onSongChanged;
        self.engine.user_context = &self.ctx;
        self.engine.enableCapture(true);
        return self;
    }

    pub fn destroy(self: *App) void {
        const allocator = self.allocator;
        self.engine.destroy();
        self.play_queue.deinit();
        self.db.deinit();
        self.lib.destroy();
        self.config.destroy();
        allocator.destroy(self);
    }

    /// Start the first playable song, preferring non-MP3 files first (this
    /// Allegro build may lack an MP3 codec) and falling back to MP3. Returns
    /// the chosen path, or null if nothing in the library is playable.
    pub fn startFirstSong(self: *App) ?[:0]const u8 {
        var tries: usize = 0;
        for ([_]bool{ false, true }) |want_mp3| {
            var i: usize = 0;
            while (i < self.lib.count() and tries < 80) : (i += 1) {
                const id = self.lib.songIdAt(i);
                const path = self.lib.songPath(id) orelse continue;
                const is_mp3 = std.mem.endsWith(u8, path, ".mp3");
                if (is_mp3 != want_mp3) continue;
                tries += 1;
                if (self.engine.playSound(path)) |_| {
                    self.current_path = path;
                    return path;
                } else |_| {}
            }
        }
        return null;
    }

    /// Play every song in an album from its first track (see playAlbumFromIndex).
    pub fn playAlbum(self: *App, album_id: i64) ?[:0]const u8 {
        return self.playAlbumFromIndex(album_id, 0);
    }

    /// Play an album starting at `start_index`: rebuilds the play queue as an
    /// Album context (so next/prev/auto-advance stay within this album) and
    /// begins playback at the chosen track. Returns the started path.
    pub fn playAlbumFromIndex(self: *App, album_id: i64, start_index: usize) ?[:0]const u8 {
        const songs = self.db.getSongsByAlbum(album_id) catch return null;
        if (songs.len == 0) return null;
        const start = @min(start_index, songs.len - 1);

        var ids = std.ArrayList(i32){ .items = &.{}, .capacity = 0 };
        defer ids.deinit(self.allocator);
        for (songs) |s| {
            ids.append(self.allocator, @intCast(s.id)) catch return null;
        }

        self.play_queue.clear();
        self.play_queue.context_type = .Album;
        self.play_queue.context_id = @intCast(album_id);
        self.play_queue.enqueueMany(ids.items) catch return null;
        self.play_queue.current_index = start;

        const path = self.lib.songPath(songs[start].id) orelse return null;
        _ = self.engine.playSound(path) catch return null;
        return path;
    }
};
