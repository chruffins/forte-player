//! Iterative radix-2 Cooley–Tukey FFT for real input, SIMD-accelerated.
//!
//! `re`/`im` hold the real/imaginary parts; on return they hold the complex
//! spectrum (DC + positive frequencies, then negative mirrored). Power of two,
//! in-place, no heap allocation.
//!
//! The inner radix-2 butterfly is vectorized: each stage's twiddle factors are
//! materialized into a contiguous table so `W` butterflies run in one vector
//! op (`W` = the target's widest native f32 vector via
//! `std.simd.suggestVectorLength`). A scalar tail handles the `half % W`
//! remainder and the tiny stages where a stage is narrower than a vector; for
//! inputs too large for the stack twiddle table the stage loop falls back to
//! the scalar path entirely. The SIMD and scalar paths are exercised against
//! each other in the tests below.

const std = @import("std");

/// f32 lanes processed per SIMD butterfly batch. 8 on most x86-64 (AVX2),
/// 16 on AVX-512, 4 on SSE-only targets. `@Vector` with a wider-than-native
/// width still compiles and lowers correctly — just to 2× the native op — so
/// this is purely a performance knob.
const W: comptime_int = std.simd.suggestVectorLength(f32) orelse 4;
const Vec = @Vector(W, f32);

/// Largest n (power of two) the SIMD path serves. Bigger inputs use the scalar
/// fallback so the per-stage twiddle table can live on the stack.
pub const max_simd_n: usize = 8192;

/// Twiddle factors for a fixed transform size. They are stored in stage order
/// rather than natural-frequency order, so SIMD butterflies can load a
/// contiguous vector instead of gathering strided scalar entries every frame.
pub const TwiddleCache = struct {
    n: usize = 0,
    /// The stages together contain n - 1 entries; max_simd_n leaves room for
    /// every supported transform size.
    stage_re: [max_simd_n]f32 = undefined,
    stage_im: [max_simd_n]f32 = undefined,

    pub fn init(n: usize) TwiddleCache {
        std.debug.assert(n >= 2 and n <= max_simd_n and (n & (n - 1)) == 0);
        var out = TwiddleCache{ .n = n };
        var len: usize = 2;
        while (len <= n) : (len <<= 1) {
            const half = len / 2;
            const base = half - 1;
            const ang = -2.0 * std.math.pi / @as(f32, @floatFromInt(len));
            for (0..half) |k| {
                const phase = ang * @as(f32, @floatFromInt(k));
                out.stage_re[base + k] = @cos(phase);
                out.stage_im[base + k] = @sin(phase);
            }
        }
        return out;
    }
};

/// In-place FFT on the complex data in `re`/`im`.
pub fn fft(re: []f32, im: []f32) void {
    const n = re.len;
    std.debug.assert(n == im.len);
    std.debug.assert(n >= 2 and (n & (n - 1)) == 0); // power of two

    bitReverse(re, im);

    if (n <= max_simd_n) {
        simdStages(re, im);
    } else {
        scalarStages(re, im);
    }
}

/// Cached equivalent of `fft` for a repeatedly-used transform size.
pub fn fftWithCache(re: []f32, im: []f32, cache: *const TwiddleCache) void {
    const n = re.len;
    std.debug.assert(n == im.len and n == cache.n);
    std.debug.assert(n >= 2 and (n & (n - 1)) == 0);
    bitReverse(re, im);
    if (n <= max_simd_n) {
        simdStagesCached(re, im, cache);
    } else {
        scalarStages(re, im);
    }
}

/// Bit-reversal permutation (kept scalar: it's O(n), not the kernel hot path).
fn bitReverse(re: []f32, im: []f32) void {
    const n = re.len;
    var j: usize = 0;
    for (1..n) |i| {
        var bit: usize = n >> 1;
        while (j & bit != 0) : (bit >>= 1) j ^= bit;
        j ^= bit;
        if (i < j) {
            std.mem.swap(f32, &re[i], &re[j]);
            std.mem.swap(f32, &im[i], &im[j]);
        }
    }
}

/// Scalar Cooley–Tukey stage loop, twiddles advanced incrementally. Serves as
/// the fallback for very large inputs.
fn scalarStages(re: []f32, im: []f32) void {
    const n = re.len;
    var len: usize = 2;
    while (len <= n) : (len <<= 1) {
        const ang = -2.0 * std.math.pi / @as(f32, @floatFromInt(len));
        const wlen_re = @cos(ang);
        const wlen_im = @sin(ang);
        var i: usize = 0;
        while (i < n) : (i += len) {
            var w_re: f32 = 1.0;
            var w_im: f32 = 0.0;
            var k: usize = 0;
            while (k < len / 2) : (k += 1) {
                const u_re = re[i + k];
                const u_im = im[i + k];
                const a_re = re[i + k + len / 2];
                const a_im = im[i + k + len / 2];
                const v_re = a_re * w_re - a_im * w_im;
                const v_im = a_re * w_im + a_im * w_re;
                re[i + k] = u_re + v_re;
                im[i + k] = u_im + v_im;
                re[i + k + len / 2] = u_re - v_re;
                im[i + k + len / 2] = u_im - v_im;
                const nw_re = w_re * wlen_re - w_im * wlen_im;
                w_im = w_re * wlen_im + w_im * wlen_re;
                w_re = nw_re;
            }
        }
    }
}

/// Uncached source: materialize one stage's twiddles in contiguous SIMD order.
const LocalTwiddles = struct {
    re: [max_simd_n / 2]f32 = undefined,
    im: [max_simd_n / 2]f32 = undefined,

    inline fn prepare(self: *LocalTwiddles, len: usize) void {
        const half = len / 2;
        const angle = -2.0 * std.math.pi / @as(f32, @floatFromInt(len));
        for (0..half) |k| {
            const phase = angle * @as(f32, @floatFromInt(k));
            self.re[k] = @cos(phase);
            self.im[k] = @sin(phase);
        }
    }

    inline fn vectorRe(self: *const LocalTwiddles, _: usize, k: usize) Vec {
        return self.re[k..][0..W].*;
    }
    inline fn vectorIm(self: *const LocalTwiddles, _: usize, k: usize) Vec {
        return self.im[k..][0..W].*;
    }
    inline fn scalarRe(self: *const LocalTwiddles, _: usize, k: usize) f32 {
        return self.re[k];
    }
    inline fn scalarIm(self: *const LocalTwiddles, _: usize, k: usize) f32 {
        return self.im[k];
    }
};

/// Cached source: index the same stage-ordered table prepared by Analyzer.init.
const CachedTwiddles = struct {
    cache: *const TwiddleCache,

    inline fn prepare(_: CachedTwiddles, _: usize) void {}
    inline fn vectorRe(self: CachedTwiddles, base: usize, k: usize) Vec {
        return self.cache.stage_re[base + k ..][0..W].*;
    }
    inline fn vectorIm(self: CachedTwiddles, base: usize, k: usize) Vec {
        return self.cache.stage_im[base + k ..][0..W].*;
    }
    inline fn scalarRe(self: CachedTwiddles, base: usize, k: usize) f32 {
        return self.cache.stage_re[base + k];
    }
    inline fn scalarIm(self: CachedTwiddles, base: usize, k: usize) f32 {
        return self.cache.stage_im[base + k];
    }
};

fn simdStages(re: []f32, im: []f32) void {
    var twiddles = LocalTwiddles{};
    simdStagesWithSource(re, im, &twiddles);
}

fn simdStagesCached(re: []f32, im: []f32, cache: *const TwiddleCache) void {
    simdStagesWithSource(re, im, CachedTwiddles{ .cache = cache });
}

/// Shared SIMD butterfly traversal; only stage-twiddle sourcing differs.
fn simdStagesWithSource(re: []f32, im: []f32, twiddles: anytype) void {
    const n = re.len;
    var len: usize = 2;
    while (len <= n) : (len <<= 1) {
        const half = len / 2;
        const stage_base = half - 1;
        twiddles.prepare(len);

        var i: usize = 0;
        while (i < n) : (i += len) {
            const top = i + half;
            var k: usize = 0;
            while (k + W <= half) : (k += W) {
                const ure: Vec = re[i + k ..][0..W].*;
                const uim: Vec = im[i + k ..][0..W].*;
                const are: Vec = re[top + k ..][0..W].*;
                const aim: Vec = im[top + k ..][0..W].*;
                const wre = twiddles.vectorRe(stage_base, k);
                const wim = twiddles.vectorIm(stage_base, k);
                const vre = are * wre - aim * wim;
                const vim = are * wim + aim * wre;
                re[i + k ..][0..W].* = ure + vre;
                im[i + k ..][0..W].* = uim + vim;
                re[top + k ..][0..W].* = ure - vre;
                im[top + k ..][0..W].* = uim - vim;
            }
            while (k < half) : (k += 1) {
                const u_re = re[i + k];
                const u_im = im[i + k];
                const a_re = re[top + k];
                const a_im = im[top + k];
                const w_re = twiddles.scalarRe(stage_base, k);
                const w_im = twiddles.scalarIm(stage_base, k);
                const v_re = a_re * w_re - a_im * w_im;
                const v_im = a_re * w_im + a_im * w_re;
                re[i + k] = u_re + v_re;
                im[i + k] = u_im + v_im;
                re[top + k] = u_re - v_re;
                im[top + k] = u_im - v_im;
            }
        }
    }
}

test "fft of a pure sine peaks at the expected bin" {
    const n: usize = 256;
    const freq: f32 = 40.0;
    var re: [n]f32 = undefined;
    var im: [n]f32 = undefined;
    for (0..n) |i| {
        re[i] = @sin(2.0 * std.math.pi * freq * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n)));
        im[i] = 0.0;
    }
    fft(&re, &im);

    const peak_bin = @as(usize, @intFromFloat(freq));
    try std.testing.expect(@abs(re[0]) < 0.01 and @abs(im[0]) < 0.01);
    const mag = @sqrt(re[peak_bin] * re[peak_bin] + im[peak_bin] * im[peak_bin]);
    try std.testing.expect(mag > @as(f32, @floatFromInt(n)) * 0.4);
    const mirror_mag = @sqrt(re[n - peak_bin] * re[n - peak_bin] + im[n - peak_bin] * im[n - peak_bin]);
    try std.testing.expect(mirror_mag > @as(f32, @floatFromInt(n)) * 0.4);
}

test "fft of silence is silence" {
    const n: usize = 64;
    var re: [n]f32 = @splat(0);
    var im: [n]f32 = @splat(0);
    fft(&re, &im);
    for (re, im) |r, i| {
        try std.testing.expect(r == 0.0 and i == 0.0);
    }
}

test "cached and uncached SIMD paths agree through the maximum size" {
    const sizes = [_]usize{ 2, 4, 8, 16, 64, 128, 512, 1024, max_simd_n };
    var prng = std.Random.DefaultPrng.init(0xcace);
    const rng = prng.random();
    for (sizes) |n| {
        var cached_re: [max_simd_n]f32 = undefined;
        var cached_im: [max_simd_n]f32 = undefined;
        var plain_re: [max_simd_n]f32 = undefined;
        var plain_im: [max_simd_n]f32 = undefined;
        for (0..n) |i| {
            cached_re[i] = rng.floatNorm(f32);
            cached_im[i] = rng.floatNorm(f32);
            plain_re[i] = cached_re[i];
            plain_im[i] = cached_im[i];
        }

        const cache = TwiddleCache.init(n);
        fftWithCache(cached_re[0..n], cached_im[0..n], &cache);
        fft(plain_re[0..n], plain_im[0..n]);
        try std.testing.expectEqualSlices(f32, plain_re[0..n], cached_re[0..n]);
        try std.testing.expectEqualSlices(f32, plain_im[0..n], cached_im[0..n]);
    }
}

test "SIMD path matches the scalar reference across sizes" {
    // Lock the vectorized kernel against the scalar reference so an optimization
    // regression can't silently corrupt the spectrum. Covers both the vector
    // main loop and the scalar tail / tiny-stage paths.
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const rng = prng.random();
    const sizes = [_]usize{ 2, 4, 8, 16, 64, 128, 512, 1024 };
    for (sizes) |n| {
        var re: [1024]f32 = @splat(0);
        var im: [1024]f32 = @splat(0);
        var ref_re: [1024]f32 = @splat(0);
        var ref_im: [1024]f32 = @splat(0);
        for (0..n) |i| {
            const v = rng.floatNorm(f32);
            re[i] = v;
            im[i] = rng.floatNorm(f32);
            ref_re[i] = v;
            ref_im[i] = im[i];
        }

        fft(re[0..n], im[0..n]);
        // Mirror fft()'s internal order: bit-reverse, then run the scalar stages.
        bitReverse(ref_re[0..n], ref_im[0..n]);
        scalarStages(ref_re[0..n], ref_im[0..n]);

        for (0..n) |i| {
            // SIMD uses directly-evaluated cos/sin twiddles while the scalar
            // reference multiplies them incrementally, so they differ by float
            // rounding (measured ~3e-4 at n=1024). 1e-2 gives ~30x margin while
            // still catching any real algorithm/permutation regression.
            try std.testing.expect(@abs(re[i] - ref_re[i]) < 1e-2);
            try std.testing.expect(@abs(im[i] - ref_im[i]) < 1e-2);
        }
    }
}
