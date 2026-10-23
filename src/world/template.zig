//! Typed, display-scoped owner for the native world renderer.
//! Keep this value in one stable location; destroy it before its display/context.
const std = @import("std");
const config = @import("../core/config.zig");
const model = @import("model.zig");
const c = @import("forte_c");

fn resolvePaths(comptime count: usize, allocator: std.mem.Allocator, relative_paths: [count][]const u8) ![count][:0]u8 {
    var paths: [count][:0]u8 = undefined;
    var initialized: usize = 0;
    errdefer freePaths(allocator, paths[0..initialized]);
    for (relative_paths, 0..) |relative, i| {
        paths[i] = try config.resolveAssetPath(allocator, relative);
        initialized += 1;
    }
    return paths;
}

fn freePaths(allocator: std.mem.Allocator, paths: []const [:0]u8) void {
    for (paths) |path| allocator.free(path);
}

/// A single GPU-resource owner; do not copy after initialization.
pub const World = struct {
    native: ?*c.ForteWorld = null,

    pub fn init(allocator: std.mem.Allocator) !World {
        const sky_files = [_][]const u8{
            "world/skybox/night-ocean/right.png",
            "world/skybox/night-ocean/left.png",
            "world/skybox/night-ocean/up.png",
            "world/skybox/night-ocean/down.png",
            "world/skybox/night-ocean/back.png",
            "world/skybox/night-ocean/front.png",
        };
        const sky_paths = try resolvePaths(sky_files.len, allocator, sky_files);
        defer freePaths(allocator, &sky_paths);
        const shader_files = [_][]const u8{
            "shaders/world_floor.vert",
            "shaders/world_floor.frag",
            "shaders/world_fireflies.vert",
            "shaders/world_fireflies.frag",
        };
        const shader_paths = try resolvePaths(shader_files.len, allocator, shader_files);
        defer freePaths(allocator, &shader_paths);

        var faces: [sky_files.len][*c]const u8 = undefined;
        var shaders: [shader_files.len][*c]const u8 = undefined;
        for (sky_paths, 0..) |path, i| faces[i] = path.ptr;
        for (shader_paths, 0..) |path, i| shaders[i] = path.ptr;

        return .{
            .native = c.forte_world_create(&faces, &shaders) orelse return error.WorldRendererUnavailable,
        };
    }

    pub fn deinit(self: *World) void {
        if (self.native) |renderer| c.forte_world_destroy(renderer);
        self.native = null;
    }

    pub fn draw(self: *World, pose: model.Pose, bands: *const [48]f32, vocal: f32, seconds: f64, width: i32, height: i32) bool {
        return c.forte_world_draw(self.native, pose.x, pose.y, pose.z, pose.yaw, pose.pitch, bands, vocal, seconds, width, height);
    }

    pub fn setPointLights(self: *World, enabled: bool) void {
        c.forte_world_set_point_lights(self.native, enabled);
    }

    pub fn hasSky(self: *const World) bool {
        return c.forte_world_has_sky(self.native);
    }

    pub fn glError() u32 {
        return c.forte_world_gl_error();
    }
};
