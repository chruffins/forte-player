//! Bar-spectrum computation for the TUI visualizer.
//!
//! Takes the newest mono samples, applies a Hann window, runs the FFT, groups
//! the magnitude bins into log-spaced bands (like a spectrum analyzer), and
//! smooths them with a fast-attack / slow-decay envelope so the bars look
//! musical rather than jittery. Pure math (allocation-free); the caller owns
//! the sample buffer and the `Smoother`.

const std = @import("std");
const fft_mod = @import("fft.zig");

/// FFT window size (power of two; ~23ms @ 44.1kHz).
pub const n_samples: usize = 1024;
/// Number of rendered bars.
pub const n_bands: usize = 48;

/// Per-band envelope with automatic gain control: attack is instant (follow
/// the peak up), decay is slow, and the whole spectrum is normalized against a
/// slowly-releasing global peak so quiet and loud tracks both read well.
pub const Smoother = struct {
    levels: [n_bands]f32 = [_]f32{0} ** n_bands,
    /// Smoothed global peak (AGC reference).
    peak: f32 = 0.001,
    /// Exponential decay factor applied per frame when the signal falls.
    decay: f32 = 0.88,

    pub fn update(self: *Smoother, raw: []const f32) void {
        std.debug.assert(raw.len == n_bands);
        var frame_peak: f32 = 0.001;
        for (raw) |v| frame_peak = @max(frame_peak, v);
        self.peak = if (frame_peak > self.peak) frame_peak else self.peak * 0.90 + frame_peak * 0.10;
        const gain = 0.9 / self.peak;
        for (raw, 0..) |v, i| {
            const target = @min(v * gain, 1.0);
            const cur = self.levels[i];
            self.levels[i] = if (target >= cur) target else cur * self.decay + target * (1.0 - self.decay);
        }
    }
};

/// Compute `n_bands` log-spaced band magnitudes in [0,1] from `samples`
/// (0 < len <= n_samples; shorter input is zero-padded).
pub fn computeBands(samples: []const f32, bands: *[n_bands]f32) void {
    var re: [n_samples]f32 = [_]f32{0} ** n_samples;
    var im: [n_samples]f32 = [_]f32{0} ** n_samples;

    const n = @min(samples.len, n_samples);
    for (0..n) |i| {
        // Hann window.
        const w = 0.5 - 0.5 * @cos(2.0 * std.math.pi * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n)));
        re[i] = samples[i] * w;
    }
    fft_mod.fft(&re, &im);

    // Band boundaries: log-spaced from bin 2 up to bin n/2.
    const max_bin: f32 = @floatFromInt(n_samples / 2);
    const lo: f32 = 2.0;
    const lo_log = @log(lo);
    const span_log = @log(max_bin) - lo_log;
    const norm = 1.0 / @as(f32, @floatFromInt(n_samples));

    for (0..n_bands) |b| {
        const bf: f32 = @floatFromInt(b);
        const b_lo = @exp(lo_log + span_log * bf / @as(f32, @floatFromInt(n_bands)));
        const b_hi = @exp(lo_log + span_log * (bf + 1.0) / @as(f32, @floatFromInt(n_bands)));
        const first: usize = @intFromFloat(b_lo);
        const last: usize = @min(@as(usize, @intFromFloat(b_hi)), n_samples / 2);
        var acc: f32 = 0.0;
        var cnt: usize = 0;
        var k = first;
        while (k < last) : (k += 1) {
            acc += @sqrt(re[k] * re[k] + im[k] * im[k]) * norm;
            cnt += 1;
        }
        bands[b] = if (cnt > 0) acc / @as(f32, @floatFromInt(cnt)) else 0.0;
    }

    // Normalize: scale so typical music sits comfortably below 1.0.
    for (bands) |*v| {
        v.* = @min(v.* * 6.0, 1.0);
    }
}

test "computeBands: silence yields silence" {
    var samples: [n_samples]f32 = [_]f32{0} ** n_samples;
    var bands: [n_bands]f32 = undefined;
    computeBands(&samples, &bands);
    for (bands) |b| try std.testing.expect(b == 0.0);
}

test "computeBands: a mid-frequency tone lights the mid bands, not the edges" {
    const freq: f32 = 440.0;
    const rate: f32 = 44100.0;
    var samples: [n_samples]f32 = undefined;
    for (0..n_samples) |i| {
        samples[i] = @sin(2.0 * std.math.pi * freq * @as(f32, @floatFromInt(i)) / rate) * 0.5;
    }
    var bands: [n_bands]f32 = undefined;
    computeBands(&samples, &bands);

    // The 440Hz tone is bin ~10 of 512; with 48 log-spaced bands over ~8
    // octaves it lands in the low-mid region, far from both edges.
    var max_v: f32 = 0.0;
    var max_i: usize = 0;
    for (bands, 0..) |b, i| {
        if (b > max_v) {
            max_v = b;
            max_i = i;
        }
    }
    try std.testing.expect(max_i >= 8 and max_i <= 20);
    try std.testing.expect(max_v > 0.05);
}

test "smoother: AGC normalizes loudness with fast attack, slow decay" {
    var sm = Smoother{};
    var raw: [n_bands]f32 = [_]f32{0} ** n_bands;

    // silence -> silence
    sm.update(&raw);
    try std.testing.expectEqual(@as(f32, 0.0), sm.levels[3]);

    // loud signal attacks instantly, AGC-normalized to ~0.9 (not clipped)
    raw[3] = 1.0;
    sm.update(&raw);
    try std.testing.expect(@abs(sm.levels[3] - 0.9) < 0.05);

    // a much quieter signal converges to a similar displayed level (AGC)
    var sm2 = Smoother{};
    var raw2: [n_bands]f32 = [_]f32{0} ** n_bands;
    var f: usize = 0;
    while (f < 20) : (f += 1) {
        raw2[3] = 0.1;
        sm2.update(&raw2);
    }
    try std.testing.expect(sm2.levels[3] > 0.4);

    // decay: falls gradually when the signal stops, not instantly
    const before = sm2.levels[3];
    raw2[3] = 0.0;
    sm2.update(&raw2);
    try std.testing.expect(sm2.levels[3] < before);
    try std.testing.expect(sm2.levels[3] > 0.0);
}
