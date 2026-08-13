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
    \\  disc_number INTEGER DEFAULT 1,
    \\  play_count INTEGER DEFAULT 0,
    \\  last_played INTEGER,
    \\  favorite INTEGER DEFAULT 0,
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
    \\  FOREIGN KEY(artist_id) REFERENCES artists(id) ON DELETE CASCADE,
    \\  UNIQUE(name, artist_id));
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
    \\  desc TEXT,
    \\  created_at INTEGER);
    ,
    \\CREATE TABLE IF NOT EXISTS album_artists (
    \\  album_id INTEGER NOT NULL,
    \\  artist_id INTEGER NOT NULL,
    \\  FOREIGN KEY(album_id) REFERENCES albums(id) ON DELETE CASCADE,
    \\  FOREIGN KEY(artist_id) REFERENCES artists(id) ON DELETE CASCADE,
    \\  PRIMARY KEY(album_id, artist_id));
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

/// CREATE INDEX IF NOT EXISTS for the FK columns (SQLite doesn't auto-index FKs).
const indexes = [_][]const u8{
    "CREATE INDEX IF NOT EXISTS idx_songs_album ON songs(album_id);",
    "CREATE INDEX IF NOT EXISTS idx_sa_song ON song_artists(song_id);",
    "CREATE INDEX IF NOT EXISTS idx_sa_artist ON song_artists(artist_id);",
    "CREATE INDEX IF NOT EXISTS idx_sg_song ON song_genres(song_id);",
    "CREATE INDEX IF NOT EXISTS idx_sg_genre ON song_genres(genre_id);",
    "CREATE INDEX IF NOT EXISTS idx_ps_song ON playlist_songs(song_id);",
    "CREATE INDEX IF NOT EXISTS idx_genre_parent ON genres(parent_id);",
};

const song_cols =
    \\SELECT id, song_path,
    \\       COALESCE(title, ''),
    \\       COALESCE(album_id, -1),
    \\       COALESCE(track, 0),
    \\       COALESCE(comment, ''),
    \\       COALESCE(duration, 0),
    \\       COALESCE(disc_number, 1),
    \\       COALESCE(play_count, 0),
    \\       COALESCE(last_played, -1),
    \\       COALESCE(favorite, 0)
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
        for (indexes) |idx| try raw.execDynamic(idx, .{}, .{});

        var db = Database{ .allocator = allocator, .raw = raw };
        try db.migrate();
        return db;
    }

    /// Best-effort migration for databases created with an older schema:
    /// adds the columns that were introduced after the first release.
    fn migrate(self: *Database) !void {
        try self.ensureColumn("songs", "disc_number", "ALTER TABLE songs ADD COLUMN disc_number INTEGER DEFAULT 1;");
        try self.ensureColumn("songs", "play_count", "ALTER TABLE songs ADD COLUMN play_count INTEGER DEFAULT 0;");
        try self.ensureColumn("songs", "last_played", "ALTER TABLE songs ADD COLUMN last_played INTEGER;");
        try self.ensureColumn("songs", "favorite", "ALTER TABLE songs ADD COLUMN favorite INTEGER DEFAULT 0;");
        try self.ensureColumn("playlists", "created_at", "ALTER TABLE playlists ADD COLUMN created_at INTEGER;");
    }

    fn doesColumnExist(self: *Database, table: []const u8, column: []const u8) !bool {
        const q = try std.fmt.allocPrint(self.allocator, "SELECT COUNT(*) FROM pragma_table_info('{s}') WHERE name='{s}';", .{ table, column });
        defer self.allocator.free(q);
        var stmt = try self.raw.prepareDynamic(q);
        defer stmt.deinit();
        const count = try stmt.one(i64, .{}, .{});
        return (count orelse 0) > 0;
    }

    fn ensureColumn(self: *Database, table: []const u8, column: []const u8, ddl: []const u8) !void {
        if (try self.doesColumnExist(table, column)) return;
        try self.raw.execDynamic(ddl, .{}, .{});
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
        disc_number: i64,
    ) !i64 {
        try self.raw.exec(
            "INSERT INTO songs(song_path, title, album_id, track, duration, disc_number) VALUES(?, ?, ?, ?, ?, ?);",
            .{},
            .{ path, title, album_id, track, duration, disc_number },
        );
        return self.lastId();
    }

    // ---- album cover helpers (MusicBrainz release group ids) ----

    pub const AlbumMbid = struct {
        album_id: i64,
        mbid: []const u8,
    };

    /// album_id + musicbrainz_release_group_id for every album that has one.
    pub fn getAllAlbumMbids(self: *Database) ![]AlbumMbid {
        var stmt = try self.raw.prepareDynamic(
            "SELECT id, COALESCE(musicbrainz_release_group_id, '') FROM albums WHERE musicbrainz_release_group_id IS NOT NULL AND musicbrainz_release_group_id != '';",
        );
        defer stmt.deinit();
        var iter = try stmt.iteratorAlloc(AlbumMbid, self.allocator, .{});
        var list = std.ArrayList(AlbumMbid){ .items = &.{}, .capacity = 0 };
        defer list.deinit(self.allocator);
        while (try iter.nextAlloc(self.allocator, .{})) |row| {
            try list.append(self.allocator, row);
        }
        return list.toOwnedSlice(self.allocator);
    }

    /// Persist a resolved MusicBrainz release group id for an album.
    pub fn setAlbumMbid(self: *Database, album_id: i64, mbid: []const u8) !void {
        try self.raw.exec("UPDATE albums SET musicbrainz_release_group_id = ? WHERE id = ?;", .{}, .{ mbid, album_id });
    }

    // ---- reads ----

    /// Record a playback: bump `play_count` and set `last_played` (epoch secs).
    pub fn markPlayed(self: *Database, id: i64, now_secs: i64) !void {
        try self.raw.exec(
            "UPDATE songs SET play_count = play_count + 1, last_played = ? WHERE id = ?;",
            .{},
            .{ now_secs, id },
        );
    }

    /// Set the favorite (0/1) flag for a song.
    pub fn setFavorite(self: *Database, id: i64, favorite: i64) !void {
        try self.raw.exec("UPDATE songs SET favorite = ? WHERE id = ?;", .{}, .{ favorite, id });
    }

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

    pub const SongContext = struct { artist: []const u8, album: []const u8 };

    /// Artist + album names for a song (null if it has no album/artist).
    pub fn getSongContext(self: *Database, song_id: i64) !?SongContext {
        var stmt = try self.raw.prepareDynamic(
            "SELECT COALESCE(a.name,''), COALESCE(al.name,'') FROM songs s JOIN albums al ON al.id = s.album_id JOIN artists a ON a.id = al.artist_id WHERE s.id = ?;",
        );
        defer stmt.deinit();
        const Row = struct { artist: []const u8, album: []const u8 };
        const r = try stmt.oneAlloc(Row, self.allocator, .{}, .{ song_id });
        return if (r) |row| .{ .artist = row.artist, .album = row.album } else null;
    }

    /// The file path for a song id, or null if absent.
    pub fn getSongPathById(self: *Database, id: i64) !?[]const u8 {
        var stmt = try self.raw.prepareDynamic("SELECT song_path FROM songs WHERE id = ?;");
        defer stmt.deinit();
        const PathRow = struct { song_path: []const u8 };
        const row = try stmt.oneAlloc(PathRow, self.allocator, .{}, .{id});
        return if (row) |r| r.song_path else null;
    }

    // ---- scanner helpers ----

    pub const SongImportInfo = struct {
        id: i64,
        file_size: i64,
        file_mtime_ticks: i64,
    };

    /// Existing row for a path (for change detection), or null.
    pub fn getSongImportInfoByPath(self: *Database, path: []const u8) !?SongImportInfo {
        var stmt = try self.raw.prepareDynamic(
            "SELECT id, COALESCE(file_size, -1), COALESCE(file_mtime_ticks, -1) FROM songs WHERE song_path = ?;",
        );
        defer stmt.deinit();
        const Row = struct { id: i64, file_size: i64, file_mtime_ticks: i64 };
        const r = try stmt.one(Row, .{}, .{path});
        return if (r) |row| .{ .id = row.id, .file_size = row.file_size, .file_mtime_ticks = row.file_mtime_ticks } else null;
    }

    pub fn getOrCreateArtist(self: *Database, name: []const u8) !i64 {
        try self.raw.exec("INSERT OR IGNORE INTO artists(name) VALUES(?);", .{}, .{name});
        const Row = struct { id: i64 };
        var stmt = try self.raw.prepareDynamic("SELECT id FROM artists WHERE name = ?;");
        defer stmt.deinit();
        const row = (try stmt.one(Row, .{}, .{name})) orelse return error.ArtistNotFound;
        return row.id;
    }

    pub fn getOrCreateAlbum(self: *Database, title: []const u8, artist_id: i64, year: ?i64) !i64 {
        const y = year orelse -1;
        try self.raw.exec(
            "INSERT OR IGNORE INTO albums(name, artist_id, year) VALUES(?, ?, ?);",
            .{},
            .{ title, artist_id, y },
        );
        const Row = struct { id: i64 };
        var stmt = try self.raw.prepareDynamic("SELECT id FROM albums WHERE name = ? AND artist_id = ?;");
        defer stmt.deinit();
        const row = (try stmt.one(Row, .{}, .{ title, artist_id })) orelse return error.AlbumNotFound;
        return row.id;
    }

    /// Update an existing song's metadata + file fingerprint.
    pub fn updateSong(
        self: *Database,
        id: i64,
        title: []const u8,
        album_id: i64,
        track: i64,
        disc_number: i64,
        duration: i64,
        file_size: i64,
        file_mtime_ticks: i64,
    ) !void {
        try self.raw.exec(
            "UPDATE songs SET title=?, album_id=?, track=?, disc_number=?, duration=?, file_size=?, file_mtime_ticks=? WHERE id=?;",
            .{},
            .{ title, album_id, track, disc_number, duration, file_size, file_mtime_ticks, id },
        );
    }

    pub fn deleteSongById(self: *Database, id: i64) !void {
        try self.raw.exec("DELETE FROM songs WHERE id=?;", .{}, .{id});
    }

    /// Record the on-disk fingerprint (size + mtime) for change detection.
    pub fn setSongFileState(self: *Database, id: i64, file_size: i64, file_mtime_ticks: i64) !void {
        try self.raw.exec(
            "UPDATE songs SET file_size=?, file_mtime_ticks=? WHERE id=?;",
            .{},
            .{ file_size, file_mtime_ticks, id },
        );
    }
};

test "database: schema, insert, and query round-trip (in-memory)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var db = try Database.open(arena.allocator(), null);
    defer db.deinit();

    const artist_id = try db.addArtist("The Example Band");
    const album_id = try db.addAlbum("Test Record", artist_id, 2024);
    const s1 = try db.addSong("/music/a.ogg", "Track A", album_id, 1, 120, 1);
    const s2 = try db.addSong("/music/b.ogg", "Track B", album_id, 2, 180, 1);
    try std.testing.expect(s1 != s2);

    const by_id = try db.getSongById(s2);
    try std.testing.expect(by_id != null);
    try std.testing.expectEqualStrings("Track B", by_id.?.title);
    try std.testing.expectEqual(@as(i64, 2), by_id.?.track);
    try std.testing.expectEqual(@as(i64, album_id), by_id.?.album_id);
    // new columns: defaults after insert
    try std.testing.expectEqual(@as(i64, 1), by_id.?.disc_number);
    try std.testing.expectEqual(@as(i64, 0), by_id.?.play_count);
    try std.testing.expectEqual(@as(i64, -1), by_id.?.last_played);
    try std.testing.expectEqual(@as(i64, 0), by_id.?.favorite);

    // disc_number round-trips through the column
    _ = try db.addSong("/music/d1.ogg", "Disc Track", album_id, 1, 150, 2);
    const d = (try db.getSongById(s2 + 1));
    try std.testing.expectEqual(@as(i64, 2), d.?.disc_number);

    const all = try db.getAllSongs();
    try std.testing.expectEqual(@as(usize, 3), all.len);
    try std.testing.expectEqualStrings("/music/b.ogg", all[1].path);

    const path = try db.getSongPathById(s1);
    try std.testing.expect(path != null);
    try std.testing.expectEqualStrings("/music/a.ogg", path.?);
}

test "database: player-state updates (markPlayed, setFavorite)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var db = try Database.open(arena.allocator(), null);
    defer db.deinit();

    const artist = try db.addArtist("P");
    const album = try db.addAlbum("PA", artist, 2021);
    const s = try db.addSong("/p/x.ogg", "X", album, 1, 60, 1);

    try db.markPlayed(s, 1000);
    try db.markPlayed(s, 2000);
    try db.setFavorite(s, 1);

    const row = (try db.getSongById(s)).?;
    try std.testing.expectEqual(@as(i64, 2), row.play_count);
    try std.testing.expectEqual(@as(i64, 2000), row.last_played);
    try std.testing.expectEqual(@as(i64, 1), row.favorite);
}

test "database: rollback discards pending inserts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var db = try Database.open(arena.allocator(), null);
    defer db.deinit();

    try db.begin();
    const artist = try db.addArtist("R");
    const album = try db.addAlbum("Rollback", artist, 2000);
    _ = try db.addSong("/x.ogg", "X", album, 1, 10, 1);
    try db.rollback();

    const songs = try db.getAllSongs();
    try std.testing.expectEqual(@as(usize, 0), songs.len);
}
