//! High-level metadata editing: write tags first, then reconcile the
//! corresponding database row from a fresh TagLib extraction.

const std = @import("std");
const database = @import("database.zig");
const scanner = @import("scanner.zig");
const taglib_art = @import("taglib_art.zig");
const taglib_meta = @import("taglib_meta.zig");

pub const Edit = struct {
    title: ?[]const u8 = null,
    artist: ?[]const u8 = null,
    album: ?[]const u8 = null,
    genre: ?[]const u8 = null,
    comment: ?[]const u8 = null,
    year: ?u32 = null,
    track: ?u32 = null,
    disc: ?u32 = null,
};

pub const Error = error{
    SongNotFound,
    MetadataReadFailed,
};

/// Edit common tags on disk and update the database only after TagLib has
/// successfully saved them. A fresh extraction is used so format-specific
/// normalization is reflected in the database.
pub fn editSong(db: *database.Database, allocator: std.mem.Allocator, song_id: i64, edit: Edit) !void {
    const song = (try db.getSongById(song_id)) orelse return error.SongNotFound;
    const context = (try db.getSongContextWithAllocator(allocator, song_id)) orelse return error.SongNotFound;
    const album = (try db.getAlbumById(song.album_id)) orelse return error.SongNotFound;
    const genre = try db.getSongGenreStringWithAllocator(allocator, song_id);

    var metadata = taglib_art.Metadata{
        .title = song.title,
        .artist = context.artist,
        .album = context.album,
        .genre = genre,
        .comment = song.comment,
        .year = @intCast(@max(album.year, 0)),
        .track = @intCast(@max(song.track, 0)),
        .disc = @intCast(@max(song.disc_number, 0)),
    };
    if (edit.title) |v| metadata.title = v;
    if (edit.artist) |v| metadata.artist = v;
    if (edit.album) |v| metadata.album = v;
    if (edit.genre) |v| metadata.genre = v;
    if (edit.comment) |v| metadata.comment = v;
    if (edit.year) |v| metadata.year = v;
    if (edit.track) |v| metadata.track = v;
    if (edit.disc) |v| metadata.disc = v;

    try taglib_art.writeMetadata(song.path, metadata);
    var fresh = taglib_meta.extractor.extract(allocator, song.path) orelse return error.MetadataReadFailed;
    // TagLib's C API does not expose DISCNUMBER consistently. Preserve an
    // explicitly edited value when the extractor reports its default.
    if (edit.disc) |v| fresh.disc_number = @intCast(v);
    try scanner.reconcileMetadata(db, allocator, song_id, fresh);
}

test "metadata edit: edit shape is optional and defaults safely" {
    const edit = Edit{ .title = "New title", .track = 3 };
    try std.testing.expectEqualStrings("New title", edit.title.?);
    try std.testing.expectEqual(@as(?u32, 3), edit.track);
    try std.testing.expect(edit.album == null);
}
