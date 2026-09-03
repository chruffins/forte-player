const std = @import("std");
const c = @import("c");
const Display = @import("display.zig").Display;
const Config = @import("config.zig").Config;
const Color = @import("color.zig").Color;
const Bitmap = @import("graphics.zig").Bitmap;
const Str = @import("utf8.zig").String;

// ---------------------------------------------------------------------------
// System information
// ---------------------------------------------------------------------------

pub fn cpuCount() i32 {
    return c.al_get_cpu_count();
}

pub fn ramSize() i32 {
    return c.al_get_ram_size();
}

pub fn getErrno() i32 {
    return c.al_get_errno();
}

pub fn setErrno(errnum: i32) void {
    c.al_set_errno(errnum);
}

pub const AssertHandler = *const fn (expr: [*c]const u8, file: [*c]const u8, line: i32, func: [*c]const u8) callconv(.c) void;
pub const TraceHandler = *const fn (msg: [*c]const u8) callconv(.c) void;

/// Install a custom handler for assertion failures.
pub fn registerAssertHandler(handler: ?AssertHandler) void {
    c.al_register_assert_handler(@ptrCast(handler));
}

/// Install a custom handler for trace messages.
pub fn registerTraceHandler(handler: ?TraceHandler) void {
    c.al_register_trace_handler(@ptrCast(handler));
}

pub fn systemId() c.ALLEGRO_SYSTEM_ID {
    return c.al_get_system_id();
}

/// The global configuration created at startup.
pub fn systemConfig() ?Config {
    const cfg = c.al_get_system_config();
    return if (cfg) |cc| Config.fromCPtr(cc) else null;
}

pub fn systemDriver() ?*c.ALLEGRO_SYSTEM {
    return c.al_get_system_driver();
}

// ---------------------------------------------------------------------------
// State save / restore
// ---------------------------------------------------------------------------

pub const StateFlags = struct {
    pub const NEW_DISPLAY_PARAMETERS = c.ALLEGRO_STATE_NEW_DISPLAY_PARAMETERS;
    pub const NEW_BITMAP_PARAMETERS = c.ALLEGRO_STATE_NEW_BITMAP_PARAMETERS;
    pub const DISPLAY = c.ALLEGRO_STATE_DISPLAY;
    pub const TARGET_BITMAP = c.ALLEGRO_STATE_TARGET_BITMAP;
    pub const BLENDER = c.ALLEGRO_STATE_BLENDER;
    pub const NEW_FILE_INTERFACE = c.ALLEGRO_STATE_NEW_FILE_INTERFACE;
    pub const TRANSFORM = c.ALLEGRO_STATE_TRANSFORM;
    pub const PROJECTION_TRANSFORM = c.ALLEGRO_STATE_PROJECTION_TRANSFORM;
    pub const BITMAP = c.ALLEGRO_STATE_BITMAP;
    pub const ALL = c.ALLEGRO_STATE_ALL;
};

const StateBuf = extern struct {
    _tls: [1024]u8,
};

/// Save and restore Allegro global state (e.g. target bitmap, blender).
pub const State = struct {
    buf: StateBuf = undefined,

    pub fn store(self: *State, flags: i32) void {
        c.al_store_state(@ptrCast(&self.buf), flags);
    }

    pub fn restore(self: *const State) void {
        c.al_restore_state(@ptrCast(&self.buf));
    }
};

// ---------------------------------------------------------------------------
// Addon versions (packed integers, render with system.versionToString)
// ---------------------------------------------------------------------------

pub const AddonVersion = struct {
    pub fn color() u32 {
        return c.al_get_allegro_color_version();
    }
    pub fn font() u32 {
        return c.al_get_allegro_font_version();
    }
    pub fn image() u32 {
        return c.al_get_allegro_image_version();
    }
    pub fn primitives() u32 {
        return c.al_get_allegro_primitives_version();
    }
    pub fn ttf() u32 {
        return c.al_get_allegro_ttf_version();
    }
    pub fn audio() u32 {
        return c.al_get_allegro_audio_version();
    }
    pub fn memfile() u32 {
        return c.al_get_allegro_memfile_version();
    }
    pub fn physfs() u32 {
        return c.al_get_allegro_physfs_version();
    }
    /// Folds a packed minor/wip/release trio into the same layout as the core version.
    pub fn toCoreFormat(v: u32) u32 {
        // Allegro addon versions are (minor << 16) | (wip << 8) | release.
        return v & 0x00FFFFFF;
    }
};

// ---------------------------------------------------------------------------
// Bitmap identification
// ---------------------------------------------------------------------------

pub fn identifyBitmap(filename: [:0]const u8) [:0]const u8 {
    return std.mem.span(c.al_identify_bitmap(filename.ptr));
}

/// Convert all pixels of `magenta` in `bitmap` to fully-transparent black.
pub fn convertMaskToAlpha(bitmap: *Bitmap, maskColor: Color) void {
    c.al_convert_mask_to_alpha(bitmap.bmp, maskColor.toAllegroColor());
}

// ---------------------------------------------------------------------------
// System mouse cursors & main-loop wrapper
// ---------------------------------------------------------------------------

pub const SystemCursor = struct {
    pub const DEFAULT = c.ALLEGRO_SYSTEM_MOUSE_CURSOR_DEFAULT;
    pub const NONE = c.ALLEGRO_SYSTEM_MOUSE_CURSOR_NONE;
    pub const ARROW = c.ALLEGRO_SYSTEM_MOUSE_CURSOR_ARROW;
    pub const BUSY = c.ALLEGRO_SYSTEM_MOUSE_CURSOR_BUSY;
    pub const QUESTION = c.ALLEGRO_SYSTEM_MOUSE_CURSOR_QUESTION;
    pub const EDIT = c.ALLEGRO_SYSTEM_MOUSE_CURSOR_EDIT;
    pub const MOVE = c.ALLEGRO_SYSTEM_MOUSE_CURSOR_MOVE;
    pub const RESIZE_N = c.ALLEGRO_SYSTEM_MOUSE_CURSOR_RESIZE_N;
    pub const RESIZE_S = c.ALLEGRO_SYSTEM_MOUSE_CURSOR_RESIZE_S;
    pub const RESIZE_E = c.ALLEGRO_SYSTEM_MOUSE_CURSOR_RESIZE_E;
    pub const RESIZE_W = c.ALLEGRO_SYSTEM_MOUSE_CURSOR_RESIZE_W;
    pub const RESIZE_NE = c.ALLEGRO_SYSTEM_MOUSE_CURSOR_RESIZE_NE;
    pub const RESIZE_NW = c.ALLEGRO_SYSTEM_MOUSE_CURSOR_RESIZE_NW;
    pub const RESIZE_SE = c.ALLEGRO_SYSTEM_MOUSE_CURSOR_RESIZE_SE;
    pub const RESIZE_SW = c.ALLEGRO_SYSTEM_MOUSE_CURSOR_RESIZE_SW;
    pub const RESIZE_NESW = c.ALLEGRO_SYSTEM_MOUSE_CURSOR_RESIZE_NESW;
    pub const RESIZE_NWSE = c.ALLEGRO_SYSTEM_MOUSE_CURSOR_RESIZE_NWSE;
    pub const ALT_SELECT = c.ALLEGRO_SYSTEM_MOUSE_CURSOR_ALT_SELECT;
    pub const PRECISION = c.ALLEGRO_SYSTEM_MOUSE_CURSOR_PRECISION;
    pub const LINK = c.ALLEGRO_SYSTEM_MOUSE_CURSOR_LINK;
    pub const PROGRESS = c.ALLEGRO_SYSTEM_MOUSE_CURSOR_PROGRESS;
};

pub fn setSystemMouseCursor(display: *Display, cursor: c.ALLEGRO_SYSTEM_MOUSE_CURSOR) bool {
    return c.al_set_system_mouse_cursor(display.display, cursor);
}

const MainProc = *const fn (argc: i32, argv: [*][*]u8) callconv(.c) c_int;

/// Win32 wrapper that sets up the `allegro_main` shim. Not needed on Linux but
/// provided for portability of the entry point.
pub fn runMain(argv: [][*]u8, proc: MainProc) c_int {
    return c.al_run_main(@intCast(argv.len), argv.ptr, @ptrCast(proc));
}

test "refAllDecls" {
    std.testing.refAllDecls(State);
}
