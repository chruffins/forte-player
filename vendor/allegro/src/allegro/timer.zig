const std = @import("std");
const c = @import("c");
const EventSource = @import("events.zig").EventSource;

pub const TimerError = error{ CreateFailed };

/// A countdown timer that emits events on the main event queue.
pub const Timer = struct {
    timer: *c.ALLEGRO_TIMER,

    pub fn create(intervalSecs: f64) !Timer {
        const t = c.al_create_timer(intervalSecs) orelse return TimerError.CreateFailed;
        return .{ .timer = t };
    }

    pub fn destroy(self: *Timer) void {
        c.al_destroy_timer(self.timer);
    }

    pub fn start(self: *Timer) void {
        c.al_start_timer(self.timer);
    }

    pub fn stop(self: *Timer) void {
        c.al_stop_timer(self.timer);
    }

    pub fn @"resume"(self: *Timer) void {
        c.al_resume_timer(self.timer);
    }

    pub fn isStarted(self: *Timer) bool {
        return c.al_get_timer_started(self.timer);
    }

    pub fn getSpeed(self: *Timer) f64 {
        return c.al_get_timer_speed(self.timer);
    }

    pub fn setSpeed(self: *Timer, seconds: f64) void {
        c.al_set_timer_speed(self.timer, seconds);
    }

    pub fn getCount(self: *Timer) i64 {
        return c.al_get_timer_count(self.timer);
    }

    pub fn setCount(self: *Timer, count: i64) void {
        c.al_set_timer_count(self.timer, count);
    }

    pub fn addCount(self: *Timer, diff: i64) void {
        c.al_add_timer_count(self.timer, diff);
    }

    pub fn eventSource(self: *Timer) EventSource {
        return .{ .source = c.al_get_timer_event_source(self.timer) };
    }
};

test "refAllDecls" {
    std.testing.refAllDecls(Timer);
}
