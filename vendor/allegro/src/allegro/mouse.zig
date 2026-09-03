const std = @import("std");
const c = @import("c");
const EventSource = @import("events.zig").EventSource;
const Display = @import("display.zig").Display;

pub const MouseError = error{ InstallFailed };

pub fn install() !void {
    if (!c.al_install_mouse()) return MouseError.InstallFailed;
}

pub fn uninstall() void {
    c.al_uninstall_mouse();
}

pub fn installed() bool {
    return c.al_is_mouse_installed();
}

pub fn eventSource() EventSource {
    return .{ .source = c.al_get_mouse_event_source() };
}

pub const Button = enum(c_int) {
    Left = 1,
    Right = 2,
    Middle = 3,
    _,
};

/// Snapshot of the mouse position, wheel and buttons.
pub const State = struct {
    state: c.ALLEGRO_MOUSE_STATE,

    pub fn get() State {
        var s: c.ALLEGRO_MOUSE_STATE = undefined;
        c.al_get_mouse_state(&s);
        return .{ .state = s };
    }

    pub fn x(self: *const State) i32 {
        return self.state.x;
    }

    pub fn y(self: *const State) i32 {
        return self.state.y;
    }

    pub fn z(self: *const State) i32 {
        return self.state.z;
    }

    pub fn w(self: *const State) i32 {
        return self.state.w;
    }

    pub fn pressure(self: *const State) f32 {
        return self.state.pressure;
    }

    pub fn axis(self: *const State, axisIdx: i32) i32 {
        return c.al_get_mouse_state_axis(&self.state, axisIdx);
    }

    pub fn buttonDown(self: *const State, button: i32) bool {
        return c.al_mouse_button_down(&self.state, button);
    }

    pub fn isButtonDown(button: i32) bool {
        var s: c.ALLEGRO_MOUSE_STATE = undefined;
        c.al_get_mouse_state(&s);
        return c.al_mouse_button_down(&s, button);
    }
};

pub fn numAxes() u32 {
    return c.al_get_mouse_num_axes();
}

pub fn numButtons() u32 {
    return c.al_get_mouse_num_buttons();
}

pub fn setXY(display: *Display, x: i32, y: i32) bool {
    return c.al_set_mouse_xy(display.display, x, y);
}

pub fn setZ(z: i32) bool {
    return c.al_set_mouse_z(z);
}

pub fn setW(w: i32) bool {
    return c.al_set_mouse_w(w);
}

pub fn setAxis(axis: i32, value: i32) bool {
    return c.al_set_mouse_axis(axis, value);
}

pub fn getCursorPosition(x: *i32, y: *i32) bool {
    return c.al_get_mouse_cursor_position(x, y);
}

pub fn canGetCursorPosition() bool {
    return c.al_can_get_mouse_cursor_position();
}

pub fn setWheelPrecision(p: i32) void {
    c.al_set_mouse_wheel_precision(p);
}

pub fn getWheelPrecision() i32 {
    return c.al_get_mouse_wheel_precision();
}

pub fn grab(display: *Display) bool {
    return c.al_grab_mouse(display.display);
}

pub fn ungrab() bool {
    return c.al_ungrab_mouse();
}

/// A custom mouse cursor.
pub const Cursor = struct {
    cursor: *c.ALLEGRO_MOUSE_CURSOR,

    pub fn create(sprite: *c.ALLEGRO_BITMAP, xfocus: i32, yfocus: i32) !Cursor {
        const cur = c.al_create_mouse_cursor(sprite, xfocus, yfocus) orelse return error.CreateFailed;
        return .{ .cursor = cur };
    }

    pub fn destroy(self: *Cursor) void {
        c.al_destroy_mouse_cursor(self.cursor);
    }
};

pub fn setCursor(display: *Display, cursor: ?*Cursor) bool {
    if (cursor) |cur| {
        return c.al_set_mouse_cursor(display.display, cur.cursor);
    } else {
        return c.al_set_mouse_cursor(display.display, null);
    }
}

pub fn showCursor(display: *Display) bool {
    return c.al_show_mouse_cursor(display.display);
}

pub fn hideCursor(display: *Display) bool {
    return c.al_hide_mouse_cursor(display.display);
}

test "refAllDecls" {
    std.testing.refAllDecls(State);
    std.testing.refAllDecls(Cursor);
}
