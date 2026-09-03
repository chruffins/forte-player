const std = @import("std");
const c = @import("c");

/// A 16.16 fixed point number.
pub const Fixed = c.al_fixed;

pub const ONE: Fixed = 1 << 16;
pub const HALF: Fixed = 1 << 15;

/// Convert an integer to fixed point.
pub fn fromInt(x: i32) Fixed {
    return x << 16;
}

/// Convert fixed point to the nearest integer.
pub fn toInt(x: Fixed) i32 {
    return (x + HALF) >> 16;
}

/// Convert fixed point to a rounded-down integer (floor).
pub fn floor(x: Fixed) i32 {
    return x >> 16;
}

pub fn ceil(x: Fixed) i32 {
    const fx = x + (ONE - 1);
    return fx >> 16;
}

pub fn toFloat(x: Fixed) f32 {
    return @as(f32, @floatFromInt(x)) / 65536.0;
}

pub fn fromFloat(x: f32) Fixed {
    return @as(Fixed, @intFromFloat(x * 65536.0));
}

pub fn add(a: Fixed, b: Fixed) Fixed {
    return a + b;
}

pub fn sub(a: Fixed, b: Fixed) Fixed {
    return a - b;
}

/// Fixed-point multiplication (16.16 * 16.16 -> 16.16).
pub fn mul(a: Fixed, b: Fixed) Fixed {
    return @intCast((@as(i64, a) * @as(i64, b)) >> 16);
}

/// Fixed-point division.
pub fn div(a: Fixed, b: Fixed) Fixed {
    return @intCast((@as(i64, a) << 16) / @as(i64, b));
}

/// Multiply by a fixed constant then divide by another (avoids overflow).
pub fn muldiv(a: Fixed, b: Fixed, c_: Fixed) Fixed {
    return @intCast((@as(i64, a) * @as(i64, b)) / @as(i64, c_));
}

pub fn sqrt(x: Fixed) Fixed {
    return c.al_fixsqrt(x);
}

pub fn hypot(x: Fixed, y: Fixed) Fixed {
    return c.al_fixhypot(x, y);
}

pub fn atan(x: Fixed) Fixed {
    return c.al_fixatan(x);
}

pub fn atan2(y: Fixed, x: Fixed) Fixed {
    return c.al_fixatan2(y, x);
}

test "refAllDecls" {
    std.testing.refAllDecls(@This());
}
