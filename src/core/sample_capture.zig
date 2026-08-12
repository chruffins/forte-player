//! Fixed-capacity ring buffer of normalized f32 samples, fed from the audio
//! thread (via the mixer postprocess callback) and drained from the main
//! thread. Mirrors `MusicEngine::SampleCaptureState` in the C++ original.
//!
//! The backing buffer is allocated up-front and the mutex is created in `init`,
//! so neither `buf` nor `mutex` needs to be optional.

const std = @import("std");
const al = @import("allegro");

pub const SampleCapture = struct {
    allocator: std.mem.Allocator,
    mutex: al.threads.Mutex,

    enabled: bool = true,
    /// Interleaved channel count (used to decode + downmix the callback buffer).
    channels: usize = 2,

    // `size` is the number of valid samples (<= buf.len). `write_pos` is the
    // next slot to write, wrapping around `buf.len`.
    buf: []f32,
    write_pos: usize = 0,
    size: usize = 0,

    pub fn init(allocator: std.mem.Allocator, capacity: usize) !SampleCapture {
        return .{
            .allocator = allocator,
            .mutex = try al.threads.Mutex.create(),
            .buf = try allocator.alloc(f32, capacity),
        };
    }

    pub fn deinit(self: *SampleCapture) void {
        self.allocator.free(self.buf);
        self.buf = &.{};
        self.mutex.destroy();
    }

    // Locking a mutex is a synchronization operation, not a mutation of the
    // object's logical state, so casting away const here lets reader methods
    // stay `const` (matching the C++ accessors) while still being thread-safe.
    fn lock(self: *const SampleCapture) void {
        @constCast(&self.mutex).lock();
    }
    fn unlock(self: *const SampleCapture) void {
        @constCast(&self.mutex).unlock();
    }

    pub fn setEnabled(self: *SampleCapture, value: bool) void {
        self.lock();
        defer self.unlock();
        self.enabled = value;
    }

    pub fn isEnabled(self: *const SampleCapture) bool {
        self.lock();
        defer self.unlock();
        return self.enabled;
    }

    pub fn setCapacity(self: *SampleCapture, sample_count: usize) !void {
        self.lock();
        defer self.unlock();
        const new_buf = try self.allocator.alloc(f32, sample_count);
        self.allocator.free(self.buf);
        self.buf = new_buf;
        self.write_pos = 0;
        self.size = 0;
    }

    pub fn getCapacity(self: *const SampleCapture) usize {
        self.lock();
        defer self.unlock();
        return self.buf.len;
    }

    pub fn getSize(self: *const SampleCapture) usize {
        self.lock();
        defer self.unlock();
        return self.size;
    }

    pub fn clear(self: *SampleCapture) void {
        self.lock();
        defer self.unlock();
        self.write_pos = 0;
        self.size = 0;
    }

    /// Copy up to `max_samples` of the newest captured samples into `out`.
    /// Returns the number of samples written.
    pub fn copyRecent(self: *const SampleCapture, max_samples: usize, out: []f32) usize {
        self.lock();
        defer self.unlock();
        if (self.size == 0 or max_samples == 0 or self.buf.len == 0) return 0;

        const count = @min(max_samples, self.size);
        const start = (self.write_pos + self.buf.len - count) % self.buf.len;
        for (0..count) |i| {
            out[i] = self.buf[(start + i) % self.buf.len];
        }
        return count;
    }

    /// Copy up to `max_frames` downmixed to mono into `out`. Returns frames written.
    pub fn copyRecentMono(self: *const SampleCapture, max_frames: usize, out: []f32) usize {
        self.lock();
        defer self.unlock();
        const channel_count = @max(@as(usize, 1), self.channels);
        if (self.size == 0 or max_frames == 0 or self.buf.len == 0) return 0;

        const available_frames = self.size / channel_count;
        const frame_count = @min(max_frames, available_frames);
        if (frame_count == 0) return 0;

        const sample_count = frame_count * channel_count;
        const start = (self.write_pos + self.buf.len - sample_count) % self.buf.len;
        for (0..frame_count) |frame| {
            var sum: f32 = 0.0;
            const frame_start = (start + frame * channel_count) % self.buf.len;
            for (0..channel_count) |ch| {
                sum += self.buf[(frame_start + ch) % self.buf.len];
            }
            out[frame] = sum / @as(f32, @floatFromInt(channel_count));
        }
        return frame_count;
    }

    /// Append interleaved s16 samples (normalized to [-1, 1]).
    /// Called from the audio callback thread.
    pub fn appendInterleavedInt16(self: *SampleCapture, samples: []const i16) void {
        self.lock();
        defer self.unlock();
        if (!self.enabled or self.buf.len == 0 or samples.len == 0) return;
        for (samples) |s| {
            self.buf[self.write_pos] = @as(f32, @floatFromInt(s)) / 32768.0;
            self.write_pos = (self.write_pos + 1) % self.buf.len;
            if (self.size < self.buf.len) self.size += 1;
        }
    }
};

test "ring buffer append + mono downmix" {
    // Allegro must be installed for `al.threads.Mutex.create()` to work.
    _ = al.init() catch return error.SkipZigTest;

    var cap = try SampleCapture.init(std.testing.allocator, 8);
    defer cap.deinit();

    cap.channels = 2;
    cap.setEnabled(true);
    cap.appendInterleavedInt16(&.{ 32767, -32768, 0, 16384 }); // normalized: 1, -1, 0, 0.5

    try std.testing.expectEqual(@as(usize, 4), cap.getSize());
    try std.testing.expectEqual(@as(usize, 8), cap.getCapacity());

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
    const data = [_]i16{ 32767, -32768, 32767, -32768, 16384, -16384 }; // 6 samples into cap 4
    cap.appendInterleavedInt16(&data); // wraps

    try std.testing.expectEqual(@as(usize, 4), cap.getSize());

    var out: [4]f32 = undefined;
    const n = cap.copyRecent(4, &out);
    try std.testing.expectEqual(@as(usize, 4), n);
    // The ring holds the newest 4 writes chronologically: {1,-1,0.5,-0.5}.
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), out[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), out[1], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), out[2], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, -0.5), out[3], 0.001);

    cap.clear();
    try std.testing.expectEqual(@as(usize, 0), cap.getSize());
}
