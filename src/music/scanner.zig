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
    /// Album artist, distinct from the per-track artist. This is what defines
    /// album identity for featured tracks and compilations.
    album_artist: []const u8 = "",
    album: []const u8,
    comment: []const u8 = "",
    genre: []const u8 = "",
    track: i64,
    disc_number: i64 = 1,
    year: ?i64,
    duration: i64,
};

pub const ScanResult = struct {
    scanned: usize = 0,
    imported: usize = 0,
    updated: usize = 0,
    removed: usize = 0,
    skipped: usize = 0,
    metadata_fallbacks: usize = 0,
    filesystem_failures: usize = 0,
};

/// Pluggable metadata extraction (e.g. taglib vs filename fallback).
pub const Extractor = struct {
    extract: *const fn (std.mem.Allocator, []const u8) ?Metadata,
};

pub const ProgressFn = *const fn (ctx: *anyopaque, result: *const ScanResult) void;
pub const CancelFn = *const fn (ctx: *anyopaque) bool;

pub const ScanOptions = struct {
    ctx: ?*anyopaque = null,
    on_progress: ?ProgressFn = null,
    should_cancel: ?CancelFn = null,
};

/// Filename-only extractor; used by tests and as the default.
pub const fallback_extractor = Extractor{ .extract = fallbackExtract };

fn fallbackExtract(a: std.mem.Allocator, path: []const u8) ?Metadata {
    return extractFallback(a, path) catch null;
}

const audio_exts = [_][]const u8{ ".mp3", ".flac", ".ogg", ".wav", ".m4a", ".mp4", ".aac", ".opus" };
// Database owns this version so insert/update paths and scan invalidation
// cannot drift apart.
const current_metadata_version = database.current_metadata_version;

/// Recursively scan `dir` and update `db` accordingly.
pub fn scanDirectory(db: *database.Database, backing: std.mem.Allocator, dir: []const u8, extractor: Extractor) !ScanResult {
    return scanDirectoryWithOptions(db, backing, dir, extractor, .{});
}

pub fn scanDirectoryWithOptions(db: *database.Database, backing: std.mem.Allocator, dir: []const u8, extractor: Extractor, options: ScanOptions) !ScanResult {
    var arena = std.heap.ArenaAllocator.init(backing);
    defer arena.deinit();
    const a = arena.allocator();

    // Every path seen on disk this run (arena-owned, so `seen` keys stay stable).
    var seen = std.StringHashMap(void).init(a);
    var result = ScanResult{};

    // Keep a scan atomic: a traversal or metadata/database failure should not
    // leave half of the library updated while the other half is stale.
    try db.begin();
    errdefer db.rollback() catch {};

    try walk(db, a, dir, extractor, &seen, &result, options);
    // Never treat an inaccessible/missing root or subtree as a clean scan:
    // deleting all unseen rows would destroy a library merely because a mount
    // is temporarily unavailable.
    if (result.filesystem_failures > 0) return error.FilesystemFailure;

    // Remove database rows for files that no longer exist under the tree.
    // Only id/path are needed for reconciliation; avoid materializing every
    // metadata column for large libraries.
    const db_songs = try db.getAllSongPathsWithAllocator(a);
    for (db_songs) |s| {
        if (!seen.contains(s.path)) {
            try db.deleteSongById(s.id);
            result.removed += 1;
        }
    }
    try db.pruneOrphans();

    // Post-pass: make sure every album that still lacks a cover gets one.
    // Runs on every scan (not just imports) so covers added to a folder after
    // an earlier import are picked up, and tries every song of an album (not
    // just the first) until one yields art.
    try recoverMissingCovers(db, a);
    try db.commit();

    return result;
}

/// For each album with no stored cover, try extracting embedded art (or a
/// folder cover) from its songs until one succeeds. Cheap: only extracts for
/// albums that still lack a cover, and stops at the first song that yields one.
/// Album art may live in a later track, or be added to a folder after the
/// initial import, so this runs on every scan rather than once at import.
fn recoverMissingCovers(db: *database.Database, a: std.mem.Allocator) !void {
    // Query only albums that can actually need work. The previous implementation
    // materialized and sorted every song on every scan before checking covers.
    const albums = try db.getAlbumsMissingCoverWithAllocator(a);
    for (albums) |album| {
        const songs = try db.getSongsByAlbumWithAllocator(a, album);
        for (songs) |song| {
            if (taglib_art.extract(a, song.path)) |cover| {
                try db.setAlbumCover(album, cover.mime, cover.bytes);
                break;
            }
        }
    }
}

fn walk(db: *database.Database, a: std.mem.Allocator, dir: []const u8, extractor: Extractor, seen: *std.StringHashMap(void), result: *ScanResult, options: ScanOptions) !void {
    var dirbuf: [path_buf_size:0]u8 = undefined;
    const dirz = toSentinel(&dirbuf, dir) orelse return error.PathTooLong;

    var entry = al.filesystem.Entry.create(dirz) catch {
        result.filesystem_failures += 1;
        return;
    };
    defer entry.destroy();
    if (!entry.update()) {
        result.filesystem_failures += 1;
        return;
    }
    if (!entry.isDirectory()) return;
    if (!entry.openDirectory()) {
        result.filesystem_failures += 1;
        return;
    }
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
            try walk(db, a, cpath, extractor, seen, result, options);
        } else if (hasAudioExtension(base)) {
            try processFile(db, a, cpath, c.size(), c.mtime(), extractor, seen, result, options);
        }
    }
}

fn quickFingerprint(path: []const u8, file_size: i64) ?i64 {
    var pathbuf: [path_buf_size:0]u8 = undefined;
    const pathz = toSentinel(&pathbuf, path) orelse return null;
    var file = al.file.File.open(pathz, "r") catch return null;
    defer _ = file.close();

    var hash = std.hash.Wyhash.init(0);
    hash.update(std.mem.asBytes(&file_size));
    var chunk: [4096]u8 = undefined;
    const first_n = file.read(&chunk);
    hash.update(chunk[0..first_n]);
    if (file_size > chunk.len) {
        if (!file.fseek(@max(@as(i64, 0), file_size - chunk.len), 0)) return null;
        const last_n = file.read(&chunk);
        hash.update(chunk[0..last_n]);
    }
    return @intCast(hash.final() & std.math.maxInt(i63));
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
    options: ScanOptions,
) !void {
    if (options.should_cancel) |cancel| {
        if (cancel(options.ctx orelse return error.InvalidScanOptions)) return error.ScanCancelled;
    }
    try seen.put(try a.dupe(u8, path), {});
    result.scanned += 1;
    if (options.on_progress) |progress| progress(options.ctx orelse return error.InvalidScanOptions, result);

    const existing = try db.getSongImportInfoByPath(path);
    // Size + mtime are only a fast candidate check: files can be rewritten in
    // place while preserving both values. Keep the bounded first/last-chunk
    // fingerprint check so unchanged content is skipped without weakening
    // change detection.
    const fingerprint = quickFingerprint(path, file_size) orelse -1;
    if (existing) |info| if (info.file_size == file_size and info.file_mtime_ticks == mtime and info.file_fingerprint == fingerprint and fingerprint >= 0 and info.metadata_version >= current_metadata_version) {
        result.skipped += 1;
        return;
    };
    if (try persistFile(db, a, path, file_size, mtime, fingerprint, extractor, result, existing)) {
        result.updated += 1;
    } else {
        result.imported += 1;
    }
}

fn persistFile(
    db: *database.Database,
    a: std.mem.Allocator,
    path: []const u8,
    file_size: i64,
    mtime: i64,
    fingerprint: i64,
    extractor: Extractor,
    result: *ScanResult,
    existing: ?database.Database.SongImportInfo,
) !bool {
    const meta = try extractMetadata(a, path, extractor, result);
    const album_id = try persistMetadata(db, meta, path);
    if (existing) |info| {
        try db.updateSongWithMetadataAndFingerprint(info.id, meta.title, album_id, meta.track, meta.disc_number, meta.comment, meta.duration, file_size, mtime, fingerprint);
        try persistAssociations(db, info.id, album_id, meta);
        return true;
    }
    const new_id = try db.addSongWithMetadata(path, meta.title, album_id, meta.track, meta.comment, meta.duration, meta.disc_number);
    try db.setSongFileStateWithFingerprint(new_id, file_size, mtime, fingerprint);
    try persistAssociations(db, new_id, album_id, meta);
    return false;
}

fn extractMetadata(a: std.mem.Allocator, path: []const u8, extractor: Extractor, result: *ScanResult) !Metadata {
    if (extractor.extract(a, path)) |meta| return meta;
    result.metadata_fallbacks += 1;
    return extractFallback(a, path);
}

fn trimTag(value: []const u8) []const u8 {
    return std.mem.trim(u8, value, " \t\r\n");
}

fn firstTagValue(value: []const u8) []const u8 {
    var parts = std.mem.splitAny(u8, value, ";|");
    return trimTag(parts.next() orelse "");
}

fn albumGroupKey(path: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfAny(u8, path, "/\\") orelse return "";
    var dir = path[0..slash];
    const leaf_start = (std.mem.lastIndexOfAny(u8, dir, "/\\") orelse return dir) + 1;
    const leaf = dir[leaf_start..];
    // Disc/CD subdirectories are common for multi-disc releases; use the
    // release directory rather than splitting each disc into its own album.
    if (std.ascii.startsWithIgnoreCase(leaf, "disc ") or std.ascii.startsWithIgnoreCase(leaf, "disk ") or std.ascii.startsWithIgnoreCase(leaf, "cd ")) {
        dir = dir[0 .. leaf_start - 1];
    }
    return dir;
}

fn persistMetadata(db: *database.Database, meta: Metadata, path: []const u8) !i64 {
    const primary_artist = firstTagValue(meta.artist);
    const artist = if (primary_artist.len > 0) primary_artist else "Unknown Artist";
    const album_artist_tag = firstTagValue(meta.album_artist);
    const artist_id = try db.getOrCreateArtist(artist);
    if (album_artist_tag.len > 0) {
        const album_artist_id = try db.getOrCreateArtist(album_artist_tag);
        return db.getOrCreateAlbum(meta.album, album_artist_id, meta.year);
    }
    return db.getOrCreateAlbumWithoutAlbumArtist(meta.album, artist_id, meta.year, albumGroupKey(path));
}

fn persistAssociations(db: *database.Database, song_id: i64, album_id: i64, meta: Metadata) !void {
    try db.clearSongAssociations(song_id);

    var artists = std.mem.splitAny(u8, meta.artist, ";|");
    while (artists.next()) |raw| {
        const name = trimTag(raw);
        if (name.len == 0) continue;
        const artist_id = try db.getOrCreateArtist(name);
        try db.addSongArtist(song_id, artist_id);
        try db.addAlbumArtist(album_id, artist_id);
    }

    var genres = std.mem.splitAny(u8, meta.genre, ";|,");
    while (genres.next()) |raw| {
        const name = trimTag(raw);
        if (name.len == 0) continue;
        const genre_id = try db.getOrCreateGenre(name);
        try db.addSongGenre(song_id, genre_id);
    }
}

/// Reconcile one database row after an external metadata edit. This keeps the
/// database consistent with the freshly extracted tags and rebuilds the song's
/// artist/genre associations without requiring a full library scan.
pub fn reconcileMetadata(db: *database.Database, a: std.mem.Allocator, song_id: i64, meta: Metadata) !void {
    const old = (try db.getSongById(song_id)) orelse return error.SongNotFound;
    const album_id = try persistMetadata(db, meta, old.path);
    try db.updateSongWithMetadataAndFingerprint(
        song_id,
        meta.title,
        album_id,
        meta.track,
        meta.disc_number,
        meta.comment,
        meta.duration,
        -1,
        -1,
        -1,
    );
    try persistAssociations(db, song_id, album_id, meta);
    try db.pruneOrphans();
    _ = a;
}

fn extractFallback(a: std.mem.Allocator, path: []const u8) !Metadata {
    const base = basename(path);
    var i: usize = base.len;
    while (i > 0 and base[i - 1] != '.') i -= 1;
    const stem = if (i > 0) base[0 .. i - 1] else base;
    return .{
        .title = try a.dupe(u8, stem),
        .artist = try a.dupe(u8, "Unknown Artist"),
        .album_artist = try a.dupe(u8, ""),
        .album = try a.dupe(u8, "Unknown Album"),
        .comment = "",
        .genre = "",
        .track = 0,
        .disc_number = 1,
        .year = null,
        .duration = 0,
    };
}

fn basename(path: []const u8) []const u8 {
    const start = if (std.mem.lastIndexOfAny(u8, path, "/\\")) |i| i + 1 else 0;
    return path[start..];
}

fn hasAudioExtension(name: []const u8) bool {
    var i: usize = name.len;
    while (i > 0 and name[i - 1] != '.') i -= 1;
    if (i == 0) return false;
    const e = name[i - 1 ..];
    for (audio_exts) |x| if (std.ascii.eqlIgnoreCase(e, x)) return true;
    return false;
}

fn toSentinel(buf: [:0]u8, s: []const u8) ?[:0]const u8 {
    if (s.len + 1 > buf.len) return null;
    @memcpy(buf[0..s.len], s);
    buf[s.len] = 0;
    return buf[0..s.len :0];
}

fn compilationExtractor(a: std.mem.Allocator, path: []const u8) ?Metadata {
    const featured = std.mem.endsWith(u8, path, "track2.ogg");
    return .{
        .title = a.dupe(u8, if (featured) "Second Song" else "First Song") catch return null,
        .artist = a.dupe(u8, if (featured) "Guest Artist" else "Main Artist") catch return null,
        .album_artist = a.dupe(u8, "Various Artists") catch return null,
        .album = a.dupe(u8, "Compilation") catch return null,
        .track = if (featured) 2 else 1,
        .year = 2024,
        .duration = 180,
    };
}

test "scanner: album artist keeps compilations together" {
    _ = al.init() catch return error.SkipZigTest;
    const root = "/tmp/forte_album_artist_test";
    _ = al.filesystem.removeFilename("/tmp/forte_album_artist_test/track1.ogg");
    _ = al.filesystem.removeFilename("/tmp/forte_album_artist_test/track2.ogg");
    _ = al.filesystem.removeFilename(root);
    _ = al.filesystem.makeDirectory(root);
    for ([_][]const u8{ "track1.ogg", "track2.ogg" }) |name| {
        var path: [128]u8 = undefined;
        const p_slice = try std.fmt.bufPrint(&path, "{s}/{s}", .{ root, name });
        path[p_slice.len] = 0;
        const p: [:0]const u8 = path[0..p_slice.len :0];
        var f = al.file.File.open(p, "w") catch return error.Failed;
        _ = f.close();
    }

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var db = try database.Database.open(arena.allocator(), null);
    defer db.deinit();
    _ = try scanDirectory(&db, std.testing.allocator, root, .{ .extract = compilationExtractor });

    const albums = try db.getAlbums(.by_name);
    try std.testing.expectEqual(@as(usize, 1), albums.len);
    try std.testing.expectEqual(@as(i64, 2), albums[0].track_count);
    const songs = try db.getAllSongs();
    try std.testing.expectEqual(@as(usize, 2), songs.len);
    try std.testing.expectEqual(songs[0].album_id, songs[1].album_id);
}

fn untaggedSameTitleExtractor(a: std.mem.Allocator, path: []const u8) ?Metadata {
    const side_b = std.mem.indexOf(u8, path, "/B/") != null;
    return .{
        .title = a.dupe(u8, if (side_b) "B Track" else "A Track") catch return null,
        .artist = a.dupe(u8, if (side_b) "Artist B" else "Artist A") catch return null,
        .album = a.dupe(u8, "Same Title") catch return null,
        .track = 1,
        .year = null,
        .duration = 180,
    };
}

test "scanner: untagged same-title albums use folder identity" {
    _ = al.init() catch return error.SkipZigTest;
    const root = "/tmp/forte_untagged_album_test";
    _ = al.filesystem.removeFilename("/tmp/forte_untagged_album_test/A/track.ogg");
    _ = al.filesystem.removeFilename("/tmp/forte_untagged_album_test/B/track.ogg");
    _ = al.filesystem.removeFilename("/tmp/forte_untagged_album_test/A");
    _ = al.filesystem.removeFilename("/tmp/forte_untagged_album_test/B");
    _ = al.filesystem.removeFilename(root);
    _ = al.filesystem.makeDirectory(root);
    _ = al.filesystem.makeDirectory("/tmp/forte_untagged_album_test/A");
    _ = al.filesystem.makeDirectory("/tmp/forte_untagged_album_test/B");
    for ([_][]const u8{ "/tmp/forte_untagged_album_test/A/track.ogg", "/tmp/forte_untagged_album_test/B/track.ogg" }) |path| {
        var pathbuf: [128:0]u8 = undefined;
        const pathz = toSentinel(&pathbuf, path) orelse return error.Failed;
        var f = al.file.File.open(pathz, "w") catch return error.Failed;
        _ = f.close();
    }

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var db = try database.Database.open(arena.allocator(), null);
    defer db.deinit();
    _ = try scanDirectory(&db, std.testing.allocator, root, .{ .extract = untaggedSameTitleExtractor });
    const albums = try db.getAlbums(.by_name);
    try std.testing.expectEqual(@as(usize, 2), albums.len);
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
    try std.testing.expectEqual(@as(usize, 0), (try db.getAlbums(.by_name)).len);
}

test "scanner: audio extensions are case insensitive" {
    try std.testing.expect(hasAudioExtension("TRACK.FLAC"));
    try std.testing.expect(hasAudioExtension("track.OpUs"));
    try std.testing.expect(!hasAudioExtension("cover.JPG"));
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
