//! Port of `music::PlayQueue` from audio-visualizer-cpp (pure Zig, no Allegro).
//!
//! Tracks a queue of song ids, playback position, repeat/shuffle state and the
//! playback context (individual / album / playlist). Shuffle keeps the current
//! song first and uses a deterministic seed so tests are reproducible.

const std = @import("std");

pub const RepeatMode = enum { None, All, One };
pub const PlaybackContextType = enum { Individual, Album, Playlist, Artist, Genre };

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
    /// Seed for the shuffle RNG. Tests can overwrite this with a fixed value;
    /// normal queues get a fresh seed so shuffle order differs between runs.
    seed: u64 = 0,
    /// Increments when queue membership/order changes. Frontends use this to
    /// avoid rebuilding expensive queue display rows on every animation tick.
    generation: u64 = 0,

    pub const Cursor = struct {
        current_index: usize,
        shuffle_pos: usize,
        played_len: usize,
        shuffle_order_len: usize,
    };

    /// Owned rollback state for operations that replace the playback context.
    /// Queue replacement can be followed by a stream-load failure, so callers
    /// need more than the lightweight navigation cursor to restore safely.
    pub const Snapshot = struct {
        allocator: std.mem.Allocator,
        song_ids: std.ArrayList(i32) = .{ .items = &.{}, .capacity = 0 },
        played_indices: std.ArrayList(usize) = .{ .items = &.{}, .capacity = 0 },
        shuffle_order: std.ArrayList(usize) = .{ .items = &.{}, .capacity = 0 },
        current_index: usize,
        shuffle_pos: usize,
        is_shuffled: bool,
        repeat_mode: RepeatMode,
        context_type: PlaybackContextType,
        context_id: i32,
        seed: u64,
        generation: u64,

        pub fn deinit(self: *Snapshot) void {
            self.song_ids.deinit(self.allocator);
            self.played_indices.deinit(self.allocator);
            self.shuffle_order.deinit(self.allocator);
        }
    };

    pub fn init(allocator: std.mem.Allocator) PlayQueue {
        var seed: u64 = 0;
        std.Io.Threaded.global_single_threaded.io().random(std.mem.asBytes(&seed));
        return .{
            .allocator = allocator,
            .seed = seed,
        };
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

    pub fn cursor(self: *const PlayQueue) Cursor {
        return .{
            .current_index = self.current_index,
            .shuffle_pos = self.shuffle_pos,
            .played_len = self.played_indices.items.len,
            .shuffle_order_len = self.shuffle_order.items.len,
        };
    }

    pub fn snapshot(self: *const PlayQueue) !Snapshot {
        var out = Snapshot{
            .allocator = self.allocator,
            .current_index = self.current_index,
            .shuffle_pos = self.shuffle_pos,
            .is_shuffled = self.is_shuffled,
            .repeat_mode = self.repeat_mode,
            .context_type = self.context_type,
            .context_id = self.context_id,
            .seed = self.seed,
            .generation = self.generation,
        };
        errdefer out.deinit();
        try out.song_ids.appendSlice(self.allocator, self.song_ids.items);
        try out.played_indices.appendSlice(self.allocator, self.played_indices.items);
        try out.shuffle_order.appendSlice(self.allocator, self.shuffle_order.items);
        return out;
    }

    /// Restore and consume an owned snapshot without allocating. This is used
    /// on stream-load failure, where a second allocation could fail too.
    pub fn restoreSnapshot(self: *PlayQueue, saved: *Snapshot) void {
        self.song_ids.deinit(self.allocator);
        self.played_indices.deinit(self.allocator);
        self.shuffle_order.deinit(self.allocator);
        self.song_ids = saved.song_ids;
        self.played_indices = saved.played_indices;
        self.shuffle_order = saved.shuffle_order;
        saved.song_ids = .{ .items = &.{}, .capacity = 0 };
        saved.played_indices = .{ .items = &.{}, .capacity = 0 };
        saved.shuffle_order = .{ .items = &.{}, .capacity = 0 };
        self.current_index = saved.current_index;
        self.shuffle_pos = saved.shuffle_pos;
        self.is_shuffled = saved.is_shuffled;
        self.repeat_mode = saved.repeat_mode;
        self.context_type = saved.context_type;
        self.context_id = saved.context_id;
        self.seed = saved.seed;
        self.generation = saved.generation;
    }

    /// Restore the navigation state captured by `cursor()`. This is used by the
    /// engine when a candidate song cannot be loaded, so a failed transition
    /// does not consume queue history or leave the cursor stranded.
    pub fn restore(self: *PlayQueue, state: Cursor) void {
        self.current_index = state.current_index;
        self.shuffle_pos = state.shuffle_pos;
        // `pop()` and `clearRetainingCapacity()` preserve the backing storage,
        // so restoring a cursor may need to grow the visible length again.
        // The snapshot was taken from these same lists, therefore capacity is
        // sufficient unless the caller discarded the queue entirely.
        if (state.played_len <= self.played_indices.capacity) {
            self.played_indices.items.len = state.played_len;
        }
        if (state.shuffle_order_len <= self.shuffle_order.capacity) {
            self.shuffle_order.items.len = state.shuffle_order_len;
        }
    }

    pub fn currentIndex(self: *const PlayQueue) usize {
        return self.current_index;
    }

    pub fn revision(self: *const PlayQueue) u64 {
        return self.generation;
    }

    fn changed(self: *PlayQueue) void {
        self.generation +%= 1;
    }

    fn syncShufflePos(self: *PlayQueue) void {
        if (!self.is_shuffled) return;
        for (self.shuffle_order.items, 0..) |idx, pos| {
            if (idx == self.current_index) {
                self.shuffle_pos = pos;
                return;
            }
        }
    }

    /// Select an exact queue occurrence after a user-initiated jump. This is
    /// index-based because the same song may legitimately appear more than
    /// once in a queue.
    pub fn selectIndex(self: *PlayQueue, index: usize) !void {
        if (index >= self.song_ids.items.len) return error.IndexOutOfBounds;
        self.current_index = index;
        self.played_indices.clearRetainingCapacity();
        if (self.is_shuffled and self.shuffle_order.items.len == 0) {
            try self.rebuildShuffleOrder();
        }
        self.syncShufflePos();
    }

    /// Select the first queue occurrence of a song id.
    pub fn selectSong(self: *PlayQueue, song_id: i32) !void {
        for (self.song_ids.items, 0..) |id, index| {
            if (id == song_id) return self.selectIndex(index);
        }
        return error.SongNotInQueue;
    }

    /// Set the starting index for a newly-built context without recording the
    /// old queue cursor as history.
    pub fn setStartIndex(self: *PlayQueue, index: usize) !void {
        if (index >= self.song_ids.items.len) return error.IndexOutOfBounds;
        self.current_index = index;
        self.played_indices.clearRetainingCapacity();
        if (self.is_shuffled and self.shuffle_order.items.len == 0) {
            try self.rebuildShuffleOrder();
        }
        self.syncShufflePos();
    }

    /// Commit a successfully loaded queue transition. `next()` uses this too;
    /// callers that probe several candidates can restore a cursor and commit
    /// only the candidate that actually loaded.
    pub fn commitIndex(self: *PlayQueue, index: usize) !void {
        if (index >= self.song_ids.items.len) return error.IndexOutOfBounds;
        if (index != self.current_index) {
            try self.played_indices.append(self.allocator, self.current_index);
            self.current_index = index;
        }
        self.syncShufflePos();
    }

    fn rebuildShuffleOrder(self: *PlayQueue) !void {
        const n = self.song_ids.items.len;
        self.shuffle_order.clearRetainingCapacity();
        self.shuffle_pos = 0;
        if (n == 0) return;

        var others: std.ArrayList(usize) = .{ .items = &.{}, .capacity = 0 };
        defer others.deinit(self.allocator);
        for (0..n) |i| {
            if (i != self.current_index) try others.append(self.allocator, i);
        }
        if (others.items.len != 0) self.rng().shuffleWithIndex(usize, others.items, usize);
        try self.shuffle_order.append(self.allocator, self.current_index);
        try self.shuffle_order.appendSlice(self.allocator, others.items);
    }

    pub fn enqueue(self: *PlayQueue, song_id: i32) !void {
        try self.song_ids.append(self.allocator, song_id);
        // queue changed - invalidate any existing shuffle metadata
        self.shuffle_order.clearRetainingCapacity();
        self.shuffle_pos = 0;
        self.changed();
    }

    pub fn enqueueMany(self: *PlayQueue, ids: []const i32) !void {
        try self.song_ids.appendSlice(self.allocator, ids);
        self.shuffle_order.clearRetainingCapacity();
        self.shuffle_pos = 0;
        if (ids.len > 0) self.changed();
    }

    /// Insert a song immediately after the current occurrence. This is the
    /// queue equivalent of a user-facing "play next" action.
    pub fn enqueueNext(self: *PlayQueue, song_id: i32) !void {
        if (self.song_ids.items.len == 0) return self.enqueue(song_id);
        const index = @min(self.current_index + 1, self.song_ids.items.len);
        try self.song_ids.insert(self.allocator, index, song_id);
        self.shuffle_order.clearRetainingCapacity();
        self.shuffle_pos = 0;
        self.changed();
    }

    pub fn items(self: *const PlayQueue) []const i32 {
        return self.song_ids.items;
    }

    /// Replace the queue with a new playback context.
    pub fn replace(self: *PlayQueue, ids: []const i32, context_type: PlaybackContextType, context_id: i32) !void {
        // Build the replacement first so an allocation failure leaves the
        // existing queue and its cursor untouched.
        var replacement: std.ArrayList(i32) = .{ .items = &.{}, .capacity = 0 };
        errdefer replacement.deinit(self.allocator);
        try replacement.appendSlice(self.allocator, ids);
        self.song_ids.deinit(self.allocator);
        self.song_ids = replacement;
        self.played_indices.clearRetainingCapacity();
        self.shuffle_order.clearRetainingCapacity();
        self.current_index = 0;
        self.shuffle_pos = 0;
        self.context_type = context_type;
        self.context_id = context_id;
        self.changed();
    }

    pub fn removeAt(self: *PlayQueue, index: usize) !void {
        if (index >= self.song_ids.items.len) return error.IndexOutOfBounds;
        const removed_current = index == self.current_index;
        _ = self.song_ids.orderedRemove(index);
        self.played_indices.clearRetainingCapacity();
        self.shuffle_order.clearRetainingCapacity();
        if (self.song_ids.items.len == 0) {
            self.current_index = 0;
        } else if (removed_current) {
            self.current_index = @min(index, self.song_ids.items.len - 1);
        } else if (index < self.current_index) {
            self.current_index -= 1;
        }
        self.shuffle_pos = 0;
        self.changed();
    }

    pub fn moveAt(self: *PlayQueue, from: usize, to: usize) !void {
        if (from >= self.song_ids.items.len or to >= self.song_ids.items.len) return error.IndexOutOfBounds;
        if (from == to) return;
        const old_current = self.current_index;
        const id = self.song_ids.orderedRemove(from);
        try self.song_ids.insert(self.allocator, to, id);
        self.played_indices.clearRetainingCapacity();
        self.shuffle_order.clearRetainingCapacity();
        // Preserve the current *occurrence*, not just its song id. Duplicate
        // queue entries are valid and searching by id would select the wrong
        // one after a reorder.
        if (from == old_current) {
            self.current_index = to;
        } else {
            var new_index = old_current;
            if (from < new_index) new_index -= 1;
            if (to <= new_index) new_index += 1;
            self.current_index = new_index;
        }
        self.shuffle_pos = 0;
        self.changed();
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
                try self.rebuildShuffleOrder();
                self.syncShufflePos();
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
        try self.commitIndex(t);
        return self.song_ids.items[self.current_index];
    }

    /// Move to the previous song, using play history. `null` if none.
    pub fn previous(self: *PlayQueue) ?i32 {
        if (self.song_ids.items.len == 0) return null;

        if (self.played_indices.items.len != 0) {
            self.current_index = self.played_indices.pop().?;
            self.syncShufflePos();
            return self.song_ids.items[self.current_index];
        }

        if (self.is_shuffled and self.shuffle_order.items.len != 0) {
            if (self.shuffle_pos == 0) {
                if (self.repeat_mode != .All) return null;
                self.shuffle_pos = self.shuffle_order.items.len - 1;
            } else {
                self.shuffle_pos -= 1;
            }
            self.current_index = self.shuffle_order.items[self.shuffle_pos];
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
        self.changed();
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

            try self.rebuildShuffleOrder();
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

test "queue: snapshot restores complete context" {
    var q = PlayQueue.init(std.testing.allocator);
    defer q.deinit();
    try q.replace(&.{ 1, 2, 3 }, .Album, 12);
    try q.setStartIndex(1);
    q.setRepeatMode(.One);
    var saved = try q.snapshot();
    defer saved.deinit();

    try q.replace(&.{9}, .Playlist, 44);
    q.setRepeatMode(.None);
    q.restoreSnapshot(&saved);
    try std.testing.expectEqualSlices(i32, &.{ 1, 2, 3 }, q.items());
    try std.testing.expectEqual(@as(usize, 1), q.currentIndex());
    try std.testing.expectEqual(PlaybackContextType.Album, q.context_type);
    try std.testing.expectEqual(@as(i32, 12), q.context_id);
    try std.testing.expectEqual(RepeatMode.One, q.getRepeatMode());
}

test "queue: replace, move, and remove" {
    var q = PlayQueue.init(std.testing.allocator);
    defer q.deinit();
    try q.replace(&.{ 1, 2, 3 }, .Playlist, 7);
    try q.moveAt(0, 2);
    try std.testing.expectEqualSlices(i32, &.{ 2, 3, 1 }, q.items());
    try q.removeAt(1);
    try std.testing.expectEqualSlices(i32, &.{ 2, 1 }, q.items());
    try std.testing.expectEqual(PlaybackContextType.Playlist, q.context_type);
}

test "queue: duplicate entries preserve exact current occurrence" {
    var q = PlayQueue.init(std.testing.allocator);
    defer q.deinit();
    try q.enqueueMany(&.{ 7, 8, 7 });
    try q.selectIndex(2);
    try q.moveAt(2, 0);
    try std.testing.expectEqualSlices(i32, &.{ 7, 7, 8 }, q.items());
    try std.testing.expectEqual(@as(usize, 0), q.currentIndex());
    try q.selectIndex(1);
    try std.testing.expectEqual(@as(?i32, 7), q.current());

    try q.moveAt(0, 2);
    try std.testing.expectEqualSlices(i32, &.{ 7, 8, 7 }, q.items());
    try std.testing.expectEqual(@as(usize, 0), q.currentIndex());
}

test "queue: reorder and remove preserve current song" {
    var q = PlayQueue.init(std.testing.allocator);
    defer q.deinit();
    try q.enqueueMany(&.{ 1, 2, 3, 4 });
    _ = try q.next(); // current = 2
    try q.moveAt(0, 3);
    try std.testing.expectEqual(@as(?i32, 2), q.current());
    try std.testing.expectEqualSlices(i32, &.{ 2, 3, 4, 1 }, q.items());
    try q.removeAt(0);
    try std.testing.expectEqual(@as(?i32, 3), q.current());
    try std.testing.expectEqual(@as(usize, 0), q.currentIndex());
}

test "queue: clear resets context and navigation" {
    var q = PlayQueue.init(std.testing.allocator);
    defer q.deinit();
    try q.replace(&.{ 1, 2 }, .Album, 44);
    q.setRepeatMode(.One);
    q.clear();
    try std.testing.expectEqual(@as(usize, 0), q.size());
    try std.testing.expectEqual(PlaybackContextType.Individual, q.context_type);
    try std.testing.expectEqual(@as(i32, -1), q.context_id);
    try std.testing.expectEqual(RepeatMode.One, q.repeat_mode);
}

test "queue: enqueueNext inserts after current" {
    var q = PlayQueue.init(std.testing.allocator);
    defer q.deinit();
    try q.enqueueMany(&.{ 1, 2, 3 });
    _ = try q.next();
    try q.enqueueNext(9);
    try std.testing.expectEqualSlices(i32, &.{ 1, 2, 9, 3 }, q.items());
    try std.testing.expectEqual(@as(?i32, 2), q.current());
}

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

test "queue: manual selection resets history and next follows selected song" {
    var q = PlayQueue.init(std.testing.allocator);
    defer q.deinit();
    try q.enqueueMany(&.{ 10, 20, 30, 40 });

    _ = try q.next(); // 20, history contains 10
    try q.selectSong(40);
    try std.testing.expectEqual(@as(?i32, 40), q.current());
    // Previous uses the selected queue position, not the stale history from
    // before the manual jump.
    try std.testing.expectEqual(@as(?i32, 30), q.previous());
    try std.testing.expectEqual(@as(?i32, 40), try q.next());
}

test "queue: shuffle previous restores position" {
    var q = PlayQueue.init(std.testing.allocator);
    defer q.deinit();
    try q.enqueueMany(&.{ 1, 2, 3, 4 });
    q.seed = 55;
    try q.setShuffled(true);

    const first_next = (try q.next()).?;
    const second_next = (try q.next()).?;
    try std.testing.expectEqual(first_next, q.previous().?);
    try std.testing.expectEqual(second_next, try q.next());
}
