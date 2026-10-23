//! Zig wrapper for the TagLib album-art shim (see `taglib_art.cpp`).
//!
//! Extracts embedded cover art (ID3v2 APIC / FLAC picture / MP4 covr / Xiph
//! pictures) from an audio file, falling back to a folder cover
//! (cover.jpg / folder.jpg / ...). Returns allocator-owned bytes.

const std = @import("std");

const c = @import("forte_c");

pub const Cover = struct {
    bytes: []const u8,
    mime: []const u8,
};

pub const Metadata = struct {
    title: []const u8 = "",
    artist: []const u8 = "",
    album: []const u8 = "",
    genre: []const u8 = "",
    comment: []const u8 = "",
    year: u32 = 0,
    track: u32 = 0,
    disc: u32 = 0,
};

pub const WriteError = error{ PathTooLong, TagLibSaveFailed };

pub const ReplayGain = struct {
    track_gain_db: ?f64 = null,
    track_peak: ?f64 = null,
    album_gain_db: ?f64 = null,
    album_peak: ?f64 = null,
};

/// Read standard ReplayGain tags through TagLib's format-independent property map.
/// Missing files/tags are represented as null values (unity in playback).
pub fn extractReplayGain(path: []const u8) ?ReplayGain {
    var pathbuf: [std.Io.Dir.max_path_bytes:0]u8 = undefined;
    if (path.len + 1 > pathbuf.len) return null;
    @memcpy(pathbuf[0..path.len], path);
    pathbuf[path.len] = 0;
    var tg: f64 = 0;
    var tp: f64 = 0;
    var ag: f64 = 0;
    var ap: f64 = 0;
    var htg: c_int = 0;
    var htp: c_int = 0;
    var hag: c_int = 0;
    var hap: c_int = 0;
    if (c.forte_extract_replaygain(pathbuf[0..path.len :0].ptr, &tg, &htg, &tp, &htp, &ag, &hag, &ap, &hap) != 1) return null;
    return .{
        .track_gain_db = if (htg != 0) tg else null,
        .track_peak = if (htp != 0) tp else null,
        .album_gain_db = if (hag != 0) ag else null,
        .album_peak = if (hap != 0) ap else null,
    };
}

pub fn extractDiscNumber(path: []const u8) u32 {
    var pathbuf: [std.Io.Dir.max_path_bytes:0]u8 = undefined;
    if (path.len + 1 > pathbuf.len) return 1;
    @memcpy(pathbuf[0..path.len], path);
    pathbuf[path.len] = 0;
    const disc = c.forte_extract_disc_number(pathbuf[0..path.len :0].ptr);
    return if (disc > 0) disc else 1;
}

/// Write common tags through the C++ shim. The operation is intentionally
/// synchronous: callers can update the database only after this succeeds.
pub fn writeMetadata(path: []const u8, metadata: Metadata) WriteError!void {
    var pathbuf: [std.Io.Dir.max_path_bytes:0]u8 = undefined;
    if (path.len + 1 > pathbuf.len) return error.PathTooLong;
    @memcpy(pathbuf[0..path.len], path);
    pathbuf[path.len] = 0;
    var title: [1024:0]u8 = undefined;
    var artist: [1024:0]u8 = undefined;
    var album: [1024:0]u8 = undefined;
    var genre: [1024:0]u8 = undefined;
    var comment: [1024:0]u8 = undefined;
    const title_z = copyZ(&title, metadata.title) orelse return error.PathTooLong;
    const artist_z = copyZ(&artist, metadata.artist) orelse return error.PathTooLong;
    const album_z = copyZ(&album, metadata.album) orelse return error.PathTooLong;
    const genre_z = copyZ(&genre, metadata.genre) orelse return error.PathTooLong;
    const comment_z = copyZ(&comment, metadata.comment) orelse return error.PathTooLong;
    var error_buf: [256:0]u8 = undefined;
    const ok = c.forte_write_metadata(
        pathbuf[0..path.len :0].ptr,
        title_z.ptr,
        artist_z.ptr,
        album_z.ptr,
        genre_z.ptr,
        comment_z.ptr,
        metadata.year,
        metadata.track,
        metadata.disc,
        &error_buf,
        error_buf.len,
    );
    if (ok != 1) return error.TagLibSaveFailed;
}

fn copyZ(dst: []u8, value: []const u8) ?[:0]u8 {
    if (value.len + 1 > dst.len) return null;
    @memcpy(dst[0..value.len], value);
    dst[value.len] = 0;
    return dst[0..value.len :0];
}

/// Extract a copied ALBUMARTIST value using TagLib's C++ property API.
/// The C shim owns the temporary C string; the returned slice is allocator-owned.
pub fn extractAlbumArtist(a: std.mem.Allocator, path: []const u8) ?[]const u8 {
    var pathbuf: [std.Io.Dir.max_path_bytes:0]u8 = undefined;
    if (path.len + 1 > pathbuf.len) return null;
    @memcpy(pathbuf[0..path.len], path);
    pathbuf[path.len] = 0;
    const value = c.forte_extract_album_artist(pathbuf[0..path.len :0].ptr) orelse return null;
    defer c.forte_free_string(value);
    return a.dupe(u8, std.mem.span(value)) catch null;
}

/// Extract the cover for `path` (allocator-owned on success).
pub fn extract(a: std.mem.Allocator, path: []const u8) ?Cover {
    var pathbuf: [std.Io.Dir.max_path_bytes:0]u8 = undefined;
    if (path.len + 1 > pathbuf.len) return null;
    @memcpy(pathbuf[0..path.len], path);
    pathbuf[path.len] = 0;

    var data: [*c]u8 = null;
    var size: usize = 0;
    var mime: [*c]u8 = null;
    if (c.forte_extract_cover(pathbuf[0..path.len :0].ptr, &data, &size, &mime) != 1) return null;
    defer c.forte_free_cover(data, mime);

    if (data == null or mime == null or size == 0) return null;
    const d: [*]const u8 = @ptrCast(data);

    const bytes = a.dupe(u8, d[0..size]) catch return null;
    const mime_slice = a.dupe(u8, std.mem.span(mime)) catch {
        a.free(bytes);
        return null;
    };
    return .{ .bytes = bytes, .mime = mime_slice };
}
