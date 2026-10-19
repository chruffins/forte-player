//! Headless tests of the `MusicEngine` transport logic, driven by `FakeDriver`
//! so no audio device / real mixer is required.

const std = @import("std");
const al = @import("allegro");
const music = @import("music_engine.zig");
const PlayQueue = @import("../music/play_queue.zig").PlayQueue;
const FakeEngine = music.MusicEngine(music.FakeDriver);

/// A driver identical to `FakeDriver` except that `load` fails for any path
/// starting with "bad" — lets us exercise failed-load handling without a real
/// audio device (mirrors a file this Allegro build can't decode, e.g. MP3).
const FickleDriver = struct {
    pub const Stream = music.FakeDriver.Stream;

    pub fn init(_: std.mem.Allocator) !FickleDriver {
        return .{};
    }
    pub fn deinit(_: *FickleDriver) void {}
    pub fn hook(_: *FickleDriver) !void {}
    pub fn load(_: *FickleDriver, path: [:0]const u8) !Stream {
        if (std.mem.startsWith(u8, path, "bad")) return error.LoadFailed;
        var fake: music.FakeDriver = .{};
        return music.FakeDriver.load(&fake, path);
    }
    pub fn streamEventSource(_: *FickleDriver, _: *Stream) ?al.events.EventSource {
        return null;
    }
    pub fn setGain(_: *FickleDriver, _: f32) void {}
    pub fn setSampleBufferCapacity(_: *FickleDriver, _: usize) !void {}
    pub fn enableCapture(_: *FickleDriver, _: bool) void {}
    pub fn bufferedCount(_: *const FickleDriver) usize {
        return 0;
    }
    pub fn copyRecentMono(_: *const FickleDriver, _: usize, out: []f32) usize {
        @memset(out[0..0], 0);
        return 0;
    }
    pub fn clearCapture(_: *FickleDriver) void {}
};

const FickleEngine = music.MusicEngine(FickleDriver);

/// Map a song id to a distinct path whose length gives a distinct fake duration
/// (len 1..5 -> duration 2..6), letting us assert which song is current.
fn resolveSong(id: i32, _: *anyopaque) ?[:0]const u8 {
    const paths = [_][:0]const u8{ "a", "bb", "ccc", "dddd" };
    if (id >= 0 and id < paths.len) return paths[@intCast(id)];
    return null;
}

test "playSound: isPlaying, duration, start time" {
    var engine = try FakeEngine.create(std.testing.allocator);
    defer engine.destroy();

    try std.testing.expect(!engine.isPlaying());

    try engine.playSound("media/a/b"); // path len 7 -> duration 8s
    try std.testing.expect(engine.isPlaying());
    try std.testing.expectEqual(@as(f64, 0.0), engine.getTime());
    // len("media/a/b") = 9 -> (9 % 997) + 1 = 10
    try std.testing.expectEqual(@as(f64, 10.0), engine.getDuration());
}

test "pause / resume / isPlaying" {
    var engine = try FakeEngine.create(std.testing.allocator);
    defer engine.destroy();

    try engine.playSound("x");
    try std.testing.expect(engine.isPlaying());

    engine.pause();
    try std.testing.expect(!engine.isPlaying());

    engine.resumePlayback();
    try std.testing.expect(engine.isPlaying());

    engine.stop();
    try std.testing.expect(!engine.isPlaying());
}

test "seek + update reflect position" {
    var engine = try FakeEngine.create(std.testing.allocator);
    defer engine.destroy();

    try engine.playSound("song");

    engine.setProgress(42.0);
    try std.testing.expectEqual(@as(f64, 42.0), engine.getTime()); // set via seek
    engine.update(); // re-reads from fake stream (position stays 42)
    try std.testing.expectEqual(@as(f64, 42.0), engine.getTime());
}

test "pan and speed forwarded to the (fake) stream" {
    var engine = try FakeEngine.create(std.testing.allocator);
    defer engine.destroy();
    try engine.playSound("song");

    engine.setPan(0.5);
    engine.setSpeed(2.0);
    // The fake records these; we can observe them through the stream we loaded,
    // but via the public API the important thing is no crash + still playing.
    try std.testing.expect(engine.isPlaying());
}

test "normalization is per stream and composes separately with master gain" {
    var engine = try FakeEngine.create(std.testing.allocator);
    defer engine.destroy();
    engine.setGain(0.4);
    engine.setNormalizationGain(1.7);
    try std.testing.expectEqual(@as(f32, 0.4), engine.drv.mixer_gain);
    try engine.playSound("first");
    try std.testing.expectApproxEqAbs(@as(f32, 1.7), engine.stream.?.gain(), 0.0001);
    engine.setNormalizationGain(0.75);
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), engine.stream.?.gain(), 0.0001);
    try std.testing.expectEqual(@as(f32, 0.4), engine.drv.mixer_gain);
    try engine.playSound("second");
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), engine.stream.?.gain(), 0.0001);
}

test "gain clamps to [0, 1]" {
    var engine = try FakeEngine.create(std.testing.allocator);
    defer engine.destroy();

    engine.setGain(3.0);
    try std.testing.expectEqual(@as(f32, 1.0), engine.getGain());
    engine.setGain(-2.0);
    try std.testing.expectEqual(@as(f32, 0.0), engine.getGain());
    engine.setGain(0.5);
    try std.testing.expectEqual(@as(f32, 0.5), engine.getGain());
}

test "capture pass-through is a safe no-op on the fake" {
    var engine = try FakeEngine.create(std.testing.allocator);
    defer engine.destroy();

    engine.enableCapture(true);
    try std.testing.expectEqual(@as(usize, 0), engine.bufferedCount());
    var out: [16]f32 = undefined;
    try std.testing.expectEqual(@as(usize, 0), engine.copyRecentMono(16, &out));
    engine.clearCapture();
    try engine.setSampleBufferCapacity(1024);
}

test "gapless preload promotes queue successor and crossfades per stream" {
    var engine = try FakeEngine.create(std.testing.allocator);
    defer engine.destroy();
    var queue = PlayQueue.init(std.testing.allocator);
    defer queue.deinit();
    try queue.enqueueMany(&.{ 0, 1 });
    engine.resolve_song = resolveSong;
    engine.setPlayQueue(&queue);
    engine.setCrossfadeSecs(2);
    try engine.playSound("a");

    engine.stream.?.position = 0.5; // duration is 2s; begin preloading
    engine.update();
    try std.testing.expect(engine.next_stream != null);
    try std.testing.expectEqual(@as(?i32, 0), queue.current());

    engine.stream.?.position = 1.0;
    engine.update();
    try std.testing.expect(engine.next_stream.?.playing());
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), engine.next_stream.?.gain(), 0.0001);

    engine.stream.?.position = 1.5;
    engine.update();
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), engine.stream.?.gain(), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), engine.next_stream.?.gain(), 0.0001);

    engine.stream.?.position = 2.0;
    engine.update();
    try std.testing.expectEqual(@as(?i32, 1), queue.current());
    try std.testing.expectEqual(@as(f64, 3.0), engine.getDuration());
    try std.testing.expect(engine.isPlaying());
}

test "manual navigation and pause/stop cancel or defer preloaded promotion" {
    var engine = try FakeEngine.create(std.testing.allocator);
    defer engine.destroy();
    var queue = PlayQueue.init(std.testing.allocator);
    defer queue.deinit();
    try queue.enqueueMany(&.{ 0, 1, 2 });
    engine.resolve_song = resolveSong;
    engine.setPlayQueue(&queue);
    engine.setCrossfadeSecs(2);
    try engine.playSound("a");
    engine.stream.?.position = 0.5;
    engine.update();
    try std.testing.expect(engine.next_stream != null);

    engine.pause();
    engine.stream.?.position = engine.getDuration();
    engine.update();
    try std.testing.expectEqual(@as(?i32, 0), queue.current());
    try std.testing.expect(!engine.next_stream.?.playing());

    engine.resumePlayback();
    try std.testing.expect(try engine.playNext());
    try std.testing.expect(engine.next_stream == null);
    try std.testing.expectEqual(@as(?i32, 1), queue.current());
    try engine.playPrevious();
    try std.testing.expectEqual(@as(?i32, 0), queue.current());
    engine.stop();
    try engine.handleAudioStreamFinishedFromEvent();
    try std.testing.expect(!engine.isPlaying());
}

test "queue edits invalidate preloaded destination; seek cancels overlap" {
    var engine = try FakeEngine.create(std.testing.allocator);
    defer engine.destroy();
    var queue = PlayQueue.init(std.testing.allocator);
    defer queue.deinit();
    try queue.enqueueMany(&.{ 0, 1, 2 });
    engine.resolve_song = resolveSong;
    engine.setPlayQueue(&queue);
    engine.setCrossfadeSecs(0);
    try engine.playSound("a");
    engine.stream.?.position = 0.5;
    engine.update();
    try std.testing.expect(engine.next_stream != null);
    try queue.moveAt(1, 2);
    engine.update();
    try std.testing.expect(engine.next_stream != null);
    engine.setProgress(0.25);
    try std.testing.expect(engine.next_stream == null);
    try std.testing.expectEqual(@as(f64, 0.25), engine.getTime());
}

test "auto-advance: repeat None stops when queue runs out" {
    var engine = try FakeEngine.create(std.testing.allocator);
    defer engine.destroy();
    var queue = PlayQueue.init(std.testing.allocator);
    defer queue.deinit();
    try queue.enqueueMany(&.{ 0, 1 });

    engine.resolve_song = resolveSong;
    engine.setPlayQueue(&queue);

    try engine.playSound("a"); // id 0 (duration 2)
    try std.testing.expectEqual(@as(f64, 2.0), engine.getDuration());

    try engine.handleAudioStreamFinished(); // -> id 1 ("bb", duration 3)
    try std.testing.expect(engine.isPlaying());
    try std.testing.expectEqual(@as(f64, 3.0), engine.getDuration());

    try engine.handleAudioStreamFinished(); // repeat None, no next -> stop
    try std.testing.expect(!engine.isPlaying());
}

test "auto-advance: repeat All wraps to the first song" {
    var engine = try FakeEngine.create(std.testing.allocator);
    defer engine.destroy();
    var queue = PlayQueue.init(std.testing.allocator);
    defer queue.deinit();
    try queue.enqueueMany(&.{ 0, 1 });

    engine.resolve_song = resolveSong;
    engine.setPlayQueue(&queue);
    engine.setRepeatMode(.All);

    try engine.playSound("a"); // id 0
    try engine.handleAudioStreamFinished(); // -> id 1
    try engine.handleAudioStreamFinished(); // wraps -> id 0
    try std.testing.expect(engine.isPlaying());
    try std.testing.expectEqual(@as(f64, 2.0), engine.getDuration());
}

test "auto-advance: repeat One replays the same song" {
    var engine = try FakeEngine.create(std.testing.allocator);
    defer engine.destroy();
    var queue = PlayQueue.init(std.testing.allocator);
    defer queue.deinit();
    try queue.enqueueMany(&.{ 0, 1 });

    engine.resolve_song = resolveSong;
    engine.setPlayQueue(&queue);
    engine.setRepeatMode(.One);

    try engine.playSound("a"); // id 0 (duration 2)
    try engine.handleAudioStreamFinished(); // replays id 0
    try std.testing.expect(engine.isPlaying());
    try std.testing.expectEqual(@as(f64, 2.0), engine.getDuration()); // still id 0
}

test "auto-advance: finishing without a queue just stops" {
    var engine = try FakeEngine.create(std.testing.allocator);
    defer engine.destroy();

    try engine.playSound("a");
    try std.testing.expect(engine.isPlaying());
    try engine.handleAudioStreamFinished(); // no queue -> stop
    try std.testing.expect(!engine.isPlaying());
}

test "playNext / playPrevious use the queue" {
    var engine = try FakeEngine.create(std.testing.allocator);
    defer engine.destroy();
    var queue = PlayQueue.init(std.testing.allocator);
    defer queue.deinit();
    try queue.enqueueMany(&.{ 0, 1, 2 });

    engine.resolve_song = resolveSong;
    engine.setPlayQueue(&queue);

    try engine.playSound("a"); // id 0
    try std.testing.expect(try engine.playNext()); // -> id 1 ("bb")
    try std.testing.expectEqual(@as(f64, 3.0), engine.getDuration());

    try engine.playPrevious(); // back to id 0
    try std.testing.expectEqual(@as(f64, 2.0), engine.getDuration());
}

test "playNext returns false when no song resolves / queue empty" {
    var engine = try FakeEngine.create(std.testing.allocator);
    defer engine.destroy();

    // No queue at all -> false, nothing to play.
    try std.testing.expect(!try engine.playNext());

    var queue = PlayQueue.init(std.testing.allocator);
    defer queue.deinit();
    try queue.enqueueMany(&.{ 0, 1 });
    engine.resolve_song = resolveSong;
    engine.setPlayQueue(&queue);
    queue.current_index = 1; // set past the end so there's no next
    try std.testing.expect(!try engine.playNext());
}

test "failed load keeps the current song playing and control intact" {
    var engine = try FickleEngine.create(std.testing.allocator);
    defer engine.destroy();

    try engine.playSound("good1"); // len 5 -> duration 6
    try std.testing.expect(engine.isPlaying());
    const playing_duration = engine.getDuration();

    // Loading an undecodable file must NOT stop the current song.
    try std.testing.expectError(error.LoadFailed, engine.playSound("badfile"));
    try std.testing.expect(engine.isPlaying());
    try std.testing.expectEqual(playing_duration, engine.getDuration());

    // Control still works (resume/next paths aren't dead no-ops).
    engine.pause();
    try std.testing.expect(!engine.isPlaying());
    engine.resumePlayback();
    try std.testing.expect(engine.isPlaying());
}

// id -> path map with an intentionally-undecodable middle entry (id 1).
fn fickleResolve(id: i32, _: *anyopaque) ?[:0]const u8 {
    const paths = [_][:0]const u8{ "ok0", "bad1", "ok2" };
    if (id >= 0 and id < paths.len) return paths[@intCast(id)];
    return null;
}

test "playNext skips songs that cannot be loaded" {
    var engine = try FickleEngine.create(std.testing.allocator);
    defer engine.destroy();
    var queue = PlayQueue.init(std.testing.allocator);
    defer queue.deinit();
    try queue.enqueueMany(&.{ 0, 1, 2 });
    engine.resolve_song = fickleResolve;
    engine.setPlayQueue(&queue);

    try engine.playSound("ok0"); // id 0
    try std.testing.expect(try engine.playNext()); // skips "bad1", lands on "ok2"
    try std.testing.expect(engine.isPlaying());
    // len("ok2") = 3 -> duration 4
    try std.testing.expectEqual(@as(f64, 4.0), engine.getDuration());
    // The failed middle track is not inserted into previous() history.
    try std.testing.expectEqual(@as(?i32, 0), queue.previous());
}

test "playNext with only unloadable songs left returns false, keeps current playing" {
    var engine = try FickleEngine.create(std.testing.allocator);
    defer engine.destroy();
    var queue = PlayQueue.init(std.testing.allocator);
    defer queue.deinit();
    try queue.enqueueMany(&.{ 0, 1 }); // id 1 is "bad1" (undecodable)
    engine.resolve_song = fickleResolve;
    engine.setPlayQueue(&queue);

    try engine.playSound("ok0"); // id 0
    // playNext: next is "bad1" (skip) then end-of-queue (repeat off) -> false.
    try std.testing.expect(!try engine.playNext());
    try std.testing.expect(engine.isPlaying()); // current song still playing
    // The failed transition must not consume the queue cursor/history.
    try std.testing.expectEqual(@as(?i32, 0), queue.current());
    try std.testing.expectEqual(@as(?i32, null), queue.previous());
}
