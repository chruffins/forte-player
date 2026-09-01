//! Taglib-backed metadata extraction (C API via `tag_c.h`).
//!
//! Provides a `scanner.Extractor` that parses audio tags (title/artist/album/
//! comment/genre/track/year/duration). Compiled and linked only into the frontends (main/tui)
//! via `libtag_c`. `@cInclude` needs `/usr/include/taglib` on the search path.

const std = @import("std");
const c = @cImport({
    @cInclude("tag_c.h");
});
const scanner = @import("scanner.zig");
const taglib_art = @import("taglib_art.zig");

pub const extractor = scanner.Extractor{ .extract = extract };

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

    const file = c.taglib_file_new(pathbuf[0..path.len :0].ptr) orelse return null;
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
    };
    return meta;
}
