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
/// Audio sample rate the FFT assumes (matches the engine's voice/mixer rate).
pub const default_sample_rate: u32 = 44100;

/// Optional perceptual frequency weighting applied per band, before the final
/// scale/clamp. `a_weight` is the standard SSPL "A" curve: heavy low bass and
/// the very high treble are attenuated relative to the ~1 kHz midrange, so the
/// bars more closely track what the ear actually perceives as loud.
/// `none` leaves the raw magnitude spectrum untouched.
pub const Weighting = enum { none, a_weight };

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
/// Compute A-weighted bar bands at the engine's default sample rate. This is
/// what the visualizer uses; see `computeBandsEx` for the full control knob.
pub fn computeBands(samples: []const f32, bands: *[n_bands]f32) void {
    computeBandsEx(samples, bands, default_sample_rate, .a_weight);
}

/// Cached analyzer for repeated fixed-size spectrum frames. All transcendental
/// setup work is done once; `compute` only windows, transforms, and accumulates.
pub const Analyzer = struct {
    rate: u32,
    weighting: Weighting,
    hann: [n_samples]f32,
    first: [n_bands]usize,
    last: [n_bands]usize,
    weights: [n_bands]f32,
    twiddles: fft_mod.TwiddleCache,

    pub fn init(rate: u32, weighting: Weighting) Analyzer {
        var out: Analyzer = undefined;
        out.rate = rate;
        out.weighting = weighting;
        out.twiddles = fft_mod.TwiddleCache.init(n_samples);
        for (0..n_samples) |i| {
            out.hann[i] = 0.5 - 0.5 * @cos(2.0 * std.math.pi * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n_samples)));
        }
        const max_bin: f32 = @floatFromInt(n_samples / 2);
        const lo_log = @log(@as(f32, 2.0));
        const span_log = @log(max_bin) - lo_log;
        for (0..n_bands) |b| {
            const bf: f32 = @floatFromInt(b);
            out.first[b] = @intFromFloat(@exp(lo_log + span_log * bf / @as(f32, @floatFromInt(n_bands))));
            out.last[b] = @min(@as(usize, @intFromFloat(@exp(lo_log + span_log * (bf + 1.0) / @as(f32, @floatFromInt(n_bands))))), n_samples / 2);
            if (weighting == .a_weight) {
                const center = (@as(f32, @floatFromInt(out.first[b])) + @as(f32, @floatFromInt(out.last[b]))) * 0.5;
                out.weights[b] = aWeightGain(center * @as(f32, @floatFromInt(rate)) / @as(f32, @floatFromInt(n_samples)));
            } else out.weights[b] = 1.0;
        }
        return out;
    }

    pub fn compute(self: *const Analyzer, samples: []const f32, bands: *[n_bands]f32) void {
        var re: [n_samples]f32 = [_]f32{0} ** n_samples;
        var im: [n_samples]f32 = [_]f32{0} ** n_samples;
        const n = @min(samples.len, n_samples);
        for (0..n) |i| re[i] = samples[i] * self.hann[i];
        fft_mod.fftWithCache(&re, &im, &self.twiddles);
        const norm = 1.0 / @as(f32, @floatFromInt(n_samples));
        for (0..n_bands) |b| {
            var acc: f32 = 0.0;
            var k = self.first[b];
            const end = self.last[b];
            while (k < end) : (k += 1) acc += @sqrt(re[k] * re[k] + im[k] * im[k]) * norm;
            const count = end -| self.first[b];
            bands[b] = if (count > 0) @min((acc / @as(f32, @floatFromInt(count))) * self.weights[b] * 6.0, 1.0) else 0.0;
        }
    }
};

/// Compatibility wrapper for callers that do not retain an analyzer.
pub fn computeBandsEx(samples: []const f32, bands: *[n_bands]f32, rate: u32, weighting: Weighting) void {
    var analyzer = Analyzer.init(rate, weighting);
    analyzer.compute(samples, bands);
}

/// A-weighting as a linear amplitude gain for a frequency in Hz. The standard
/// SSPL 'A' curve is roughly flat (~0 dB) around 1 kHz and rolls off hard in
/// the bass (≈ -20 dB at 120 Hz). Returns a fraction in (0, 1] for audible
/// frequencies.
fn aWeightGain(freq: f32) f32 {
    const f2 = freq * freq;
    const num = 12194.0 * 12194.0 * f2 * f2;
    const fa = f2 + 20.6 * 20.6;
    const fb = f2 + 107.7 * 107.7;
    const fc = f2 + 737.9 * 737.9;
    const fd = f2 + 12194.0 * 12194.0;
    const r = num / (fa * @sqrt(fb * fc) * fd);
    const db = 20.0 * @log10(r) + 2.0;
    return std.math.pow(f32, 10.0, db / 20.0);
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

fn findMax(bands: []const f32) f32 {
    var m: f32 = 0.0;
    for (bands) |v| m = @max(m, v);
    return m;
}

test "A-weighting gain: flat near 1kHz, rolled off in the bass and treble" {
    // ~0 dB (gain ~1.0) near 1 kHz, where the A curve is flat.
    try std.testing.expect(@abs(aWeightGain(1000.0) - 1.0) < 0.05);
    // Strong attenuation in the bass (~-20 dB at 120 Hz).
    try std.testing.expect(aWeightGain(120.0) < 0.2);
    // Some roll-off in the treble too (relative to the 1 kHz reference).
    try std.testing.expect(aWeightGain(10000.0) < aWeightGain(1000.0));
}

test "A-weighted bands attenuate a low-frequency tone vs a mid one" {
    const rate: u32 = 44100;
    var samples: [n_samples]f32 = undefined;

    // Fill the window with a tone. Same peak amplitude for both tones.
    const fill = struct {
        fn go(freq: f32, ratev: u32, out: *[n_samples]f32) void {
            for (0..n_samples) |i| {
                out[i] = @sin(2.0 * std.math.pi * freq * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(ratev))) * 0.5;
            }
        }
    }.go;

    fill(120.0, rate, &samples);
    var low_raw: [n_bands]f32 = undefined;
    var low_w: [n_bands]f32 = undefined;
    computeBandsEx(&samples, &low_raw, rate, .none);
    computeBandsEx(&samples, &low_w, rate, .a_weight);

    fill(1000.0, rate, &samples);
    var mid_raw: [n_bands]f32 = undefined;
    var mid_w: [n_bands]f32 = undefined;
    computeBandsEx(&samples, &mid_raw, rate, .none);
    computeBandsEx(&samples, &mid_w, rate, .a_weight);

    // Unweighted, equal-amplitude tones both register (raw spectrum doesn't
    // zero out either).
    try std.testing.expect(findMax(&low_raw) > 0.4);
    try std.testing.expect(findMax(&mid_raw) > 0.4);

    // A-weighting cuts the 120 Hz tone's peak ~5x (0.73 -> 0.15) while leaving
    // the 1 kHz tone essentially untouched (0.49 -> 0.50), which is exactly the
    // perceptual loudness shaping it should apply.
    const low_reduction = findMax(&low_raw) / findMax(&low_w);
    const mid_reduction = findMax(&mid_raw) / findMax(&mid_w);
    try std.testing.expect(low_reduction > 2.5);
    try std.testing.expect(mid_reduction < 1.5);
}
