//! Library scanner: walks a directory tree, importing audio files into the
//! `Database` with change detection.
//!
//! Metadata extraction is pluggable via a callback (`extractor`). The default
//! here is a filename-only fallback; a taglib-backed extractor can be supplied
//! behind a build option (see `scanner.zig` design note) when `libtag1-dev` is
//! installed. The walk / change-detection / upsert logic is pure Zig.

const std = @import("std");
const al = @import("allegro");
const database = @import("database.zig");
const taglib_art = @import("taglib_art.zig");

pub const path_buf_size = std.Io.Dir.max_path_bytes;

pub const Metadata = struct {
    title: []const u8,
    artist: []const u8,
    album: []const u8,
    track: i64,
    year: ?i64,
    duration: i64,
};

pub const ScanResult = struct {
    scanned: usize = 0,
    imported: usize = 0,
    updated: usize = 0,
    removed: usize = 0,
    skipped: usize = 0,
};

/// Pluggable metadata extraction (e.g. taglib vs filename fallback).
pub const Extractor = struct {
    extract: *const fn (std.mem.Allocator, []const u8) ?Metadata,
};

/// Filename-only extractor; used by tests and as the default.
pub const fallback_extractor = Extractor{ .extract = fallbackExtract };

fn fallbackExtract(a: std.mem.Allocator, path: []const u8) ?Metadata {
    return extractFallback(a, path) catch null;
}

const audio_exts = [_][]const u8{ ".mp3", ".flac", ".ogg", ".wav", ".m4a", ".mp4", ".aac", ".opus" };

/// Recursively scan `dir` and update `db` accordingly.
pub fn scanDirectory(db: *database.Database, backing: std.mem.Allocator, dir: []const u8, extractor: Extractor) !ScanResult {
    var arena = std.heap.ArenaAllocator.init(backing);
    defer arena.deinit();
    const a = arena.allocator();

    // Every path seen on disk this run (arena-owned, so `seen` keys stay stable).
    var seen = std.StringHashMap(void).init(a);
    var result = ScanResult{};

    try walk(db, a, dir, extractor, &seen, &result);

    // Remove database rows for files that no longer exist under the tree.
    const db_songs = try db.getAllSongs();
    for (db_songs) |s| {
        if (!seen.contains(s.path)) {
            try db.deleteSongById(s.id);
            result.removed += 1;
        }
    }

    // Post-pass: make sure every album that still lacks a cover gets one.
    // Runs on every scan (not just imports) so covers added to a folder after
    // an earlier import are picked up, and tries every song of an album (not
    // just the first) until one yields art.
    try recoverMissingCovers(db, a);

    return result;
}

/// For each album with no stored cover, try extracting embedded art (or a
/// folder cover) from its songs until one succeeds. Cheap: only extracts for
/// albums that still lack a cover, and stops at the first song that yields one.
/// Album art may live in a later track, or be added to a folder after the
/// initial import, so this runs on every scan rather than once at import.
fn recoverMissingCovers(db: *database.Database, a: std.mem.Allocator) !void {
    const songs = try db.getAllSongs();

    // Sort (album, path) by album id so each album's songs are contiguous.
    const P = struct { album: i64, path: []const u8 };
    var list = std.ArrayList(P){ .items = &.{}, .capacity = 0 };
    defer list.deinit(a);
    for (songs) |s| try list.append(a, .{ .album = s.album_id, .path = s.path });
    std.mem.sort(P, list.items, {}, struct {
        fn lt(_: void, x: P, y: P) bool {
            return x.album < y.album;
        }
    }.lt);

    var i: usize = 0;
    while (i < list.items.len) {
        const album = list.items[i].album;
        var j = i;
        while (j < list.items.len and list.items[j].album == album) j += 1;

        if (try db.getAlbumCover(album) == null) {
            for (list.items[i..j]) |p| {
                if (taglib_art.extract(a, p.path)) |cover| {
                    try db.setAlbumCover(album, cover.mime, cover.bytes);
                    break;
                }
            }
        }
        i = j;
    }
}

fn walk(db: *database.Database, a: std.mem.Allocator, dir: []const u8, extractor: Extractor, seen: *std.StringHashMap(void), result: *ScanResult) !void {
    var dirbuf: [path_buf_size:0]u8 = undefined;
    const dirz = toSentinel(&dirbuf, dir) orelse return error.PathTooLong;

    var entry = al.filesystem.Entry.create(dirz) catch return;
    defer entry.destroy();
    if (!entry.update()) return; // stat so mode/size/mtime are valid
    if (!entry.isDirectory()) return;
    if (!entry.openDirectory()) return;
    defer _ = entry.closeDirectory();

    while (true) {
        const child = entry.readDirectory() orelse break;
        var c = child;
        defer c.destroy();
        // al_get_fs_entry_name returns the child's full path (sentinel-terminated).
        const cpath = c.name();
        const base = basename(cpath);
        if (std.mem.eql(u8, base, ".") or std.mem.eql(u8, base, "..")) continue;

        if (c.isDirectory()) {
            try walk(db, a, cpath, extractor, seen, result);
        } else if (hasAudioExtension(base)) {
            try processFile(db, a, cpath, c.size(), c.mtime(), extractor, seen, result);
        }
    }
}

fn processFile(
    db: *database.Database,
    a: std.mem.Allocator,
    path: []const u8,
    file_size: i64,
    mtime: i64,
    extractor: Extractor,
    seen: *std.StringHashMap(void),
    result: *ScanResult,
) !void {
    try seen.put(try a.dupe(u8, path), {});
    result.scanned += 1;

    const existing = try db.getSongImportInfoByPath(path);
    if (existing) |info| {
        if (info.file_size == file_size and info.file_mtime_ticks == mtime) {
            result.skipped += 1;
            return;
        }
        // File changed on disk -> re-extract and update.
        const meta = extractor.extract(a, path) orelse try extractFallback(a, path);
        const artist_id = try db.getOrCreateArtist(meta.artist);
        const album_id = try db.getOrCreateAlbum(meta.album, artist_id, meta.year);
        try db.updateSong(info.id, meta.title, album_id, meta.track, 1, meta.duration, file_size, mtime);
        result.updated += 1;
    } else {
        const meta = extractor.extract(a, path) orelse try extractFallback(a, path);
        const artist_id = try db.getOrCreateArtist(meta.artist);
        const album_id = try db.getOrCreateAlbum(meta.album, artist_id, meta.year);
        const new_id = try db.addSong(path, meta.title, album_id, meta.track, meta.duration, 1);
        try db.setSongFileState(new_id, file_size, mtime);
        result.imported += 1;
    }
}

fn extractFallback(a: std.mem.Allocator, path: []const u8) !Metadata {
    const base = basename(path);
    var i: usize = base.len;
    while (i > 0 and base[i - 1] != '.') i -= 1;
    const stem = if (i > 0) base[0 .. i - 1] else base;
    return .{
        .title = try a.dupe(u8, stem),
        .artist = try a.dupe(u8, "Unknown Artist"),
        .album = try a.dupe(u8, "Unknown Album"),
        .track = 0,
        .year = null,
        .duration = 0,
    };
}

fn basename(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| return path[i + 1 ..];
    return path;
}

fn hasAudioExtension(name: []const u8) bool {
    var i: usize = name.len;
    while (i > 0 and name[i - 1] != '.') i -= 1;
    if (i == 0) return false;
    const e = name[i - 1 ..];
    for (audio_exts) |x| if (std.mem.eql(u8, e, x)) return true;
    return false;
}

fn toSentinel(buf: [:0]u8, s: []const u8) ?[:0]const u8 {
    if (s.len + 1 > buf.len) return null;
    @memcpy(buf[0..s.len], s);
    buf[s.len] = 0;
    return buf[0..s.len :0];
}

test "scanner: imports files, skips unchanged, removes deleted" {
    _ = al.init() catch return error.SkipZigTest;
    const root = "/tmp/forte_scan_test";
    _ = al.filesystem.removeFilename(root);
    _ = al.filesystem.makeDirectory(root);

    const sub = "/tmp/forte_scan_test/Album";
    _ = al.filesystem.makeDirectory(sub);
    const song = "/tmp/forte_scan_test/Album/track1.ogg";
    {
        var f = al.file.File.open(song, "w") catch return error.Failed;
        _ = f.close();
    }

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var db = try database.Database.open(arena.allocator(), null);
    defer db.deinit();

    // First scan imports 1.
    var r = try scanDirectory(&db, std.testing.allocator, root, fallback_extractor);
    try std.testing.expectEqual(@as(usize, 1), r.imported);
    try std.testing.expectEqual(@as(usize, 1), (try db.getAllSongs()).len);

    // Second scan: unchanged -> skipped, nothing imported/updated.
    r = try scanDirectory(&db, std.testing.allocator, root, fallback_extractor);
    try std.testing.expectEqual(@as(usize, 1), r.skipped);
    try std.testing.expectEqual(@as(usize, 0), r.imported);

    // Delete the file -> removed.
    _ = al.filesystem.removeFilename(song);
    r = try scanDirectory(&db, std.testing.allocator, root, fallback_extractor);
    try std.testing.expectEqual(@as(usize, 1), r.removed);
    try std.testing.expectEqual(@as(usize, 0), (try db.getAllSongs()).len);
}

test "scanner: folder cover extracted on import and recovered on later rescan" {
    _ = al.init() catch return error.SkipZigTest;
    const root = "/tmp/forte_cover_test";
    const album_dir = "/tmp/forte_cover_test/Album";
    const song = "/tmp/forte_cover_test/Album/track1.ogg";
    const cover_path = "/tmp/forte_cover_test/Album/cover.jpg";

    // Clean slate. removeFilename is non-recursive, so remove files before the
    // dirs they live in, or a stale cover from a previous run survives inside
    // the recreated Album/ dir and this test's "no cover yet" step breaks.
    _ = al.filesystem.removeFilename(cover_path);
    _ = al.filesystem.removeFilename(song);
    _ = al.filesystem.removeFilename(album_dir);
    _ = al.filesystem.removeFilename(root);
    _ = al.filesystem.makeDirectory(root);
    _ = al.filesystem.makeDirectory(album_dir);
    {
        var f = al.file.File.open(song, "w") catch return error.Failed;
        _ = f.close();
    }

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var db = try database.Database.open(arena.allocator(), null);
    defer db.deinit();

    // No cover file yet -> first scan imports the song but stores no art.
    const r = try scanDirectory(&db, std.testing.allocator, root, fallback_extractor);
    try std.testing.expectEqual(@as(usize, 1), r.imported);
    const songs = try db.getAllSongs();
    try std.testing.expectEqual(@as(usize, 1), songs.len);
    try std.testing.expect(try db.getAlbumCover(songs[0].album_id) == null);

    // User drops a cover.jpg into the folder. The song is unchanged on the
    // rescan (so it is skipped), but the post-pass must still recover the art.
    {
        var f = al.file.File.open(cover_path, "w") catch return error.Failed;
        _ = f.write("fake-jpeg-bytes");
        _ = f.close();
    }
    const r2 = try scanDirectory(&db, std.testing.allocator, root, fallback_extractor);
    try std.testing.expectEqual(@as(usize, 1), r2.skipped);

    const cover = (try db.getAlbumCover(songs[0].album_id)) orelse return error.ExpectedCover;
    try std.testing.expectEqualStrings("image/jpeg", cover.mime);
    try std.testing.expectEqualStrings("fake-jpeg-bytes", cover.bytes);
}
