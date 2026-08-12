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
const PlayQueue = @import("play_queue.zig").PlayQueue;
const RepeatMode = @import("play_queue.zig").RepeatMode;
const PlaybackContextType = @import("play_queue.zig").PlaybackContextType;

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

        /// Optional play queue (not owned) that drives next/previous/auto-advance.
        queue: ?*PlayQueue = null,

        /// Optional hook fired when a new song begins (path + engine as ctx).
        on_song_changed: ?*const fn (path: [:0]const u8, engine: *anyopaque) void = null,
        /// Optional hook fired when the current song finishes (before auto-advance).
        on_song_finished: ?*const fn (engine: *anyopaque) void = null,
        /// Optional resolver mapping a song id -> file path (borrowed, sentinel-terminated).
        /// Used by playNext/playPrevious/auto-advance.
        resolve_song: ?*const fn (id: i32, engine: *anyopaque) ?[:0]const u8 = null,

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

        // ---- Queue / repeat / auto-advance ----

        pub fn setPlayQueue(self: *Self, queue: ?*PlayQueue) void {
            self.queue = queue;
        }

        /// Advance to the next song in the queue and start it. Returns true if a
        /// song was started, false if there was no next song in the queue.
        pub fn playNext(self: *Self) !bool {
            const q = self.queue orelse return false;
            const id = (try q.next()) orelse return false;
            const path = self.resolveSongPath(id) orelse return false;
            try self.playSound(path);
            return true;
        }

        /// Move to the previous song from play history and start it (no-op if none).
        pub fn playPrevious(self: *Self) !void {
            const q = self.queue orelse return;
            const id = q.previous() orelse return;
            if (self.resolveSongPath(id)) |path| try self.playSound(path);
        }

        /// End-of-song handling: fire the hook, then auto-advance according to the
        /// repeat mode (One replays the current track; All wraps; None stops when
        /// the queue runs out). The real app calls this when the audio stream
        /// finishes; tests drive it directly.
        pub fn handleAudioStreamFinished(self: *Self) !void {
            if (self.on_song_finished) |cb| cb(@ptrCast(self));

            const q = self.queue orelse {
                self.stop();
                return;
            };

            switch (q.getRepeatMode()) {
                .One => {
                    if (q.current()) |id| {
                        if (self.resolveSongPath(id)) |path| {
                            try self.playSound(path);
                            return;
                        }
                    }
                    self.stop();
                },
                .None, .All => {
                    if (try self.playNext()) return;
                    self.stop();
                },
            }
        }

        fn resolveSongPath(self: *Self, id: i32) ?[:0]const u8 {
            const cb = self.resolve_song orelse return null;
            return cb(id, @ptrCast(self));
        }

        pub fn setRepeat(self: *Self, enabled: bool) void {
            if (self.queue) |q| q.setRepeatMode(if (enabled) .All else .None);
        }
        pub fn setRepeatMode(self: *Self, mode: RepeatMode) void {
            if (self.queue) |q| q.setRepeatMode(mode);
        }
        pub fn getRepeatMode(self: *const Self) RepeatMode {
            return if (self.queue) |q| q.getRepeatMode() else .None;
        }
        pub fn cycleRepeatMode(self: *Self) void {
            self.setRepeatMode(switch (self.getRepeatMode()) {
                .None => .All,
                .All => .One,
                .One => .None,
            });
        }
        pub fn isRepeating(self: *const Self) bool {
            return if (self.queue) |q| q.isRepeating() else false;
        }
        pub fn setShuffled(self: *Self, enabled: bool) !void {
            if (self.queue) |q| try q.setShuffled(enabled);
        }
        pub fn isShuffled(self: *const Self) bool {
            return if (self.queue) |q| q.isShuffled() else false;
        }
        pub fn setContext(self: *Self, context_type: PlaybackContextType, context_id: i32) void {
            if (self.queue) |q| {
                q.context_type = context_type;
                q.context_id = context_id;
            }
        }
        pub fn getContextType(self: *const Self) PlaybackContextType {
            return if (self.queue) |q| q.context_type else .Individual;
        }
        pub fn getContextId(self: *const Self) i32 {
            return if (self.queue) |q| q.context_id else -1;
        }
    };
}
