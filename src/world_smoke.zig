//! Real-GPU integration check. No audio engine or user configuration/database.
//! Framebuffer readback is test-only, never used by the production renderer.
const std = @import("std");
const al = @import("allegro");
const native = @import("world/template.zig");
const model = @import("world/model.zig");
const c = @import("forte_c");
const width = 640;
const height = 360;
fn expect(value: bool) !void {
    if (!value) return error.WorldSmokeFailed;
}
fn capture(world: *native.World, pose: model.Pose, bands: *const [48]f32, out: []u8) !u64 {
    return captureAt(world, pose, bands, out, 4);
}
fn captureAt(world: *native.World, pose: model.Pose, bands: *const [48]f32, out: []u8, seconds: f64) !u64 {
    return captureWithVocal(world, pose, bands, out, seconds, 0);
}
fn captureWithVocal(world: *native.World, pose: model.Pose, bands: *const [48]f32, out: []u8, seconds: f64, vocal: f32) !u64 {
    al.graphics.resetClipRectangle();
    al.graphics.clearToColor(al.Color.fromRgb(3, 6, 10));
    try expect(world.draw(pose, bands, vocal, seconds, width, height));
    try expect(native.World.glError() == 0);
    c.glReadPixels(0, 0, width, height, c.GL_RGBA, c.GL_UNSIGNED_BYTE, out.ptr);
    var sum: u64 = 0;
    for (out, 0..) |value, i| if (i % 4 != 3) {
        sum += value;
    };
    return sum;
}
pub fn main() !void {
    try al.system.init();
    defer al.system.uninstall();
    try al.primitives.init();
    al.Display.setNewFlags(al.DisplayFlags.WINDOWED | al.DisplayFlags.OPENGL | al.DisplayFlags.PROGRAMMABLE_PIPELINE | al.DisplayFlags.RESIZABLE);
    c.al_set_new_display_option(c.ALLEGRO_DEPTH_SIZE, 24, c.ALLEGRO_REQUIRE);
    var display = try al.Display.create(width, height);
    defer display.destroy();
    al.Display.setNewWindowTitle("Forte world GPU smoke");
    const initial_shader = c.al_get_current_shader();
    var world = try native.World.init(std.heap.page_allocator);
    defer world.deinit();
    try expect(c.al_get_current_shader() == initial_shader);
    try expect(world.hasSky());
    const allocator = std.heap.page_allocator;
    const idle = try allocator.alloc(u8, width * height * 4);
    defer allocator.free(idle);
    const active = try allocator.alloc(u8, width * height * 4);
    defer allocator.free(active);
    const saved_shader = c.al_get_current_shader();
    const saved_transform = c.al_get_current_transform().*;
    const saved_projection = c.al_get_current_projection_transform().*;
    var bands: [48]f32 = @splat(0);
    const idle_sum = try capture(&world, .{}, &bands, idle);
    bands = @splat(std.math.nan(f32));
    try expect(try capture(&world, .{}, &bands, active) == idle_sum);
    bands = @splat(1);
    const active_sum = try capture(&world, .{}, &bands, active);
    try expect(active_sum > idle_sum + 10000);
    const vocal_sum = try captureWithVocal(&world, .{}, &bands, active, 4, 1);
    try expect(vocal_sum > active_sum);
    try expect(vocal_sum > idle_sum + 10000);
    // Sprite positions/glow stay identical: only ground illumination changes.
    world.setPointLights(false);
    const unlit_sum = try capture(&world, .{}, &bands, idle);
    world.setPointLights(true);
    try expect(try capture(&world, .{}, &bands, active) > unlit_sum + 10000);
    var ground_gain: i64 = 0;
    for (0..width * (height / 3) * 4) |i| {
        if (i % 4 != 3) ground_gain += @as(i64, active[i]) - @as(i64, idle[i]);
    }
    try expect(ground_gain > 10000);
    const restored_transform = c.al_get_current_transform().*;
    const restored_projection = c.al_get_current_projection_transform().*;
    try expect(std.mem.eql(u8, std.mem.asBytes(&saved_transform), std.mem.asBytes(&restored_transform)));
    try expect(std.mem.eql(u8, std.mem.asBytes(&saved_projection), std.mem.asBytes(&restored_projection)));
    try expect(c.al_get_current_shader() == saved_shader);
    // Both ends of the 48-band array must light different fireflies.
    bands = @splat(0);
    bands[0] = 1;
    try expect(try capture(&world, .{}, &bands, active) > idle_sum);
    bands = @splat(0);
    bands[47] = 1;
    try expect(try capture(&world, .{}, &bands, active) > idle_sum);
    // Crossing the old hourly clock wrap must not teleport the swarm/lights.
    bands = @splat(1);
    _ = try captureAt(&world, .{}, &bands, idle, 3599.99999);
    _ = try captureAt(&world, .{}, &bands, active, 3600.00001);
    var clock_difference: u64 = 0;
    for (idle, active) |a, b| clock_difference += @abs(@as(i32, a) - @as(i32, b));
    try expect(clock_difference < 20000);
    // Camera movement changes the world; reset/reinit reproduces the same frame.
    bands = @splat(1);
    _ = try capture(&world, .{}, &bands, idle);
    _ = try capture(&world, .{ .x = 4, .yaw = 0.3 }, &bands, active);
    try expect(!std.mem.eql(u8, idle, active));
    _ = try capture(&world, .{}, &bands, active);
    @memcpy(idle, active);
    world.deinit();
    world = try native.World.init(allocator);
    _ = try capture(&world, .{}, &bands, active);
    try expect(std.mem.eql(u8, idle, active));
    if (c.getenv("FORTE_WORLD_CAPTURE")) |path| try expect(c.al_save_bitmap(path, c.al_get_backbuffer(@ptrCast(display.display))));
    try expect(display.resize(800, 480));
    al.graphics.setTargetBackbuffer(display.display);
    al.graphics.clearToColor(al.Color.fromRgb(3, 6, 10));
    try expect(world.draw(.{}, &bands, 0, 4, display.getWidth(), display.getHeight()));
    try expect(native.World.glError() == 0);
    std.debug.print("World GPU smoke passed: sky, point-light ground illumination, reactive first/last bands, continuous clock, camera, state restoration, reinit and resize.\n", .{});
}
