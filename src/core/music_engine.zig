//! Zig port of the Allegro-critical core of the C++ `MusicEngine`
//! (src/core/music_engine.cpp) from the audio-visualizer-cpp project.
//!
//! `MusicEngine` is generic over a low-level audio `Drv` (a duck-typed seam --
//! see `driver.zig`), so the transport logic (play/pause/seek/status/capture
//! pass-through) is identical whether it runs against the real Allegro stack
//! (`AllegroDriver`) or an in-memory fake (`FakeDriver`) in headless tests.
//!
//! Idiomatic-Zig notes vs. the C++ original:
//!   * Valid by construction: `create()` builds the whole audio graph and
//!     returns a heap `*MusicEngine` with a non-optional `*Drv`, so there is no
//!     `initialize()`/`shutdown()` duality and no `?voice`/`?mixer` fields.
//!     The stable heap address is also what the C postprocess callback
//!     (`data == engine`) requires -- a by-value return could never guarantee it.
//!   * Optionals remain only where a value is *genuinely absent*: no song
//!     loaded (`stream`), an optional external event queue, and optional hooks.
//!
//! Deliberately NOT ported (app logic, not Allegro wrapper surface): the
//! AppState / Library / PlayQueue / SongView / ProgressBar model and the
//! album/playlist queue context management.

const std = @import("std");
const al = @import("allegro");
const driver_mod = @import("driver.zig");

pub const SampleCapture = @import("sample_capture.zig").SampleCapture;
pub const AllegroDriver = driver_mod.AllegroDriver;
pub const FakeDriver = driver_mod.FakeDriver;

/// Real, audio-device-backed engine used by the application.
pub const RealEngine = MusicEngine(AllegroDriver);

/// Generic playable audio engine. `Drv` is a duck-typed audio driver.
pub fn MusicEngine(comptime Drv: type) type {
    return struct {
        const Self = @This();
        const Stream = Drv.Stream;

        allocator: std.mem.Allocator,
        drv: *Drv, // owned, non-optional (stable heap address)

        // 'No song loaded' is the one genuinely-absent field.
        stream: ?Stream = null,

        /// Optional external queue the current stream's event source registers onto.
        event_queue: ?*al.events.EventQueue = null,

        time: f64 = 0.0,
        duration: f64 = 0.0,
        gain: f32 = 1.0,

        /// Optional hook fired when a new song begins (path + engine as ctx).
        on_song_changed: ?*const fn (path: [:0]const u8, engine: *anyopaque) void = null,

        pub fn create(allocator: std.mem.Allocator) !*Self {
            const drv = try allocator.create(Drv);
            errdefer allocator.destroy(drv);

            drv.* = try Drv.init(allocator);
            errdefer drv.deinit();
            try drv.hook();

            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);

            self.* = .{
                .allocator = allocator,
                .drv = drv,
            };
            return self;
        }

        pub fn destroy(self: *Self) void {
            const allocator = self.allocator;
            if (self.stream) |*s| s.destroy();
            self.drv.deinit();
            allocator.destroy(self.drv);
            allocator.destroy(self);
        }

        pub fn playSound(self: *Self, path: [:0]const u8) !void {
            if (self.stream) |*old| old.destroy();
            self.stream = null;

            var stream = try self.drv.load(path);
            errdefer stream.destroy();

            self.time = 0.0;
            self.duration = stream.lengthSecs();
            std.debug.print("forte: loaded stream, duration={d:.3}s\n", .{self.duration});

            _ = stream.setPlaying(true);

            if (self.event_queue) |q| {
                if (self.drv.streamEventSource(&stream)) |src| {
                    var src_mut = src;
                    q.registerSource(&src_mut);
                }
            }

            self.stream = stream;
            if (self.on_song_changed) |cb| cb(path, @ptrCast(self));
        }

        pub fn pause(self: *Self) void {
            if (self.stream) |*s| _ = s.setPlaying(false);
        }

        pub fn resumePlayback(self: *Self) void {
            if (self.stream) |*s| _ = s.setPlaying(true);
        }

        pub fn stop(self: *Self) void {
            if (self.stream) |*s| {
                _ = s.setPlaying(false);
                s.destroy();
                self.stream = null;
            }
        }

        pub fn getTime(self: *const Self) f64 {
            return self.time;
        }

        pub fn getDuration(self: *const Self) f64 {
            return self.duration;
        }

        pub fn setGain(self: *Self, value: f32) void {
            self.gain = @max(0.0, @min(value, 1.0));
            self.drv.setGain(self.gain);
        }

        pub fn getGain(self: *const Self) f32 {
            return self.gain;
        }

        pub fn setPan(self: *Self, pan: f32) void {
            if (self.stream) |*s| _ = s.setPan(pan);
        }

        pub fn setSpeed(self: *Self, speed: f32) void {
            if (self.stream) |*s| _ = s.setSpeed(speed);
        }

        pub fn isPlaying(self: *const Self) bool {
            return if (self.stream) |*s| s.playing() else false;
        }

        /// Poll the stream position. Mirrors `MusicEngine::update()`.
        pub fn update(self: *Self) void {
            if (self.stream) |*s| self.time = s.positionSecs();
        }

        pub fn setProgress(self: *Self, position: f64) void {
            if (self.stream) |*s| {
                _ = s.seekSecs(position);
                self.time = position;
            }
        }

        // ---- Sample-capture pass-through (delegates to the driver) ----
        pub fn setSampleBufferCapacity(self: *Self, n: usize) !void {
            try self.drv.setSampleBufferCapacity(n);
        }
        pub fn enableCapture(self: *Self, enabled: bool) void {
            self.drv.enableCapture(enabled);
        }
        pub fn bufferedCount(self: *const Self) usize {
            return self.drv.bufferedCount();
        }
        pub fn copyRecentMono(self: *const Self, max_frames: usize, out: []f32) usize {
            return self.drv.copyRecentMono(max_frames, out);
        }
        pub fn clearCapture(self: *Self) void {
            self.drv.clearCapture();
        }
    };
}
