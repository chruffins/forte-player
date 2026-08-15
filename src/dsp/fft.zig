//! Iterative radix-2 Cooley–Tukey FFT for real input.
//!
//! Pure math, no allocation, in-place on `re`/`im` (both length `n`, a power
//! of two). Used by the TUI spectrum to turn recent mono samples into
//! frequency magnitudes. Tested headlessly.

const std = @import("std");

/// In-place FFT. `re`/`im` hold the real/imaginary parts; on return they hold
/// the complex spectrum (DC + positive frequencies, then negative mirrored).
pub fn fft(re: []f32, im: []f32) void {
    const n = re.len;
    std.debug.assert(n == im.len);
    std.debug.assert(n >= 2 and (n & (n - 1)) == 0); // power of two

    // Bit-reversal permutation.
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

    // Butterfly stages.
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

    // The bin for a frequency f (integer cycles over the window) is f itself.
    const peak_bin = @as(usize, @intFromFloat(freq));
    // DC bin should be ~0 for a full-cycle sine.
    try std.testing.expect(@abs(re[0]) < 0.01 and @abs(im[0]) < 0.01);
    // Peak at bin `freq`, mirrored at n-freq.
    const mag = @sqrt(re[peak_bin] * re[peak_bin] + im[peak_bin] * im[peak_bin]);
    try std.testing.expect(mag > @as(f32, @floatFromInt(n)) * 0.4); // n/2 amplitude for a full-scale sine
    const mirror_mag = @sqrt(re[n - peak_bin] * re[n - peak_bin] + im[n - peak_bin] * im[n - peak_bin]);
    try std.testing.expect(mirror_mag > @as(f32, @floatFromInt(n)) * 0.4);
}

test "fft of silence is silence" {
    const n: usize = 64;
    var re: [n]f32 = [_]f32{0} ** n;
    var im: [n]f32 = [_]f32{0} ** n;
    fft(&re, &im);
    for (re, im) |r, i| {
        try std.testing.expect(r == 0.0 and i == 0.0);
    }
}
