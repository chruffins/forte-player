//! SQLite-backed music database, port of `database/MusicDatabase` from
//! audio-visualizer-cpp, built on the vendored `zig-sqlite` wrapper.
//!
//! Scope: schema creation, transactions, inserting entities, and the read
//! queries the Library layer needs. (The taglib-based scanner that feeds this
//! is intentionally not ported yet; rows are inserted programmatically.)

const std = @import("std");
const sqlite = @import("sqlite");
const entity = @import("entity.zig");

const schema = [_][]const u8{
    \\CREATE TABLE IF NOT EXISTS songs (
    \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
    \\  song_path TEXT NOT NULL UNIQUE,
    \\  title TEXT,
    \\  album_id INTEGER,
    \\  track INTEGER,
    \\  comment TEXT,
    \\  duration INTEGER,
    \\  file_size INTEGER,
    \\  file_mtime_ticks INTEGER,
    \\  FOREIGN KEY(album_id) REFERENCES albums(id) ON DELETE CASCADE);
    ,
    \\CREATE TABLE IF NOT EXISTS artists (
    \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
    \\  name TEXT NOT NULL UNIQUE,
    \\  picture_path TEXT,
    \\  desc TEXT);
    ,
    \\CREATE TABLE IF NOT EXISTS albums (
    \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
    \\  release_type INTEGER DEFAULT 1,
    \\  name TEXT NOT NULL,
    \\  year INTEGER,
    \\  picture_path TEXT,
    \\  musicbrainz_release_group_id TEXT,
    \\  cover_art_block BLOB,
    \\  cover_art_mime TEXT,
    \\  artist_id INTEGER,
    \\  FOREIGN KEY(artist_id) REFERENCES artists(id) ON DELETE CASCADE);
    ,
    \\CREATE TABLE IF NOT EXISTS genres (
    \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
    \\  name TEXT NOT NULL UNIQUE,
    \\  parent_id INTEGER);
    ,
    \\CREATE TABLE IF NOT EXISTS playlists (
    \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
    \\  name TEXT NOT NULL,
    \\  picture_path TEXT,
    \\  desc TEXT);
    ,
    \\CREATE TABLE IF NOT EXISTS playlist_songs (
    \\  playlist_id INTEGER NOT NULL,
    \\  song_id INTEGER NOT NULL,
    \\  position INTEGER NOT NULL,
    \\  FOREIGN KEY(playlist_id) REFERENCES playlists(id) ON DELETE CASCADE,
    \\  FOREIGN KEY(song_id) REFERENCES songs(id) ON DELETE CASCADE,
    \\  PRIMARY KEY(playlist_id, position));
    ,
    \\CREATE TABLE IF NOT EXISTS song_artists (
    \\  song_id INTEGER NOT NULL,
    \\  artist_id INTEGER NOT NULL,
    \\  FOREIGN KEY(song_id) REFERENCES songs(id) ON DELETE CASCADE,
    \\  FOREIGN KEY(artist_id) REFERENCES artists(id) ON DELETE CASCADE,
    \\  PRIMARY KEY(song_id, artist_id));
    ,
    \\CREATE TABLE IF NOT EXISTS song_genres (
    \\  song_id INTEGER NOT NULL,
    \\  genre_id INTEGER NOT NULL,
    \\  FOREIGN KEY(song_id) REFERENCES songs(id) ON DELETE CASCADE,
    \\  FOREIGN KEY(genre_id) REFERENCES genres(id) ON DELETE CASCADE,
    \\  PRIMARY KEY(song_id, genre_id));
    ,
};

const song_cols =
    \\SELECT id, song_path,
    \\       COALESCE(title, ''),
    \\       COALESCE(album_id, -1),
    \\       COALESCE(track, 0),
    \\       COALESCE(comment, ''),
    \\       COALESCE(duration, 0)
    \\FROM songs
;

pub const Database = struct {
    allocator: std.mem.Allocator,
    raw: sqlite.Db,

    /// Open (creating if needed) a database at `path`, or an in-memory one when
    /// `path` is null. Enables FK constraints and creates the schema.
    pub fn open(allocator: std.mem.Allocator, path: ?[:0]const u8) !Database {
        var raw = if (path) |p|
            try sqlite.Db.init(.{
                .mode = .{ .File = p },
                .open_flags = .{ .write = true, .create = true },
            })
        else
            try sqlite.Db.init(.{ .mode = .{ .Memory = {} }, .open_flags = .{ .write = true } });
        errdefer raw.deinit();

        try raw.exec("PRAGMA foreign_keys = ON;", .{}, .{});
        // zig-sqlite's exec runs a single statement, so create each table separately.
        for (schema) |ddl| try raw.execDynamic(ddl, .{}, .{});

        return .{ .allocator = allocator, .raw = raw };
    }

    pub fn deinit(self: *Database) void {
        self.raw.deinit();
    }

    pub fn exec(self: *Database, comptime q: []const u8) !void {
        try self.raw.exec(q, .{}, .{});
    }

    pub fn begin(self: *Database) !void {
        try self.raw.exec("BEGIN;", .{}, .{});
    }
    pub fn commit(self: *Database) !void {
        try self.raw.exec("COMMIT;", .{}, .{});
    }
    pub fn rollback(self: *Database) !void {
        try self.raw.exec("ROLLBACK;", .{}, .{});
    }

    fn lastId(self: *Database) i64 {
        return self.raw.getLastInsertRowID();
    }

    // ---- insert helpers (return the new row id) ----

    pub fn addGenre(self: *Database, name: []const u8) !i64 {
        try self.raw.exec("INSERT INTO genres(name) VALUES(?);", .{}, .{name});
        return self.lastId();
    }

    pub fn addArtist(self: *Database, name: []const u8) !i64 {
        try self.raw.exec("INSERT INTO artists(name) VALUES(?);", .{}, .{name});
        return self.lastId();
    }

    pub fn addAlbum(self: *Database, title: []const u8, artist_id: i64, year: ?i64) !i64 {
        const y = year orelse -1;
        try self.raw.exec(
            "INSERT INTO albums(name, artist_id, year) VALUES(?, ?, ?);",
            .{},
            .{ title, artist_id, y },
        );
        return self.lastId();
    }

    pub fn addSong(
        self: *Database,
        path: []const u8,
        title: []const u8,
        album_id: i64,
        track: i64,
        duration: i64,
    ) !i64 {
        try self.raw.exec(
            "INSERT INTO songs(song_path, title, album_id, track, duration) VALUES(?, ?, ?, ?, ?);",
            .{},
            .{ path, title, album_id, track, duration },
        );
        return self.lastId();
    }

    // ---- reads ----

    /// All songs, ordered by id, allocated with `self.allocator` (strings too).
    /// Iterates manually: zig-sqlite's `.all` uses `std.ArrayList(Type) = .{}`
    /// which doesn't compile against 0.16's unmanaged ArrayList.
    pub fn getAllSongs(self: *Database) ![]entity.Song {
        var stmt = try self.raw.prepareDynamic(song_cols ++ ";");
        defer stmt.deinit();
        var iter = try stmt.iteratorAlloc(entity.Song, self.allocator, .{});
        var list = std.ArrayList(entity.Song){ .items = &.{}, .capacity = 0 };
        defer list.deinit(self.allocator);
        while (try iter.nextAlloc(self.allocator, .{})) |row| {
            try list.append(self.allocator, row);
        }
        return list.toOwnedSlice(self.allocator);
    }

    pub fn getSongById(self: *Database, id: i64) !?entity.Song {
        var stmt = try self.raw.prepareDynamic(song_cols ++ " WHERE id = ?;");
        defer stmt.deinit();
        return try stmt.oneAlloc(entity.Song, self.allocator, .{}, .{id});
    }

    /// The file path for a song id, or null if absent.
    pub fn getSongPathById(self: *Database, id: i64) !?[]const u8 {
        var stmt = try self.raw.prepareDynamic("SELECT song_path FROM songs WHERE id = ?;");
        defer stmt.deinit();
        const PathRow = struct { song_path: []const u8 };
        const row = try stmt.oneAlloc(PathRow, self.allocator, .{}, .{id});
        return if (row) |r| r.song_path else null;
    }
};

test "database: schema, insert, and query round-trip (in-memory)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var db = try Database.open(arena.allocator(), null);
    defer db.deinit();

    const artist_id = try db.addArtist("The Example Band");
    const album_id = try db.addAlbum("Test Record", artist_id, 2024);
    const s1 = try db.addSong("/music/a.ogg", "Track A", album_id, 1, 120);
    const s2 = try db.addSong("/music/b.ogg", "Track B", album_id, 2, 180);
    try std.testing.expect(s1 != s2);

    const by_id = try db.getSongById(s2);
    try std.testing.expect(by_id != null);
    try std.testing.expectEqualStrings("Track B", by_id.?.title);
    try std.testing.expectEqual(@as(i64, 2), by_id.?.track);
    try std.testing.expectEqual(@as(i64, album_id), by_id.?.album_id);

    const all = try db.getAllSongs();
    try std.testing.expectEqual(@as(usize, 2), all.len);
    try std.testing.expectEqualStrings("/music/b.ogg", all[1].path);

    const path = try db.getSongPathById(s1);
    try std.testing.expect(path != null);
    try std.testing.expectEqualStrings("/music/a.ogg", path.?);
}

test "database: rollback discards pending inserts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var db = try Database.open(arena.allocator(), null);
    defer db.deinit();

    try db.begin();
    const artist = try db.addArtist("R");
    const album = try db.addAlbum("Rollback", artist, 2000);
    _ = try db.addSong("/x.ogg", "X", album, 1, 10);
    try db.rollback();

    const songs = try db.getAllSongs();
    try std.testing.expectEqual(@as(usize, 0), songs.len);
}
