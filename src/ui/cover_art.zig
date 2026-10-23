//! Converts cover image bytes (JPEG/PNG) into a half-block terminal art grid.
//!
//! Each output cell holds two colors: the upper pixel color (fg) and the lower
//! pixel color (bg); the TUI renders it with the '▀' character, so every cell
//! shows two full-color pixels. Decoding + downsampling use Allegro's image
//! addon with MEMORY bitmaps, so no display is required (headless-safe).

const std = @import("std");
const U = @import("ui_state.zig");

const c = @import("forte_c");

/// Downsample `bytes` (a JPEG/PNG) into a `w x h` grid of `out` cells.
/// Returns false on any failure (undecodable data, no image addon, ...).
pub fn renderCover(bytes: []const u8, w: usize, h: usize, out: []U.ArtCell) bool {
    if (w == 0 or h == 0 or out.len < w * h) return false;

    const file = c.al_open_memfile(@ptrCast(@constCast(bytes.ptr)), @intCast(bytes.len), "rb") orelse return false;
    defer _ = c.al_fclose(file);

    // NULL ident lets Allegro sniff the magic; fall back to explicit idents.
    const src = c.al_load_bitmap_f(file, null) orelse loadByIdent(file, ".jpg") orelse loadByIdent(file, ".png") orelse return false;
    defer c.al_destroy_bitmap(src);

    const sw = c.al_get_bitmap_width(src);
    const sh = c.al_get_bitmap_height(src);
    if (sw <= 0 or sh <= 0) return false;

    // Downsample onto a small memory bitmap (2 rows of pixels per cell row).
    c.al_set_new_bitmap_flags(c.ALLEGRO_MEMORY_BITMAP);
    const target = c.al_create_bitmap(@intCast(w), @intCast(h * 2)) orelse return false;
    defer c.al_destroy_bitmap(target);

    c.al_set_target_bitmap(target);
    c.al_clear_to_color(c.al_map_rgb(0.0, 0.0, 0.0));
    c.al_draw_scaled_bitmap(
        src,
        0.0,
        0.0,
        @floatFromInt(sw),
        @floatFromInt(sh),
        0.0,
        0.0,
        @floatFromInt(w),
        @floatFromInt(h * 2),
        0,
    );
    c.al_set_target_bitmap(null);

    for (0..h) |y| {
        for (0..w) |x| {
            const top = c.al_get_pixel(target, @intCast(x), @intCast(y * 2));
            const bot = c.al_get_pixel(target, @intCast(x), @intCast(y * 2 + 1));
            var tr: u8 = 0;
            var tg: u8 = 0;
            var tb: u8 = 0;
            var br: u8 = 0;
            var bg: u8 = 0;
            var bb: u8 = 0;
            c.al_unmap_rgb(top, &tr, &tg, &tb);
            c.al_unmap_rgb(bot, &br, &bg, &bb);
            out[y * w + x] = .{
                .fg = .{ tr, tg, tb },
                .bg = .{ br, bg, bb },
            };
        }
    }
    return true;
}

/// Rewind `file` and load with an explicit format ident.
fn loadByIdent(file: ?*c.struct_ALLEGRO_FILE, ident: [*:0]const u8) ?*c.struct_ALLEGRO_BITMAP {
    _ = c.al_fseek(file, 0, c.ALLEGRO_SEEK_SET);
    return c.al_load_bitmap_f(file, ident);
}

test "renderCover downsamples a known image" {
    // Build a tiny 2x2 bitmap (top row red, bottom row blue), save as PNG to
    // a memfile, then renderCover into a 1x1 grid: fg ~ red, bg ~ blue.
    const allegro_init = @import("../core/allegro_init.zig");
    try allegro_init.initialize();

    c.al_set_new_bitmap_flags(c.ALLEGRO_MEMORY_BITMAP);
    const bmp = c.al_create_bitmap(2, 2) orelse return error.SkipZigTest;
    defer c.al_destroy_bitmap(bmp);
    c.al_set_target_bitmap(bmp);
    c.al_clear_to_color(c.al_map_rgb(0.0, 0.0, 0.0));
    c.al_put_pixel(0, 0, c.al_map_rgb(255.0, 0.0, 0.0));
    c.al_put_pixel(1, 0, c.al_map_rgb(255.0, 0.0, 0.0));
    c.al_put_pixel(0, 1, c.al_map_rgb(0.0, 0.0, 255.0));
    c.al_put_pixel(1, 1, c.al_map_rgb(0.0, 0.0, 255.0));
    c.al_set_target_bitmap(null);

    // Save to a temp file (the 5.2.10 memfile header lacks read-back helpers).
    if (!c.al_save_bitmap("/tmp/fp_cover_test.png", bmp)) return error.SkipZigTest;
    defer _ = c.remove("/tmp/fp_cover_test.png");
    const f = c.fopen("/tmp/fp_cover_test.png", "rb") orelse return error.SkipZigTest;
    defer _ = c.fclose(f);
    _ = c.fseek(f, 0, c.SEEK_END);
    const sz = c.ftell(f);
    _ = c.fseek(f, 0, c.SEEK_SET);
    if (sz <= 0 or sz > 4096) return error.SkipZigTest;
    var bytes: [4096]u8 = undefined;
    const rd = c.fread(&bytes, 1, @intCast(sz), f);
    if (rd != sz) return error.SkipZigTest;

    var cell: [1]U.ArtCell = undefined;
    try std.testing.expect(renderCover(bytes[0..@intCast(sz)], 1, 1, &cell));
    // The top pixel of the 1x1 target = red, bottom = blue.
    try std.testing.expect(cell[0].fg[0] > 200 and cell[0].fg[1] < 60 and cell[0].fg[2] < 60);
    try std.testing.expect(cell[0].bg[0] < 60 and cell[0].bg[1] < 60 and cell[0].bg[2] > 200);
}
