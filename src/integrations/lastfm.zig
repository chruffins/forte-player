//! Last.fm scrobbling via the `zscrob` library (a local Zig rewrite of libscrob).
//!
//! The `Scrobbler` listens to song changes (`onSongStarted`) and per-frame ticks
//! from the frontend, and submits a scrobble once a track has been played long
//! enough to count. The standard Last.fm rule is used: a track counts once it
//! has been playing for at least half its duration, or four minutes, whichever
//! comes first — and never earlier than 30 seconds.
//!
//! Submission is synchronous (a tiny HTTP POST) and happens at most once per
//! track, so it never floods the UI; this mirrors how the cover resolver already
//! performs occasional HTTP work from `tick()`. Credentials come from the config
//! (`lastfm` section). If any of api_key / shared_secret / session_key is
//! missing, the scrobbler is created disabled and this whole module is a no-op.

const std = @import("std");
const zscrob = @import("zscrob");

const c_time = @cImport({ @cInclude("time.h"); });

/// No track counts before this many seconds of play.
const min_play_secs: f64 = 30.0;
/// A track is fully "played" after this many seconds, or half its duration,
/// whichever comes first.
const max_before_scrobble_secs: f64 = 240.0;

/// Seconds of play at which a track of `duration` (0 = unknown) becomes
/// scrobble-eligible.
fn scrobbleThreshold(duration: f64) f64 {
    if (duration <= 0) return max_before_scrobble_secs;
    return @min(max_before_scrobble_secs, duration / 2.0);
}

/// Pure playback-eligibility rule: a track of `duration` seconds at playback
/// `position` has been played enough to scrobble.
pub fn scrobbleEligible(position: f64, duration: f64) bool {
    return position >= min_play_secs and position >= scrobbleThreshold(duration);
}

fn unixSeconds() u32 {
    return @intCast(@as(i64, @intCast(c_time.time(null))));
}

pub const Scrobbler = struct {
    allocator: std.mem.Allocator,
    client: ?zscrob.Client,
    enabled: bool,

    // ---- current-track tracking (owned by the frontend thread) ----
    cur_id: i64 = -1,
    /// Borrowed from the library arena (valid for the app's lifetime).
    cur_artist: []const u8,
    cur_title: []const u8,
    cur_album: ?[]const u8,
    /// Unix seconds when playback of the current track began.
    cur_started_at: u32 = 0,
    cur_duration: f64 = 0,
    /// True once the current track has been (or was skipped and decided on).
    cur_submitted: bool = false,

    /// Build a scrobbler. Returns null on allocation failure; otherwise returns
    /// a (possibly disabled) scrobbler. It is disabled when a credential is
    /// missing or the session key is rejected. Always call `destroy`.
    pub fn init(allocator: std.mem.Allocator, api_key: []const u8, shared_secret: []const u8, session_key: []const u8) ?*Scrobbler {
        const s = allocator.create(Scrobbler) catch return null;
        s.* = .{
            .allocator = allocator,
            .client = null,
            .enabled = false,
            .cur_artist = "",
            .cur_title = "",
            .cur_album = null,
        };
        if (api_key.len == 0 or shared_secret.len == 0 or session_key.len == 0) return s;

        var client = zscrob.Client.init(allocator, api_key, shared_secret) catch return s;
        client.setSessionKey(session_key) catch {
            client.deinit();
            return s;
        };
        s.client = client;
        s.enabled = true;
        return s;
    }

    pub fn destroy(self: *Scrobbler) void {
        if (self.client) |*c| c.deinit();
        const a = self.allocator;
        a.destroy(self);
    }

    pub fn isEnabled(self: *const Scrobbler) bool {
        return self.enabled;
    }

    /// A new track started. Finalizes the previous one (submitting it if it had
    /// played long enough to count) and resets the current-track state. `now` is
    /// the unix time the new track began.
    pub fn onSongStarted(self: *Scrobbler, id: i64, artist: []const u8, title: []const u8, album: []const u8) void {
        if (!self.enabled) return;

        // Finalize the outgoing track before overwriting it.
        const now = unixSeconds();
        if (self.cur_id >= 0 and !self.cur_submitted) {
            const elapsed: f64 = @floatFromInt(now -| self.cur_started_at);
            if (scrobbleEligible(elapsed, self.cur_duration)) {
                self.submit(self.cur_artist, self.cur_title, self.cur_album, self.cur_started_at);
            }
            self.cur_submitted = true; // decided either way — don't re-submit
        }

        self.cur_id = id;
        self.cur_artist = artist;
        self.cur_title = title;
        self.cur_album = if (album.len > 0) album else null;
        self.cur_started_at = now;
        self.cur_duration = 0;
        self.cur_submitted = false;
    }

    /// Per-frame drive: submit the current track the moment it becomes
    /// scrobble-eligible. `position`/`duration` come from the engine snapshot.
    pub fn tick(self: *Scrobbler, playing: bool, position: f64, duration: f64) void {
        if (!self.enabled or self.cur_id < 0 or self.cur_submitted) return;
        self.cur_duration = duration;
        if (playing and scrobbleEligible(position, duration)) {
            self.submit(self.cur_artist, self.cur_title, self.cur_album, self.cur_started_at);
            self.cur_submitted = true;
        }
    }

    fn submit(self: *Scrobbler, artist: []const u8, title: []const u8, album: ?[]const u8, timestamp: u32) void {
        const client = &(self.client orelse return);
        var track = zscrob.Track.init(self.allocator, artist, title, timestamp) catch return;
        defer track.deinit();
        if (album) |a| track.setAlbum(a) catch {};
        // Best-effort: a failed network call must never interrupt playback.
        zscrob.scrobble.scrobbleTrack(client, &track) catch return;
    }
};

test "scrobbleEligible: half-or-4-min rule" {
    // A 4-minute song counts at 2:00 (half duration < 4 min).
    try std.testing.expect(!scrobbleEligible(119.0, 240.0));
    try std.testing.expect(scrobbleEligible(120.0, 240.0));

    // A 20-minute song counts at 4:00 (4 min < half).
    try std.testing.expect(!scrobbleEligible(239.0, 1200.0));
    try std.testing.expect(scrobbleEligible(240.0, 1200.0));

    // Never before 30 seconds, even for a short song.
    try std.testing.expect(!scrobbleEligible(20.0, 40.0));
    // A 60-second song counts exactly at 30s (half duration).
    try std.testing.expect(scrobbleEligible(30.0, 60.0));

    // Unknown duration: the 4-minute floor applies.
    try std.testing.expect(scrobbleEligible(240.0, 0.0));
    try std.testing.expect(!scrobbleEligible(100.0, 0.0));
}

test "scrobbler without credentials is disabled" {
    var s = Scrobbler.init(std.testing.allocator, "", "", "").?;
    defer s.destroy();
    try std.testing.expect(!s.enabled);

    // Even if driven, a disabled scrobbler must not crash.
    s.onSongStarted(1, "A", "T", "");
    s.tick(true, 1000.0, 100.0);
}
