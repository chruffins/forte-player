//! Display-owned GPU visualization. One rectangle, one uniform array upload.
//! Compile once; no allocation, bitmap locks, vertex generation, or per-bar
//! draw calls during rendering. A missing GPU path leaves the GUI usable.
const std = @import("std");
const al = @import("allegro");
const ui = @import("ui.zig");
const low = @import("render.zig");
const spectrum = @import("../dsp/spectrum.zig");
const config = @import("../core/config.zig");

comptime {
    std.debug.assert(spectrum.n_bands == 48);
}
pub const Mode = enum(i32) {
    mirror,
    polar,
    pub fn label(self: Mode) []const u8 {
        return switch (self) {
            .mirror => "Mirror Spectrum",
            .polar => "Polar Spectrum",
        };
    }
    pub fn next(self: Mode) Mode {
        return if (self == .mirror) .polar else .mirror;
    }
    pub fn fromConfig(value: i64) Mode {
        return if (value == 1) .polar else .mirror;
    }
};

/// Normalize the public snapshot at the shader boundary, including non-finite
/// input. The fixed upload also prevents short arrays exposing old GPU values.
pub fn packLevels(values: []const f32) [spectrum.n_bands]f32 {
    var out: [spectrum.n_bands]f32 = @splat(0);
    for (values[0..@min(out.len, values.len)], 0..) |v, i| out[i] = if (std.math.isFinite(v)) @max(0, @min(1, v)) else 0;
    return out;
}

pub const Visualizer = struct {
    shader: ?al.shader.Shader = null,
    failed: bool = false,

    pub fn init(allocator: std.mem.Allocator) !Visualizer {
        const vertex_path = try config.resolveAssetPath(allocator, "shaders/visualizer.vert");
        defer allocator.free(vertex_path);
        const fragment_path = try config.resolveAssetPath(allocator, "shaders/visualizer.frag");
        defer allocator.free(fragment_path);
        var shader = try al.shader.Shader.create(al.shader.Platform.GLSL);
        errdefer shader.destroy();
        if (!shader.attachVertexSourceFile(vertex_path) or
            !shader.attachPixelSourceFile(fragment_path))
        {
            std.log.err("visualizer shader source: {s}", .{shader.getLog()});
            return error.ShaderSourceFailed;
        }
        shader.build() catch |err| {
            std.log.err("visualizer shader build: {s}", .{shader.getLog()});
            return err;
        };
        return .{ .shader = shader };
    }

    /// Must run before the owning display is destroyed.
    pub fn deinit(self: *Visualizer) void {
        if (self.shader) |*shader| shader.destroy();
        self.* = .{};
    }
    pub fn available(self: *const Visualizer) bool {
        return self.shader != null and !self.failed;
    }

    pub fn draw(self: *Visualizer, rect: ui.Rect, values: []const f32, mode: Mode, seconds: f64) bool {
        if (!self.available() or rect.w <= 0 or rect.h <= 0) return false;
        const shader = &self.shader.?;
        const previous = al.shader.Shader.current();
        if (!shader.use()) {
            self.failed = true;
            std.log.err("visualizer shader activation failed", .{});
            return false;
        }
        defer {
            if (previous) |old| {
                var restore = old;
                _ = restore.use();
            } else _ = al.shader.Shader.useNone();
        }
        const levels = packLevels(values);
        const bounds = [_]f32{ rect.x, rect.y, rect.w, rect.h };
        const size = [_]f32{ rect.w, rect.h };
        if (!al.shader.Shader.setFloatVector("vis_rect", 4, &bounds) or
            !al.shader.Shader.setFloatVector("vis_size", 2, &size) or
            !al.shader.Shader.setFloatVector("levels", 4, &levels) or
            !al.shader.Shader.setInt("vis_mode", @intFromEnum(mode)) or
            !al.shader.Shader.setFloat("vis_time", @floatCast(@mod(seconds, 3600))))
        {
            self.failed = true;
            std.log.err("visualizer uniform upload failed", .{});
            return false;
        }
        const clip = low.pushClip(rect);
        defer low.popClip(clip);
        low.fillRect(rect, al.Color.fromRgb(255, 255, 255));
        return true;
    }
};

test "shader band upload is bounded, sanitized and zero padded" {
    const upload = packLevels(&.{ -1, 0.5, 3, std.math.nan(f32), std.math.inf(f32) });
    try std.testing.expectEqual(@as(f32, 0), upload[0]);
    try std.testing.expectEqual(@as(f32, 0.5), upload[1]);
    try std.testing.expectEqual(@as(f32, 1), upload[2]);
    for (upload[3..]) |value| try std.testing.expectEqual(@as(f32, 0), value);
    const too_many: [96]f32 = @splat(0.75);
    const bounded = packLevels(&too_many);
    try std.testing.expectEqual(@as(usize, 48), bounded.len);
    for (bounded) |value| try std.testing.expectEqual(@as(f32, 0.75), value);
}
test "visualizer configuration is tolerant of invalid persisted modes" {
    try std.testing.expectEqual(Mode.mirror, Mode.fromConfig(-1));
    try std.testing.expectEqual(Mode.polar, Mode.fromConfig(1));
    try std.testing.expectEqual(Mode.mirror, Mode.fromConfig(99));
    try std.testing.expectEqual(Mode.mirror, Mode.mirror.next().next());
}
