//! Low-level audio "drivers" behind a duck-typed seam so that `MusicEngine`
//! can be instantiated against either the real Allegro stack or a pure in-memory
//! fake (for headless tests of the transport logic).
//!
//! The duck-typed contract each driver provides (what `MusicEngine(Drv)`
//! relies on):
//!   * `Stream`        — the stream type used for a single song
//!   * `init(allocator) !Drv`  (value)  / `deinit(*Drv)`
//!   * `hook(*Drv) !void`      — register the mixer postprocess callback (real only)
//!   * `load(*Drv, path) !Stream`
//!   * `streamEventSource(*Drv, *Stream) ?EventSource`  (null => none, e.g. fake)
//!   * `setGain(*Drv, f32)`
//!   * capture: `setSampleBufferCapacity`, `enableCapture`, `bufferedCount`,
//!              `copyRecentMono`, `clearCapture`
//!
//! `Stream` itself must provide: `destroy`, `setPlaying`, `playing`, `setPan`,
//! `setSpeed`, `positionSecs`, `lengthSecs`, `seekSecs`.

const std = @import("std");
const al = @import("allegro");
const SampleCapture = @import("sample_capture.zig").SampleCapture;

const kDefaultSampleBufferCapacity: usize = 44100 * 2 * 4; // ~4s stereo @ 44.1kHz

/// The real Allegro backend. Owns the voice/mixer graph and the capture ring.
///
/// Intended to be heap-allocated (`*AllegroDriver`) so the mixer postprocess
/// callback (`alPostProcess`) has a stable address for its `data` pointer.
pub const AllegroDriver = struct {
    allocator: std.mem.Allocator,
    voice: al.audio.Voice,
    mixer: al.audio.Mixer,
    capture: SampleCapture,

    pub const Stream = al.audio.AudioStream;

    pub fn init(allocator: std.mem.Allocator) !AllegroDriver {
        var voice = try al.audio.Voice.create(44100, al.audio.Depth.INT16, al.audio.ChannelConf.P2);
        errdefer voice.destroy();

        var mixer = try al.audio.Mixer.create(44100, al.audio.Depth.INT16, al.audio.ChannelConf.P2);
        errdefer mixer.destroy();
        try mixer.attachToVoice(&voice);

        var capture = try SampleCapture.init(allocator, kDefaultSampleBufferCapacity);
        errdefer capture.deinit();

        capture.channels = @max(@as(usize, 1), al.audio.channelCount(mixer.getChannels()));

        return .{
            .allocator = allocator,
            .voice = voice,
            .mixer = mixer,
            .capture = capture,
        };
    }

    pub fn deinit(self: *AllegroDriver) void {
        _ = self.mixer.setPostProcessCallback(null, null);
        self.mixer.destroy();
        self.voice.destroy();
        self.capture.deinit();
    }

    /// Register the postprocess callback. `data` is this driver's stable heap
    /// address, retrieved in `alPostProcess`.
    pub fn hook(self: *AllegroDriver) !void {
        if (!self.mixer.setPostProcessCallback(&alPostProcess, @ptrCast(self))) {
            return error.CallbackRegistrationFailed;
        }
    }

    pub fn load(self: *AllegroDriver, path: [:0]const u8) !Stream {
        var s = try al.audio.AudioStream.load(path, 4, 4096);
        errdefer s.destroy();
        try s.attachToMixer(&self.mixer);
        return s;
    }

    pub fn streamEventSource(self: *AllegroDriver, stream: *Stream) ?al.events.EventSource {
        _ = self;
        return stream.eventSource();
    }

    pub fn setGain(self: *AllegroDriver, gain: f32) void {
        _ = self.mixer.setGain(gain);
    }

    pub fn setSampleBufferCapacity(self: *AllegroDriver, n: usize) !void {
        try self.capture.setCapacity(n);
    }
    pub fn enableCapture(self: *AllegroDriver, enabled: bool) void {
        self.capture.setEnabled(enabled);
    }
    pub fn bufferedCount(self: *const AllegroDriver) usize {
        return self.capture.getSize();
    }
    pub fn captureSequence(self: *const AllegroDriver) u64 {
        return self.capture.sequence();
    }
    pub fn copyRecentMono(self: *const AllegroDriver, max_frames: usize, out: []f32) usize {
        return self.capture.copyRecentMono(max_frames, out);
    }
    pub fn clearCapture(self: *AllegroDriver) void {
        self.capture.clear();
    }

    fn alPostProcess(buf: ?*anyopaque, samples: u32, data: ?*anyopaque) callconv(.c) void {
        if (data == null or buf == null or samples == 0) return;
        const driver: *AllegroDriver = @ptrCast(@alignCast(data.?));
        const int16_samples: [*]const i16 = @ptrCast(@alignCast(buf.?));
        driver.capture.appendInterleavedInt16(
            int16_samples[0 .. @as(usize, samples) * driver.capture.channels],
        );
    }
};

/// In-memory stream used by `FakeDriver` in headless tests.
pub const FakeStream = struct {
    is_playing: bool = false,
    position: f64 = 0.0,
    length_secs: f64 = 100.0,
    pan: f32 = 0.0,
    speed: f32 = 1.0,

    pub fn destroy(_: *FakeStream) void {}
    pub fn setPlaying(self: *FakeStream, v: bool) bool {
        self.is_playing = v;
        return true;
    }
    pub fn playing(self: *const FakeStream) bool {
        return self.is_playing;
    }
    pub fn setPan(self: *FakeStream, v: f32) bool {
        self.pan = v;
        return true;
    }
    pub fn setSpeed(self: *FakeStream, v: f32) bool {
        self.speed = v;
        return true;
    }
    pub fn positionSecs(self: *const FakeStream) f64 {
        return self.position;
    }
    pub fn lengthSecs(self: *const FakeStream) f64 {
        return self.length_secs;
    }
    pub fn seekSecs(self: *FakeStream, t: f64) bool {
        self.position = t;
        return true;
    }
};

/// A pure in-memory driver for headless testing of the transport logic
/// (play/pause/seek/status). No audio device, no capture.
pub const FakeDriver = struct {
    pub const Stream = FakeStream;

    pub fn init(_: std.mem.Allocator) !FakeDriver {
        return .{};
    }
    pub fn deinit(_: *FakeDriver) void {}

    pub fn hook(_: *FakeDriver) !void {}

    pub fn load(_: *FakeDriver, path: [:0]const u8) !Stream {
        // Deterministic duration derived from the "path" so tests can assert.
        const len: f64 = if (path.len == 0) 0.0 else @as(f64, @floatFromInt(@rem(path.len, 997))) + 1.0;
        return .{ .length_secs = len, .is_playing = false };
    }

    pub fn streamEventSource(_: *FakeDriver, _: *Stream) ?al.events.EventSource {
        return null; // no real event source in the fake
    }

    pub fn setGain(_: *FakeDriver, _: f32) void {}

    pub fn setSampleBufferCapacity(_: *FakeDriver, _: usize) !void {}
    pub fn enableCapture(_: *FakeDriver, _: bool) void {}
    pub fn bufferedCount(_: *const FakeDriver) usize {
        return 0;
    }
    pub fn captureSequence(_: *const FakeDriver) u64 {
        return 0;
    }
    pub fn copyRecentMono(_: *const FakeDriver, _: usize, out: []f32) usize {
        @memset(out[0..0], 0);
        return 0;
    }
    pub fn clearCapture(_: *FakeDriver) void {}
};
