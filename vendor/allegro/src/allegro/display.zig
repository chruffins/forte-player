const std = @import("std");
const c = @import("c");
const Color = @import("color.zig").Color;
const EventSource = @import("events.zig").EventSource;

pub const DisplayError = error{ CreateFailed };

/// Window / display configuration flags (bitwise OR).
pub const DisplayFlags = struct {
    pub const WINDOWED = c.ALLEGRO_WINDOWED;
    pub const FULLSCREEN = c.ALLEGRO_FULLSCREEN;
    pub const OPENGL = c.ALLEGRO_OPENGL;
    pub const RESIZABLE = c.ALLEGRO_RESIZABLE;
    pub const FRAMELESS = c.ALLEGRO_FRAMELESS; // == NOFRAME
    pub const NOFRAME = c.ALLEGRO_NOFRAME;
    pub const OPENGL_3_0 = c.ALLEGRO_OPENGL_3_0;
    pub const OPENGL_FORWARD_COMPATIBLE = c.ALLEGRO_OPENGL_FORWARD_COMPATIBLE;
    pub const FULLSCREEN_WINDOW = c.ALLEGRO_FULLSCREEN_WINDOW;
    pub const PROGRAMMABLE_PIPELINE = c.ALLEGRO_PROGRAMMABLE_PIPELINE;
    pub const MAXIMIZED = c.ALLEGRO_MAXIMIZED;
    pub const OPENGL_ES_PROFILE = c.ALLEGRO_OPENGL_ES_PROFILE;
};

pub const DisplayOptions = struct {
    pub const RED_SIZE = c.ALLEGRO_RED_SIZE;
    pub const GREEN_SIZE = c.ALLEGRO_GREEN_SIZE;
    pub const BLUE_SIZE = c.ALLEGRO_BLUE_SIZE;
    pub const ALPHA_SIZE = c.ALLEGRO_ALPHA_SIZE;
    pub const RED_SHIFT = c.ALLEGRO_RED_SHIFT;
    pub const GREEN_SHIFT = c.ALLEGRO_GREEN_SHIFT;
    pub const BLUE_SHIFT = c.ALLEGRO_BLUE_SHIFT;
    pub const ALPHA_SHIFT = c.ALLEGRO_ALPHA_SHIFT;
    pub const ACCUM_RED_SIZE = c.ALLEGRO_ACCUM_RED_SIZE;
    pub const ACCUM_GREEN_SIZE = c.ALLEGRO_ACCUM_GREEN_SIZE;
    pub const ACCUM_BLUE_SIZE = c.ALLEGRO_ACCUM_BLUE_SIZE;
    pub const ACCUM_ALPHA_SIZE = c.ALLEGRO_ACCUM_ALPHA_SIZE;
    pub const STEREO = c.ALLEGRO_STEREO;
    pub const AUX_BUFFERS = c.ALLEGRO_AUX_BUFFERS;
    pub const COLOR_SIZE = c.ALLEGRO_COLOR_SIZE;
    pub const DEPTH_SIZE = c.ALLEGRO_DEPTH_SIZE;
    pub const STENCIL_SIZE = c.ALLEGRO_STENCIL_SIZE;
    pub const SAMPLE_BUFFERS = c.ALLEGRO_SAMPLE_BUFFERS;
    pub const SAMPLES = c.ALLEGRO_SAMPLES;
    pub const RENDER_METHOD = c.ALLEGRO_RENDER_METHOD;
    pub const FLOAT_COLOR = c.ALLEGRO_FLOAT_COLOR;
    pub const FLOAT_DEPTH = c.ALLEGRO_FLOAT_DEPTH;
    pub const FLOAT_STENCIL = c.ALLEGRO_FLOAT_STENCIL;
    pub const SUPPORTED_ORIENTATIONS = c.ALLEGRO_SUPPORTED_ORIENTATIONS;
    pub const OPENGL_MAJOR_VERSION = c.ALLEGRO_OPENGL_MAJOR_VERSION;
    pub const OPENGL_MINOR_VERSION = c.ALLEGRO_OPENGL_MINOR_VERSION;
    pub const PROGRAMMABLE_PIPELINE = c.ALLEGRO_PROGRAMMABLE_PIPELINE;
};

/// A single fullscreen display mode.
pub const DisplayMode = struct {
    width: i32,
    height: i32,
    format: i32,
    refresh_rate: i32,
};

pub fn numDisplayModes() i32 {
    return c.al_get_num_display_modes();
}

/// Fetch the display mode at `index`, or null if out of range.
pub fn getDisplayMode(index: i32) ?DisplayMode {
    var mode: c.ALLEGRO_DISPLAY_MODE = undefined;
    const r = c.al_get_display_mode(index, &mode);
    if (r == null) return null;
    return .{
        .width = mode.width,
        .height = mode.height,
        .format = mode.format,
        .refresh_rate = mode.refresh_rate,
    };
}

pub const Display = struct {
    display: *c.ALLEGRO_DISPLAY,

    pub fn create(width: i32, height: i32) !Display {
        const d = c.al_create_display(width, height) orelse return DisplayError.CreateFailed;
        return .{ .display = d };
    }

    pub fn destroy(self: *Display) void {
        c.al_destroy_display(self.display);
    }

    pub fn getBackbuffer(self: *Display) *c.ALLEGRO_BITMAP {
        return c.al_get_backbuffer(self.display).?;
    }

    pub fn eventSource(self: *Display) EventSource {
        return .{ .source = c.al_get_display_event_source(self.display) };
    }

    pub fn current() ?Display {
        const d = c.al_get_current_display();
        return if (d) |ptr| Display{ .display = ptr } else null;
    }

    pub fn flip() void {
        c.al_flip_display();
    }

    pub fn waitForVsync() bool {
        return c.al_wait_for_vsync();
    }

    pub fn updateRegion(x: i32, y: i32, width: i32, height: i32) void {
        c.al_update_display_region(x, y, width, height);
    }

    pub fn clearToColor(color: Color) void {
        c.al_clear_to_color(color.toAllegroColor());
    }

    pub fn resize(self: *Display, width: i32, height: i32) bool {
        return c.al_resize_display(self.display, width, height);
    }

    pub fn acknowledgeResize(self: *Display) bool {
        return c.al_acknowledge_resize(self.display);
    }

    pub fn acknowledgeDrawingHalt(self: *Display) void {
        c.al_acknowledge_drawing_halt(self.display);
    }

    pub fn acknowledgeDrawingResume(self: *Display) void {
        c.al_acknowledge_drawing_resume(self.display);
    }

    pub fn getWidth(self: *Display) i32 {
        return c.al_get_display_width(self.display);
    }

    pub fn getHeight(self: *Display) i32 {
        return c.al_get_display_height(self.display);
    }

    pub fn getFlags(self: *Display) i32 {
        return c.al_get_display_flags(self.display);
    }

    pub fn setFlag(self: *Display, flag: i32, onoff: bool) bool {
        return c.al_set_display_flag(self.display, flag, onoff);
    }

    pub fn toggleFlag(self: *Display, flag: i32) bool {
        return c.al_toggle_display_flag(self.display, flag);
    }

    pub fn getFormat(self: *Display) i32 {
        return c.al_get_display_format(self.display);
    }

    pub fn getOrientation(self: *Display) i32 {
        return c.al_get_display_orientation(self.display);
    }

    pub fn getRefreshRate(self: *Display) i32 {
        return c.al_get_display_refresh_rate(self.display);
    }

    pub fn getAdapter(self: *Display) i32 {
        return c.al_get_display_adapter(self.display);
    }

    pub fn getOption(self: *Display, option: i32) i32 {
        return c.al_get_display_option(self.display, option);
    }

    pub fn setOption(self: *Display, option: i32, value: i32) void {
        c.al_set_display_option(self.display, option, value);
    }

    // -- New-display "pending" settings (applied at next create()) --

    pub fn setNewFlags(flags: i32) void {
        c.al_set_new_display_flags(flags);
    }

    pub fn getNewFlags() i32 {
        return c.al_get_new_display_flags();
    }

    pub fn setNewOption(option: i32, value: i32, importance: i32) void {
        c.al_set_new_display_option(option, value, importance);
    }

    pub fn getNewOption(option: i32, importance: *i32) i32 {
        return c.al_get_new_display_option(option, importance);
    }

    pub fn setNewAdapter(adapter: i32) void {
        c.al_set_new_display_adapter(adapter);
    }

    pub fn getNewAdapter() i32 {
        return c.al_get_new_display_adapter();
    }

    pub fn setNewRefreshRate(rr: i32) void {
        c.al_set_new_display_refresh_rate(rr);
    }

    pub fn getNewRefreshRate() i32 {
        return c.al_get_new_display_refresh_rate();
    }

    pub fn resetNewOptions() void {
        c.al_reset_new_display_options();
    }

    pub fn setNewWindowPosition(x: i32, y: i32) void {
        c.al_set_new_window_position(x, y);
    }

    pub fn getNewWindowPosition(x: *i32, y: *i32) void {
        c.al_get_new_window_position(x, y);
    }

    pub fn setNewWindowTitle(title: [:0]const u8) void {
        c.al_set_new_window_title(title.ptr);
    }

    pub fn getNewWindowTitle() [:0]const u8 {
        return std.mem.span(c.al_get_new_window_title());
    }

    // -- Window management --

    pub fn setWindowTitle(self: *Display, title: [:0]const u8) void {
        c.al_set_window_title(self.display, title.ptr);
    }

    pub fn setWindowPosition(self: *Display, x: i32, y: i32) void {
        c.al_set_window_position(self.display, x, y);
    }

    pub fn getWindowPosition(self: *Display, x: *i32, y: *i32) void {
        c.al_get_window_position(self.display, x, y);
    }

    pub fn setWindowConstraints(self: *Display, min_w: i32, min_h: i32, max_w: i32, max_h: i32) bool {
        return c.al_set_window_constraints(self.display, min_w, min_h, max_w, max_h);
    }

    pub fn getWindowConstraints(self: *Display, min_w: *i32, min_h: *i32, max_w: *i32, max_h: *i32) bool {
        return c.al_get_window_constraints(self.display, min_w, min_h, max_w, max_h);
    }

    pub fn applyWindowConstraints(self: *Display, onoff: bool) void {
        c.al_apply_window_constraints(self.display, onoff);
    }

    pub fn setIcon(self: *Display, icon: *c.ALLEGRO_BITMAP) void {
        c.al_set_display_icon(self.display, icon);
    }

    pub fn setIcons(self: *Display, icons: []const *c.ALLEGRO_BITMAP) void {
        c.al_set_display_icons(self.display, @intCast(icons.len), icons.ptr);
    }

    // -- Clipboard --

    /// Returns an owned, null-terminated copy of the clipboard text, or null if unavailable.
    /// The caller must call `std.heap.page_allocator.free` on the result.
    pub fn getClipboardText(self: *Display, allocator: std.mem.Allocator) !?[:0]u8 {
        const text = c.al_get_clipboard_text(self.display);
        if (text == null) return null;
        const slice = std.mem.span(text);
        const buf = try allocator.dupeZ(u8, slice);
        c.al_free(text);
        return buf;
    }

    pub fn setClipboardText(self: *Display, text: [:0]const u8) bool {
        return c.al_set_clipboard_text(self.display, text.ptr);
    }

    pub fn clipboardHasText(self: *Display) bool {
        return c.al_clipboard_has_text(self.display);
    }

    // -- Misc --

    pub fn inhibitScreensaver(inhibit: bool) bool {
        return c.al_inhibit_screensaver(inhibit);
    }
};

test "refAllDecls" {
    std.testing.refAllDecls(Display);
}
