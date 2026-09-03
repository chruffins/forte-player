const std = @import("std");
const c = @import("c");
const KeyCode = @import("events.zig").KeyCode;
const EventSource = @import("events.zig").EventSource;

pub const KeyboardError = error{ InstallFailed };

pub fn install() !void {
    if (!c.al_install_keyboard()) return KeyboardError.InstallFailed;
}

pub fn uninstall() void {
    c.al_uninstall_keyboard();
}

pub fn installed() bool {
    return c.al_is_keyboard_installed();
}

pub fn eventSource() EventSource {
    return .{ .source = c.al_get_keyboard_event_source() };
}

/// The set of currently held-down keys.
pub const State = struct {
    state: c.ALLEGRO_KEYBOARD_STATE,

    pub fn get() State {
        var s: c.ALLEGRO_KEYBOARD_STATE = undefined;
        c.al_get_keyboard_state(&s);
        return .{ .state = s };
    }

    pub fn isDown(self: *const State, key: KeyCode) bool {
        return c.al_key_down(&self.state, @intFromEnum(key));
    }
};

pub fn keyDown(key: KeyCode) bool {
    var s: c.ALLEGRO_KEYBOARD_STATE = undefined;
    c.al_get_keyboard_state(&s);
    return c.al_key_down(&s, @intFromEnum(key));
}

pub fn setLeds(leds: i32) bool {
    return c.al_set_keyboard_leds(leds);
}

pub fn canSetLeds(leds: i32) bool {
    return c.al_can_set_keyboard_leds(leds);
}

test "refAllDecls" {
    std.testing.refAllDecls(State);
}
