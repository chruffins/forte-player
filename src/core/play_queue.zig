//! Port of `music::PlayQueue` from audio-visualizer-cpp (pure Zig, no Allegro).
//!
//! Tracks a queue of song ids, playback position, repeat/shuffle state and the
//! playback context (individual / album / playlist). Shuffle keeps the current
//! song first and uses a deterministic seed so tests are reproducible.

const std = @import("std");

pub const RepeatMode = enum { None, All, One };
pub const PlaybackContextType = enum { Individual, Album, Playlist };

pub const PlayQueue = struct {
    allocator: std.mem.Allocator,
    song_ids: std.ArrayList(i32) = .{ .items = &.{}, .capacity = 0 },
    /// Stack of indices actually played, for reverse navigation.
    played_indices: std.ArrayList(usize) = .{ .items = &.{}, .capacity = 0 },
    shuffle_order: std.ArrayList(usize) = .{ .items = &.{}, .capacity = 0 },

    current_index: usize = 0,
    shuffle_pos: usize = 0,
    is_shuffled: bool = false,
    repeat_mode: RepeatMode = .None,
    context_type: PlaybackContextType = .Individual,
    context_id: i32 = -1,
    /// Seed for the shuffle RNG (0 => deterministic, e.g. for tests).
    seed: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) PlayQueue {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *PlayQueue) void {
        self.song_ids.deinit(self.allocator);
        self.played_indices.deinit(self.allocator);
        self.shuffle_order.deinit(self.allocator);
    }

    fn rng(self: *const PlayQueue) std.Random {
        var prng = std.Random.DefaultPrng.init(self.seed);
        return prng.random();
    }

    pub fn enqueue(self: *PlayQueue, song_id: i32) !void {
        try self.song_ids.append(self.allocator, song_id);
        // queue changed - invalidate any existing shuffle metadata
        self.shuffle_order.clearRetainingCapacity();
        self.shuffle_pos = 0;
    }

    pub fn enqueueMany(self: *PlayQueue, ids: []const i32) !void {
        try self.song_ids.appendSlice(self.allocator, ids);
        self.shuffle_order.clearRetainingCapacity();
        self.shuffle_pos = 0;
    }

    /// Current song id without advancing. `null` if the queue is empty.
    pub fn current(self: *const PlayQueue) ?i32 {
        if (self.song_ids.items.len == 0 or self.current_index >= self.song_ids.items.len) return null;
        return self.song_ids.items[self.current_index];
    }

    /// Advance to the next song and return its id. `null` if there is no next.
    ///
    /// Play history is only recorded when the current song actually changes, so
    /// a *failing* `next()` (end of queue, no wrap) never corrupts `previous()`.
    pub fn next(self: *PlayQueue) !?i32 {
        const n = self.song_ids.items.len;
        if (n == 0) return null;
        if (self.repeat_mode == .One) return self.current();

        // Compute the target index first; null = no advance (leave history alone).
        var target: ?usize = null;
        var shuffle_target_pos: ?usize = null; // only used in shuffle mode

        if (self.is_shuffled) {
            // ensure we have a shuffle order
            if (self.shuffle_order.items.len == 0) {
                self.shuffle_order.clearRetainingCapacity();
                for (0..n) |i| try self.shuffle_order.append(self.allocator, i);
                self.rng().shuffleWithIndex(usize, self.shuffle_order.items, usize);
                // position shuffle_pos at current song
                var found: ?usize = null;
                for (self.shuffle_order.items, 0..) |idx, i| {
                    if (idx == self.current_index) {
                        found = i;
                        break;
                    }
                }
                if (found) |f| {
                    self.shuffle_pos = f;
                } else {
                    // current index not found (shouldn't happen) - start at 0
                    self.shuffle_pos = 0;
                    self.current_index = self.shuffle_order.items[0];
                    return self.song_ids.items[self.current_index];
                }
            }

            const pos = self.shuffle_pos;
            if (pos + 1 < self.shuffle_order.items.len) {
                target = self.shuffle_order.items[pos + 1];
                shuffle_target_pos = pos + 1;
            } else if (self.repeat_mode == .All and self.shuffle_order.items.len != 0) {
                // reached end of the shuffle list - wrap
                target = self.shuffle_order.items[0];
                shuffle_target_pos = 0;
            }
        } else {
            if (self.current_index + 1 < n) {
                target = self.current_index + 1;
            } else if (self.repeat_mode == .All) {
                target = 0;
            }
        }

        const t = target orelse return null; // no advance: don't touch history

        if (shuffle_target_pos) |p| self.shuffle_pos = p;
        if (t != self.current_index) {
            // record the song we're leaving only if we actually move
            try self.played_indices.append(self.allocator, self.current_index);
            self.current_index = t;
        }
        return self.song_ids.items[self.current_index];
    }

    /// Move to the previous song, using play history. `null` if none.
    pub fn previous(self: *PlayQueue) ?i32 {
        if (self.song_ids.items.len == 0) return null;

        if (self.played_indices.items.len != 0) {
            self.current_index = self.played_indices.pop().?;
            return self.song_ids.items[self.current_index];
        }

        if (self.current_index == 0) {
            if (self.repeat_mode == .All) {
                self.current_index = self.song_ids.items.len - 1;
                return self.song_ids.items[self.current_index];
            }
            return null;
        }
        self.current_index -= 1;
        return self.song_ids.items[self.current_index];
    }

    pub fn clear(self: *PlayQueue) void {
        self.song_ids.clearRetainingCapacity();
        self.played_indices.clearRetainingCapacity();
        self.shuffle_order.clearRetainingCapacity();
        self.current_index = 0;
        self.shuffle_pos = 0;
        self.context_type = .Individual;
        self.context_id = -1;
    }

    pub fn size(self: *const PlayQueue) usize {
        return self.song_ids.items.len;
    }

    /// Enable/disable shuffle. When enabling, the current song stays first and
    /// the rest are shuffled.
    pub fn setShuffled(self: *PlayQueue, on: bool) !void {
        if (on == self.is_shuffled) return;
        self.is_shuffled = on;
        if (on) {
            const n = self.song_ids.items.len;
            if (n == 0) {
                self.shuffle_order.clearRetainingCapacity();
                self.shuffle_pos = 0;
                return;
            }
            if (self.current_index >= n) self.current_index = 0;

            // collect other indices and shuffle them
            var others: std.ArrayList(usize) = .{ .items = &.{}, .capacity = 0 };
            defer others.deinit(self.allocator);
            for (0..n) |i| {
                if (i != self.current_index) try others.append(self.allocator, i);
            }
            if (others.items.len != 0) self.rng().shuffleWithIndex(usize, others.items, usize);

            // current_index first, then the shuffled others
            self.shuffle_order.clearRetainingCapacity();
            try self.shuffle_order.append(self.allocator, self.current_index);
            for (others.items) |idx| try self.shuffle_order.append(self.allocator, idx);
            self.shuffle_pos = 0;
        } else {
            self.shuffle_order.clearRetainingCapacity();
            self.shuffle_pos = 0;
        }
    }

    pub fn isShuffled(self: *const PlayQueue) bool {
        return self.is_shuffled;
    }

    pub fn repeat(self: *PlayQueue, on: bool) void {
        self.repeat_mode = if (on) .All else .None;
    }

    pub fn setRepeatMode(self: *PlayQueue, mode: RepeatMode) void {
        self.repeat_mode = mode;
    }

    pub fn getRepeatMode(self: *const PlayQueue) RepeatMode {
        return self.repeat_mode;
    }

    pub fn isRepeating(self: *const PlayQueue) bool {
        return self.repeat_mode != .None;
    }
};

test "queue: enqueue + advance (no repeat)" {
    var q = PlayQueue.init(std.testing.allocator);
    defer q.deinit();
    try q.enqueueMany(&.{ 10, 20, 30 });

    try std.testing.expectEqual(@as(?i32, 10), q.current());
    try std.testing.expectEqual(@as(?i32, 20), try q.next());
    try std.testing.expectEqual(@as(?i32, 30), try q.next());
    try std.testing.expectEqual(@as(?i32, null), try q.next()); // no wrap without repeat
    try std.testing.expectEqual(@as(?i32, 30), q.current());
}

test "queue: repeat All wraps to the start" {
    var q = PlayQueue.init(std.testing.allocator);
    defer q.deinit();
    try q.enqueueMany(&.{ 1, 2, 3 });
    q.setRepeatMode(.All);

    try std.testing.expectEqual(@as(?i32, 2), try q.next()); // 2
    try std.testing.expectEqual(@as(?i32, 3), try q.next()); // 3
    try std.testing.expectEqual(@as(?i32, 1), try q.next()); // wraps to 1
}

test "queue: repeat One returns current without advancing" {
    var q = PlayQueue.init(std.testing.allocator);
    defer q.deinit();
    try q.enqueueMany(&.{ 7, 8 });
    q.setRepeatMode(.One);

    try std.testing.expectEqual(@as(?i32, 7), try q.next());
    try std.testing.expectEqual(@as(?i32, 7), try q.next());
    try std.testing.expectEqual(@as(?i32, 7), q.current());
}

test "queue: previous uses play history" {
    var q = PlayQueue.init(std.testing.allocator);
    defer q.deinit();
    try q.enqueueMany(&.{ 10, 20, 30, 40 });

    _ = try q.next(); // 20, history=[0]
    _ = try q.next(); // 30, history=[0,1]
    _ = try q.next(); // 40, history=[0,1,2]

    try std.testing.expectEqual(@as(?i32, 30), q.previous()); // back to 30
    try std.testing.expectEqual(@as(?i32, 20), q.previous());
}

test "queue: failed next() does not corrupt previous()" {
    var q = PlayQueue.init(std.testing.allocator);
    defer q.deinit();
    try q.enqueueMany(&.{ 10, 20, 30 });

    _ = try q.next(); // 20
    _ = try q.next(); // 30
    try std.testing.expectEqual(@as(?i32, null), try q.next()); // no wrap (repeat None)

    // previous must return 20, not linger on the current song (30).
    try std.testing.expectEqual(@as(?i32, 20), q.previous());
}

test "queue: shuffle keeps current first, all ids present" {
    var q = PlayQueue.init(std.testing.allocator);
    defer q.deinit();
    try q.enqueueMany(&.{ 100, 200, 300, 400, 500 });
    q.seed = 1234;

    try q.setShuffled(true);
    try std.testing.expect(q.isShuffled());

    // current stays first
    try std.testing.expectEqual(@as(?i32, 100), q.current());

    // traverse the whole shuffle order (repeat off), each id exactly once
    var seen = [_]bool{ false, false, false, false, false };
    seen[0] = true; // current (100) is first in the order
    var count: usize = 1;
    while (try q.next()) |id| {
        const idx: usize = @intCast(@divTrunc(id - 100, 100));
        try std.testing.expect(!seen[idx]);
        seen[idx] = true;
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 5), count);
    for (seen) |s| try std.testing.expect(s);
}
