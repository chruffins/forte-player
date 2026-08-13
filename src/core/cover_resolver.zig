//! Album cover resolution for Discord presence.
//!
//! The library's tags carry no MusicBrainz ids, so we resolve covers at runtime
//! by querying the MusicBrainz release-group search API (over HTTPS via Zig's
//! native std.http/TLS), then hand Discord the Cover Art Archive "front" URL:
//!   https://coverartarchive.org/release-group/{mbid}/front
//!
//! Best-effort and rate-limited (MusicBrainz allows ~1 req/s and wants a real
//! User-Agent). Results are cached in memory for the session and persisted to
//! the albums table, so each album is looked up at most once. `tick()` runs
//! from the app's main loop (never from a hook), so a slow network can't block
//! playback or input.

const std = @import("std");
const db_mod = @import("../music/database.zig");

const c = @cImport({
    @cInclude("time.h");
});

const user_agent = "forte-player/0.1 (https://github.com/chruffins/audio-visualizer-cpp)";
const min_request_interval_secs: i64 = 1;
const search_url_base = "https://musicbrainz.org/ws/2/release-group/?query=";
const cover_url_base = "https://coverartarchive.org/release-group/";

pub const CoverResolver = struct {
    allocator: std.mem.Allocator,
    db: *db_mod.Database,
    threaded: std.Io.Threaded,
    client: std.http.Client,
    cache: std.AutoHashMapUnmanaged(i64, Entry) = .{},
    pending: std.ArrayList(i64) = .{ .items = &.{}, .capacity = 0 },
    pending_album: std.ArrayList([]const u8) = .{ .items = &.{}, .capacity = 0 },
    pending_artist: std.ArrayList([]const u8) = .{ .items = &.{}, .capacity = 0 },
    last_request_secs: i64 = 0,

    const Entry = union(enum) {
        pending,
        ok: []const u8, // cover URL (allocator-owned)
        none,
    };

    /// Create on the heap: the std.http client's `Io` holds a pointer to this
    /// resolver's Threaded, so the instance must live at a stable address.
    pub fn init(allocator: std.mem.Allocator, db: *db_mod.Database) !*CoverResolver {
        const r = try allocator.create(CoverResolver);
        errdefer allocator.destroy(r);
        r.* = .{
            .allocator = allocator,
            .db = db,
            .threaded = std.Io.Threaded.init(allocator, .{}),
            .client = undefined,
        };
        r.client = .{ .allocator = allocator, .io = r.threaded.io() };

        // Preload persisted MBIDs so known albums get covers immediately.
        if (db.getAllAlbumMbids()) |rows| {
            for (rows) |row| {
                if (row.mbid.len == 0) continue;
                const url = std.fmt.allocPrint(allocator, "{s}{s}/front", .{ cover_url_base, row.mbid }) catch continue;
                r.cache.put(allocator, row.album_id, .{ .ok = url }) catch {
                    allocator.free(url);
                    continue;
                };
            }
        } else |_| {}

        return r;
    }

    pub fn destroy(self: *CoverResolver) void {
        self.deinit();
        const allocator = self.allocator;
        allocator.destroy(self);
    }

    pub fn deinit(self: *CoverResolver) void {
        var it = self.cache.valueIterator();
        while (it.next()) |e| switch (e.*) {
            .ok => |url| self.allocator.free(url),
            else => {},
        };
        self.cache.deinit(self.allocator);
        self.pending.deinit(self.allocator);
        self.pending_album.deinit(self.allocator);
        self.pending_artist.deinit(self.allocator);
        self.client.deinit();
    }

    /// Queue a cover lookup for an album (idempotent). Called when a song
    /// changes; the actual network request happens later on `tick()`.
    pub fn enqueue(self: *CoverResolver, album_id: i64, album: []const u8, artist: []const u8) void {
        if (self.cache.contains(album_id)) return;
        self.cache.put(self.allocator, album_id, .pending) catch return;
        self.pending.append(self.allocator, album_id) catch return;
        self.pending_album.append(self.allocator, album) catch return;
        self.pending_artist.append(self.allocator, artist) catch return;
    }

    /// Cover URL for an album if already resolved, else null.
    pub fn coverUrlFor(self: *const CoverResolver, album_id: i64) ?[]const u8 {
        return switch (self.cache.get(album_id) orelse return null) {
            .ok => |url| url,
            else => null,
        };
    }

    /// Run at most one lookup, respecting the rate limit. Returns true if a
    /// lookup completed this call (so the caller can refresh the presence).
    pub fn tick(self: *CoverResolver) bool {
        if (self.pending.items.len == 0) return false;
        const now: i64 = @intCast(c.time(null));
        if (self.last_request_secs != 0 and now - self.last_request_secs < min_request_interval_secs) return false;
        self.last_request_secs = now;

        const album_id = self.pending.orderedRemove(0);
        const album = self.pending_album.orderedRemove(0);
        const artist = self.pending_artist.orderedRemove(0);
        const url = self.lookup(album_id, album, artist);
        _ = self.cache.put(self.allocator, album_id, if (url) |u| .{ .ok = u } else .none) catch {};
        return true;
    }

    // ---- lookup ----

    fn lookup(self: *CoverResolver, album_id: i64, album: []const u8, artist: []const u8) ?[]const u8 {
        var url_buf: [1024]u8 = undefined;
        const url = buildSearchUrl(&url_buf, album, artist) orelse return null;

        var body_buf: [1 << 20]u8 = undefined;
        var w = std.Io.Writer.fixed(&body_buf);
        const res = self.client.fetch(.{
            .location = .{ .url = url },
            .headers = .{ .user_agent = .{ .override = user_agent } },
            .response_writer = &w,
        }) catch return null;
        if (res.status != .ok) return null;

        const mbid = pickReleaseGroup(self.allocator, body_buf[0..w.end], album) orelse return null;
        defer self.allocator.free(mbid);

        // Persist so subsequent runs skip the lookup.
        self.db.setAlbumMbid(album_id, mbid) catch {};

        return std.fmt.allocPrint(self.allocator, "{s}{s}/front", .{ cover_url_base, mbid }) catch null;
    }
};

/// Percent-encode `src` (RFC 3986 unreserved chars pass through).
fn percentEncode(dst: []u8, src: []const u8) ?[]const u8 {
    const hex = "0123456789ABCDEF";
    var n: usize = 0;
    for (src) |b| {
        const ok = (b >= 'a' and b <= 'z') or (b >= 'A' and b <= 'Z') or
            (b >= '0' and b <= '9') or b == '-' or b == '.' or b == '_' or b == '~';
        if (ok) {
            if (n >= dst.len) return null;
            dst[n] = b;
            n += 1;
        } else {
            if (n + 3 > dst.len) return null;
            dst[n] = '%';
            dst[n + 1] = hex[b >> 4];
            dst[n + 2] = hex[b & 0xf];
            n += 3;
        }
    }
    return dst[0..n];
}

/// https://musicbrainz.org/ws/2/release-group/?query=release:".." AND artist:".."&fmt=json&limit=5
fn buildSearchUrl(buf: []u8, album: []const u8, artist: []const u8) ?[]const u8 {
    var q: [512]u8 = undefined;
    const query = std.fmt.bufPrint(&q, "release:\"{s}\" AND artist:\"{s}\" AND primarytype:album", .{ album, artist }) catch return null;
    var enc_buf: [1600]u8 = undefined;
    const enc = percentEncode(&enc_buf, query) orelse return null;
    return std.fmt.bufPrint(buf, "{s}{s}&fmt=json&limit=5", .{ search_url_base, enc }) catch null;
}

const ReleaseGroup = struct {
    id: []const u8,
    title: []const u8 = "",
};

const SearchResponse = struct {
    @"release-groups": []ReleaseGroup = &.{},
};

/// Pick the best release group for `album` (case-insensitive title match wins,
/// else the first/highest-score result). Returns an allocator-owned MBID.
fn pickReleaseGroup(allocator: std.mem.Allocator, body: []const u8, album: []const u8) ?[]const u8 {
    var parsed = std.json.parseFromSlice(SearchResponse, allocator, body, .{ .ignore_unknown_fields = true }) catch return null;
    defer parsed.deinit();

    const groups = parsed.value.@"release-groups";
    if (groups.len == 0) return null;
    for (groups) |g| {
        if (std.ascii.eqlIgnoreCase(g.title, album)) {
            return allocator.dupe(u8, g.id) catch null;
        }
    }
    return allocator.dupe(u8, groups[0].id) catch null;
}

test "percentEncode encodes query syntax" {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("release%3A%22It%27s%20a%20Sin%22", percentEncode(&buf, "release:\"It's a Sin\"").?);
}

test "pickReleaseGroup prefers an exact title match" {
    const body = "{\"release-groups\":[{\"id\":\"aaa\",\"title\":\"Other Album\"},{\"id\":\"bbb\",\"title\":\"Fashion\"}]}";
    const mbid = pickReleaseGroup(std.testing.allocator, body, "fashion").?;
    defer std.testing.allocator.free(mbid);
    try std.testing.expectEqualStrings("bbb", mbid);
}

test "pickReleaseGroup falls back to the first result" {
    const body = "{\"release-groups\":[{\"id\":\"zzz\",\"title\":\"Unrelated\"}]}";
    const mbid = pickReleaseGroup(std.testing.allocator, body, "Something Else").?;
    defer std.testing.allocator.free(mbid);
    try std.testing.expectEqualStrings("zzz", mbid);
}

test "pickReleaseGroup returns null on no results" {
    const body = "{\"release-groups\":[]}";
    try std.testing.expect(pickReleaseGroup(std.testing.allocator, body, "x") == null);
}
