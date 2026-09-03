const std = @import("std");
const c = @import("c");

// ---- Shared value types (re-exported flat) ----
pub const Vec2 = @import("allegro/vec.zig").Vec2;
pub const Vec3 = @import("allegro/vec.zig").Vec3;
pub const Vec4 = @import("allegro/vec.zig").Vec4;
pub const Color = @import("allegro/color.zig").Color;
pub const Transform = @import("allegro/transform.zig").Transform;

// ---- Core system & management namespaces ----
pub const system = @import("allegro/system.zig");
pub const display = @import("allegro/display.zig");
pub const monitor = @import("allegro/monitor.zig");
pub const events = @import("allegro/events.zig");
pub const keyboard = @import("allegro/keyboard.zig");
pub const mouse = @import("allegro/mouse.zig");
pub const joystick = @import("allegro/joystick.zig");
pub const touch = @import("allegro/touch.zig");
pub const timer = @import("allegro/timer.zig");
pub const time = @import("allegro/time.zig");
pub const threads = @import("allegro/threads.zig");

// ---- Graphics ----
pub const graphics = @import("allegro/graphics.zig");
pub const primitives = @import("allegro/primitives.zig");
pub const shader = @import("allegro/shader.zig");

// ---- Data / I/O ----
pub const file = @import("allegro/file.zig");
pub const memory = @import("allegro/memory.zig");
pub const path = @import("allegro/path.zig");
pub const config = @import("allegro/config.zig");
pub const utf8 = @import("allegro/utf8.zig");
pub const filesystem = @import("allegro/filesystem.zig");

// ---- Math / misc / UI ----
pub const fixed = @import("allegro/fixed.zig");
pub const misc = @import("allegro/misc.zig");
pub const menu = @import("allegro/menu.zig");

// ---- Convenience flat re-exports (match the ninja usage style) ----
pub const Display = display.Display;
pub const DisplayFlags = display.DisplayFlags;
pub const DisplayOptions = display.DisplayOptions;
pub const Event = events.Event;
pub const EventType = events.EventType;
pub const EventQueue = events.EventQueue;
pub const EventSource = events.EventSource;
pub const KeyCode = events.KeyCode;
pub const KeyMod = events.KeyMod;
pub const Timer = timer.Timer;
pub const Bitmap = graphics.Bitmap;
pub const Font = @import("allegro/font.zig").Font;

// ---- Convenience functions (flat, matching ninja examples) ----

pub fn init() !void {
    try system.init();
}

pub fn installKeyboard() !void {
    try keyboard.install();
}

pub fn installMouse() !void {
    try mouse.install();
}

pub fn installJoystick() !void {
    try joystick.install();
}

pub fn initPrimitivesAddon() !void {
    try primitives.init();
}

pub fn initFontAddon() !void {
    try font.init();
}

pub fn initTtfAddon() !void {
    try ttf.init();
}

pub fn eventType(event: Event) EventType {
    return events.eventType(event);
}

pub fn eventKeyboardKeycode(event: Event) KeyCode {
    return events.eventKeyboardKeycode(event);
}

pub fn eventKeyboard(event: Event) ?events.KeyboardEvent {
    return events.keyboard(event);
}

pub fn eventMouse(event: Event) ?events.MouseEvent {
    return events.mouse(event);
}

pub fn eventDisplay(event: Event) ?events.DisplayEvent {
    return events.display(event);
}

pub fn eventTimer(event: Event) ?events.TimerEvent {
    return events.timer(event);
}

// ---- Populated by the media addon modules ----
pub const font = @import("allegro/font.zig");
pub const ttf = @import("allegro/ttf.zig");
pub const image = @import("allegro/image.zig");
pub const audio = @import("allegro/audio.zig");
pub const acodec = @import("allegro/acodec.zig");
pub const video = @import("allegro/video.zig");
pub const dialog = @import("allegro/dialog.zig");
