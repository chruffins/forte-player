//! Last.fm scrobbling via the `zscrobble` library.
//!
//! Playback eligibility is tracked on the frontend thread, but HTTP submission
//! is queued to a dedicated worker. Last.fm outages or slow requests therefore
//! cannot pause audio or make the render loop miss frames.

const std = @import("std");
const zscrobble = @import("zscrobble");

const min_play_secs: f64 = 30.0;
const max_before_scrobble_secs: f64 = 240.0;

const Job = struct {
    artist: []u8,
    title: []u8,
    album: ?[]u8,
    timestamp: u32,
};

/// Seconds of play at which a track of `duration` seconds becomes eligible.
fn scrobbleThreshold(duration: f64) f64 {
    if (duration <= 0) return max_before_scrobble_secs;
    return @min(max_before_scrobble_secs, duration / 2.0);
}

pub fn scrobbleEligible(position: f64, duration: f64) bool {
    return position >= min_play_secs and position >= scrobbleThreshold(duration);
}

fn unixSeconds() u32 {
    return @intCast(std.Io.Clock.real.now(std.Io.Threaded.global_single_threaded.io()).toSeconds());
}

/// Short-lived interactive authorization ticket. The user opens `url`, grants
/// access, then the frontend calls finishAuth with this ticket's token.
pub const AuthTicket = struct {
    allocator: std.mem.Allocator,
    url: []u8,
    token: []u8,

    pub fn deinit(self: *AuthTicket) void {
        self.allocator.free(self.url);
        self.allocator.free(self.token);
        self.* = undefined;
    }
};

pub fn beginAuth(allocator: std.mem.Allocator, api_key: []const u8, shared_secret: []const u8) !AuthTicket {
    var client = try zscrobble.Client.init(allocator, api_key, shared_secret);
    defer client.deinit();
    try client.getToken();
    const url = try client.getAuthUrl(allocator);
    errdefer allocator.free(url);
    const token = try allocator.dupe(u8, client.token orelse return error.InvalidResponse);
    return .{ .allocator = allocator, .url = url, .token = token };
}

pub fn finishAuth(allocator: std.mem.Allocator, api_key: []const u8, shared_secret: []const u8, token: []const u8) ![]u8 {
    var client = try zscrobble.Client.init(allocator, api_key, shared_secret);
    defer client.deinit();
    client.token = try allocator.dupe(u8, token);
    try client.getSessionKey();
    return try allocator.dupe(u8, client.session_key orelse return error.InvalidResponse);
}

pub const Scrobbler = struct {
    allocator: std.mem.Allocator,
    client: ?zscrobble.Client,
    enabled: bool,

    // Frontend-thread playback state.
    cur_id: i64 = -1,
    cur_artist: []u8,
    cur_title: []u8,
    cur_album: ?[]u8,
    cur_started_at: u32 = 0,
    cur_duration: f64 = 0,
    cur_submitted: bool = false,
    cur_eligible: bool = false,

    // Worker-owned HTTP client; queue synchronization is shared.
    threaded: std.Io.Threaded,
    mutex: std.Io.Mutex = .init,
    condition: std.Io.Condition = .init,
    jobs: std.ArrayList(Job) = .{ .items = &.{}, .capacity = 0 },
    worker: ?std.Thread = null,
    stopping: bool = false,

    /// Build a scrobbler. It is disabled when credentials are missing or the
    /// client/worker cannot be initialized. Always call `destroy`.
    pub fn init(allocator: std.mem.Allocator, api_key: []const u8, shared_secret: []const u8, session_key: []const u8) ?*Scrobbler {
        const s = allocator.create(Scrobbler) catch return null;
        s.* = .{
            .allocator = allocator,
            .client = null,
            .enabled = false,
            .cur_artist = &.{},
            .cur_title = &.{},
            .cur_album = null,
            .threaded = std.Io.Threaded.init(allocator, .{}),
        };
        if (api_key.len == 0 or shared_secret.len == 0 or session_key.len == 0) return s;

        var client = zscrobble.Client.init(allocator, api_key, shared_secret) catch return s;
        client.setSessionKey(session_key) catch {
            client.deinit();
            return s;
        };
        s.client = client;
        s.worker = std.Thread.spawn(.{}, workerMain, .{s}) catch {
            s.client.?.deinit();
            s.client = null;
            return s;
        };
        s.enabled = true;
        return s;
    }

    pub fn destroy(self: *Scrobbler) void {
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
        self.jobs.deinit(self.allocator);
        self.clearCurrentMetadata();
        if (self.client) |*c| c.deinit();
        self.threaded.deinit();
        const a = self.allocator;
        a.destroy(self);
    }

    pub fn isEnabled(self: *const Scrobbler) bool {
        return self.enabled;
    }

    pub fn onSongStarted(self: *Scrobbler, id: i64, artist: []const u8, title: []const u8, album: []const u8) void {
        if (!self.enabled) return;

        const now = unixSeconds();
        if (self.cur_id >= 0 and !self.cur_submitted) {
            // Eligibility is latched from playing-time ticks, not wall-clock
            // time. A paused track must not become scrobble-eligible merely
            // because the user left it paused for several minutes.
            if (self.cur_eligible) {
                self.submit(self.cur_artist, self.cur_title, self.cur_album, self.cur_started_at);
            }
            self.cur_submitted = true;
        }

        const new_artist = self.allocator.dupe(u8, artist) catch return;
        const new_title = self.allocator.dupe(u8, title) catch {
            self.allocator.free(new_artist);
            return;
        };
        const new_album = if (album.len > 0) self.allocator.dupe(u8, album) catch {
            self.allocator.free(new_artist);
            self.allocator.free(new_title);
            return;
        } else null;
        self.clearCurrentMetadata();
        self.cur_id = id;
        self.cur_artist = new_artist;
        self.cur_title = new_title;
        self.cur_album = new_album;
        self.cur_started_at = now;
        self.cur_duration = 0;
        self.cur_submitted = false;
        self.cur_eligible = false;
    }

    pub fn tick(self: *Scrobbler, playing: bool, position: f64, duration: f64) void {
        if (!self.enabled or self.cur_id < 0 or self.cur_submitted) return;
        self.cur_duration = duration;
        if (playing and scrobbleEligible(position, duration)) {
            self.cur_eligible = true;
            self.submit(self.cur_artist, self.cur_title, self.cur_album, self.cur_started_at);
            self.cur_submitted = true;
        }
    }

    fn clearCurrentMetadata(self: *Scrobbler) void {
        if (self.cur_artist.len > 0) self.allocator.free(self.cur_artist);
        if (self.cur_title.len > 0) self.allocator.free(self.cur_title);
        if (self.cur_album) |album| self.allocator.free(album);
        self.cur_artist = &.{};
        self.cur_title = &.{};
        self.cur_album = null;
    }

    fn submit(self: *Scrobbler, artist: []const u8, title: []const u8, album: ?[]const u8, timestamp: u32) void {
        const owned_artist = self.allocator.dupe(u8, artist) catch return;
        const owned_title = self.allocator.dupe(u8, title) catch {
            self.allocator.free(owned_artist);
            return;
        };
        const owned_album = if (album) |value| self.allocator.dupe(u8, value) catch {
            self.allocator.free(owned_artist);
            self.allocator.free(owned_title);
            return;
        } else null;
        const job = Job{
            .artist = owned_artist,
            .title = owned_title,
            .album = owned_album,
            .timestamp = timestamp,
        };
        const io = self.threaded.io();
        self.mutex.lockUncancelable(io);
        if (self.stopping) {
            self.mutex.unlock(io);
            freeJob(self.allocator, job);
            return;
        }
        self.jobs.append(self.allocator, job) catch {
            self.mutex.unlock(io);
            freeJob(self.allocator, job);
            return;
        };
        self.condition.signal(io);
        self.mutex.unlock(io);
    }

    fn workerMain(self: *Scrobbler) void {
        const io = self.threaded.io();
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

            if (self.client) |*client| {
                var track = zscrobble.Track.init(self.allocator, job.artist, job.title, job.timestamp) catch {
                    freeJob(self.allocator, job);
                    continue;
                };
                defer track.deinit();
                if (job.album) |album| track.setAlbum(album) catch {};
                // Best effort: a failed request is discarded, never propagated
                // into the audio/render thread.
                client.scrobbleTrack(&track) catch {};
            }
            freeJob(self.allocator, job);
        }
    }
};

fn freeJob(allocator: std.mem.Allocator, job: Job) void {
    allocator.free(job.artist);
    allocator.free(job.title);
    if (job.album) |album| allocator.free(album);
}

test "scrobbleEligible: half-or-4-min rule" {
    try std.testing.expect(!scrobbleEligible(119.0, 240.0));
    try std.testing.expect(scrobbleEligible(120.0, 240.0));
    try std.testing.expect(!scrobbleEligible(239.0, 1200.0));
    try std.testing.expect(scrobbleEligible(240.0, 1200.0));
    try std.testing.expect(!scrobbleEligible(20.0, 40.0));
    try std.testing.expect(scrobbleEligible(30.0, 60.0));
    try std.testing.expect(scrobbleEligible(240.0, 0.0));
    try std.testing.expect(!scrobbleEligible(100.0, 0.0));
}

test "scrobbler without credentials is disabled" {
    var s = Scrobbler.init(std.testing.allocator, "", "", "").?;
    defer s.destroy();
    try std.testing.expect(!s.enabled);
    s.onSongStarted(1, "A", "T", "");
    s.tick(true, 1000.0, 100.0);
}
