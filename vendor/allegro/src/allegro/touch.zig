const std = @import("std");
const c = @import("c");
const EventSource = @import("events.zig").EventSource;

pub const TouchError = error{ InstallFailed };

pub fn install() !void {
    if (!c.al_install_touch_input()) return TouchError.InstallFailed;
}

pub fn uninstall() void {
    c.al_uninstall_touch_input();
}

pub fn installed() bool {
    return c.al_is_touch_input_installed();
}

pub fn eventSource() EventSource {
    return .{ .source = c.al_get_touch_input_event_source() };
}

/// A single touch point / finger.
pub const TouchState = struct {
    id: i32,
    x: f32,
    y: f32,
    dx: f32,
    dy: f32,
    primary: bool,
};

/// The current set of touch points.
pub const State = struct {
    state: c.ALLEGRO_TOUCH_INPUT_STATE,

    pub fn get() State {
        var s: c.ALLEGRO_TOUCH_INPUT_STATE = undefined;
        c.al_get_touch_input_state(&s);
        return .{ .state = s };
    }

    /// Returns the raw fixed 16-slot touch array. Active touches are tracked
    /// via touch events rather than a polled count in Allegro 5.
    pub fn touches(self: *const State) []const c.ALLEGRO_TOUCH_STATE {
        return &self.state.touches;
    }
};

test "refAllDecls" {
    std.testing.refAllDecls(State);
}
