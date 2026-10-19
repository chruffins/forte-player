//! ReplayGain conversion and peak-safe effective stream multiplier.
//! Missing/invalid measurements deliberately produce unity gain.
const std = @import("std");

pub const Policy = enum { track, album };
pub const Measurement = struct {
    track_gain_db: ?f64 = null,
    track_peak: ?f64 = null,
    album_gain_db: ?f64 = null,
    album_peak: ?f64 = null,
};

pub fn dbToLinear(db: ?f64) f32 {
    const value = db orelse return 1.0;
    if (!std.math.isFinite(value) or value < -60.0 or value > 60.0) return 1.0;
    return @floatCast(std.math.pow(f64, 10.0, value / 20.0));
}

/// Return the linear stream multiplier before master volume. A known peak
/// always bounds the output amplitude to `peak_limit`; absent tags use unity.
pub fn effectiveGain(measurement: Measurement, enabled: bool, policy: Policy, peak_limit: f64) f32 {
    if (!enabled) return 1.0;
    const db = switch (policy) {
        .track => measurement.track_gain_db,
        .album => measurement.album_gain_db,
    };
    const peak = switch (policy) {
        .track => measurement.track_peak,
        .album => measurement.album_peak,
    };
    var gain: f64 = dbToLinear(db);
    if (peak) |p| {
        if (std.math.isFinite(p) and p > 0 and std.math.isFinite(peak_limit) and peak_limit > 0) {
            gain = @min(gain, peak_limit / p);
        }
    }
    if (!std.math.isFinite(gain) or gain < 0) return 1.0;
    return @floatCast(@min(gain, 16.0));
}

test "ReplayGain dB converts to linear amplitude and rejects absent or invalid values" {
    try std.testing.expectApproxEqAbs(@as(f32, 1), dbToLinear(null), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 2), dbToLinear(6.0205999), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1), dbToLinear(std.math.nan(f64)), 0.0001);
}

test "peak protection caps boosts and missing measurements remain unity" {
    const m = Measurement{ .track_gain_db = 6.0, .track_peak = 0.8 };
    const gain = effectiveGain(m, true, .track, 0.95);
    try std.testing.expect(gain < 1.19 and gain > 1.18);
    try std.testing.expectEqual(@as(f32, 1), effectiveGain(.{}, true, .track, 0.95));
    try std.testing.expectEqual(@as(f32, 1), effectiveGain(m, false, .track, 0.95));
}

test "album policy uses album gain and peak metadata" {
    const m = Measurement{ .track_gain_db = -6, .track_peak = 0.5, .album_gain_db = 3, .album_peak = 1.0 };
    try std.testing.expectApproxEqAbs(@as(f32, 1.4125), effectiveGain(m, true, .album, 1.5), 0.001);
}
