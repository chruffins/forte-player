//! Pure walking camera and HUD geometry. No display, physics or audio ownership.
const std = @import("std");
const ui = @import("../ui/ui.zig");

const world_limit: f32 = 52;
const walk_speed: f32 = 4;
const sprint_speed: f32 = 8;
const look_speed: f32 = 1.2;
const mouse_sensitivity: f32 = 0.004;
const max_pitch: f32 = std.math.pi * 0.42;
/// World-only presentation smoothing: the shared FFT envelope has instant
/// attack for meters, but billboard size/light strength should ease at frame cadence.
const attack_seconds: f32 = 0.065;
const release_seconds: f32 = 0.10;

pub const GlowEnvelope = struct {
    levels: [48]f32 = @splat(0),
    pub fn update(self: *GlowEnvelope, target: *const [48]f32, seconds: f32) void {
        if (!std.math.isFinite(seconds) or seconds <= 0) return;
        for (target, &self.levels) |raw, *level| {
            const value = if (std.math.isFinite(raw)) @max(0, @min(1, raw)) else 0;
            const tau: f32 = if (value > level.*) attack_seconds else release_seconds;
            const blend = 1 - @exp(-seconds / tau);
            level.* += (value - level.*) * blend;
        }
    }
};

pub fn validViewName(name: []const u8) bool {
    if (name.len == 0 or name.len > 40) return false;
    for (name) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '_' and ch != '-') return false;
    return true;
}

pub fn recordingFrames(samples: u64, fps: u64) !u64 {
    if (samples == 0 or (fps != 30 and fps != 60)) return error.InvalidRecordingClock;
    const ticks = try std.math.mul(u64, samples, fps);
    return std.math.divCeil(u64, ticks, 44100);
}

test "recording clock includes final partial frame and validates view names" {
    try std.testing.expectEqual(@as(u64, 30), try recordingFrames(44100, 30));
    try std.testing.expectEqual(@as(u64, 61), try recordingFrames(44101, 60));
    try std.testing.expectEqual(@as(u64, 1), try recordingFrames(1, 30));
    try std.testing.expectError(error.InvalidRecordingClock, recordingFrames(0, 30));
    try std.testing.expectError(error.InvalidRecordingClock, recordingFrames(1, 24));
    try std.testing.expect((Pose{}).isValid());
    try std.testing.expect(!(Pose{ .x = world_limit + 1 }).isValid());
    try std.testing.expect(validViewName("my-shot_2"));
    try std.testing.expect(!validViewName("../bad"));
    try std.testing.expect(!validViewName(""));
}

pub const Pose = struct {
    x: f32 = 0,
    y: f32 = 1.8,
    z: f32 = 11,
    yaw: f32 = 0,
    pitch: f32 = -0.12,

    pub fn isValid(self: Pose) bool {
        return std.math.isFinite(self.x) and std.math.isFinite(self.y) and std.math.isFinite(self.z) and
            std.math.isFinite(self.yaw) and std.math.isFinite(self.pitch) and
            @abs(self.x) <= world_limit and @abs(self.z) <= world_limit and
            self.y >= 0.1 and self.y <= 20 and @abs(self.yaw) <= std.math.pi and @abs(self.pitch) <= max_pitch;
    }

    pub fn look(self: *Pose, dx: f32, dy: f32) void {
        if (!std.math.isFinite(dx) or !std.math.isFinite(dy)) return;
        self.yaw = wrap(self.yaw + dx * mouse_sensitivity);
        self.pitch = clampPitch(self.pitch - dy * mouse_sensitivity);
    }
    pub fn step(self: *Pose, input: Held, seconds: f32) void {
        const dt = if (std.math.isFinite(seconds)) @max(0, @min(seconds, 0.1)) else 0;
        self.walk(input, dt);
        self.rotate(input, dt);
    }

    fn walk(self: *Pose, input: Held, dt: f32) void {
        const forward = axis(input.forward, input.backward);
        const sideways = axis(input.right, input.left);
        const magnitude = @sqrt(forward * forward + sideways * sideways);
        if (magnitude == 0) return;
        const speed = if (input.fast) sprint_speed else walk_speed;
        const distance = dt * speed / magnitude;
        self.x += (@sin(self.yaw) * forward + @cos(self.yaw) * sideways) * distance;
        self.z += (-@cos(self.yaw) * forward + @sin(self.yaw) * sideways) * distance;
        self.x = @max(-world_limit, @min(world_limit, self.x));
        self.z = @max(-world_limit, @min(world_limit, self.z));
    }

    fn rotate(self: *Pose, input: Held, dt: f32) void {
        self.yaw = wrap(self.yaw + axis(input.look_right, input.look_left) * dt * look_speed);
        self.pitch = clampPitch(self.pitch + axis(input.look_up, input.look_down) * dt);
    }
};

fn axis(positive: bool, negative: bool) f32 {
    return @as(f32, @floatFromInt(@intFromBool(positive))) - @as(f32, @floatFromInt(@intFromBool(negative)));
}

fn clampPitch(value: f32) f32 {
    return @max(-max_pitch, @min(max_pitch, value));
}

fn wrap(value: f32) f32 {
    return @mod(value + std.math.pi, 2 * std.math.pi) - std.math.pi;
}
pub const Held = struct {
    forward: bool = false,
    backward: bool = false,
    left: bool = false,
    right: bool = false,
    fast: bool = false,
    look_left: bool = false,
    look_right: bool = false,
    look_up: bool = false,
    look_down: bool = false,
};
pub const Hud = struct {
    width: f32,
    height: f32,
    pub fn control(self: Hud, index: usize) ui.Rect {
        const size: f32 = 32;
        return .{ .x = self.width - 132 + @as(f32, @floatFromInt(index)) * 38, .y = self.height - 64, .w = size, .h = size };
    }
    pub fn seek(self: Hud) ui.Rect {
        return .{ .x = 24, .y = self.height - 18, .w = @max(0, self.width - 48), .h = 2 };
    }
    pub fn picker(self: Hud) ui.Rect {
        const w = @min(640, self.width - 32);
        const h = @min(480, self.height - 40);
        return .{ .x = (self.width - w) / 2, .y = (self.height - h) / 2, .w = w, .h = h };
    }
    pub fn pickerRow(self: Hud, index: usize) ui.Rect {
        const card = self.picker();
        return .{ .x = card.x + 16, .y = card.y + 92 + @as(f32, @floatFromInt(index)) * 42, .w = @max(0, card.w - 32), .h = 40 };
    }
    pub fn pickerVisible(self: Hud) usize {
        return @max(1, @as(usize, @intFromFloat(@max(0, self.picker().h - 124) / 42)));
    }
};
pub fn matches(text: []const u8, query: []const u8) bool {
    if (query.len == 0) return true;
    if (query.len > text.len) return false;
    for (0..text.len - query.len + 1) |i| if (std.ascii.eqlIgnoreCase(text[i..][0..query.len], query)) return true;
    return false;
}

/// Build an unfiltered library context, mapping filtered selection back to its
/// original row. Caller owns song_ids. A picker is not a jump within the old queue.
pub fn pickerChoice(allocator: std.mem.Allocator, rows: anytype, filtered: []const usize, selection: usize) !struct { song_ids: []i64, start_index: usize } {
    if (selection >= filtered.len or filtered[selection] >= rows.len) return error.InvalidSelection;
    const ids = try allocator.alloc(i64, rows.len);
    for (rows, 0..) |row, i| ids[i] = row.id;
    return .{ .song_ids = ids, .start_index = filtered[selection] };
}

test "picker replaces an unrelated queue and maps filtered selection to library order" {
    const Queue = @import("../music/play_queue.zig").PlayQueue;
    const allocator = std.testing.allocator;
    const rows = [_]struct { id: i64 }{ .{ .id = 10 }, .{ .id = 20 }, .{ .id = 30 } };
    const choice = try pickerChoice(allocator, &rows, &.{1}, 0);
    defer allocator.free(choice.song_ids);
    var queue = Queue.init(allocator);
    defer queue.deinit();
    try queue.replace(&.{10}, .Album, 9);
    try std.testing.expectError(error.SongNotInQueue, queue.selectSong(20));
    var ids: [3]i32 = undefined;
    for (choice.song_ids, 0..) |id, i| ids[i] = @intCast(id);
    try queue.replace(&ids, .Individual, -1);
    try queue.setStartIndex(choice.start_index);
    try std.testing.expectEqual(@as(?i32, 20), queue.current());
    try std.testing.expectEqual(@as(?i32, 30), queue.next());
    try std.testing.expectError(error.InvalidSelection, pickerChoice(allocator, &rows, &.{}, 0));
    try std.testing.expectError(error.InvalidSelection, pickerChoice(allocator, &rows, &.{3}, 0));
}

test "world glow eases FFT jumps, stays bounded and is frame-rate independent" {
    var target: [48]f32 = @splat(1);
    var envelope = GlowEnvelope{};
    envelope.update(&target, 1.0 / 60.0);
    try std.testing.expect(envelope.levels[0] > 0 and envelope.levels[0] < 0.3);
    for ([_]usize{ 30, 60, 144 }) |hz| {
        var e = GlowEnvelope{};
        for (0..hz) |_| e.update(&target, 1.0 / @as(f32, @floatFromInt(hz)));
        try std.testing.expectApproxEqAbs(@as(f32, 1 - @exp(-1.0 / 0.065)), e.levels[0], 0.00001);
        target = @splat(0);
        for (0..hz) |_| e.update(&target, 1.0 / @as(f32, @floatFromInt(hz)));
        try std.testing.expectApproxEqAbs(@as(f32, @exp(-1.0 / 0.10)), e.levels[0], 0.00001);
        target = @splat(1);
    }
    const before = envelope.levels;
    envelope.update(&target, 0);
    envelope.update(&target, std.math.nan(f32));
    try std.testing.expectEqual(before, envelope.levels);
    target[0] = std.math.nan(f32);
    target[1] = std.math.inf(f32);
    target[2] = -100;
    target[3] = 100;
    envelope.update(&target, 1);
    for (envelope.levels) |value| try std.testing.expect(std.math.isFinite(value) and value >= 0 and value <= 1);
}

test "walking is camera-relative, bounded and diagonal-normalized" {
    var p = Pose{};
    p.step(.{ .forward = true }, 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 10.6), p.z, 0.001);
    var diagonal = Pose{};
    diagonal.step(.{ .forward = true, .right = true }, 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 0.4), @sqrt(diagonal.x * diagonal.x + (diagonal.z - 11) * (diagonal.z - 11)), 0.001);
    p = .{ .yaw = std.math.pi / 2.0, .x = 52 };
    p.step(.{ .forward = true }, 0.1);
    try std.testing.expectEqual(@as(f32, 52), p.x);
    p.look(0, 100000);
    try std.testing.expect(p.pitch >= -max_pitch);
    const before = p;
    p.step(.{ .forward = true }, std.math.nan(f32));
    try std.testing.expectEqual(before, p);
}
test "HUD and music picker remain inside compact windows" {
    for ([_][2]f32{ .{ 480, 320 }, .{ 1120, 720 }, .{ 1920, 1080 } }) |size| {
        const hud = Hud{ .width = size[0], .height = size[1] };
        const picker = hud.picker();
        for (0..hud.pickerVisible()) |i| try std.testing.expect(hud.pickerRow(i).bottom() < picker.bottom());
        for (0..3) |i| try std.testing.expect(hud.control(i).bottom() < hud.seek().y);
    }
    try std.testing.expect(matches("After the Rain", "RAIN"));
    try std.testing.expect(!matches("After the Rain", "ocean"));
}
