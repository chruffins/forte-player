//! Lightweight singing-voice prominence heuristic for visualizer use.
//! This is not source separation: other pitched/periodic instruments can score.
const std = @import("std");

const sample_rate: f32 = 11025;
const decimation: usize = 4;
const max_samples: usize = 256;
const min_f0: f32 = 80;
const max_f0: f32 = 1000;

/// Score how voice-like a short mono window is using pitch-range periodicity
/// and an energy gate. Input is downsampled by four with a box low-pass first.
pub fn estimate(samples: []const f32) f32 {
    const count = @min(samples.len / decimation, max_samples);
    if (count < 32) return 0;

    var signal: [max_samples]f32 = @splat(0);
    var mean: f32 = 0;
    var energy: f32 = 0;
    for (0..count) |i| {
        var sum: f32 = 0;
        for (0..decimation) |j| {
            const sample = samples[i * decimation + j];
            sum += if (std.math.isFinite(sample)) sample else 0;
        }
        signal[i] = sum / @as(f32, decimation);
        mean += signal[i];
    }
    mean /= @as(f32, @floatFromInt(count));
    for (signal[0..count]) |*sample| {
        sample.* -= mean;
        energy += sample.* * sample.*;
    }
    const rms = @sqrt(energy / @as(f32, @floatFromInt(count)));
    if (rms < 0.002) return 0;

    const min_lag: usize = @intFromFloat(sample_rate / max_f0);
    const max_lag = @min(@as(usize, @intFromFloat(sample_rate / min_f0)), count / 2);
    var best: f32 = 0;
    for (min_lag..max_lag + 1) |lag| {
        var cross: f32 = 0;
        var left_energy: f32 = 0;
        var right_energy: f32 = 0;
        for (0..count - lag) |i| {
            const left = signal[i];
            const right = signal[i + lag];
            cross += left * right;
            left_energy += left * left;
            right_energy += right * right;
        }
        const denominator = @sqrt(left_energy * right_energy);
        if (denominator > 0) best = @max(best, cross / denominator);
    }

    // Map normalized autocorrelation into a soft confidence, then suppress
    // near-silence so codec noise does not look like singing.
    const periodicity = smoothstep(0.38, 0.82, best);
    const audibility = smoothstep(0.002, 0.02, rms);
    return periodicity * audibility;
}

fn smoothstep(edge0: f32, edge1: f32, value: f32) f32 {
    const t = @max(0, @min(1, (value - edge0) / (edge1 - edge0)));
    return t * t * (3 - 2 * t);
}

/// Frame-rate-independent smoothing for the visualizer's vocal accent.
pub const Envelope = struct {
    value: f32 = 0,

    pub fn update(self: *Envelope, target: f32, seconds: f32) f32 {
        if (!std.math.isFinite(seconds) or seconds <= 0) return self.value;
        const bounded = if (std.math.isFinite(target)) @max(0, @min(1, target)) else 0;
        const tau: f32 = if (bounded > self.value) 0.09 else 0.24;
        self.value += (bounded - self.value) * (1 - @exp(-seconds / tau));
        return self.value;
    }
};

test "vocal prominence favors audible periodic frames over silence and noise" {
    const n = 1024;
    var tone: [n]f32 = undefined;
    var noise: [n]f32 = undefined;
    var silence: [n]f32 = @splat(0);
    var rng = std.Random.DefaultPrng.init(0x51_6e_67);
    for (0..n) |i| {
        const t = @as(f32, @floatFromInt(i)) / 44100;
        tone[i] = 0.25 * @sin(2 * std.math.pi * 220 * t) +
            0.08 * @sin(2 * std.math.pi * 660 * t);
        noise[i] = rng.random().float(f32) * 0.5 - 0.25;
    }
    try std.testing.expect(estimate(&tone) > 0.75);
    try std.testing.expect(estimate(&noise) < 0.4);
    try std.testing.expectEqual(@as(f32, 0), estimate(&silence));
    tone[100] = std.math.nan(f32);
    try std.testing.expect(std.math.isFinite(estimate(&tone)));
}

test "vocal prominence envelope is smooth, bounded and cadence independent" {
    for ([_]usize{ 30, 60, 144 }) |hz| {
        var envelope = Envelope{};
        for (0..hz) |_| _ = envelope.update(1, 1.0 / @as(f32, @floatFromInt(hz)));
        try std.testing.expectApproxEqAbs(@as(f32, 1 - @exp(-1.0 / 0.09)), envelope.value, 0.00001);
        for (0..hz) |_| _ = envelope.update(0, 1.0 / @as(f32, @floatFromInt(hz)));
        try std.testing.expectApproxEqAbs(@as(f32, @exp(-1.0 / 0.24)), envelope.value, 0.00001);
    }
}
