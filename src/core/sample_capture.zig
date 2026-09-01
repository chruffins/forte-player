//! Fixed-capacity ring buffer of normalized f32 samples, fed from the audio
//! thread and read by the main thread.
//!
//! The hot append path is a single-producer atomic ring: it never takes a
//! mutex or allocates. A control mutex is retained only for resize/clear and
//! protects the backing allocation while no writer is active.

const std = @import("std");
const al = @import("allegro");

pub const SampleCapture = struct {
    allocator: std.mem.Allocator,
    control_mutex: al.threads.Mutex,

    enabled: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
    /// Closed before control operations wait for users and touch the backing
    /// allocation. The second check closes the wait-for-zero admission race.
    admission_closed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    active_writers: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    active_readers: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    /// Interleaved channel count (configured before playback starts).
    channels: usize = 2,

    buf: []f32,
    capacity: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    write_pos: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    size: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    write_sequence: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    pub fn init(allocator: std.mem.Allocator, capacity: usize) !SampleCapture {
        return .{
            .allocator = allocator,
            .control_mutex = try al.threads.Mutex.create(),
            .buf = try allocator.alloc(f32, capacity),
            .capacity = std.atomic.Value(usize).init(capacity),
        };
    }

    pub fn deinit(self: *SampleCapture) void {
        self.control_mutex.lock();
        self.admission_closed.store(true, .release);
        self.enabled.store(false, .release);
        self.waitForAccess();
        self.capacity.store(0, .release);
        self.allocator.free(self.buf);
        self.buf = &.{};
        self.control_mutex.unlock();
        self.control_mutex.destroy();
    }

    fn waitForAccess(self: *SampleCapture) void {
        while (self.active_writers.load(.acquire) != 0 or self.active_readers.load(.acquire) != 0) {
            _ = std.Thread.yield() catch {};
        }
    }

    fn admit(self: *const SampleCapture, counter: *std.atomic.Value(usize)) bool {
        if (self.admission_closed.load(.acquire)) return false;
        _ = counter.fetchAdd(1, .acq_rel);
        if (self.admission_closed.load(.acquire)) {
            _ = counter.fetchSub(1, .release);
            return false;
        }
        return true;
    }

    pub fn setEnabled(self: *SampleCapture, value: bool) void {
        self.control_mutex.lock();
        if (!value) {
            self.enabled.store(false, .release);
            self.waitForAccess();
        } else {
            self.enabled.store(true, .release);
        }
        self.control_mutex.unlock();
    }

    pub fn isEnabled(self: *const SampleCapture) bool {
        return self.enabled.load(.acquire);
    }

    pub fn setCapacity(self: *SampleCapture, sample_count: usize) !void {
        self.control_mutex.lock();
        const was_enabled = self.enabled.load(.acquire);
        self.admission_closed.store(true, .release);
        self.enabled.store(false, .release);
        self.waitForAccess();

        const new_buf = self.allocator.alloc(f32, sample_count) catch |err| {
            self.admission_closed.store(false, .release);
            self.enabled.store(was_enabled, .release);
            self.control_mutex.unlock();
            return err;
        };
        self.allocator.free(self.buf);
        self.buf = new_buf;
        self.capacity.store(sample_count, .release);
        self.write_pos.store(0, .release);
        self.size.store(0, .release);
        _ = self.write_sequence.fetchAdd(2, .release);
        self.admission_closed.store(false, .release);
        self.enabled.store(was_enabled, .release);
        self.control_mutex.unlock();
    }

    pub fn getCapacity(self: *const SampleCapture) usize {
        return self.capacity.load(.acquire);
    }

    pub fn getSize(self: *const SampleCapture) usize {
        return @min(self.size.load(.acquire), self.capacity.load(.acquire));
    }

    pub fn sequence(self: *const SampleCapture) u64 {
        return self.write_sequence.load(.acquire);
    }

    pub fn clear(self: *SampleCapture) void {
        self.control_mutex.lock();
        const was_enabled = self.enabled.load(.acquire);
        self.admission_closed.store(true, .release);
        self.enabled.store(false, .release);
        self.waitForAccess();
        self.write_pos.store(0, .release);
        self.size.store(0, .release);
        _ = self.write_sequence.fetchAdd(2, .release);
        self.admission_closed.store(false, .release);
        self.enabled.store(was_enabled, .release);
        self.control_mutex.unlock();
    }

    /// Copy up to `max_samples` newest samples. A concurrent append can cause
    /// one retry; returning a slightly older coherent window is preferable to
    /// blocking the audio producer.
    pub fn copyRecent(self: *const SampleCapture, max_samples: usize, out: []f32) usize {
        if (max_samples == 0 or out.len == 0) return 0;
        if (!self.admit(&@constCast(self).active_readers)) return 0;
        defer _ = @constCast(self).active_readers.fetchSub(1, .release);
        if (!self.enabled.load(.acquire) or self.buf.len == 0) return 0;
        for (0..2) |_| {
            const sequence_before = self.write_sequence.load(.acquire);
            if ((sequence_before & 1) != 0) continue;
            const size_before = @min(self.size.load(.acquire), self.buf.len);
            if (size_before == 0) return 0;
            const count = @min(@min(max_samples, out.len), size_before);
            const write_before = self.write_pos.load(.acquire);
            const start = (write_before + self.buf.len - count) % self.buf.len;
            for (0..count) |i| out[i] = self.buf[(start + i) % self.buf.len];
            const sequence_after = self.write_sequence.load(.acquire);
            if (sequence_before == sequence_after and (sequence_after & 1) == 0 and size_before == self.size.load(.acquire) and write_before == self.write_pos.load(.acquire)) return count;
        }
        return 0;
    }

    /// Copy up to `max_frames` downmixed to mono into `out`. Returns frames written.
    pub fn copyRecentMono(self: *const SampleCapture, max_frames: usize, out: []f32) usize {
        const channel_count = @max(@as(usize, 1), self.channels);
        if (max_frames == 0 or out.len == 0) return 0;
        if (!self.admit(&@constCast(self).active_readers)) return 0;
        defer _ = @constCast(self).active_readers.fetchSub(1, .release);
        if (!self.enabled.load(.acquire) or self.buf.len == 0) return 0;

        for (0..2) |_| {
            const sequence_before = self.write_sequence.load(.acquire);
            if ((sequence_before & 1) != 0) continue;
            const size_before = @min(self.size.load(.acquire), self.buf.len);
            const available_frames = size_before / channel_count;
            const frame_count = @min(@min(max_frames, out.len), available_frames);
            if (frame_count == 0) return 0;

            const sample_count = frame_count * channel_count;
            const write_before = self.write_pos.load(.acquire);
            const start = (write_before + self.buf.len - sample_count) % self.buf.len;
            for (0..frame_count) |frame| {
                var sum: f32 = 0.0;
                const frame_start = (start + frame * channel_count) % self.buf.len;
                for (0..channel_count) |ch| sum += self.buf[(frame_start + ch) % self.buf.len];
                out[frame] = sum / @as(f32, @floatFromInt(channel_count));
            }
            const sequence_after = self.write_sequence.load(.acquire);
            if (sequence_before == sequence_after and (sequence_after & 1) == 0 and size_before == self.size.load(.acquire) and write_before == self.write_pos.load(.acquire)) return frame_count;
        }
        return 0;
    }

    /// Append interleaved s16 samples. This is called from the mixer callback;
    /// it deliberately performs no mutex operations and no allocations.
    pub fn appendInterleavedInt16(self: *SampleCapture, samples: []const i16) void {
        if (samples.len == 0) return;
        // Admit the writer before reading the backing slice. Control operations
        // disable capture, wait for admitted writers, then resize/free it. A
        // pre-admission buf.len check could race with that free.
        if (!self.admit(&self.active_writers)) return;
        defer _ = self.active_writers.fetchSub(1, .release);
        // Sequence-lock the payload so readers can reject a window that was
        // overwritten while it was being copied.
        _ = self.write_sequence.fetchAdd(1, .acq_rel);
        defer _ = self.write_sequence.fetchAdd(1, .release);
        if (!self.enabled.load(.acquire)) return;

        const capacity = self.buf.len;
        if (capacity == 0) return;
        var write_pos = self.write_pos.load(.monotonic);
        var size = self.size.load(.monotonic);
        for (samples) |s| {
            self.buf[write_pos] = @as(f32, @floatFromInt(s)) / 32768.0;
            write_pos = (write_pos + 1) % capacity;
            if (size < capacity) size += 1;
        }
        self.write_pos.store(write_pos, .release);
        self.size.store(size, .release);
    }
};

test "ring buffer append + mono downmix" {
    _ = al.init() catch return error.SkipZigTest;
    var cap = try SampleCapture.init(std.testing.allocator, 8);
    defer cap.deinit();

    cap.channels = 2;
    cap.appendInterleavedInt16(&.{ 32767, -32768, 0, 16384 });
    try std.testing.expectEqual(@as(usize, 4), cap.getSize());

    var out: [4]f32 = undefined;
    const n = cap.copyRecentMono(2, &out);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), out[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), out[1], 0.001);
}

test "ring wrap + copyRecent newest-window" {
    _ = al.init() catch return error.SkipZigTest;
    var cap = try SampleCapture.init(std.testing.allocator, 4);
    defer cap.deinit();

    cap.channels = 1;
    cap.appendInterleavedInt16(&.{ 32767, -32768, 32767, -32768, 16384, -16384 });
    var out: [4]f32 = undefined;
    const n = cap.copyRecent(4, &out);
    try std.testing.expectEqual(@as(usize, 4), n);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), out[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), out[1], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), out[2], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, -0.5), out[3], 0.001);

    cap.clear();
    try std.testing.expectEqual(@as(usize, 0), cap.getSize());
}
