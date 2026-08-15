//! Zig wrapper for the TagLib album-art shim (see `taglib_art.cpp`).
//!
//! Extracts embedded cover art (ID3v2 APIC / FLAC picture / MP4 covr / Xiph
//! pictures) from an audio file, falling back to a folder cover
//! (cover.jpg / folder.jpg / ...). Returns allocator-owned bytes.

const std = @import("std");

const c = @cImport({
    @cInclude("taglib_art.h");
});

pub const Cover = struct {
    bytes: []const u8,
    mime: []const u8,
};

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
