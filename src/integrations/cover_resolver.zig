//! Album cover resolution for Discord presence.
//!
//! MusicBrainz and Cover Art Archive requests run on a dedicated worker thread.
//! The main thread only queues jobs and applies completed results, so a slow
//! network or TLS handshake cannot stall playback, rendering, or input.

const std = @import("std");
const db_mod = @import("../music/database.zig");

const user_agent = "forte-player/0.1 (https://github.com/chruffins/audio-visualizer-cpp)";
const search_url_base = "https://musicbrainz.org/ws/2/release-group/?query=";
const cover_url_base = "https://coverartarchive.org/release-group/";

const JobKind = enum { lookup, image };
const Job = struct {
    kind: JobKind,
    album_id: i64,
    first: []u8,
    second: []u8,
};
pub const FailureKind = enum { invalid_query, request_failed, http_status, invalid_response, out_of_memory };

pub const Failure = struct {
    kind: FailureKind,
    album_id: i64,
};

const Result = struct {
    kind: JobKind,
    album_id: i64,
    failure: ?FailureKind = null,
    url: ?[]u8 = null,
    mbid: ?[]u8 = null,
    bytes: ?[]u8 = null,
};

pub const CoverResolver = struct {
    allocator: std.mem.Allocator,
    db: *db_mod.Database,
    threaded: std.Io.Threaded,
    client: std.http.Client,

    // These fields are main-thread-owned. The worker communicates through the
    // jobs/results queues below and never touches the database or UI caches.
    cache: std.AutoHashMapUnmanaged(i64, Entry) = .{},
    image_cache: std.AutoHashMapUnmanaged(i64, []const u8) = .{},
    /// FIFO eviction keeps downloaded artwork bounded for large libraries.
    image_order: std.ArrayList(i64) = .{ .items = &.{}, .capacity = 0 },
    image_cache_bytes: usize = 0,
    image_pending: std.AutoHashMapUnmanaged(i64, void) = .{},
    last_failure: ?Failure = null,

    mutex: std.Io.Mutex = .init,
    condition: std.Io.Condition = .init,
    jobs: std.ArrayList(Job) = .{ .items = &.{}, .capacity = 0 },
    results: std.ArrayList(Result) = .{ .items = &.{}, .capacity = 0 },
    worker: ?std.Thread = null,
    stopping: bool = false,

    const Entry = union(enum) {
        pending,
        ok: []const u8,
        none,
    };

    /// Create on the heap: the HTTP client's Io and the worker both retain a
    /// pointer to this resolver, so its address must remain stable.
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

        // If thread creation fails, deinit also tears down the HTTP client,
        // caches, and threaded I/O before the heap object is released.
        errdefer r.deinit();
        r.worker = try std.Thread.spawn(.{}, workerMain, .{r});
        return r;
    }

    pub fn destroy(self: *CoverResolver) void {
        self.deinit();
        const allocator = self.allocator;
        allocator.destroy(self);
    }

    pub fn deinit(self: *CoverResolver) void {
        const io = self.threaded.io();
        if (self.worker) |thread| {
            self.mutex.lockUncancelable(io);
            self.stopping = true;
            for (self.jobs.items) |job| freeJob(self.allocator, job);
            self.jobs.clearRetainingCapacity();
            self.condition.broadcast(io);
            self.mutex.unlock(io);
            thread.join();
            self.worker = null;
        }

        var it = self.cache.valueIterator();
        while (it.next()) |e| switch (e.*) {
            .ok => |url| self.allocator.free(url),
            else => {},
        };
        self.cache.deinit(self.allocator);

        var iit = self.image_cache.valueIterator();
        while (iit.next()) |bytes| if (bytes.*.len > 0) self.allocator.free(bytes.*);
        self.image_cache.deinit(self.allocator);
        self.image_order.deinit(self.allocator);
        self.image_pending.deinit(self.allocator);

        for (self.results.items) |result| freeResult(self.allocator, result);
        self.results.deinit(self.allocator);
        self.jobs.deinit(self.allocator);
        self.client.deinit();
        self.threaded.deinit();
    }

    /// Queue a MusicBrainz lookup for an album. This is idempotent.
    pub fn enqueue(self: *CoverResolver, album_id: i64, album: []const u8, artist: []const u8) void {
        if (self.cache.contains(album_id)) return;
        self.cache.put(self.allocator, album_id, .pending) catch return;

        const owned_album = self.allocator.dupe(u8, album) catch {
            _ = self.cache.remove(album_id);
            return;
        };
        const owned_artist = self.allocator.dupe(u8, artist) catch {
            self.allocator.free(owned_album);
            _ = self.cache.remove(album_id);
            return;
        };
        if (!self.enqueueOwned(.{
            .kind = .lookup,
            .album_id = album_id,
            .first = owned_album,
            .second = owned_artist,
        })) {
            self.allocator.free(owned_album);
            self.allocator.free(owned_artist);
            _ = self.cache.remove(album_id);
        }
    }

    /// Cover URL for an album if already resolved, else null.
    pub fn coverUrlFor(self: *const CoverResolver, album_id: i64) ?[]const u8 {
        return switch (self.cache.get(album_id) orelse return null) {
            .ok => |url| url,
            else => null,
        };
    }

    /// Return already-fetched cover bytes. If the URL is known but the image is
    /// not cached, this schedules a background download and returns null until
    /// a later poll observes its result.
    pub fn coverImageBytes(self: *CoverResolver, album_id: i64) ?[]const u8 {
        if (self.image_cache.get(album_id)) |bytes| {
            return if (bytes.len > 0) bytes else null;
        }
        if (self.image_pending.contains(album_id)) return null;
        const url = self.coverUrlFor(album_id) orelse return null;
        const owned_url = self.allocator.dupe(u8, url) catch return null;
        self.image_pending.put(self.allocator, album_id, {}) catch {
            self.allocator.free(owned_url);
            return null;
        };
        if (!self.enqueueOwned(.{
            .kind = .image,
            .album_id = album_id,
            .first = owned_url,
            .second = &.{},
        })) {
            self.allocator.free(owned_url);
            _ = self.image_pending.remove(album_id);
        }
        return null;
    }

    /// Return and clear the most recent worker failure.
    pub fn takeFailure(self: *CoverResolver) ?Failure {
        const failure = self.last_failure;
        self.last_failure = null;
        return failure;
    }

    /// Apply completed worker results. No network is performed here. Returns
    /// true when at least one result was applied so the frontend can redraw.
    pub fn tick(self: *CoverResolver) bool {
        var changed = false;
        while (true) {
            var result: ?Result = null;
            const io = self.threaded.io();
            self.mutex.lockUncancelable(io);
            if (self.results.items.len > 0) result = self.results.orderedRemove(0);
            self.mutex.unlock(io);
            const r = result orelse break;
            changed = true;
            self.applyResult(r);
        }
        return changed;
    }

    fn enqueueOwned(self: *CoverResolver, job: Job) bool {
        const io = self.threaded.io();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.jobs.append(self.allocator, job) catch return false;
        self.condition.signal(io);
        return true;
    }

    fn workerMain(self: *CoverResolver) void {
        const io = self.threaded.io();
        var made_request = false;
        while (true) {
            self.mutex.lockUncancelable(io);
            while (self.jobs.items.len == 0 and !self.stopping) {
                self.condition.waitUncancelable(io, &self.mutex);
            }
            if (self.stopping and self.jobs.items.len == 0) {
                self.mutex.unlock(io);
                return;
            }
            const job = self.jobs.orderedRemove(0);
            self.mutex.unlock(io);

            // MusicBrainz requests are rate-limited to roughly one per second.
            // Sleeping here, rather than in tick(), keeps the UI responsive.
            if (made_request) {
                _ = std.Io.Clock.Duration.sleep(
                    .{ .clock = .boot, .raw = std.Io.Duration.fromSeconds(1) },
                    io,
                ) catch {};
            }
            made_request = true;
            const result = switch (job.kind) {
                .lookup => self.lookupNetwork(job.album_id, job.first, job.second),
                .image => self.fetchImage(job.album_id, job.first),
            };
            freeJob(self.allocator, job);

            self.mutex.lockUncancelable(io);
            if (self.stopping) {
                freeResult(self.allocator, result);
            } else {
                self.results.append(self.allocator, result) catch freeResult(self.allocator, result);
            }
            self.mutex.unlock(io);
        }
    }

    // The TUI only needs the current/near-current artwork. Keeping 32 MiB of
    // decoded network responses made RSS look like a leak after browsing a
    // few albums, even though the cache was technically bounded. Eight MiB
    // retains normal cover sizes while putting a tighter ceiling on long runs.
    const max_image_cache_bytes: usize = 8 * 1024 * 1024;

    fn removeImageOrder(self: *CoverResolver, album_id: i64) void {
        var i: usize = 0;
        while (i < self.image_order.items.len) {
            if (self.image_order.items[i] == album_id) {
                _ = self.image_order.orderedRemove(i);
            } else {
                i += 1;
            }
        }
    }

    fn trimImageCache(self: *CoverResolver) void {
        // Keep the newest result even if a single response is larger than the
        // budget; otherwise the next frame would immediately re-download the
        // same current artwork forever.
        while (self.image_cache_bytes > max_image_cache_bytes and self.image_order.items.len > 1) {
            const album_id = self.image_order.orderedRemove(0);
            if (self.image_cache.fetchRemove(album_id)) |old| {
                self.image_cache_bytes -|= old.value.len;
                if (old.value.len > 0) self.allocator.free(old.value);
            }
        }
    }

    fn applyResult(self: *CoverResolver, result: Result) void {
        if (result.failure) |kind| self.last_failure = .{ .kind = kind, .album_id = result.album_id };
        switch (result.kind) {
            .lookup => {
                if (result.mbid) |mbid| {
                    self.db.setAlbumMbid(result.album_id, mbid) catch {};
                    self.allocator.free(mbid);
                }
                if (result.url) |url| {
                    if (self.cache.fetchRemove(result.album_id)) |old| {
                        switch (old.value) {
                            .ok => |old_url| self.allocator.free(old_url),
                            else => {},
                        }
                    }
                    self.cache.put(self.allocator, result.album_id, .{ .ok = url }) catch {
                        self.allocator.free(url);
                    };
                } else {
                    _ = self.cache.put(self.allocator, result.album_id, .none) catch {};
                }
            },
            .image => {
                _ = self.image_pending.remove(result.album_id);
                const bytes = result.bytes orelse &.{};
                if (self.image_cache.fetchRemove(result.album_id)) |old| {
                    self.image_cache_bytes -|= old.value.len;
                    if (old.value.len > 0) self.allocator.free(old.value);
                    self.removeImageOrder(result.album_id);
                }
                self.image_cache.put(self.allocator, result.album_id, bytes) catch {
                    if (bytes.len > 0) self.allocator.free(bytes);
                    return;
                };
                self.image_cache_bytes += bytes.len;
                if (bytes.len > 0) self.image_order.append(self.allocator, result.album_id) catch {
                    _ = self.image_cache.remove(result.album_id);
                    self.image_cache_bytes -|= bytes.len;
                    self.allocator.free(bytes);
                    return;
                };
                self.trimImageCache();
            },
        }
    }

    fn lookupNetwork(self: *CoverResolver, album_id: i64, album: []const u8, artist: []const u8) Result {
        var result = Result{ .kind = .lookup, .album_id = album_id };
        var url_buf: [1024]u8 = undefined;
        const search_url = buildSearchUrl(&url_buf, album, artist) orelse {
            result.failure = .invalid_query;
            return result;
        };

        var body_buf: [1 << 20]u8 = undefined;
        var w = std.Io.Writer.fixed(&body_buf);
        const response = self.client.fetch(.{
            .location = .{ .url = search_url },
            .headers = .{ .user_agent = .{ .override = user_agent } },
            .response_writer = &w,
        }) catch {
            result.failure = .request_failed;
            return result;
        };
        if (response.status != .ok) {
            result.failure = .http_status;
            return result;
        }

        const mbid = pickReleaseGroup(self.allocator, body_buf[0..w.end], album) orelse {
            result.failure = .invalid_response;
            return result;
        };
        const url = std.fmt.allocPrint(self.allocator, "{s}{s}/front", .{ cover_url_base, mbid }) catch {
            self.allocator.free(mbid);
            result.failure = .out_of_memory;
            return result;
        };
        result.mbid = mbid;
        result.url = url;
        return result;
    }

    fn fetchImage(self: *CoverResolver, album_id: i64, url: []const u8) Result {
        var result = Result{ .kind = .image, .album_id = album_id };
        var buf: [2 << 20]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        const response = self.client.fetch(.{
            .location = .{ .url = url },
            .headers = .{ .user_agent = .{ .override = user_agent } },
            .response_writer = &w,
        }) catch {
            result.failure = .request_failed;
            return result;
        };
        if (response.status != .ok) {
            result.failure = .http_status;
            return result;
        }
        result.bytes = self.allocator.dupe(u8, buf[0..w.end]) catch {
            result.failure = .out_of_memory;
            return result;
        };
        return result;
    }
};

fn freeJob(allocator: std.mem.Allocator, job: Job) void {
    allocator.free(job.first);
    if (job.second.len > 0) allocator.free(job.second);
}

fn freeResult(allocator: std.mem.Allocator, result: Result) void {
    if (result.url) |url| allocator.free(url);
    if (result.mbid) |mbid| allocator.free(mbid);
    if (result.bytes) |bytes| allocator.free(bytes);
}

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
fn pickReleaseGroup(allocator: std.mem.Allocator, body: []const u8, album: []const u8) ?[]u8 {
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
