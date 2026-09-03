const std = @import("std");
const c = @import("c");
const EventSource = @import("events.zig").EventSource;

pub const JoystickError = error{ InstallFailed };

pub fn install() !void {
    if (!c.al_install_joystick()) return JoystickError.InstallFailed;
}

pub fn uninstall() void {
    c.al_uninstall_joystick();
}

pub fn installed() bool {
    return c.al_is_joystick_installed();
}

pub fn eventSource() EventSource {
    return .{ .source = c.al_get_joystick_event_source() };
}

pub fn reconfigure() bool {
    return c.al_reconfigure_joysticks();
}

pub fn numJoysticks() i32 {
    return c.al_get_num_joysticks();
}

/// A connected joystick/gamepad.
pub const Joystick = struct {
    joy: *c.ALLEGRO_JOYSTICK,

    /// Fetch the joystick at `index`.
    pub fn get(index: i32) ?Joystick {
        const j = c.al_get_joystick(index);
        return if (j) |ptr| Joystick{ .joy = ptr } else null;
    }

    pub fn release(self: *Joystick) void {
        c.al_release_joystick(self.joy);
    }

    pub fn active(self: *Joystick) bool {
        return c.al_get_joystick_active(self.joy);
    }

    pub fn name(self: *Joystick) [:0]const u8 {
        return std.mem.span(c.al_get_joystick_name(self.joy));
    }

    pub fn numSticks(self: *Joystick) i32 {
        return c.al_get_joystick_num_sticks(self.joy);
    }

    pub fn stickFlags(self: *Joystick, stick: i32) i32 {
        return c.al_get_joystick_stick_flags(self.joy, stick);
    }

    pub fn stickName(self: *Joystick, stick: i32) [:0]const u8 {
        return std.mem.span(c.al_get_joystick_stick_name(self.joy, stick));
    }

    pub fn numAxes(self: *Joystick, stick: i32) i32 {
        return c.al_get_joystick_num_axes(self.joy, stick);
    }

    pub fn axisName(self: *Joystick, stick: i32, axis: i32) [:0]const u8 {
        return std.mem.span(c.al_get_joystick_axis_name(self.joy, stick, axis));
    }

    pub fn numButtons(self: *Joystick) i32 {
        return c.al_get_joystick_num_buttons(self.joy);
    }

    pub fn buttonName(self: *Joystick, button: i32) [:0]const u8 {
        return std.mem.span(c.al_get_joystick_button_name(self.joy, button));
    }

    /// Returns the current state (axis positions + button states).
    pub fn state(self: *Joystick) State {
        var s: c.ALLEGRO_JOYSTICK_STATE = undefined;
        c.al_get_joystick_state(self.joy, &s);
        return .{ .state = s };
    }
};

/// Snapshot of a joystick's axes and buttons.
pub const State = struct {
    state: c.ALLEGRO_JOYSTICK_STATE,

    pub fn axisPosition(self: *const State, stick: i32, axis: i32) f32 {
        return self.state.stick[@intCast(stick)].axis[@intCast(axis)];
    }

    pub fn buttonDown(self: *const State, button: i32) bool {
        if (button < 0 or button >= 32) return false;
        return self.state.button[@intCast(button)] != 0;
    }
};

test "refAllDecls" {
    std.testing.refAllDecls(Joystick);
    std.testing.refAllDecls(State);
}
