//! Taglib-backed metadata extraction (C API via `tag_c.h`).
//!
//! Provides a `scanner.Extractor` that parses audio tags (title/artist/album/
//! comment/genre/track/year/duration). Compiled and linked only into the frontends (main/tui)
//! via `libtag_c`. `@cInclude` needs `/usr/include/taglib` on the search path.

const std = @import("std");
const builtin = @import("builtin");
const c = @import("forte_c");
const scanner = @import("scanner.zig");
const taglib_art = @import("taglib_art.zig");

pub const extractor = scanner.Extractor{ .extract = extract };
pub const RawTagSignals = struct { title: bool = false, artist: bool = false, album: bool = false };

fn openTaglibFile(path: [:0]const u8) ?[*c]c.TagLib_File {
    if (builtin.os.tag == .windows) {
        const wide = std.unicode.utf8ToUtf16LeAllocZ(std.heap.page_allocator, path) catch return null;
        defer std.heap.page_allocator.free(wide);
        return c.taglib_file_new_wchar(@ptrCast(wide.ptr));
    }
    return c.taglib_file_new(path.ptr);
}

/// Return raw source tag presence without applying the user-facing fallbacks.
pub fn rawTagSignals(path: []const u8) ?RawTagSignals {
    var pathbuf: [std.Io.Dir.max_path_bytes:0]u8 = undefined;
    if (path.len + 1 > pathbuf.len) return null;
    @memcpy(pathbuf[0..path.len], path);
    pathbuf[path.len] = 0;
    const file = openTaglibFile(pathbuf[0..path.len :0]) orelse return null;
    defer c.taglib_file_free(file);
    const tag = c.taglib_file_tag(file) orelse return null;
    const title = cstr(c.taglib_tag_title(tag));
    const artist = cstr(c.taglib_tag_artist(tag));
    const album = cstr(c.taglib_tag_album(tag));
    defer c.taglib_tag_free_strings();
    return .{
        .title = std.mem.trim(u8, title, " \\t\\r\\n").len > 0,
        .artist = std.mem.trim(u8, artist, " \\t\\r\\n").len > 0,
        .album = std.mem.trim(u8, album, " \\t\\r\\n").len > 0,
    };
}

fn cstr(p: [*c]u8) []const u8 {
    if (p == null) return "";
    const z: [*:0]const u8 = @ptrCast(p);
    return std.mem.span(z);
}

fn baseStem(path: []const u8) []const u8 {
    var i: usize = path.len;
    while (i > 0 and path[i - 1] != '/') i -= 1;
    const base = path[i..];
    var j: usize = base.len;
    while (j > 0 and base[j - 1] != '.') j -= 1;
    if (j > 1 and j < base.len) return base[0 .. j - 1];
    return base;
}

fn extract(a: std.mem.Allocator, path: []const u8) ?scanner.Metadata {
    var pathbuf: [std.Io.Dir.max_path_bytes:0]u8 = undefined;
    if (path.len + 1 > pathbuf.len) return null;
    @memcpy(pathbuf[0..path.len], path);
    pathbuf[path.len] = 0;

    const file = openTaglibFile(pathbuf[0..path.len :0]) orelse return null;
    defer c.taglib_file_free(file);

    const tag = c.taglib_file_tag(file) orelse return null;
    const props = c.taglib_file_audioproperties(file);

    const title = cstr(c.taglib_tag_title(tag));
    const artist = cstr(c.taglib_tag_artist(tag));
    const album = cstr(c.taglib_tag_album(tag));
    // Use the C++ shim for ALBUMARTIST. The TagLib C property API returns a
    // temporary char** whose representation is not safe to treat as a Zig
    // string slice on all supported TagLib builds.
    const album_artist = taglib_art.extractAlbumArtist(a, path) orelse &.{};
    const comment = cstr(c.taglib_tag_comment(tag));
    const genre = cstr(c.taglib_tag_genre(tag));
    defer c.taglib_tag_free_strings();

    const year: i64 = c.taglib_tag_year(tag);
    const track: i64 = c.taglib_tag_track(tag);
    const duration: i64 = if (props) |p| c.taglib_audioproperties_length(p) else 0;

    const meta = scanner.Metadata{
        .title = a.dupe(u8, if (title.len > 0) title else baseStem(path)) catch return null,
        .artist = a.dupe(u8, if (artist.len > 0) artist else "Unknown Artist") catch return null,
        .album_artist = album_artist,
        .album = a.dupe(u8, if (album.len > 0) album else "Unknown Album") catch return null,
        .comment = a.dupe(u8, comment) catch return null,
        .genre = a.dupe(u8, genre) catch return null,
        .track = @intCast(track),
        .disc_number = @intCast(taglib_art.extractDiscNumber(path)),
        .year = if (year > 0) year else null,
        .duration = @intCast(duration),
        .replaygain = blk: {
            const rg = taglib_art.extractReplayGain(path) orelse break :blk .{};
            break :blk .{
                .track_gain_db = rg.track_gain_db,
                .track_peak = rg.track_peak,
                .album_gain_db = rg.album_gain_db,
                .album_peak = rg.album_peak,
            };
        },
    };
    return meta;
}
