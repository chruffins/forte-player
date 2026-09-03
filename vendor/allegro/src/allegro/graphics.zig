const std = @import("std");
const c = @import("c");
const Color = @import("color.zig").Color;
const File = @import("file.zig").File;

pub const BitmapError = error{ LoadFailed, CreateFailed };

/// Bitmap creation/loading flags (bitwise OR).
pub const BitmapFlags = struct {
    pub const MEMORY_BITMAP = c.ALLEGRO_MEMORY_BITMAP;
    pub const KEEP_BITMAP_FORMAT = c.ALLEGRO_KEEP_BITMAP_FORMAT;
    pub const FORCE_LOCKING = c.ALLEGRO_FORCE_LOCKING;
    pub const NO_PREMULTIPLIED_ALPHA = c.ALLEGRO_NO_PREMULTIPLIED_ALPHA;
    pub const VIDEO_BITMAP = c.ALLEGRO_VIDEO_BITMAP;
    pub const CONVERT_BITMAP = c.ALLEGRO_CONVERT_BITMAP;
    pub const MIN_LINEAR = c.ALLEGRO_MIN_LINEAR;
    pub const MAG_LINEAR = c.ALLEGRO_MAG_LINEAR;
    pub const MIPMAP = c.ALLEGRO_MIPMAP;
    pub const NO_PRESERVE_TEXTURE = c.ALLEGRO_NO_PRESERVE_TEXTURE;
    pub const ALPHA_TEST = c.ALLEGRO_ALPHA_TEST;
    pub const ALPHA_TEST_FUNCTION = c.ALLEGRO_ALPHA_TEST_FUNCTION;
    pub const ALPHA_TEST_VALUE = c.ALLEGRO_ALPHA_TEST_VALUE;
};

/// Flags passed to draw functions controlling flipping / tinting semantics.
pub const DrawFlags = struct {
    pub const FLIP_HORIZONTAL = c.ALLEGRO_FLIP_HORIZONTAL;
    pub const FLIP_VERTICAL = c.ALLEGRO_FLIP_VERTICAL;
};

/// Blending operators (argument to `setBlender`).
pub const BlendOp = struct {
    pub const ADD = c.ALLEGRO_ADD;
    pub const DEST_MINUS_SRC = c.ALLEGRO_DEST_MINUS_SRC;
    pub const SRC_MINUS_DEST = c.ALLEGRO_SRC_MINUS_DEST;
};

/// Blend factors (source/destination for `setBlender`).
pub const BlendFunc = struct {
    pub const ZERO = c.ALLEGRO_ZERO;
    pub const ONE = c.ALLEGRO_ONE;
    pub const ALPHA = c.ALLEGRO_ALPHA;
    pub const INVERSE_ALPHA = c.ALLEGRO_INVERSE_ALPHA;
    pub const SRC_COLOR = c.ALLEGRO_SRC_COLOR;
    pub const DEST_COLOR = c.ALLEGRO_DEST_COLOR;
    pub const INVERSE_SRC_COLOR = c.ALLEGRO_INVERSE_SRC_COLOR;
    pub const INVERSE_DEST_COLOR = c.ALLEGRO_INVERSE_DEST_COLOR;
    pub const CONST_COLOR = c.ALLEGRO_CONST_COLOR;
    pub const INVERSE_CONST_COLOR = c.ALLEGRO_INVERSE_CONST_COLOR;
};

pub const RenderState = enum(c_int) {
    alpha_test = c.ALLEGRO_ALPHA_TEST,
    alpha_function = c.ALLEGRO_ALPHA_FUNCTION,
    alpha_test_value = c.ALLEGRO_ALPHA_TEST_VALUE,
    write_mask = c.ALLEGRO_WRITE_MASK,
    depth_test = c.ALLEGRO_DEPTH_TEST,
    depth_function = c.ALLEGRO_DEPTH_FUNCTION,
    blend_alpha_function = c.ALLEGRO_BLEND_ALPHA_FUNCTION,
    blend_color = c.ALLEGRO_BLEND_COLOR,
};

/// A region of a locked bitmap, used for direct pixel access.
pub const LockedRegion = struct {
    data: ?*anyopaque,
    format: c_int,
    pitch: c_int,
    pixel_size: c_int,
};

// ---------------------------------------------------------------------------
// New-bitmap settings (global defaults applied at next Bitmap.create/load)
// ---------------------------------------------------------------------------

pub fn setNewBitmapFlags(flags: c_int) void {
    c.al_set_new_bitmap_flags(flags);
}

pub fn getNewBitmapFlags() c_int {
    return c.al_get_new_bitmap_flags();
}

pub fn addNewBitmapFlag(flag: c_int) void {
    c.al_add_new_bitmap_flag(flag);
}

pub fn setNewBitmapFormat(format: c_int) void {
    c.al_set_new_bitmap_format(format);
}

pub fn getNewBitmapFormat() c_int {
    return c.al_get_new_bitmap_format();
}

pub fn resetNewBitmapSettings() void {
    c.al_reset_new_bitmap_flags();
    c.al_set_new_bitmap_format(0);
}

// ---------------------------------------------------------------------------
// Bitmap
// ---------------------------------------------------------------------------

pub const Bitmap = struct {
    bmp: *c.ALLEGRO_BITMAP,

    pub fn create(width: i32, height: i32) !Bitmap {
        const b = c.al_create_bitmap(width, height) orelse return BitmapError.CreateFailed;
        return .{ .bmp = b };
    }

    /// Load an image file (requires the image addon to be initialised in most cases).
    pub fn load(path: [:0]const u8) !Bitmap {
        const b = c.al_load_bitmap(path.ptr) orelse return BitmapError.LoadFailed;
        return .{ .bmp = b };
    }

    pub fn loadFlags(path: [:0]const u8, flags: c_int) !Bitmap {
        const b = c.al_load_bitmap_flags(path.ptr, flags) orelse return BitmapError.LoadFailed;
        return .{ .bmp = b };
    }

    pub fn loadFromFile(fp: *File, ident: [:0]const u8) !Bitmap {
        const b = c.al_load_bitmap_f(fp.file, ident.ptr) orelse return BitmapError.LoadFailed;
        return .{ .bmp = b };
    }

    pub fn loadFlagsFromFile(fp: *File, ident: [:0]const u8, flags: c_int) !Bitmap {
        const b = c.al_load_bitmap_flags_f(fp.file, ident.ptr, flags) orelse return BitmapError.LoadFailed;
        return .{ .bmp = b };
    }

    /// Steal a raw bitmap pointer (for internal / advanced use).
    pub fn fromCPointer(ptr: *c.ALLEGRO_BITMAP) Bitmap {
        return .{ .bmp = ptr };
    }

    pub fn clone(self: *Bitmap) !Bitmap {
        const b = c.al_clone_bitmap(self.bmp) orelse return BitmapError.CreateFailed;
        return .{ .bmp = b };
    }

    pub fn createSubBitmap(self: *Bitmap, x: i32, y: i32, w: i32, h: i32) !Bitmap {
        const b = c.al_create_sub_bitmap(self.bmp, x, y, w, h) orelse return BitmapError.CreateFailed;
        return .{ .bmp = b };
    }

    pub fn destroy(self: *Bitmap) void {
        c.al_destroy_bitmap(self.bmp);
    }

    pub fn getWidth(self: *Bitmap) i32 {
        return c.al_get_bitmap_width(self.bmp);
    }

    pub fn getHeight(self: *Bitmap) i32 {
        return c.al_get_bitmap_height(self.bmp);
    }

    pub fn getFlags(self: *Bitmap) i32 {
        return c.al_get_bitmap_flags(self.bmp);
    }

    pub fn getFormat(self: *Bitmap) i32 {
        return c.al_get_bitmap_format(self.bmp);
    }

    pub fn getX(self: *Bitmap) i32 {
        return c.al_get_bitmap_x(self.bmp);
    }

    pub fn getY(self: *Bitmap) i32 {
        return c.al_get_bitmap_y(self.bmp);
    }

    pub fn getParent(self: *Bitmap) ?Bitmap {
        const p = c.al_get_parent_bitmap(self.bmp);
        return if (p) |ptr| Bitmap{ .bmp = ptr } else null;
    }

    pub fn isSubBitmap(self: *Bitmap) bool {
        return c.al_is_sub_bitmap(self.bmp);
    }

    pub fn isCompatible(self: *Bitmap) bool {
        return c.al_is_compatible_bitmap(self.bmp);
    }

    pub fn isLocked(self: *Bitmap) bool {
        return c.al_is_bitmap_locked(self.bmp);
    }

    pub fn reparent(self: *Bitmap, parent: *Bitmap, x: i32, y: i32, w: i32, h: i32) void {
        c.al_reparent_bitmap(self.bmp, parent.bmp, x, y, w, h);
    }

    pub fn getPixel(self: *Bitmap, x: i32, y: i32) Color {
        return Color.fromAllegroColor(c.al_get_pixel(self.bmp, x, y));
    }

    pub fn convert(self: *Bitmap) void {
        c.al_convert_bitmap(self.bmp);
    }

    // -- Locking (direct pixel access) --

    pub fn lock(self: *Bitmap, format: c_int, flags: c_int) ?LockedRegion {
        const r = c.al_lock_bitmap(self.bmp, format, flags);
        return toLocked(r);
    }

    pub fn lockRegion(self: *Bitmap, x: i32, y: i32, width: i32, height: i32, format: c_int, flags: c_int) ?LockedRegion {
        const r = c.al_lock_bitmap_region(self.bmp, x, y, width, height, format, flags);
        return toLocked(r);
    }

    pub fn lockBlocked(self: *Bitmap, flags: c_int) ?LockedRegion {
        const r = c.al_lock_bitmap_blocked(self.bmp, flags);
        return toLocked(r);
    }

    pub fn lockRegionBlocked(self: *Bitmap, x: i32, y: i32, width: i32, height: i32, flags: c_int) ?LockedRegion {
        const r = c.al_lock_bitmap_region_blocked(self.bmp, x, y, width, height, flags);
        return toLocked(r);
    }

    pub fn unlock(self: *Bitmap) void {
        c.al_unlock_bitmap(self.bmp);
    }

    fn toLocked(r: [*c]c.ALLEGRO_LOCKED_REGION) ?LockedRegion {
        if (r == null) return null;
        return .{
            .data = r[0].data,
            .format = r[0].format,
            .pitch = r[0].pitch,
            .pixel_size = r[0].pixel_size,
        };
    }

    // -- Target / drawing --

    pub fn setTarget(self: *Bitmap) void {
        c.al_set_target_bitmap(self.bmp);
    }

    pub fn draw(self: *Bitmap, dx: f32, dy: f32, flags: c_int) void {
        c.al_draw_bitmap(self.bmp, dx, dy, flags);
    }

    pub fn drawAt(self: *Bitmap, dx: f32, dy: f32) void {
        c.al_draw_bitmap(self.bmp, dx, dy, 0);
    }

    pub fn drawTinted(self: *Bitmap, tint: Color, dx: f32, dy: f32, flags: c_int) void {
        c.al_draw_tinted_bitmap(self.bmp, tint.toAllegroColor(), dx, dy, flags);
    }

    pub fn drawRegion(self: *Bitmap, sx: f32, sy: f32, sw: f32, sh: f32, dx: f32, dy: f32, flags: c_int) void {
        c.al_draw_bitmap_region(self.bmp, sx, sy, sw, sh, dx, dy, flags);
    }

    pub fn drawTintedRegion(self: *Bitmap, tint: Color, sx: f32, sy: f32, sw: f32, sh: f32, dx: f32, dy: f32, flags: c_int) void {
        c.al_draw_tinted_bitmap_region(self.bmp, tint.toAllegroColor(), sx, sy, sw, sh, dx, dy, flags);
    }

    pub fn drawScaled(self: *Bitmap, sx: f32, sy: f32, sw: f32, sh: f32, dx: f32, dy: f32, dw: f32, dh: f32, flags: c_int) void {
        c.al_draw_scaled_bitmap(self.bmp, sx, sy, sw, sh, dx, dy, dw, dh, flags);
    }

    pub fn drawTintedScaled(self: *Bitmap, tint: Color, sx: f32, sy: f32, sw: f32, sh: f32, dx: f32, dy: f32, dw: f32, dh: f32, flags: c_int) void {
        c.al_draw_tinted_scaled_bitmap(self.bmp, tint.toAllegroColor(), sx, sy, sw, sh, dx, dy, dw, dh, flags);
    }

    pub fn drawRotated(self: *Bitmap, cx: f32, cy: f32, dx: f32, dy: f32, angle: f32, flags: c_int) void {
        c.al_draw_rotated_bitmap(self.bmp, cx, cy, dx, dy, angle, flags);
    }

    pub fn drawTintedRotated(self: *Bitmap, tint: Color, cx: f32, cy: f32, dx: f32, dy: f32, angle: f32, flags: c_int) void {
        c.al_draw_tinted_rotated_bitmap(self.bmp, tint.toAllegroColor(), cx, cy, dx, dy, angle, flags);
    }

    pub fn drawScaledRotated(self: *Bitmap, cx: f32, cy: f32, dx: f32, dy: f32, xscale: f32, yscale: f32, angle: f32, flags: c_int) void {
        c.al_draw_scaled_rotated_bitmap(self.bmp, cx, cy, dx, dy, xscale, yscale, angle, flags);
    }

    pub fn drawTintedScaledRotated(self: *Bitmap, tint: Color, cx: f32, cy: f32, dx: f32, dy: f32, xscale: f32, yscale: f32, angle: f32, flags: c_int) void {
        c.al_draw_tinted_scaled_rotated_bitmap(self.bmp, tint.toAllegroColor(), cx, cy, dx, dy, xscale, yscale, angle, flags);
    }

    pub fn drawTintedScaledRotatedRegion(self: *Bitmap, sx: f32, sy: f32, sw: f32, sh: f32, tint: Color, cx: f32, cy: f32, dx: f32, dy: f32, xscale: f32, yscale: f32, angle: f32, flags: c_int) void {
        c.al_draw_tinted_scaled_rotated_bitmap_region(self.bmp, sx, sy, sw, sh, tint.toAllegroColor(), cx, cy, dx, dy, xscale, yscale, angle, flags);
    }
};

// ---------------------------------------------------------------------------
// Top-level drawing / target helpers
// ---------------------------------------------------------------------------

pub fn getTargetBitmap() ?Bitmap {
    const b = c.al_get_target_bitmap();
    return if (b) |ptr| Bitmap{ .bmp = ptr } else null;
}

pub fn setTargetBackbuffer(display: *c.ALLEGRO_DISPLAY) void {
    c.al_set_target_backbuffer(display);
}

pub fn convertMemoryBitmaps() void {
    c.al_convert_memory_bitmaps();
}

pub fn holdBitmapDrawing(hold: bool) void {
    c.al_hold_bitmap_drawing(hold);
}

pub fn isBitmapDrawingHeld() bool {
    return c.al_is_bitmap_drawing_held();
}

pub fn clearToColor(color: Color) void {
    c.al_clear_to_color(color.toAllegroColor());
}

pub fn clearDepthBuffer(x: f32) void {
    c.al_clear_depth_buffer(x);
}

pub fn drawPixel(x: f32, y: f32, color: Color) void {
    c.al_draw_pixel(x, y, color.toAllegroColor());
}

pub fn putPixel(x: i32, y: i32, color: Color) void {
    c.al_put_pixel(x, y, color.toAllegroColor());
}

pub fn putBlendedPixel(x: i32, y: i32, color: Color) void {
    c.al_put_blended_pixel(x, y, color.toAllegroColor());
}

// ---------------------------------------------------------------------------
// Clipping
// ---------------------------------------------------------------------------

pub fn setClipRectangle(x: i32, y: i32, width: i32, height: i32) void {
    c.al_set_clipping_rectangle(x, y, width, height);
}

pub fn resetClipRectangle() void {
    c.al_reset_clipping_rectangle();
}

pub fn getClipRectangle(x: *i32, y: *i32, width: *i32, height: *i32) void {
    c.al_get_clipping_rectangle(x, y, width, height);
}

// ---------------------------------------------------------------------------
// Blending
// ---------------------------------------------------------------------------

pub fn setBlender(op: c_int, source: c_int, dest: c_int) void {
    c.al_set_blender(op, source, dest);
}

pub fn getBlender(op: *c_int, source: *c_int, dest: *c_int) void {
    c.al_get_blender(op, source, dest);
}

pub fn setSeparateBlender(op: c_int, source: c_int, dest: c_int, alpha_op: c_int, alpha_source: c_int, alpha_dest: c_int) void {
    c.al_set_separate_blender(op, source, dest, alpha_op, alpha_source, alpha_dest);
}

pub fn getSeparateBlender(op: *c_int, source: *c_int, dest: *c_int, alpha_op: *c_int, alpha_src: *c_int, alpha_dest: *c_int) void {
    c.al_get_separate_blender(op, source, dest, alpha_op, alpha_src, alpha_dest);
}

pub fn setBlendColor(color: Color) void {
    c.al_set_blend_color(color.toAllegroColor());
}

pub fn getBlendColor() Color {
    return Color.fromAllegroColor(c.al_get_blend_color());
}

// ---------------------------------------------------------------------------
// Render states
// ---------------------------------------------------------------------------

pub fn setRenderState(state: c.ALLEGRO_RENDER_STATE, value: i32) void {
    c.al_set_render_state(state, value);
}

pub fn getRenderState(state: c.ALLEGRO_RENDER_STATE) i32 {
    return c.al_get_render_state(state);
}

// ---------------------------------------------------------------------------
// Image saving / pixel format introspection
// ---------------------------------------------------------------------------

pub fn saveBitmap(path: [:0]const u8, bitmap: *Bitmap) bool {
    return c.al_save_bitmap(path.ptr, bitmap.bmp);
}

pub fn saveBitmapToFile(fp: *File, ident: [:0]const u8, bitmap: *Bitmap) bool {
    return c.al_save_bitmap_f(fp.file, ident.ptr, bitmap.bmp);
}

pub const PixelFormat = struct {
    pub const ANY = c.ALLEGRO_PIXEL_FORMAT_ANY;
    pub const ANY_15_555 = c.ALLEGRO_PIXEL_FORMAT_ANY_15_555;
    pub const ANY_16_565 = c.ALLEGRO_PIXEL_FORMAT_ANY_16_565;
    pub const ANY_24 = c.ALLEGRO_PIXEL_FORMAT_ANY_24;
    pub const ANY_32 = c.ALLEGRO_PIXEL_FORMAT_ANY_32;
    pub const ARGB_8888 = c.ALLEGRO_PIXEL_FORMAT_ARGB_8888;

    pub fn pixelSize(format: i32) i32 {
        return c.al_get_pixel_size(format);
    }

    pub fn formatBits(format: i32) i32 {
        return c.al_get_pixel_format_bits(format);
    }

    pub fn blockSize(format: i32) i32 {
        return c.al_get_pixel_block_size(format);
    }

    pub fn blockWidth(format: i32) i32 {
        return c.al_get_pixel_block_width(format);
    }

    pub fn blockHeight(format: i32) i32 {
        return c.al_get_pixel_block_height(format);
    }
};

test "refAllDecls" {
    std.testing.refAllDecls(Bitmap);
}
