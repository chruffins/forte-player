const std = @import("std");
const c = @import("c");
const Bitmap = @import("graphics.zig").Bitmap;

pub const Error = error{ InitFailed };

pub fn init() !void {
    if (!c.al_init_image_addon()) return Error.InitFailed;
}

pub fn shutdown() void {
    c.al_shutdown_image_addon();
}

pub fn initialized() bool {
    return c.al_is_image_addon_initialized();
}

pub fn version() u32 {
    return c.al_get_allegro_image_version();
}

/// Identify an image file's format by filename extension ("png", "jpg", ...).
pub fn identify(filename: [:0]const u8) [:0]const u8 {
    return std.mem.span(c.al_identify_bitmap(filename.ptr));
}

const File = @import("file.zig").File;
const BitmapWrap = @import("graphics.zig").Bitmap;

/// Identify an image format by inspecting an open Allegro file handle.
pub fn identifyFromFile(fp: *File) [:0]const u8 {
    return std.mem.span(c.al_identify_bitmap_f(fp.file));
}

// -- Plugin registration (custom bitmap loaders/savers) --

pub const BitmapLoader = *const fn (filename: [*:0]const u8) callconv(.c) ?*c.ALLEGRO_BITMAP;
pub const BitmapLoaderF = *const fn (fp: ?*c.ALLEGRO_FILE, ident: [*:0]const u8) callconv(.c) ?*c.ALLEGRO_BITMAP;
pub const BitmapSaver = *const fn (filename: [*:0]const u8, bitmap: ?*c.ALLEGRO_BITMAP) callconv(.c) bool;
pub const BitmapSaverF = *const fn (fp: ?*c.ALLEGRO_FILE, ident: [*:0]const u8, bitmap: ?*c.ALLEGRO_BITMAP) callconv(.c) bool;
pub const BitmapIdentifier = *const fn (fp: ?*c.ALLEGRO_FILE) callconv(.c) bool;

pub fn registerBitmapLoader(ext: [:0]const u8, loader: BitmapLoader) bool {
    return c.al_register_bitmap_loader(ext.ptr, @ptrCast(loader));
}

pub fn registerBitmapLoaderFromFile(ext: [:0]const u8, loader: BitmapLoaderF) bool {
    return c.al_register_bitmap_loader_f(ext.ptr, @ptrCast(loader));
}

pub fn registerBitmapSaver(ext: [:0]const u8, saver: BitmapSaver) bool {
    return c.al_register_bitmap_saver(ext.ptr, @ptrCast(saver));
}

pub fn registerBitmapSaverToFile(ext: [:0]const u8, saver: BitmapSaverF) bool {
    return c.al_register_bitmap_saver_f(ext.ptr, @ptrCast(saver));
}

pub fn registerBitmapIdentifier(ext: [:0]const u8, identifier: BitmapIdentifier) bool {
    return c.al_register_bitmap_identifier(ext.ptr, @ptrCast(identifier));
}

// Image addon convenience re-exports (the core loading/saving lives in graphics.zig).
pub const load = Bitmap.load;
pub const loadFlags = Bitmap.loadFlags;
pub const save = Bitmap.saveBitmap;

test "refAllDecls" {
    std.testing.refAllDecls(@This());
}
