//! Music domain value types (port of music/{song,album,artist,genre,playlist}.hpp).
//!
//! Plain data: strings are slices owned by whatever allocator built them
//! (for library rows, that's the Library's arena).

pub const Song = struct {
    id: i64,
    path: []const u8,
    title: []const u8,
    album_id: i64,
    track: i64,
    comment: []const u8,
    duration: i64,
    disc_number: i64,
    play_count: i64,
    last_played: i64, // -1 = never played
    favorite: i64, // 0/1
};

pub const Artist = struct {
    id: i64,
    name: []const u8,
    image_path: []const u8,
    description: []const u8,
};

pub const Album = struct {
    id: i64,
    title: []const u8,
    year: i64,
    picture_path: []const u8,
    artist_id: i64,
    musicbrainz_release_group_id: []const u8,
};

pub const Genre = struct {
    id: i64,
    name: []const u8,
};

pub const Playlist = struct {
    id: i64,
    name: []const u8,
    image_path: []const u8,
    description: []const u8,
};
