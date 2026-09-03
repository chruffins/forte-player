const std = @import("std");
const c = @import("c");
const Display = @import("display.zig").Display;
const Timer = @import("timer.zig").Timer;
const Timeout = @import("time.zig").Timeout;

/// The raw Allegro event (a tagged union keyed by `type`).
pub const Event = c.ALLEGRO_EVENT;

/// The different kinds of events that can arrive on an event queue.
pub const EventType = enum(c_int) {
    joystick_axis = c.ALLEGRO_EVENT_JOYSTICK_AXIS,
    joystick_button_down = c.ALLEGRO_EVENT_JOYSTICK_BUTTON_DOWN,
    joystick_button_up = c.ALLEGRO_EVENT_JOYSTICK_BUTTON_UP,
    joystick_configuration = c.ALLEGRO_EVENT_JOYSTICK_CONFIGURATION,

    key_down = c.ALLEGRO_EVENT_KEY_DOWN,
    key_char = c.ALLEGRO_EVENT_KEY_CHAR,
    key_up = c.ALLEGRO_EVENT_KEY_UP,

    mouse_axes = c.ALLEGRO_EVENT_MOUSE_AXES,
    mouse_button_down = c.ALLEGRO_EVENT_MOUSE_BUTTON_DOWN,
    mouse_button_up = c.ALLEGRO_EVENT_MOUSE_BUTTON_UP,
    mouse_enter_display = c.ALLEGRO_EVENT_MOUSE_ENTER_DISPLAY,
    mouse_leave_display = c.ALLEGRO_EVENT_MOUSE_LEAVE_DISPLAY,
    mouse_warped = c.ALLEGRO_EVENT_MOUSE_WARPED,

    timer = c.ALLEGRO_EVENT_TIMER,

    display_expose = c.ALLEGRO_EVENT_DISPLAY_EXPOSE,
    display_resize = c.ALLEGRO_EVENT_DISPLAY_RESIZE,
    display_close = c.ALLEGRO_EVENT_DISPLAY_CLOSE,
    display_lost = c.ALLEGRO_EVENT_DISPLAY_LOST,
    display_found = c.ALLEGRO_EVENT_DISPLAY_FOUND,
    display_switch_in = c.ALLEGRO_EVENT_DISPLAY_SWITCH_IN,
    display_switch_out = c.ALLEGRO_EVENT_DISPLAY_SWITCH_OUT,
    display_orientation = c.ALLEGRO_EVENT_DISPLAY_ORIENTATION,
    display_halt_drawing = c.ALLEGRO_EVENT_DISPLAY_HALT_DRAWING,
    display_resume_drawing = c.ALLEGRO_EVENT_DISPLAY_RESUME_DRAWING,
    display_connected = c.ALLEGRO_EVENT_DISPLAY_CONNECTED,
    display_disconnected = c.ALLEGRO_EVENT_DISPLAY_DISCONNECTED,

    touch_begin = c.ALLEGRO_EVENT_TOUCH_BEGIN,
    touch_end = c.ALLEGRO_EVENT_TOUCH_END,
    touch_move = c.ALLEGRO_EVENT_TOUCH_MOVE,
    touch_cancel = c.ALLEGRO_EVENT_TOUCH_CANCEL,

    drop = c.ALLEGRO_EVENT_DROP,

    audio_stream_fragment = c.ALLEGRO_EVENT_AUDIO_STREAM_FRAGMENT,
    audio_stream_finished = c.ALLEGRO_EVENT_AUDIO_STREAM_FINISHED,

    _,
};

/// A source that can be registered onto an event queue.
pub const EventSource = struct {
    source: *c.ALLEGRO_EVENT_SOURCE,

    /// Attach caller data that is returned verbatim via `getData`.
    pub fn setData(self: *EventSource, data: isize) void {
        c.al_set_event_source_data(self.source, data);
    }

    pub fn getData(self: *EventSource) isize {
        return c.al_get_event_source_data(self.source);
    }
};

pub const EventQueueError = error{ CreateFailed };

pub const EventQueue = struct {
    queue: *c.ALLEGRO_EVENT_QUEUE,

    pub fn create() !EventQueue {
        const q = c.al_create_event_queue() orelse return EventQueueError.CreateFailed;
        return .{ .queue = q };
    }

    pub fn destroy(self: *EventQueue) void {
        c.al_destroy_event_queue(self.queue);
    }

    pub fn registerSource(self: *EventQueue, source: *EventSource) void {
        c.al_register_event_source(self.queue, source.source);
    }

    pub fn unregisterSource(self: *EventQueue, source: *EventSource) void {
        c.al_unregister_event_source(self.queue, source.source);
    }

    pub fn registerDisplay(self: *EventQueue, disp: *Display) void {
        c.al_register_event_source(self.queue, c.al_get_display_event_source(disp.display));
    }

    pub fn unregisterDisplay(self: *EventQueue, disp: *Display) void {
        c.al_unregister_event_source(self.queue, c.al_get_display_event_source(disp.display));
    }

    pub fn registerKeyboard(self: *EventQueue) void {
        c.al_register_event_source(self.queue, c.al_get_keyboard_event_source());
    }

    pub fn registerMouse(self: *EventQueue) void {
        c.al_register_event_source(self.queue, c.al_get_mouse_event_source());
    }

    pub fn registerJoystick(self: *EventQueue) void {
        c.al_register_event_source(self.queue, c.al_get_joystick_event_source());
    }

    pub fn registerTouch(self: *EventQueue) void {
        c.al_register_event_source(self.queue, c.al_get_touch_input_event_source());
    }

    pub fn registerTimer(self: *EventQueue, tmr: *Timer) void {
        c.al_register_event_source(self.queue, c.al_get_timer_event_source(tmr.timer));
    }

    /// Block until an event is available, then write it into `event`.
    pub fn waitForEvent(self: *EventQueue, event: *Event) void {
        c.al_wait_for_event(self.queue, event);
    }

    /// Block up to `seconds`. Returns true if an event was delivered.
    pub fn waitForEventTimed(self: *EventQueue, event: *Event, seconds: f32) bool {
        return c.al_wait_for_event_timed(self.queue, event, seconds);
    }

    /// Return the next event without blocking, if one is available.
    pub fn getNextEvent(self: *EventQueue, event: *Event) bool {
        return c.al_get_next_event(self.queue, event);
    }

    /// Peek at the next event without removing it.
    pub fn peekNextEvent(self: *EventQueue, event: *Event) bool {
        return c.al_peek_next_event(self.queue, event);
    }

    /// Drop the next event from the queue.
    pub fn dropNextEvent(self: *EventQueue) bool {
        return c.al_drop_next_event(self.queue);
    }

    pub fn isEmpty(self: *EventQueue) bool {
        return c.al_is_event_queue_empty(self.queue);
    }

    pub fn flush(self: *EventQueue) void {
        c.al_flush_event_queue(self.queue);
    }

    pub fn isSourceRegistered(self: *EventQueue, source: *EventSource) bool {
        return c.al_is_event_source_registered(self.queue, source.source);
    }

    /// Block until an event is available or the given timeout elapses.
    pub fn waitForEventUntil(self: *EventQueue, event: *Event, timeout: *const Timeout) bool {
        return c.al_wait_for_event_until(self.queue, event, &timeout.timeout);
    }

    pub fn pause(self: *EventQueue, paused: bool) void {
        c.al_pause_event_queue(self.queue, paused);
    }

    pub fn isPaused(self: *EventQueue) bool {
        return c.al_is_event_queue_paused(self.queue);
    }
};

// ---------------------------------------------------------------------------
// Typed accessors
//
// These are the "opinionated" part: each returns an optional struct containing
// just the fields relevant to that kind of event, so callers never poke at the
// raw C unions by hand.
// ---------------------------------------------------------------------------

pub const KeyboardEvent = struct {
    keycode: KeyCode,
    unichar: u32,
    modifiers: u32,
    repeat: bool,
};

pub const MouseEvent = struct {
    x: i32,
    y: i32,
    z: i32,
    w: i32,
    dx: i32,
    dy: i32,
    dz: i32,
    dw: i32,
    button: u32,
    pressure: f32,
};

pub const DisplayEvent = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    orientation: i32,
};

pub const TimerEvent = struct {
    count: i64,
};

pub const TouchEvent = struct {
    id: i32,
    x: f32,
    y: f32,
    dx: f32,
    dy: f32,
    primary: bool,
};

pub const JoystickEvent = struct {
    stick: i32,
    axis: i32,
    pos: f32,
    button: i32,
};

/// The keyboard fields of an event, if it is a key event.
pub fn keyboard(event: Event) ?KeyboardEvent {
    if (!isKeyEvent(@enumFromInt(event.type))) return null;
    return .{
        .keycode = @enumFromInt(event.keyboard.keycode),
        .unichar = @intCast(event.keyboard.unichar),
        .modifiers = event.keyboard.modifiers,
        .repeat = event.keyboard.repeat,
    };
}

pub fn isKeyEvent(t: EventType) bool {
    return switch (t) {
        .key_down, .key_char, .key_up => true,
        else => false,
    };
}

pub fn keycode(event: Event) ?KeyCode {
    if (!isKeyEvent(@enumFromInt(event.type))) return null;
    return @enumFromInt(event.keyboard.keycode);
}

/// The mouse fields of an event, if it is a mouse event.
pub fn mouse(event: Event) ?MouseEvent {
    if (!isMouseEvent(@enumFromInt(event.type))) return null;
    return .{
        .x = event.mouse.x,
        .y = event.mouse.y,
        .z = event.mouse.z,
        .w = event.mouse.w,
        .dx = event.mouse.dx,
        .dy = event.mouse.dy,
        .dz = event.mouse.dz,
        .dw = event.mouse.dw,
        .button = event.mouse.button,
        .pressure = event.mouse.pressure,
    };
}

pub fn isMouseEvent(t: EventType) bool {
    return switch (t) {
        .mouse_axes, .mouse_button_down, .mouse_button_up, .mouse_enter_display, .mouse_leave_display, .mouse_warped => true,
        else => false,
    };
}

pub fn display(event: Event) ?DisplayEvent {
    if (!isDisplayEvent(@enumFromInt(event.type))) return null;
    return .{
        .x = event.display.x,
        .y = event.display.y,
        .width = event.display.width,
        .height = event.display.height,
        .orientation = event.display.orientation,
    };
}

pub fn isDisplayEvent(t: EventType) bool {
    return switch (t) {
        .display_expose, .display_resize, .display_close, .display_lost, .display_found,
        .display_switch_in, .display_switch_out, .display_orientation, .display_halt_drawing,
        .display_resume_drawing, .display_connected, .display_disconnected,
        => true,
        else => false,
    };
}

pub fn timer(event: Event) ?TimerEvent {
    if (event.type != c.ALLEGRO_EVENT_TIMER) return null;
    return .{ .count = event.timer.count };
}

pub fn touch(event: Event) ?TouchEvent {
    if (!isTouchEvent(@enumFromInt(event.type))) return null;
    return .{
        .id = event.touch.id,
        .x = event.touch.x,
        .y = event.touch.y,
        .dx = event.touch.dx,
        .dy = event.touch.dy,
        .primary = event.touch.primary,
    };
}

pub fn isTouchEvent(t: EventType) bool {
    return switch (t) {
        .touch_begin, .touch_end, .touch_move, .touch_cancel => true,
        else => false,
    };
}

pub fn joystick(event: Event) ?JoystickEvent {
    if (event.type != c.ALLEGRO_EVENT_JOYSTICK_AXIS and event.type != c.ALLEGRO_EVENT_JOYSTICK_BUTTON_DOWN and event.type != c.ALLEGRO_EVENT_JOYSTICK_BUTTON_UP) return null;
    return .{
        .stick = event.joystick.stick,
        .axis = event.joystick.axis,
        .pos = event.joystick.pos,
        .button = event.joystick.button,
    };
}

/// True for audio-stream lifecycle events (fragment available / stream finished).
pub fn isAudioStreamEvent(t: EventType) bool {
    return switch (t) {
        .audio_stream_fragment, .audio_stream_finished => true,
        else => false,
    };
}

pub fn eventType(event: Event) EventType {
    return @enumFromInt(event.type);
}

/// Helper matching the ninja example: returns the keycode as a `KeyCode` enum.
pub fn eventKeyboardKeycode(event: Event) KeyCode {
    return keycode(event) orelse .Unknown;
}

pub fn eventTimestamp(event: Event) f64 {
    return event.any.timestamp;
}

pub fn eventSource(event: Event) *c.ALLEGRO_EVENT_SOURCE {
    return event.any.source;
}

// ---------------------------------------------------------------------------
// User event sources
// ---------------------------------------------------------------------------

/// A source of user-defined events that can be registered on a queue.
pub const UserEventSource = struct {
    source: c.ALLEGRO_EVENT_SOURCE,

    pub fn init(self: *UserEventSource) void {
        c.al_init_user_event_source(&self.source);
    }

    pub fn destroy(self: *UserEventSource) void {
        c.al_destroy_user_event_source(&self.source);
    }

    pub fn setData(self: *UserEventSource, data: isize) void {
        c.al_set_event_source_data(&self.source, data);
    }

    pub fn emit(self: *UserEventSource, event: *Event) bool {
        return c.al_emit_user_event(&self.source, event, null);
    }

    /// Build an event carrying the given payload and custom `type` id, to be delivered from this source.
    pub fn makeEvent(self: *UserEventSource, t: c.ALLEGRO_EVENT_TYPE, data1: isize, data2: isize, data3: isize, data4: isize) Event {
        var e = @unionInit(Event, "user", .{ .source = &self.source });
        e.type = t;
        e.user.data1 = data1;
        e.user.data2 = data2;
        e.user.data3 = data3;
        e.user.data4 = data4;
        return e;
    }
};

/// Extract the payload carried by a user event.
pub fn userEventData(event: Event) struct { data1: isize, data2: isize, data3: isize, data4: isize } {
    return .{
        .data1 = event.user.data1,
        .data2 = event.user.data2,
        .data3 = event.user.data3,
        .data4 = event.user.data4,
    };
}

/// Release a user event received from the queue when it carries extra
/// reference-managed data.
pub fn unrefUserEvent(event: *Event) void {
    c.al_unref_user_event(&event.user);
}

// ---------------------------------------------------------------------------
// Keycodes & modifiers
// ---------------------------------------------------------------------------

pub const KeyCode = enum(c_int) {
    A = c.ALLEGRO_KEY_A, B = c.ALLEGRO_KEY_B, C = c.ALLEGRO_KEY_C, D = c.ALLEGRO_KEY_D,
    E = c.ALLEGRO_KEY_E, F = c.ALLEGRO_KEY_F, G = c.ALLEGRO_KEY_G, H = c.ALLEGRO_KEY_H,
    I = c.ALLEGRO_KEY_I, J = c.ALLEGRO_KEY_J, K = c.ALLEGRO_KEY_K, L = c.ALLEGRO_KEY_L,
    M = c.ALLEGRO_KEY_M, N = c.ALLEGRO_KEY_N, O = c.ALLEGRO_KEY_O, P = c.ALLEGRO_KEY_P,
    Q = c.ALLEGRO_KEY_Q, R = c.ALLEGRO_KEY_R, S = c.ALLEGRO_KEY_S, T = c.ALLEGRO_KEY_T,
    U = c.ALLEGRO_KEY_U, V = c.ALLEGRO_KEY_V, W = c.ALLEGRO_KEY_W, X = c.ALLEGRO_KEY_X,
    Y = c.ALLEGRO_KEY_Y, Z = c.ALLEGRO_KEY_Z,

    Num0 = c.ALLEGRO_KEY_0, Num1 = c.ALLEGRO_KEY_1, Num2 = c.ALLEGRO_KEY_2, Num3 = c.ALLEGRO_KEY_3,
    Num4 = c.ALLEGRO_KEY_4, Num5 = c.ALLEGRO_KEY_5, Num6 = c.ALLEGRO_KEY_6, Num7 = c.ALLEGRO_KEY_7,
    Num8 = c.ALLEGRO_KEY_8, Num9 = c.ALLEGRO_KEY_9,

    Pad0 = c.ALLEGRO_KEY_PAD_0, Pad1 = c.ALLEGRO_KEY_PAD_1, Pad2 = c.ALLEGRO_KEY_PAD_2,
    Pad3 = c.ALLEGRO_KEY_PAD_3, Pad4 = c.ALLEGRO_KEY_PAD_4, Pad5 = c.ALLEGRO_KEY_PAD_5,
    Pad6 = c.ALLEGRO_KEY_PAD_6, Pad7 = c.ALLEGRO_KEY_PAD_7, Pad8 = c.ALLEGRO_KEY_PAD_8,
    Pad9 = c.ALLEGRO_KEY_PAD_9,

    F1 = c.ALLEGRO_KEY_F1, F2 = c.ALLEGRO_KEY_F2, F3 = c.ALLEGRO_KEY_F3, F4 = c.ALLEGRO_KEY_F4,
    F5 = c.ALLEGRO_KEY_F5, F6 = c.ALLEGRO_KEY_F6, F7 = c.ALLEGRO_KEY_F7, F8 = c.ALLEGRO_KEY_F8,
    F9 = c.ALLEGRO_KEY_F9, F10 = c.ALLEGRO_KEY_F10, F11 = c.ALLEGRO_KEY_F11, F12 = c.ALLEGRO_KEY_F12,

    Escape = c.ALLEGRO_KEY_ESCAPE, Tilde = c.ALLEGRO_KEY_TILDE, Minus = c.ALLEGRO_KEY_MINUS,
    Equals = c.ALLEGRO_KEY_EQUALS, Backspace = c.ALLEGRO_KEY_BACKSPACE, Tab = c.ALLEGRO_KEY_TAB,
    OpenBrace = c.ALLEGRO_KEY_OPENBRACE, CloseBrace = c.ALLEGRO_KEY_CLOSEBRACE, Enter = c.ALLEGRO_KEY_ENTER,
    Semicolon = c.ALLEGRO_KEY_SEMICOLON, Quote = c.ALLEGRO_KEY_QUOTE, Backslash = c.ALLEGRO_KEY_BACKSLASH,
    Backslash2 = c.ALLEGRO_KEY_BACKSLASH2, Comma = c.ALLEGRO_KEY_COMMA, Fullstop = c.ALLEGRO_KEY_FULLSTOP,
    Slash = c.ALLEGRO_KEY_SLASH, Space = c.ALLEGRO_KEY_SPACE,

    Insert = c.ALLEGRO_KEY_INSERT, Delete = c.ALLEGRO_KEY_DELETE, Home = c.ALLEGRO_KEY_HOME,
    End = c.ALLEGRO_KEY_END, PgUp = c.ALLEGRO_KEY_PGUP, PgDn = c.ALLEGRO_KEY_PGDN,
    Left = c.ALLEGRO_KEY_LEFT, Right = c.ALLEGRO_KEY_RIGHT, Up = c.ALLEGRO_KEY_UP, Down = c.ALLEGRO_KEY_DOWN,

    PadSlash = c.ALLEGRO_KEY_PAD_SLASH, PadAsterisk = c.ALLEGRO_KEY_PAD_ASTERISK,
    PadMinus = c.ALLEGRO_KEY_PAD_MINUS, PadPlus = c.ALLEGRO_KEY_PAD_PLUS,
    PadDelete = c.ALLEGRO_KEY_PAD_DELETE, PadEnter = c.ALLEGRO_KEY_PAD_ENTER,

    PrintScreen = c.ALLEGRO_KEY_PRINTSCREEN, Pause = c.ALLEGRO_KEY_PAUSE,
    Abnt_C1 = c.ALLEGRO_KEY_ABNT_C1, Yen = c.ALLEGRO_KEY_YEN, Kana = c.ALLEGRO_KEY_KANA,
    Convert = c.ALLEGRO_KEY_CONVERT, NoConvert = c.ALLEGRO_KEY_NOCONVERT, At = c.ALLEGRO_KEY_AT,
    Circumflex = c.ALLEGRO_KEY_CIRCUMFLEX, Colon2 = c.ALLEGRO_KEY_COLON2, Kanji = c.ALLEGRO_KEY_KANJI,
    PadEquals = c.ALLEGRO_KEY_PAD_EQUALS, Backquote = c.ALLEGRO_KEY_BACKQUOTE,
    Semicolon2 = c.ALLEGRO_KEY_SEMICOLON2, Command = c.ALLEGRO_KEY_COMMAND,

    Back = c.ALLEGRO_KEY_BACK, VolumeUp = c.ALLEGRO_KEY_VOLUME_UP, VolumeDown = c.ALLEGRO_KEY_VOLUME_DOWN,
    Search = c.ALLEGRO_KEY_SEARCH, DpadCenter = c.ALLEGRO_KEY_DPAD_CENTER,
    ButtonX = c.ALLEGRO_KEY_BUTTON_X, ButtonY = c.ALLEGRO_KEY_BUTTON_Y,
    DpadUp = c.ALLEGRO_KEY_DPAD_UP, DpadDown = c.ALLEGRO_KEY_DPAD_DOWN,
    DpadLeft = c.ALLEGRO_KEY_DPAD_LEFT, DpadRight = c.ALLEGRO_KEY_DPAD_RIGHT,
    Select = c.ALLEGRO_KEY_SELECT, Start = c.ALLEGRO_KEY_START,
    ButtonL1 = c.ALLEGRO_KEY_BUTTON_L1, ButtonR1 = c.ALLEGRO_KEY_BUTTON_R1,
    ButtonL2 = c.ALLEGRO_KEY_BUTTON_L2, ButtonR2 = c.ALLEGRO_KEY_BUTTON_R2,
    ButtonA = c.ALLEGRO_KEY_BUTTON_A, ButtonB = c.ALLEGRO_KEY_BUTTON_B,
    Thumbl = c.ALLEGRO_KEY_THUMBL, Thumbr = c.ALLEGRO_KEY_THUMBR,

    Unknown = c.ALLEGRO_KEY_UNKNOWN,

    LShift = c.ALLEGRO_KEY_LSHIFT, RShift = c.ALLEGRO_KEY_RSHIFT,
    LCtrl = c.ALLEGRO_KEY_LCTRL, RCtrl = c.ALLEGRO_KEY_RCTRL,
    Alt = c.ALLEGRO_KEY_ALT, AltGr = c.ALLEGRO_KEY_ALTGR,
    LWin = c.ALLEGRO_KEY_LWIN, RWin = c.ALLEGRO_KEY_RWIN, Menu = c.ALLEGRO_KEY_MENU,
    ScrollLock = c.ALLEGRO_KEY_SCROLLLOCK, NumLock = c.ALLEGRO_KEY_NUMLOCK,
    CapsLock = c.ALLEGRO_KEY_CAPSLOCK, Max = c.ALLEGRO_KEY_MAX,

    pub fn name(self: KeyCode) [:0]const u8 {
        return std.mem.span(c.al_keycode_to_name(@intFromEnum(self)));
    }
};

pub const KeyMod = struct {
    pub const SHIFT = c.ALLEGRO_KEYMOD_SHIFT;
    pub const CTRL = c.ALLEGRO_KEYMOD_CTRL;
    pub const ALT = c.ALLEGRO_KEYMOD_ALT;
    pub const LWIN = c.ALLEGRO_KEYMOD_LWIN;
    pub const RWIN = c.ALLEGRO_KEYMOD_RWIN;
    pub const MENU = c.ALLEGRO_KEYMOD_MENU;
    pub const ALTGR = c.ALLEGRO_KEYMOD_ALTGR;
    pub const COMMAND = c.ALLEGRO_KEYMOD_COMMAND;
    pub const SCROLLLOCK = c.ALLEGRO_KEYMOD_SCROLLLOCK;
    pub const NUMLOCK = c.ALLEGRO_KEYMOD_NUMLOCK;
    pub const CAPSLOCK = c.ALLEGRO_KEYMOD_CAPSLOCK;
    pub const INALTSEQ = c.ALLEGRO_KEYMOD_INALTSEQ;
    pub const ACCENT1 = c.ALLEGRO_KEYMOD_ACCENT1;
    pub const ACCENT2 = c.ALLEGRO_KEYMOD_ACCENT2;
    pub const ACCENT3 = c.ALLEGRO_KEYMOD_ACCENT3;
    pub const ACCENT4 = c.ALLEGRO_KEYMOD_ACCENT4;

    /// True if any modifier flags are set.
    pub fn isNone(mods: u32) bool {
        return mods & (SHIFT | CTRL | ALT | LWIN | RWIN | MENU | ALTGR | COMMAND | INALTSEQ) == 0;
    }
};

test "refAllDecls" {
    std.testing.refAllDecls(EventQueue);
    std.testing.refAllDecls(KeyCode);
}
