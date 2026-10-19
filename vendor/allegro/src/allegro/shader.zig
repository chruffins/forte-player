const std = @import("std");
const c = @import("c");
const Color = @import("color.zig").Color;
const Transform = @import("transform.zig").Transform;
const Bitmap = @import("graphics.zig").Bitmap;
const uniform = @import("shader_uniform.zig");

pub const ShaderError = error{ CreateFailed, BuildFailed };

/// Which shader language / platform to use when creating a shader.
pub const Platform = struct {
    pub const AUTO = c.ALLEGRO_SHADER_AUTO;
    pub const GLSL = c.ALLEGRO_SHADER_GLSL;
    pub const HLSL = c.ALLEGRO_SHADER_HLSL;
    pub const AUTO_MINIMAL = c.ALLEGRO_SHADER_AUTO_MINIMAL;
    pub const GLSL_MINIMAL = c.ALLEGRO_SHADER_GLSL_MINIMAL;
    pub const HLSL_MINIMAL = c.ALLEGRO_SHADER_HLSL_MINIMAL;
    pub const HLSL_SM_3_0 = c.ALLEGRO_SHADER_HLSL_SM_3_0;
};

/// A shader stage: vertex or pixel (fragment).
pub const Type = struct {
    pub const VERTEX = c.ALLEGRO_VERTEX_SHADER;
    pub const PIXEL = c.ALLEGRO_PIXEL_SHADER;
};

/// Wraps a programmable-pipeline shader.
pub const Shader = struct {
    shader: *c.ALLEGRO_SHADER,

    pub fn create(platform: c.ALLEGRO_SHADER_PLATFORM) !Shader {
        const s = c.al_create_shader(platform) orelse return ShaderError.CreateFailed;
        return .{ .shader = s };
    }

    pub fn attachVertexSource(self: *Shader, source: [:0]const u8) bool {
        return c.al_attach_shader_source(self.shader, c.ALLEGRO_VERTEX_SHADER, source.ptr);
    }

    pub fn attachPixelSource(self: *Shader, source: [:0]const u8) bool {
        return c.al_attach_shader_source(self.shader, c.ALLEGRO_PIXEL_SHADER, source.ptr);
    }

    pub fn attachVertexSourceFile(self: *Shader, filename: [:0]const u8) bool {
        return c.al_attach_shader_source_file(self.shader, c.ALLEGRO_VERTEX_SHADER, filename.ptr);
    }

    pub fn attachPixelSourceFile(self: *Shader, filename: [:0]const u8) bool {
        return c.al_attach_shader_source_file(self.shader, c.ALLEGRO_PIXEL_SHADER, filename.ptr);
    }

    pub fn build(self: *Shader) !void {
        if (!c.al_build_shader(self.shader)) return ShaderError.BuildFailed;
    }

    pub fn getLog(self: *Shader) [:0]const u8 {
        return std.mem.span(c.al_get_shader_log(self.shader));
    }

    /// Activate the shader for subsequent drawing. Pass null to deactivate.
    pub fn use(self: *Shader) bool {
        return c.al_use_shader(self.shader);
    }

    pub fn useNone() bool {
        return c.al_use_shader(null);
    }

    pub fn current() ?Shader {
        const s = c.al_get_current_shader();
        return if (s) |ptr| Shader{ .shader = ptr } else null;
    }

    pub fn getPlatform(self: *Shader) c.ALLEGRO_SHADER_PLATFORM {
        return c.al_get_shader_platform(self.shader);
    }

    /// The default shader source for a given platform and stage (for building
    /// minimal shaders that you extend).
    pub fn getDefaultSource(platform: c.ALLEGRO_SHADER_PLATFORM, stage: c.ALLEGRO_SHADER_TYPE) ?[:0]const u8 {
        const s = c.al_get_default_shader_source(platform, stage);
        return if (s == null) null else std.mem.span(s);
    }

    pub fn destroy(self: *Shader) void {
        c.al_destroy_shader(self.shader);
    }

    // -- Uniform setters --

    pub fn setSampler(name: [:0]const u8, bitmap: *Bitmap, unit: i32) bool {
        return c.al_set_shader_sampler(name.ptr, bitmap.bmp, unit);
    }

    pub fn setMatrix(name: [:0]const u8, matrix: *const Transform) bool {
        return c.al_set_shader_matrix(name.ptr, @ptrCast(&matrix.matrix));
    }

    pub fn setInt(name: [:0]const u8, value: i32) bool {
        return c.al_set_shader_int(name.ptr, value);
    }

    pub fn setFloat(name: [:0]const u8, value: f32) bool {
        return c.al_set_shader_float(name.ptr, value);
    }

    pub fn setBool(name: [:0]const u8, value: bool) bool {
        return c.al_set_shader_bool(name.ptr, value);
    }

    pub fn setIntVector(name: [:0]const u8, numComponents: i32, values: []const i32) bool {
        const count = uniform.vectorCount(numComponents, values.len) orelse return false;
        return c.al_set_shader_int_vector(name.ptr, numComponents, values.ptr, count);
    }

    pub fn setFloatVector(name: [:0]const u8, numComponents: i32, values: []const f32) bool {
        const count = uniform.vectorCount(numComponents, values.len) orelse return false;
        return c.al_set_shader_float_vector(name.ptr, numComponents, values.ptr, count);
    }
};

test "refAllDecls" {
    std.testing.refAllDecls(Shader);
}
