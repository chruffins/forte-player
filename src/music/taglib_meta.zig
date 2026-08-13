//! Taglib-backed metadata extraction (C API via `tag_c.h`).
//!
//! Provides a `scanner.Extractor` that parses audio tags (title/artist/album/
//! track/year/duration). Compiled and linked only into the frontends (main/tui)
//! via `libtag_c`. `@cInclude` needs `/usr/include/taglib` on the search path.

const std = @import("std");
const c = @cImport({
    @cInclude("tag_c.h");
});
const scanner = @import("scanner.zig");

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
    defer c.taglib_tag_free_strings(); // frees all four char* copies above

    const year: i64 = c.taglib_tag_year(tag);
    const track: i64 = c.taglib_tag_track(tag);
    const duration: i64 = if (props) |p| c.taglib_audioproperties_length(p) else 0;

    const meta = scanner.Metadata{
        .title = a.dupe(u8, if (title.len > 0) title else baseStem(path)) catch return null,
        .artist = a.dupe(u8, if (artist.len > 0) artist else "Unknown Artist") catch return null,
        .album = a.dupe(u8, if (album.len > 0) album else "Unknown Album") catch return null,
        .track = @intCast(track),
        .year = if (year > 0) year else null,
        .duration = @intCast(duration),
    };
    return meta;
}
