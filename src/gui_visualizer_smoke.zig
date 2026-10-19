//! Optional real-OpenGL integration test; no audio device or user library.
//! Pixel readback below is TEST ONLY, never part of the production render path.
const std = @import("std");
const al = @import("allegro");
const vis = @import("ui/gui_visualizer.zig");

fn expect(ok: bool) !void {
    if (!ok) return error.GpuSmokeFailed;
}

pub fn main() !void {
    try al.system.init();
    defer al.system.uninstall();
    try al.primitives.init();
    al.Display.setNewFlags(al.DisplayFlags.WINDOWED | al.DisplayFlags.OPENGL | al.DisplayFlags.PROGRAMMABLE_PIPELINE);
    var display = try al.Display.create(400, 240);
    defer display.destroy();
    al.Display.setNewWindowTitle("forte GPU smoke test");
    var shader = try vis.Visualizer.init(std.heap.page_allocator);
    defer shader.deinit();
    try expect(shader.shader.?.getPlatform() == al.shader.Platform.GLSL);
    const default_vertex = al.shader.Shader.getDefaultSource(al.shader.Platform.GLSL, al.shader.Type.VERTEX) orelse return error.MissingDefaultShader;
    try expect(default_vertex.len > 0);
    al.graphics.setNewBitmapFlags(al.graphics.BitmapFlags.VIDEO_BITMAP);
    var target = try al.graphics.Bitmap.create(384, 192);
    defer target.destroy();
    target.setTarget();
    al.graphics.clearToColor(al.Color.fromRgb(0, 0, 0));
    var bands: [48]f32 = @splat(0);
    bands[0] = 0.1;
    bands[47] = 0.9;
    try expect(shader.draw(.{ .w = 384, .h = 192 }, &bands, .mirror, 1));
    try expect(al.shader.Shader.current() == null);
    // First and last groups exercise both ends of the vec4 uniform array.
    try expect(target.getPixel(4, 46).b < 0.3);
    try expect(target.getPixel(380, 46).b > 0.4);
    try expect(target.getPixel(1, 1).b < 0.3);
    bands = @splat(0);
    try expect(shader.draw(.{ .w = 384, .h = 192 }, &bands, .polar, 2));
    try expect(target.getPixel(236, 96).b > 0.4);
    try expect(target.getPixel(192, 96).b < 0.3);
    try expect(al.shader.Shader.current() == null);
    // A smaller, offset viewport verifies local coordinates and clip restoration.
    al.graphics.clearToColor(al.Color.fromRgb(0, 0, 0));
    try expect(shader.draw(.{ .x = 16, .y = 20, .w = 192, .h = 96 }, &bands, .polar, 3));
    try expect(target.getPixel(0, 0).b == 0);
    var x: i32 = 0;
    var y: i32 = 0;
    var w: i32 = 0;
    var h: i32 = 0;
    al.graphics.getClipRectangle(&x, &y, &w, &h);
    try expect(x == 0 and y == 0 and w == 384 and h == 192);
    al.graphics.setTargetBackbuffer(display.display);
    std.debug.print("GPU smoke passed: both modes, vector uploads, local viewport, shader/clip restoration.\n", .{});
}
