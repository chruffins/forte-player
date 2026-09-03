const std = @import("std");
const c = @import("c");
const Font = @import("font.zig").Font;
const File = @import("file.zig").File;

pub const Error = error{ InitFailed };

pub fn init() !void {
    if (!c.al_init_ttf_addon()) return Error.InitFailed;
}

pub fn shutdown() void {
    c.al_shutdown_ttf_addon();
}

pub fn initialized() bool {
    return c.al_is_ttf_addon_initialized();
}

pub fn version() u32 {
    return c.al_get_allegro_ttf_version();
}

/// Load a TrueType font using the freetype-backed addon.
pub fn loadFont(filename: [:0]const u8, size: i32, flags: i32) !Font {
    const f = c.al_load_ttf_font(filename.ptr, size, flags) orelse return error.LoadFailed;
    return .{ .data = f };
}

pub fn loadFontStretch(filename: [:0]const u8, w: i32, h: i32, flags: i32) !Font {
    const f = c.al_load_ttf_font_stretch(filename.ptr, w, h, flags) orelse return error.LoadFailed;
    return .{ .data = f };
}

pub fn loadFontFromFile(fp: *File, name: [:0]const u8, size: i32, flags: i32) !Font {
    const f = c.al_load_ttf_font_f(fp.file, name.ptr, size, flags) orelse return error.LoadFailed;
    return .{ .data = f };
}

pub fn loadFontStretchFromFile(fp: *File, name: [:0]const u8, w: i32, h: i32, flags: i32) !Font {
    const f = c.al_load_ttf_font_stretch_f(fp.file, name.ptr, w, h, flags) orelse return error.LoadFailed;
    return .{ .data = f };
}

test "refAllDecls" {
    std.testing.refAllDecls(@This());
}
