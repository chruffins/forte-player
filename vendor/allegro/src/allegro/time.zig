const std = @import("std");
const c = @import("c");

/// Timeouts are used by wait operations (event queues, threads, semaphores).
pub const Timeout = struct {
    timeout: c.ALLEGRO_TIMEOUT,

    pub fn init(seconds: f64) Timeout {
        var t: c.ALLEGRO_TIMEOUT = undefined;
        c.al_init_timeout(&t, seconds);
        return .{ .timeout = t };
    }
};

/// Number of seconds since some fixed point in the past (used to time animations
/// and measure frame deltas). Under all supported systems this is monotonic.
pub fn getTime() f64 {
    return c.al_get_time();
}

test "refAllDecls" {
    std.testing.refAllDecls(Timeout);
}
