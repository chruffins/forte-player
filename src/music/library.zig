//! The in-memory music library, port of `music/Library` from audio-visualizer-cpp.
//!
//! Heap-allocated like the engine: the arena lives at `&self.arena`, which is
//! only stable if the Library itself is on the heap (`create`). Returning it by
//! value would leave the maps holding a dangling allocator pointer.
//!
//! Rows are read into the arena so lookups return borrows valid for the library's
//! lifetime. It also keeps sentinel-terminated song paths to back the engine's
//! `resolve_song` hook (which needs `[:0]const u8`).

const std = @import("std");
const entity = @import("entity.zig");
const database = @import("database.zig");
const Database = database.Database;

// Keep the library load streaming: materializing an intermediate []Song and
// then copying every row into the id map needlessly doubles peak row storage.
const library_song_query =
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
    \\FROM songs ORDER BY id;
;

pub const Library = struct {
    backing: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    songs_by_id: std.AutoHashMap(i64, entity.Song),
    /// song id -> sentinel-terminated path (for resolve_song).
    paths_by_id: std.AutoHashMap(i64, [:0]const u8),
    /// path -> song id (for playback tracking).
    path_to_id: std.StringHashMap(i64),
    /// Ordered list of song ids (the natural playback order).
    order: std.ArrayList(i64),
    /// Reverse lookup for current-track highlighting.
    index_by_id: std.AutoHashMap(i64, usize),

    /// Allocate a Library whose arena backs every owned structure.
    pub fn create(backing: std.mem.Allocator) !*Library {
        const self = try backing.create(Library);
        errdefer backing.destroy(self);

        self.* = .{
            .backing = backing,
            .arena = std.heap.ArenaAllocator.init(backing),
            .songs_by_id = undefined,
            .paths_by_id = undefined,
            .path_to_id = undefined,
            .order = undefined,
            .index_by_id = undefined,
        };
        const alloc = self.arena.allocator();
        self.songs_by_id = std.AutoHashMap(i64, entity.Song).init(alloc);
        self.paths_by_id = std.AutoHashMap(i64, [:0]const u8).init(alloc);
        self.path_to_id = std.StringHashMap(i64).init(alloc);
        self.order = std.ArrayList(i64){ .items = &.{}, .capacity = 0 };
        self.index_by_id = std.AutoHashMap(i64, usize).init(alloc);
        return self;
    }

    pub fn destroy(self: *Library) void {
        const backing = self.backing;
        self.arena.deinit();
        backing.destroy(self);
    }

    /// Populate the library from the database. The db must have been opened with
    /// this library's arena allocator so its rows are library-owned.
    pub fn load(self: *Library, db: *Database) !void {
        // A reload replaces every borrowed row and path. Reset the arena rather
        // than retaining old maps/strings forever after repeated rescans.
        _ = self.arena.reset(.free_all);
        const alloc = self.arena.allocator();
        self.songs_by_id = std.AutoHashMap(i64, entity.Song).init(alloc);
        self.paths_by_id = std.AutoHashMap(i64, [:0]const u8).init(alloc);
        self.path_to_id = std.StringHashMap(i64).init(alloc);
        self.order = std.ArrayList(i64){ .items = &.{}, .capacity = 0 };
        self.index_by_id = std.AutoHashMap(i64, usize).init(alloc);

        var stmt = try db.raw.prepareDynamic(library_song_query);
        defer stmt.deinit();
        var iter = try stmt.iteratorAlloc(entity.Song, alloc, .{});
        while (try iter.nextAlloc(alloc, .{})) |s| {
            try self.songs_by_id.put(s.id, s);
            const path_z = try alloc.dupeZ(u8, s.path);
            try self.paths_by_id.put(s.id, path_z);
            try self.path_to_id.put(s.path, s.id);
            const index = self.order.items.len;
            try self.order.append(alloc, s.id);
            try self.index_by_id.put(s.id, index);
        }
    }

    pub fn size(self: *const Library) usize {
        return self.songs_by_id.count();
    }

    pub fn getSongById(self: *const Library, id: i64) ?*const entity.Song {
        return self.songs_by_id.getPtr(id);
    }

    /// Sentinel-terminated path for a song id, or null.
    pub fn songPath(self: *const Library, id: i64) ?[:0]const u8 {
        return self.paths_by_id.get(id);
    }

    /// The id for a song path, or null.
    pub fn songIdByPath(self: *const Library, path: []const u8) ?i64 {
        return self.path_to_id.get(path);
    }

    /// The song id at ordinal `i`, or -1.
    pub fn songIdAt(self: *const Library, i: usize) i64 {
        if (i >= self.order.items.len) return -1;
        return self.order.items[i];
    }

    pub fn count(self: *const Library) usize {
        return self.order.items.len;
    }

    /// Index of a song id in playback order, or null.
    pub fn indexOfId(self: *const Library, id: i64) ?usize {
        return self.index_by_id.get(id);
    }

    /// Flip the in-memory favorite flag (kept in sync with the DB by the caller).
    pub fn setFavorite(self: *Library, id: i64, fav: bool) void {
        if (self.songs_by_id.getPtr(id)) |s| s.favorite = @intFromBool(fav);
    }

    pub fn recordPlayed(self: *Library, id: i64, played_at: i64) void {
        if (self.songs_by_id.getPtr(id)) |s| {
            s.play_count +%= 1;
            s.last_played = played_at;
        }
    }
};

test "library: loads songs + path lookup" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var lib = try Library.create(std.testing.allocator);
    defer lib.destroy();

    // The db reads through the library's arena so rows are library-owned.
    var db = try Database.open(lib.arena.allocator(), null);
    defer db.deinit();

    const artist = try db.addArtist("Q");
    const album = try db.addAlbum("AQ", artist, 2020);
    _ = try db.addSong("/m/one.ogg", "One", album, 1, 90, 1);
    _ = try db.addSong("/m/two.ogg", "Two", album, 2, 95, 1);

    try lib.load(&db);

    try std.testing.expectEqual(@as(usize, 2), lib.size());
    try std.testing.expectEqual(@as(i64, 1), lib.songIdAt(0));
    try std.testing.expectEqualStrings("/m/two.ogg", lib.songPath(2).?);

    const song = lib.getSongById(1).?;
    try std.testing.expectEqualStrings("One", song.title);

    // Reloading after a rescan must not retain paths for deleted songs.
    try db.deleteSongById(1);
    try lib.load(&db);
    try std.testing.expectEqual(@as(usize, 1), lib.size());
    try std.testing.expect(lib.songIdByPath("/m/one.ogg") == null);
    try std.testing.expectEqual(@as(i64, 2), lib.songIdByPath("/m/two.ogg").?);
}
