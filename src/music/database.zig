//! SQLite-backed music database, port of `database/MusicDatabase` from
//! audio-visualizer-cpp, built on the vendored `zig-sqlite` wrapper.
//!
//! Scope: schema creation, transactions, inserting entities, and the read
//! queries the Library layer needs. (The taglib-based scanner that feeds this
//! is intentionally not ported yet; rows are inserted programmatically.)

const std = @import("std");
const sqlite = @import("sqlite");
const entity = @import("entity.zig");

/// Increment when scanner metadata interpretation changes and existing rows
/// must be re-extracted.
pub const current_metadata_version: i64 = 4;
const current_metadata_version_sql = std.fmt.comptimePrint("{d}", .{current_metadata_version});

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
    \\  metadata_version INTEGER DEFAULT 0,
    \\  file_fingerprint INTEGER DEFAULT -1,
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
    \\  album_group_key TEXT NOT NULL DEFAULT '',
    \\  artist_id INTEGER,
    \\  FOREIGN KEY(artist_id) REFERENCES artists(id) ON DELETE CASCADE,
    \\  UNIQUE(name, artist_id, album_group_key));
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
    "CREATE INDEX IF NOT EXISTS idx_sa_artist_song ON song_artists(artist_id, song_id);",
    "CREATE INDEX IF NOT EXISTS idx_album_artist ON albums(artist_id);",
    "CREATE INDEX IF NOT EXISTS idx_aa_artist_album ON album_artists(artist_id, album_id);",
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
        // Zero marks rows imported before the current metadata model; the next
        // scan re-extracts them even when their file fingerprint is unchanged.
        try self.ensureColumn("songs", "metadata_version", "ALTER TABLE songs ADD COLUMN metadata_version INTEGER DEFAULT 0;");
        try self.ensureColumn("songs", "file_fingerprint", "ALTER TABLE songs ADD COLUMN file_fingerprint INTEGER DEFAULT -1;");
        try self.ensureColumn("albums", "album_group_key", "ALTER TABLE albums ADD COLUMN album_group_key TEXT NOT NULL DEFAULT '';");
        try self.migrateAlbumIdentityConstraint();
        try self.ensureColumn("playlists", "created_at", "ALTER TABLE playlists ADD COLUMN created_at INTEGER;");
    }

    /// Rebuild the small relational core when upgrading from the original
    /// UNIQUE(name, artist_id) album constraint. SQLite cannot drop an auto
    /// index, so recreate the tables while preserving ids and all junctions.
    fn migrateAlbumIdentityConstraint(self: *Database) !void {
        const column_count = blk: {
            var stmt = try self.raw.prepareDynamic(
                "SELECT COUNT(*) FROM pragma_index_info((SELECT name FROM pragma_index_list('albums') WHERE \"unique\"=1 LIMIT 1));",
            );
            defer stmt.deinit();
            break :blk (try stmt.one(i64, .{}, .{})) orelse 0;
        };
        if (column_count != 2) return;

        try self.raw.exec("PRAGMA foreign_keys=OFF;", .{}, .{});
        var committed = false;
        errdefer {
            if (!committed) self.raw.exec("ROLLBACK;", .{}, .{}) catch {};
            self.raw.exec("PRAGMA foreign_keys=ON;", .{}, .{}) catch {};
        }
        try self.raw.exec("BEGIN;", .{}, .{});
        const drop_indexes = [_][]const u8{
            "DROP INDEX IF EXISTS idx_songs_album;",
            "DROP INDEX IF EXISTS idx_sa_song;",
            "DROP INDEX IF EXISTS idx_sa_artist;",
            "DROP INDEX IF EXISTS idx_sg_song;",
            "DROP INDEX IF EXISTS idx_sg_genre;",
            "DROP INDEX IF EXISTS idx_ps_song;",
        };
        for (drop_indexes) |sql| try self.raw.execDynamic(sql, .{}, .{});

        const renames = [_][]const u8{
            "ALTER TABLE playlist_songs RENAME TO playlist_songs_old;",
            "ALTER TABLE song_artists RENAME TO song_artists_old;",
            "ALTER TABLE song_genres RENAME TO song_genres_old;",
            "ALTER TABLE album_artists RENAME TO album_artists_old;",
            "ALTER TABLE songs RENAME TO songs_old;",
            "ALTER TABLE albums RENAME TO albums_old;",
        };
        for (renames) |sql| try self.raw.execDynamic(sql, .{}, .{});
        for (schema) |ddl| try self.raw.execDynamic(ddl, .{}, .{});

        try self.raw.exec(
            "INSERT INTO albums(id, release_type, name, year, picture_path, musicbrainz_release_group_id, cover_art_block, cover_art_mime, album_group_key, artist_id) " ++
                "SELECT id, release_type, name, year, picture_path, musicbrainz_release_group_id, cover_art_block, cover_art_mime, album_group_key, artist_id FROM albums_old;",
            .{},
            .{},
        );
        try self.raw.exec(
            "INSERT INTO songs(id, song_path, title, album_id, track, comment, duration, disc_number, play_count, last_played, favorite, metadata_version, file_fingerprint, file_size, file_mtime_ticks) " ++
                "SELECT id, song_path, title, album_id, track, comment, duration, disc_number, play_count, last_played, favorite, metadata_version, file_fingerprint, file_size, file_mtime_ticks FROM songs_old;",
            .{},
            .{},
        );
        try self.raw.exec("INSERT INTO album_artists SELECT * FROM album_artists_old;", .{}, .{});
        try self.raw.exec("INSERT INTO song_artists SELECT * FROM song_artists_old;", .{}, .{});
        try self.raw.exec("INSERT INTO song_genres SELECT * FROM song_genres_old;", .{}, .{});
        try self.raw.exec("INSERT INTO playlist_songs SELECT * FROM playlist_songs_old;", .{}, .{});

        // Commit the replacement tables before dropping the legacy copies;
        // SQLite can retain schema locks for DDL until the transaction ends.
        try self.raw.exec("COMMIT;", .{}, .{});
        committed = true;
        const drops = [_][]const u8{
            "DROP TABLE playlist_songs_old;",
            "DROP TABLE song_artists_old;",
            "DROP TABLE song_genres_old;",
            "DROP TABLE album_artists_old;",
            "DROP TABLE songs_old;",
            "DROP TABLE albums_old;",
        };
        for (drops) |sql| try self.raw.execDynamic(sql, .{}, .{});
        try self.raw.exec("PRAGMA foreign_keys=ON;", .{}, .{});
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
        return self.addAlbumWithGroupKey(title, artist_id, year, "");
    }

    pub fn addAlbumWithGroupKey(self: *Database, title: []const u8, artist_id: i64, year: ?i64, group_key: []const u8) !i64 {
        const y = year orelse -1;
        try self.raw.exec(
            "INSERT INTO albums(name, artist_id, year, album_group_key) VALUES(?, ?, ?, ?);",
            .{},
            .{ title, artist_id, y, group_key },
        );
        return self.lastId();
    }

    /// Resolve an album when the files do not provide ALBUMARTIST. The first
    /// track supplies a provisional artist; a later different track artist
    /// promotes the album to Various Artists instead of splitting the album.
    pub fn getOrCreateAlbumWithoutAlbumArtist(self: *Database, title: []const u8, track_artist_id: i64, year: ?i64, group_key: []const u8) !i64 {
        const Row = struct { id: i64, artist_id: i64, has_group_key: i64 };
        var stmt = try self.raw.prepareDynamic(
            "SELECT id, COALESCE(artist_id, -1), (album_group_key != '') FROM albums WHERE name = ? AND (album_group_key = ? OR album_group_key = '') " ++
                "ORDER BY CASE WHEN album_group_key = ? THEN 0 ELSE 1 END, id LIMIT 1;",
        );
        defer stmt.deinit();
        if (try stmt.one(Row, .{}, .{ title, group_key, group_key })) |row| {
            const y = year orelse -1;
            if (y > 0) {
                try self.raw.exec("UPDATE albums SET year=? WHERE id=? AND (year IS NULL OR year < 1);", .{}, .{ y, row.id });
            }
            if (row.has_group_key == 0 and group_key.len > 0) {
                try self.raw.exec("UPDATE albums SET album_group_key=? WHERE id=?;", .{}, .{ group_key, row.id });
            }
            if (row.artist_id != track_artist_id) {
                const various_id = try self.getOrCreateArtist("Various Artists");
                try self.raw.exec("UPDATE albums SET artist_id=? WHERE id=?;", .{}, .{ various_id, row.id });
                try self.addAlbumArtist(row.id, various_id);
            }
            return row.id;
        }
        return self.addAlbumWithGroupKey(title, track_artist_id, year, group_key);
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
        return self.addSongWithMetadata(path, title, album_id, track, "", duration, disc_number);
    }

    pub fn addSongWithMetadata(
        self: *Database,
        path: []const u8,
        title: []const u8,
        album_id: i64,
        track: i64,
        comment: []const u8,
        duration: i64,
        disc_number: i64,
    ) !i64 {
        try self.raw.exec(
            "INSERT INTO songs(song_path, title, album_id, track, comment, duration, disc_number, metadata_version) VALUES(?, ?, ?, ?, ?, ?, ?, " ++ current_metadata_version_sql ++ ");",
            .{},
            .{ path, title, album_id, track, comment, duration, disc_number },
        );
        return self.lastId();
    }

    pub fn getOrCreateGenre(self: *Database, name: []const u8) !i64 {
        try self.raw.exec("INSERT OR IGNORE INTO genres(name) VALUES(?);", .{}, .{name});
        const Row = struct { id: i64 };
        var stmt = try self.raw.prepareDynamic("SELECT id FROM genres WHERE name = ?;");
        defer stmt.deinit();
        const row = (try stmt.one(Row, .{}, .{name})) orelse return error.GenreNotFound;
        return row.id;
    }

    pub fn addSongArtist(self: *Database, song_id: i64, artist_id: i64) !void {
        try self.raw.exec("INSERT OR IGNORE INTO song_artists(song_id, artist_id) VALUES(?, ?);", .{}, .{ song_id, artist_id });
    }

    pub fn addAlbumArtist(self: *Database, album_id: i64, artist_id: i64) !void {
        try self.raw.exec("INSERT OR IGNORE INTO album_artists(album_id, artist_id) VALUES(?, ?);", .{}, .{ album_id, artist_id });
    }

    pub fn clearAlbumArtists(self: *Database, album_id: i64) !void {
        try self.raw.exec("DELETE FROM album_artists WHERE album_id=?;", .{}, .{album_id});
    }

    pub fn addSongGenre(self: *Database, song_id: i64, genre_id: i64) !void {
        try self.raw.exec("INSERT OR IGNORE INTO song_genres(song_id, genre_id) VALUES(?, ?);", .{}, .{ song_id, genre_id });
    }

    pub fn clearSongAssociations(self: *Database, song_id: i64) !void {
        try self.raw.exec("DELETE FROM song_artists WHERE song_id = ?;", .{}, .{song_id});
        try self.raw.exec("DELETE FROM song_genres WHERE song_id = ?;", .{}, .{song_id});
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

    /// Store embedded/folder album art for an album (BLOB + mime).
    pub fn setAlbumCover(self: *Database, album_id: i64, mime: []const u8, bytes: []const u8) !void {
        try self.raw.exec(
            "UPDATE albums SET cover_art_mime = ?, cover_art_block = ? WHERE id = ?;",
            .{},
            .{ mime, sqlite.Blob{ .data = bytes }, album_id },
        );
    }

    pub const AlbumCover = struct {
        mime: []const u8,
        bytes: []const u8,
    };

    pub fn getAlbumsMissingCoverWithAllocator(self: *Database, allocator: std.mem.Allocator) ![]i64 {
        var stmt = try self.raw.prepareDynamic("SELECT id FROM albums WHERE cover_art_block IS NULL OR length(cover_art_block)=0 ORDER BY id;");
        defer stmt.deinit();
        var iter = try stmt.iteratorAlloc(i64, allocator, .{});
        var list = std.ArrayList(i64){ .items = &.{}, .capacity = 0 };
        defer list.deinit(allocator);
        while (try iter.nextAlloc(allocator, .{})) |id| try list.append(allocator, id);
        return list.toOwnedSlice(allocator);
    }

    /// Album art for an album, or null if none is stored.
    pub fn getAlbumCover(self: *Database, album_id: i64) !?AlbumCover {
        return self.getAlbumCoverWithAllocator(self.allocator, album_id);
    }

    /// Variant for short-lived UI/scanner queries. The caller owns the
    /// returned strings/bytes through `allocator`.
    pub fn getAlbumCoverWithAllocator(self: *Database, allocator: std.mem.Allocator, album_id: i64) !?AlbumCover {
        var stmt = try self.raw.prepareDynamic(
            "SELECT COALESCE(cover_art_mime, ''), cover_art_block FROM albums WHERE id = ?;",
        );
        defer stmt.deinit();
        const Row = struct { mime: []const u8, bytes: ?[]const u8 };
        const row = try stmt.oneAlloc(Row, allocator, .{}, .{album_id});
        return if (row) |r|
            if (r.bytes) |b|
                if (b.len > 0) .{ .mime = r.mime, .bytes = b } else null
            else
                null
        else
            null;
    }

    // ---- artist / genre browsing ----

    pub const ArtistListing = struct {
        id: i64,
        name: []const u8,
        song_count: i64,
        album_count: i64,
    };

    pub const GenreListing = struct {
        id: i64,
        name: []const u8,
        song_count: i64,
    };

    pub fn getArtistsWithAllocator(self: *Database, allocator: std.mem.Allocator) ![]ArtistListing {
        var stmt = try self.raw.prepareDynamic(
            "WITH artist_songs AS (" ++
                "SELECT artist_id, song_id FROM song_artists " ++
                "UNION SELECT a.artist_id, s.id FROM albums a JOIN songs s ON s.album_id=a.id " ++
                "UNION SELECT aa.artist_id, s.id FROM album_artists aa JOIN songs s ON s.album_id=aa.album_id" ++
                "), song_counts AS (SELECT artist_id, COUNT(*) AS song_count FROM artist_songs GROUP BY artist_id), " ++
                "artist_albums AS (" ++
                "SELECT artist_id, id AS album_id FROM albums WHERE artist_id IS NOT NULL " ++
                "UNION SELECT artist_id, album_id FROM album_artists" ++
                "), album_counts AS (SELECT artist_id, COUNT(*) AS album_count FROM artist_albums GROUP BY artist_id) " ++
                "SELECT ar.id, ar.name, COALESCE(sc.song_count, 0) AS song_count, " ++
                "COALESCE(ac.album_count, 0) AS album_count FROM artists ar " ++
                "LEFT JOIN song_counts sc ON sc.artist_id=ar.id " ++
                "LEFT JOIN album_counts ac ON ac.artist_id=ar.id " ++
                "ORDER BY ar.name COLLATE NOCASE;",
        );
        defer stmt.deinit();
        var iter = try stmt.iteratorAlloc(ArtistListing, allocator, .{});
        var list = std.ArrayList(ArtistListing){ .items = &.{}, .capacity = 0 };
        defer list.deinit(allocator);
        while (try iter.nextAlloc(allocator, .{})) |row| try list.append(allocator, row);
        return list.toOwnedSlice(allocator);
    }

    pub fn getGenresWithAllocator(self: *Database, allocator: std.mem.Allocator) ![]GenreListing {
        var stmt = try self.raw.prepareDynamic(
            "SELECT g.id, g.name, COUNT(DISTINCT sg.song_id) AS song_count FROM genres g " ++
                "LEFT JOIN song_genres sg ON sg.genre_id=g.id GROUP BY g.id, g.name " ++
                "ORDER BY g.name COLLATE NOCASE;",
        );
        defer stmt.deinit();
        var iter = try stmt.iteratorAlloc(GenreListing, allocator, .{});
        var list = std.ArrayList(GenreListing){ .items = &.{}, .capacity = 0 };
        defer list.deinit(allocator);
        while (try iter.nextAlloc(allocator, .{})) |row| try list.append(allocator, row);
        return list.toOwnedSlice(allocator);
    }

    pub fn getSongsByArtistWithAllocator(self: *Database, allocator: std.mem.Allocator, artist_id: i64) ![]entity.Song {
        var stmt = try self.raw.prepareDynamic(song_cols ++
            " JOIN (SELECT artist_id, song_id FROM song_artists " ++
            "UNION SELECT a.artist_id, s.id FROM albums a JOIN songs s ON s.album_id=a.id " ++
            "UNION SELECT aa.artist_id, s.id FROM album_artists aa JOIN songs s ON s.album_id=aa.album_id) artist_songs " ++
            "ON artist_songs.song_id=songs.id WHERE artist_songs.artist_id=? " ++
            "ORDER BY disc_number, track, id;");
        defer stmt.deinit();
        var iter = try stmt.iteratorAlloc(entity.Song, allocator, .{artist_id});
        var list = std.ArrayList(entity.Song){ .items = &.{}, .capacity = 0 };
        defer list.deinit(allocator);
        while (try iter.nextAlloc(allocator, .{})) |row| try list.append(allocator, row);
        return list.toOwnedSlice(allocator);
    }

    pub fn getSongsByGenreWithAllocator(self: *Database, allocator: std.mem.Allocator, genre_id: i64) ![]entity.Song {
        var stmt = try self.raw.prepareDynamic(song_cols ++
            " JOIN song_genres sg ON sg.song_id=songs.id WHERE sg.genre_id=? " ++
            "ORDER BY disc_number, track, id;");
        defer stmt.deinit();
        var iter = try stmt.iteratorAlloc(entity.Song, allocator, .{genre_id});
        var list = std.ArrayList(entity.Song){ .items = &.{}, .capacity = 0 };
        defer list.deinit(allocator);
        while (try iter.nextAlloc(allocator, .{})) |row| try list.append(allocator, row);
        return list.toOwnedSlice(allocator);
    }

    // ---- album listing / playback -//-

    pub fn getAlbumById(self: *Database, album_id: i64) !?entity.Album {
        var stmt = try self.raw.prepareDynamic(
            "SELECT id, COALESCE(name,''), COALESCE(year,-1), COALESCE(picture_path,''), " ++
                "COALESCE(artist_id,-1), COALESCE(musicbrainz_release_group_id,'') " ++
                "FROM albums WHERE id=?;",
        );
        defer stmt.deinit();
        return try stmt.oneAlloc(entity.Album, self.allocator, .{}, .{album_id});
    }

    /// Album browser sort order.
    pub const AlbumSort = enum { by_name, by_year, by_artist };

    /// One row of the album browser: the album, its primary artist, the number
    /// of tracks (songs) in it, and whether we have stored cover art.
    pub const AlbumListing = struct {
        id: i64,
        name: []const u8,
        artist: []const u8,
        year: i64,
        track_count: i64,
        has_cover: bool,
    };

    /// Every album, joined with its primary artist and track count, ordered by
    /// `sort`. Allocated with `self.allocator` (strings too).
    pub fn getAlbums(self: *Database, sort: AlbumSort) ![]AlbumListing {
        return self.getAlbumsWithAllocator(self.allocator, sort);
    }

    pub fn getAlbumsWithAllocator(self: *Database, allocator: std.mem.Allocator, sort: AlbumSort) ![]AlbumListing {
        const order = switch (sort) {
            .by_name => "COALESCE(a.name,'') COLLATE NOCASE",
            .by_year => "a.year DESC, COALESCE(a.name,'') COLLATE NOCASE",
            .by_artist => "COALESCE(ar.name,'') COLLATE NOCASE, COALESCE(a.name,'') COLLATE NOCASE",
        };
        var sql_buf: [512]u8 = undefined;
        const sql = try std.fmt.bufPrint(&sql_buf,
            \\SELECT a.id AS id, COALESCE(a.name,'') AS name, COALESCE(ar.name,'') AS artist, COALESCE(a.year,-1) AS year,
            \\       COUNT(s.id) AS track_count, (a.cover_art_block IS NOT NULL) AS has_cover
            \\FROM albums a
            \\JOIN artists ar ON ar.id = a.artist_id
            \\LEFT JOIN songs s ON s.album_id = a.id
            \\GROUP BY a.id
            \\ORDER BY {s};
        , .{order});
        var stmt = try self.raw.prepareDynamic(sql);
        defer stmt.deinit();
        const Row = struct { id: i64, name: []const u8, artist: []const u8, year: i64, track_count: i64, has_cover: i64 };
        var iter = try stmt.iteratorAlloc(Row, allocator, .{});
        var list = std.ArrayList(AlbumListing){ .items = &.{}, .capacity = 0 };
        defer list.deinit(allocator);
        while (try iter.nextAlloc(allocator, .{})) |row| {
            try list.append(allocator, .{
                .id = row.id,
                .name = row.name,
                .artist = row.artist,
                .year = row.year,
                .track_count = row.track_count,
                .has_cover = row.has_cover != 0,
            });
        }
        return list.toOwnedSlice(allocator);
    }

    /// All songs in an album, ordered by disc then track (then id). Rows are
    /// allocated with `self.allocator`.
    pub fn getSongsByAlbum(self: *Database, album_id: i64) ![]entity.Song {
        return self.getSongsByAlbumWithAllocator(self.allocator, album_id);
    }

    pub fn getSongsByAlbumWithAllocator(self: *Database, allocator: std.mem.Allocator, album_id: i64) ![]entity.Song {
        var stmt = try self.raw.prepareDynamic(song_cols ++ " WHERE album_id = ? ORDER BY disc_number, track, id;");
        defer stmt.deinit();
        var iter = try stmt.iteratorAlloc(entity.Song, allocator, .{album_id});
        var list = std.ArrayList(entity.Song){ .items = &.{}, .capacity = 0 };
        defer list.deinit(allocator);
        while (try iter.nextAlloc(allocator, .{})) |row| {
            try list.append(allocator, row);
        }
        return list.toOwnedSlice(allocator);
    }

    // ---- playlists ----

    pub const PlaylistListing = struct {
        id: i64,
        name: []const u8,
        description: []const u8 = "",
        song_count: i64,
    };

    pub fn createPlaylist(self: *Database, name: []const u8) !i64 {
        return self.createPlaylistWithDescription(name, "");
    }

    pub fn createPlaylistWithDescription(self: *Database, name: []const u8, description: []const u8) !i64 {
        try self.raw.exec("INSERT INTO playlists(name, desc, created_at) VALUES(?, ?, strftime('%s','now'));", .{}, .{ name, description });
        return self.lastId();
    }

    pub fn renamePlaylist(self: *Database, id: i64, name: []const u8) !void {
        try self.raw.exec("UPDATE playlists SET name=? WHERE id=?;", .{}, .{ name, id });
    }

    pub fn updatePlaylistDescription(self: *Database, id: i64, description: []const u8) !void {
        try self.raw.exec("UPDATE playlists SET desc=? WHERE id=?;", .{}, .{ description, id });
    }

    pub fn deletePlaylist(self: *Database, id: i64) !void {
        try self.raw.exec("DELETE FROM playlists WHERE id=?;", .{}, .{id});
    }

    pub fn getPlaylistsWithAllocator(self: *Database, allocator: std.mem.Allocator) ![]PlaylistListing {
        var stmt = try self.raw.prepareDynamic(
            "SELECT p.id AS id, p.name AS name, COALESCE(p.desc, '') AS description, " ++
                "COUNT(ps.song_id) AS song_count " ++
                "FROM playlists p LEFT JOIN playlist_songs ps ON ps.playlist_id=p.id " ++
                "GROUP BY p.id, p.name, p.desc ORDER BY p.name COLLATE NOCASE;",
        );
        defer stmt.deinit();
        const Row = PlaylistListing;
        var iter = try stmt.iteratorAlloc(Row, allocator, .{});
        var list = std.ArrayList(PlaylistListing){ .items = &.{}, .capacity = 0 };
        defer list.deinit(allocator);
        while (try iter.nextAlloc(allocator, .{})) |row| try list.append(allocator, row);
        return list.toOwnedSlice(allocator);
    }

    pub fn getPlaylistSongIds(self: *Database, playlist_id: i64) ![]i64 {
        return self.getPlaylistSongIdsWithAllocator(self.allocator, playlist_id);
    }

    /// Return playlist songs in their user-defined order.
    pub fn getPlaylistTracksWithAllocator(self: *Database, allocator: std.mem.Allocator, playlist_id: i64) ![]entity.Song {
        var stmt = try self.raw.prepareDynamic(song_cols ++
            " JOIN playlist_songs ps ON ps.song_id=songs.id WHERE ps.playlist_id=? " ++
            "ORDER BY ps.position;");
        defer stmt.deinit();
        var iter = try stmt.iteratorAlloc(entity.Song, allocator, .{playlist_id});
        var list = std.ArrayList(entity.Song){ .items = &.{}, .capacity = 0 };
        defer list.deinit(allocator);
        while (try iter.nextAlloc(allocator, .{})) |row| try list.append(allocator, row);
        return list.toOwnedSlice(allocator);
    }

    pub fn clearPlaylist(self: *Database, playlist_id: i64) !void {
        try self.raw.exec("DELETE FROM playlist_songs WHERE playlist_id=?;", .{}, .{playlist_id});
    }

    /// Replace playlist ordering atomically. The IDs must be unique songs in the
    /// playlist; callers can use getPlaylistSongIdsWithAllocator first.
    pub fn reorderPlaylist(self: *Database, playlist_id: i64, song_ids: []const i64) !void {
        try self.begin();
        errdefer self.rollback() catch {};
        try self.raw.exec("DELETE FROM playlist_songs WHERE playlist_id=?;", .{}, .{playlist_id});
        for (song_ids, 0..) |song_id, position| {
            try self.raw.exec(
                "INSERT INTO playlist_songs(playlist_id, song_id, position) VALUES(?, ?, ?);",
                .{},
                .{ playlist_id, song_id, @as(i64, @intCast(position)) },
            );
        }
        try self.commit();
    }

    pub fn addSongToPlaylist(self: *Database, playlist_id: i64, song_id: i64) !void {
        const Row = struct { position: i64 };
        var stmt = try self.raw.prepareDynamic("SELECT COALESCE(MAX(position), -1) + 1 FROM playlist_songs WHERE playlist_id=?;");
        defer stmt.deinit();
        const position = if (try stmt.one(Row, .{}, .{playlist_id})) |row| row.position else 0;
        try self.raw.exec("INSERT OR IGNORE INTO playlist_songs(playlist_id, song_id, position) VALUES(?, ?, ?);", .{}, .{ playlist_id, song_id, position });
    }

    pub fn removeSongFromPlaylist(self: *Database, playlist_id: i64, song_id: i64) !void {
        try self.raw.exec("DELETE FROM playlist_songs WHERE playlist_id=? AND song_id=?;", .{}, .{ playlist_id, song_id });
        try self.normalizePlaylistPositions(playlist_id);
    }

    /// Remove exactly one playlist row by its zero-based display position.
    /// This preserves duplicate songs that occur more than once in a playlist.
    pub fn removePlaylistTrackAt(self: *Database, playlist_id: i64, position: usize) !void {
        try self.begin();
        errdefer self.rollback() catch {};
        try self.raw.exec("DELETE FROM playlist_songs WHERE playlist_id=? AND position=?;", .{}, .{ playlist_id, @as(i64, @intCast(position)) });
        try self.normalizePlaylistPositions(playlist_id);
        try self.commit();
    }

    fn normalizePlaylistPositions(self: *Database, playlist_id: i64) !void {
        const ids = try self.getPlaylistSongIdsWithAllocator(self.allocator, playlist_id);
        defer self.allocator.free(ids);
        try self.raw.exec("DELETE FROM playlist_songs WHERE playlist_id=?;", .{}, .{playlist_id});
        for (ids, 0..) |song_id, position| {
            try self.raw.exec("INSERT INTO playlist_songs(playlist_id, song_id, position) VALUES(?, ?, ?);", .{}, .{ playlist_id, song_id, @as(i64, @intCast(position)) });
        }
    }

    pub fn getPlaylistSongIdsWithAllocator(self: *Database, allocator: std.mem.Allocator, playlist_id: i64) ![]i64 {
        var stmt = try self.raw.prepareDynamic("SELECT song_id FROM playlist_songs WHERE playlist_id=? ORDER BY position;");
        defer stmt.deinit();
        var iter = try stmt.iteratorAlloc(i64, allocator, .{playlist_id});
        var list = std.ArrayList(i64){ .items = &.{}, .capacity = 0 };
        defer list.deinit(allocator);
        while (try iter.nextAlloc(allocator, .{})) |id| try list.append(allocator, id);
        return list.toOwnedSlice(allocator);
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

    pub const SongPath = struct { id: i64, path: []const u8 };

    pub fn getAllSongPathsWithAllocator(self: *Database, allocator: std.mem.Allocator) ![]SongPath {
        var stmt = try self.raw.prepareDynamic("SELECT id, song_path AS path FROM songs ORDER BY id;");
        defer stmt.deinit();
        var iter = try stmt.iteratorAlloc(SongPath, allocator, .{});
        var list = std.ArrayList(SongPath){ .items = &.{}, .capacity = 0 };
        defer list.deinit(allocator);
        while (try iter.nextAlloc(allocator, .{})) |row| try list.append(allocator, row);
        return list.toOwnedSlice(allocator);
    }

    /// All songs, ordered by id, allocated with `self.allocator` (strings too).
    /// Iterates manually: zig-sqlite's `.all` uses `std.ArrayList(Type) = .{}`
    /// which doesn't compile against 0.16's unmanaged ArrayList.
    pub fn getAllSongs(self: *Database) ![]entity.Song {
        return self.getAllSongsWithAllocator(self.allocator);
    }

    pub fn getAllSongsWithAllocator(self: *Database, allocator: std.mem.Allocator) ![]entity.Song {
        var stmt = try self.raw.prepareDynamic(song_cols ++ ";");
        defer stmt.deinit();
        var iter = try stmt.iteratorAlloc(entity.Song, allocator, .{});
        var list = std.ArrayList(entity.Song){ .items = &.{}, .capacity = 0 };
        defer list.deinit(allocator);
        while (try iter.nextAlloc(allocator, .{})) |row| {
            try list.append(allocator, row);
        }
        return list.toOwnedSlice(allocator);
    }

    pub fn getSongById(self: *Database, id: i64) !?entity.Song {
        var stmt = try self.raw.prepareDynamic(song_cols ++ " WHERE id = ?;");
        defer stmt.deinit();
        return try stmt.oneAlloc(entity.Song, self.allocator, .{}, .{id});
    }

    pub const SongContext = struct {
        /// Per-track artist, including featured artists.
        artist: []const u8,
        album: []const u8,
        /// Album-level artist used for grouping and MusicBrainz lookups.
        album_artist: []const u8,
    };

    pub const SongDisplay = struct {
        id: i64,
        title: []const u8,
        artist: []const u8,
        album: []const u8,
    };

    /// Fetch display metadata for every song in one grouped query. This is used
    /// by frontends when building library rows, avoiding one statement per song.
    pub fn getAllSongDisplaysWithAllocator(self: *Database, allocator: std.mem.Allocator) ![]SongDisplay {
        var stmt = try self.raw.prepareDynamic(
            "SELECT s.id AS id, COALESCE(s.title, '') AS title, " ++
                "COALESCE(GROUP_CONCAT(sa_artist.name, '; '), album_artist.name, '') AS artist, " ++
                "COALESCE(al.name, '') AS album FROM songs s " ++
                "JOIN albums al ON al.id=s.album_id " ++
                "JOIN artists album_artist ON album_artist.id=al.artist_id " ++
                "LEFT JOIN song_artists sa ON sa.song_id=s.id " ++
                "LEFT JOIN artists sa_artist ON sa_artist.id=sa.artist_id " ++
                "GROUP BY s.id, s.title, al.name, album_artist.name ORDER BY s.id;",
        );
        defer stmt.deinit();
        var iter = try stmt.iteratorAlloc(SongDisplay, allocator, .{});
        var list = std.ArrayList(SongDisplay){ .items = &.{}, .capacity = 0 };
        defer list.deinit(allocator);
        while (try iter.nextAlloc(allocator, .{})) |row| try list.append(allocator, row);
        return list.toOwnedSlice(allocator);
    }

    /// Artist + album names for a song (null if it has no album/artist).
    pub fn getSongContext(self: *Database, song_id: i64) !?SongContext {
        return self.getSongContextWithAllocator(self.allocator, song_id);
    }

    pub fn getSongContextWithAllocator(self: *Database, allocator: std.mem.Allocator, song_id: i64) !?SongContext {
        var stmt = try self.raw.prepareDynamic(
            "SELECT COALESCE(GROUP_CONCAT(sa_artist.name, '; '), album_artist.name, '') AS artist, " ++
                "COALESCE(al.name, '') AS album, album_artist.name AS album_artist " ++
                "FROM songs s JOIN albums al ON al.id = s.album_id " ++
                "JOIN artists album_artist ON album_artist.id = al.artist_id " ++
                "LEFT JOIN song_artists sa ON sa.song_id = s.id " ++
                "LEFT JOIN artists sa_artist ON sa_artist.id = sa.artist_id " ++
                "WHERE s.id = ? GROUP BY s.id, al.name, album_artist.name;",
        );
        defer stmt.deinit();
        const Row = struct { artist: []const u8, album: []const u8, album_artist: []const u8 };
        const r = try stmt.oneAlloc(Row, allocator, .{}, .{song_id});
        return if (r) |row| .{ .artist = row.artist, .album = row.album, .album_artist = row.album_artist } else null;
    }

    pub fn getSongGenreStringWithAllocator(self: *Database, allocator: std.mem.Allocator, song_id: i64) ![]const u8 {
        var stmt = try self.raw.prepareDynamic(
            "SELECT COALESCE(GROUP_CONCAT(g.name, '; '), '') AS genres FROM song_genres sg " ++
                "JOIN genres g ON g.id=sg.genre_id WHERE sg.song_id=?;",
        );
        defer stmt.deinit();
        const Row = struct { genres: []const u8 };
        const row = try stmt.oneAlloc(Row, allocator, .{}, .{song_id});
        return if (row) |r| r.genres else "";
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
        metadata_version: i64,
        file_fingerprint: i64,
    };

    /// Existing row for a path (for change detection), or null.
    pub fn getSongImportInfoByPath(self: *Database, path: []const u8) !?SongImportInfo {
        var stmt = try self.raw.prepareDynamic(
            "SELECT id, COALESCE(file_size, -1), COALESCE(file_mtime_ticks, -1), COALESCE(metadata_version, 0), COALESCE(file_fingerprint, -1) FROM songs WHERE song_path = ?;",
        );
        defer stmt.deinit();
        const Row = struct { id: i64, file_size: i64, file_mtime_ticks: i64, metadata_version: i64, file_fingerprint: i64 };
        const r = try stmt.one(Row, .{}, .{path});
        return if (r) |row| .{ .id = row.id, .file_size = row.file_size, .file_mtime_ticks = row.file_mtime_ticks, .metadata_version = row.metadata_version, .file_fingerprint = row.file_fingerprint } else null;
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
        // A later scan may discover a year that was missing on first import.
        if (y > 0) {
            try self.raw.exec(
                "UPDATE albums SET year=? WHERE name=? AND artist_id=? AND (year IS NULL OR year < 1);",
                .{},
                .{ y, title, artist_id },
            );
        }
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
        return self.updateSongWithMetadata(id, title, album_id, track, disc_number, "", duration, file_size, file_mtime_ticks);
    }

    pub fn updateSongWithMetadata(
        self: *Database,
        id: i64,
        title: []const u8,
        album_id: i64,
        track: i64,
        disc_number: i64,
        comment: []const u8,
        duration: i64,
        file_size: i64,
        file_mtime_ticks: i64,
    ) !void {
        return self.updateSongWithMetadataAndFingerprint(id, title, album_id, track, disc_number, comment, duration, file_size, file_mtime_ticks, -1);
    }

    pub fn updateSongWithMetadataAndFingerprint(
        self: *Database,
        id: i64,
        title: []const u8,
        album_id: i64,
        track: i64,
        disc_number: i64,
        comment: []const u8,
        duration: i64,
        file_size: i64,
        file_mtime_ticks: i64,
        file_fingerprint: i64,
    ) !void {
        try self.raw.exec(
            "UPDATE songs SET title=?, album_id=?, track=?, disc_number=?, comment=?, duration=?, metadata_version=" ++ current_metadata_version_sql ++ ", file_fingerprint=?, file_size=?, file_mtime_ticks=? WHERE id=?;",
            .{},
            .{ title, album_id, track, disc_number, comment, duration, file_fingerprint, file_size, file_mtime_ticks, id },
        );
    }

    pub fn deleteSongById(self: *Database, id: i64) !void {
        try self.raw.exec("DELETE FROM songs WHERE id=?;", .{}, .{id});
    }

    /// Remove entities left behind after files disappear from the scanned
    /// library. Playlists are intentionally preserved; their song junctions
    /// already cascade when a song is deleted.
    pub fn pruneOrphans(self: *Database) !void {
        try self.raw.exec(
            "DELETE FROM albums WHERE id NOT IN (SELECT DISTINCT album_id FROM songs WHERE album_id IS NOT NULL);",
            .{},
            .{},
        );
        try self.raw.exec(
            "DELETE FROM artists WHERE id NOT IN (SELECT artist_id FROM albums WHERE artist_id IS NOT NULL) AND id NOT IN (SELECT artist_id FROM song_artists) AND id NOT IN (SELECT artist_id FROM album_artists);",
            .{},
            .{},
        );
        try self.raw.exec(
            "DELETE FROM genres WHERE id NOT IN (SELECT genre_id FROM song_genres);",
            .{},
            .{},
        );
    }

    /// Record the on-disk fingerprint (size + mtime) for change detection.
    pub fn setSongFileState(self: *Database, id: i64, file_size: i64, file_mtime_ticks: i64) !void {
        return self.setSongFileStateWithFingerprint(id, file_size, file_mtime_ticks, -1);
    }

    pub fn setSongFileStateWithFingerprint(self: *Database, id: i64, file_size: i64, file_mtime_ticks: i64, file_fingerprint: i64) !void {
        try self.raw.exec(
            "UPDATE songs SET file_fingerprint=?, file_size=?, file_mtime_ticks=? WHERE id=?;",
            .{},
            .{ file_fingerprint, file_size, file_mtime_ticks, id },
        );
    }
};

test "database: migrates album uniqueness to include folder identity" {
    var raw = try sqlite.Db.init(.{ .mode = .{ .Memory = {} }, .open_flags = .{ .write = true } });
    var db = Database{ .allocator = std.testing.allocator, .raw = raw };
    defer db.deinit();

    for (schema) |ddl| {
        if (std.mem.indexOf(u8, ddl, "CREATE TABLE IF NOT EXISTS albums") != null) continue;
        try raw.execDynamic(ddl, .{}, .{});
    }
    try raw.exec(
        \\CREATE TABLE albums (
        \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\  release_type INTEGER DEFAULT 1,
        \\  name TEXT NOT NULL,
        \\  year INTEGER,
        \\  picture_path TEXT,
        \\  musicbrainz_release_group_id TEXT,
        \\  cover_art_block BLOB,
        \\  cover_art_mime TEXT,
        \\  album_group_key TEXT NOT NULL DEFAULT '',
        \\  artist_id INTEGER,
        \\  FOREIGN KEY(artist_id) REFERENCES artists(id) ON DELETE CASCADE,
        \\  UNIQUE(name, artist_id));
    ,
        .{},
        .{},
    );
    try db.migrate();

    const artist = try db.addArtist("Same Artist");
    const first = try db.addAlbumWithGroupKey("Same Title", artist, 2020, "/music/one");
    const second = try db.addAlbumWithGroupKey("Same Title", artist, 2020, "/music/two");
    try std.testing.expect(first != second);
}

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

    const displays = try db.getAllSongDisplaysWithAllocator(arena.allocator());
    try std.testing.expectEqual(@as(usize, 3), displays.len);
    try std.testing.expectEqualStrings("Track A", displays[0].title);
    try std.testing.expectEqualStrings("The Example Band", displays[0].artist);
    const artists = try db.getArtistsWithAllocator(arena.allocator());
    try std.testing.expectEqual(@as(usize, 1), artists.len);
    try std.testing.expectEqual(@as(i64, 3), artists[0].song_count);

    const path = try db.getSongPathById(s1);
    try std.testing.expect(path != null);
    try std.testing.expectEqualStrings("/music/a.ogg", path.?);

    const playlist = try db.createPlaylist("Favorites");
    try db.addSongToPlaylist(playlist, s1);
    try db.addSongToPlaylist(playlist, s2);
    const playlists = try db.getPlaylistsWithAllocator(arena.allocator());
    try std.testing.expectEqual(@as(usize, 1), playlists.len);
    try std.testing.expectEqual(@as(i64, 2), playlists[0].song_count);
    const playlist_ids = try db.getPlaylistSongIdsWithAllocator(arena.allocator(), playlist);
    try std.testing.expectEqualSlices(i64, &.{ s1, s2 }, playlist_ids);
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

test "database: album listing + songs by album" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var db = try Database.open(arena.allocator(), null);
    defer db.deinit();

    const a1 = try db.addArtist("Alpha");
    const a2 = try db.addArtist("Beta");
    const alb1 = try db.addAlbum("Record One", a1, 1999);
    const alb2 = try db.addAlbum("Zed", a2, 2005);
    _ = try db.addSong("/one/b.ogg", "B", alb1, 2, 60, 1);
    _ = try db.addSong("/one/a.ogg", "A", alb1, 1, 50, 1);
    _ = try db.addSong("/two/c.ogg", "C", alb2, 1, 40, 1);

    // getSongsByAlbum orders by disc, then track (so A before B).
    const alb1_songs = try db.getSongsByAlbum(alb1);
    try std.testing.expectEqual(@as(usize, 2), alb1_songs.len);
    try std.testing.expectEqualStrings("A", alb1_songs[0].title);
    try std.testing.expectEqualStrings("B", alb1_songs[1].title);

    // getAlbums: track counts + artist names, ordered by album name.
    const listing = try db.getAlbums(.by_name);
    try std.testing.expectEqual(@as(usize, 2), listing.len);
    try std.testing.expectEqualStrings("Record One", listing[0].name);
    try std.testing.expectEqualStrings("Alpha", listing[0].artist);
    try std.testing.expectEqual(@as(i64, 2), listing[0].track_count);
    try std.testing.expectEqualStrings("Zed", listing[1].name);
    try std.testing.expectEqual(@as(i64, 1), listing[1].track_count);
    try std.testing.expect(!listing[1].has_cover);

    // Sort by year (desc): newer album first.
    const by_year = try db.getAlbums(.by_year);
    try std.testing.expectEqualStrings("Zed", by_year[0].name);
    try std.testing.expectEqualStrings("Record One", by_year[1].name);
    // Sort by artist.
    const by_artist = try db.getAlbums(.by_artist);
    try std.testing.expectEqualStrings("Alpha", by_artist[0].artist);
    try std.testing.expectEqualStrings("Beta", by_artist[1].artist);
}

test "database: artist genre and playlist detail queries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var db = try Database.open(arena.allocator(), null);
    defer db.deinit();

    const artist = try db.addArtist("Query Artist");
    const guest = try db.addArtist("Guest Artist");
    const genre = try db.addGenre("Electronic");
    const album = try db.addAlbum("Query Album", artist, 2024);
    const song = try db.addSong("/query.ogg", "Query Song", album, 1, 30, 1);
    try db.addSongArtist(song, artist);
    try db.addSongArtist(song, guest);
    try db.addSongGenre(song, genre);

    const artists = try db.getArtistsWithAllocator(arena.allocator());
    try std.testing.expect(artists.len >= 2);
    const genres = try db.getGenresWithAllocator(arena.allocator());
    try std.testing.expectEqual(@as(usize, 1), genres.len);
    try std.testing.expectEqual(@as(i64, 1), genres[0].song_count);
    const by_artist = try db.getSongsByArtistWithAllocator(arena.allocator(), guest);
    try std.testing.expectEqual(@as(usize, 1), by_artist.len);
    const by_genre = try db.getSongsByGenreWithAllocator(arena.allocator(), genre);
    try std.testing.expectEqual(@as(usize, 1), by_genre.len);

    const playlist = try db.createPlaylistWithDescription("Ordered", "A test list");
    try db.addSongToPlaylist(playlist, song);
    const info = (try db.getPlaylistsWithAllocator(arena.allocator()))[0];
    try std.testing.expectEqualStrings("A test list", info.description);
    const tracks = try db.getPlaylistTracksWithAllocator(arena.allocator(), playlist);
    try std.testing.expectEqual(@as(usize, 1), tracks.len);
    try db.reorderPlaylist(playlist, &.{song});
    try db.clearPlaylist(playlist);
    try std.testing.expectEqual(@as(usize, 0), (try db.getPlaylistSongIdsWithAllocator(arena.allocator(), playlist)).len);
}
