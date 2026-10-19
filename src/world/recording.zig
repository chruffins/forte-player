//! Offline fixed-frame recording: shared renderer/FFT, FFmpeg-decoded PCM.
const std = @import("std");
const al = @import("allegro");
const config = @import("../core/config.zig");
const spectrum = @import("../dsp/spectrum.zig");
const vocal_presence = @import("../dsp/vocal_presence.zig");
const model = @import("model.zig");
const native = @import("template.zig");
const c = @cImport({
    @cInclude("allegro5/allegro.h");
    @cInclude("allegro5/allegro_opengl.h");
});

pub fn invoke(init: std.process.Init, executable: []const u8, args: anytype) !void {
    const owned_system = !al.system.isInstalled();
    if (owned_system) try al.system.init();
    defer if (owned_system) al.system.uninstall();
    if (owned_system) config.initAppIdentity();
    const allocator = init.gpa;
    const helper = try config.resolveAssetPath(allocator, "world/record_world.py");
    defer allocator.free(helper);
    const config_path = try config.configFilePath(allocator);
    defer allocator.free(config_path);
    var command: std.ArrayList([]const u8) = .empty;
    defer command.deinit(allocator);
    try command.appendSlice(allocator, &.{ "python3", helper, "--renderer", executable, "--config", config_path });
    for (args) |arg| try command.append(allocator, arg);
    var child = try std.process.spawn(init.io, .{ .argv = command.items });
    const result = try child.wait(init.io);
    switch (result) {
        .exited => |code| if (code != 0) return error.RecordingFailed,
        else => return error.RecordingFailed,
    }
}

const Recording = struct {
    pcm_path: [:0]const u8,
    width: i32,
    height: i32,
    fps: u64,
    pose: model.Pose,

    fn parse(args: []const [:0]const u8) !Recording {
        if (args.len != 11 or !std.mem.eql(u8, args[1], "--render-recording")) return error.InvalidRecordingArguments;
        const recording: Recording = .{
            .pcm_path = args[2],
            .width = try std.fmt.parseInt(i32, args[3], 10),
            .height = try std.fmt.parseInt(i32, args[4], 10),
            .fps = try std.fmt.parseInt(u64, args[5], 10),
            .pose = .{},
        };
        if (recording.width < 480 or recording.width > 3840 or recording.height < 320 or recording.height > 2160 or @mod(recording.width, 2) != 0 or @mod(recording.height, 2) != 0 or (recording.fps != 30 and recording.fps != 60)) return error.InvalidRecordingDimensions;
        var result = recording;
        inline for (.{ "x", "y", "z", "yaw", "pitch" }, 0..) |field, i| {
            @field(result.pose, field) = try std.fmt.parseFloat(f32, args[6 + i]);
            if (!std.math.isFinite(@field(result.pose, field))) return error.InvalidRecordingPose;
        }
        if (!result.pose.isValid()) return error.InvalidRecordingPose;
        return result;
    }
};

fn cancelled(events: *al.EventQueue) bool {
    var event: al.Event = undefined;
    while (events.getNextEvent(&event)) {
        const kind = al.eventType(event);
        if (kind == .display_close or (kind == .key_down and al.eventKeyboardKeycode(event) == .Escape)) return true;
    }
    return false;
}

fn renderFrame(init: std.process.Init, display: *al.Display, world: *native.World, pose: model.Pose, glow: *const [48]f32, vocal: f32, seconds: f64, width: i32, height: i32, pixels: []u8) !void {
    al.graphics.setTargetBackbuffer(display.display);
    al.graphics.resetClipRectangle();
    al.graphics.clearToColor(al.Color.fromRgb(3, 6, 10));
    if (!world.draw(pose, glow, vocal, seconds, width, height)) return error.RecordingRenderFailed;
    c.glReadPixels(0, 0, width, height, c.GL_RGBA, c.GL_UNSIGNED_BYTE, pixels.ptr);
    if (native.World.glError() != 0) return error.RecordingReadbackFailed;
    try std.Io.File.stdout().writeStreamingAll(init.io, pixels);
    al.Display.flip();
}

const AudioAnalysis = struct {
    reader: *std.Io.File.Reader,
    sample_count: u64,
    analyzer: spectrum.Analyzer,
    window: [spectrum.n_samples]f32 = @splat(0),
    ordered: [spectrum.n_samples]f32 = undefined,
    cursor: usize = 0,
    consumed: u64 = 0,
    last_tick: u64 = 0,
    bands: [48]f32 = @splat(0),
    smoother: spectrum.Smoother = .{},
    glow: model.GlowEnvelope = .{},
    vocal_target: f32 = 0,
    vocal: vocal_presence.Envelope = .{},

    fn update(self: *AudioAnalysis, frame: usize, fps: u64, dt: f32) !void {
        const tick = @as(u64, @intCast(frame)) * 20 / fps;
        if (tick != self.last_tick) try self.analyze(tick);
        self.smoother.updateTimed(&self.bands, dt);
        self.glow.update(&self.smoother.levels, dt);
        _ = self.vocal.update(self.vocal_target, dt);
    }

    fn analyze(self: *AudioAnalysis, tick: u64) !void {
        const endpoint = @min(self.sample_count, tick * 2205);
        while (self.consumed < endpoint) : (self.consumed += 1) {
            const bytes = try self.reader.interface.takeArray(4);
            const sample: f32 = @bitCast(std.mem.readInt(u32, bytes, .little));
            self.window[self.cursor] = if (std.math.isFinite(sample)) sample else 0;
            self.cursor = (self.cursor + 1) % self.window.len;
        }
        for (0..self.window.len) |i| self.ordered[i] = self.window[(self.cursor + i) % self.window.len];
        self.analyzer.compute(&self.ordered, &self.bands);
        self.vocal_target = vocal_presence.estimate(&self.ordered);
        self.last_tick = tick;
    }
};

pub fn render(init: std.process.Init, args: []const [:0]const u8) !void {
    const recording = try Recording.parse(args);
    const width = recording.width;
    const height = recording.height;
    const fps = recording.fps;
    const pose = recording.pose;
    const file = try std.Io.Dir.cwd().openFile(init.io, recording.pcm_path, .{});
    defer file.close(init.io);
    const size = (try file.stat(init.io)).size;
    if (size == 0 or size % 4 != 0) return error.InvalidRecordingPcm;
    const samples = size / 4;
    const frames = try model.recordingFrames(samples, fps);
    if (frames > fps * 86400) return error.RecordingTooLong;
    var read_buffer: [16384]u8 = undefined;
    var reader = file.reader(init.io, &read_buffer);

    try al.system.init();
    defer al.system.uninstall();
    try al.primitives.init();
    try al.keyboard.install();
    al.Display.setNewFlags(al.DisplayFlags.WINDOWED | al.DisplayFlags.OPENGL | al.DisplayFlags.PROGRAMMABLE_PIPELINE);
    c.al_set_new_display_option(c.ALLEGRO_DEPTH_SIZE, 24, c.ALLEGRO_REQUIRE);
    al.Display.setNewWindowTitle("Forte recording — Esc cancels");
    var display = try al.Display.create(width, height);
    defer display.destroy();
    display.setWindowTitle("Forte recording — Esc cancels");
    var events = try al.EventQueue.create();
    defer events.destroy();
    events.registerDisplay(&display);
    events.registerKeyboard();
    var world = try native.World.init(init.gpa);
    defer world.deinit();
    const pixels = try init.gpa.alloc(u8, @as(usize, @intCast(width)) * @as(usize, @intCast(height)) * 4);
    defer init.gpa.free(pixels);
    var audio = AudioAnalysis{
        .reader = &reader,
        .sample_count = samples,
        .analyzer = spectrum.Analyzer.init(spectrum.default_sample_rate, .a_weight),
    };
    const dt: f32 = 1.0 / @as(f32, @floatFromInt(fps));
    // Pipe backpressure controls wall time, never simulation or FFT time.
    for (0..@as(usize, @intCast(frames))) |frame| {
        if (cancelled(&events)) return error.RecordingCancelled;
        try audio.update(frame, fps, dt);
        const seconds = @as(f64, @floatFromInt(frame)) / @as(f64, @floatFromInt(fps));
        try renderFrame(init, &display, &world, pose, &audio.glow.levels, audio.vocal.value, seconds, width, height, pixels);
        if (frame % @as(usize, @intCast(fps * 5)) == 0) std.log.info("recording {d}/{d} frames", .{ frame, frames });
    }
}
