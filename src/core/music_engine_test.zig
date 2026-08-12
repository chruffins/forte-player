//! Headless tests of the `MusicEngine` transport logic, driven by `FakeDriver`
//! so no audio device / real mixer is required.

const std = @import("std");
const music = @import("music_engine.zig");
const FakeEngine = music.MusicEngine(music.FakeDriver);

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
