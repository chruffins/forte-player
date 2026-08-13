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
    return result;
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
