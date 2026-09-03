const std = @import("std");
const c = @import("c");
const Vec2 = @import("vec.zig").Vec2;
const Vec3 = @import("vec.zig").Vec3;
const Vec4 = @import("vec.zig").Vec4;

pub const Transform = extern struct {
    matrix: [4][4]f32,

    pub fn init() Transform {
        var transform: Transform = undefined;
        c.al_identity_transform(@ptrCast(&transform));
        return transform;
    }

    pub fn identity(self: *Transform) void {
        c.al_identity_transform(@ptrCast(&self.matrix));
    }

    pub fn copy(self: *Transform) Transform {
        var cpy: Transform = undefined;
        c.al_copy_transform(@ptrCast(&cpy), @ptrCast(&self.matrix));
        return cpy;
    }

    pub fn use(self: *Transform) void {
        c.al_use_transform(@ptrCast(&self.matrix));
    }

    pub fn getCurrent() ?Transform {
        var current: ?Transform = undefined;
        c.al_get_current_transform(@ptrCast(&current.matrix));
        return current;
    }

    pub fn useProjection(self: *Transform) void {
        c.al_use_projection_transform(@ptrCast(&self.matrix));
    }

    pub fn getCurrentProjection() ?Transform {
        var current: ?Transform = undefined;
        c.al_get_current_projection_transform(@ptrCast(&current.matrix));
        return current;
    }

    pub fn getCurrentInverse() ?Transform {
        var current: ?Transform = undefined;
        c.al_get_current_inverse_transform(@ptrCast(&current.matrix));
        return current;
    }

    /// Inverts the passed transform. The result is valid for 2D transforms that are not singular.
    /// Use checkInverse to check if the transform is invertible before calling this function.
    pub fn invert(self: *Transform) void {
        c.al_invert_transform(@ptrCast(&self.matrix));
    }

    pub fn transpose(self: *Transform) void {
        c.al_transpose_transform(@ptrCast(&self.matrix));
    }

    pub fn checkInverse(self: *Transform) bool {
        return c.al_check_inverse_transform(@ptrCast(&self.matrix)) != 0;
    }

    /// Create a 2D transformation by applying the transformations in the following order: rotate, scale, translate.
    /// Faster than building the transform manually by calling rotate, scale, and translate separately.
    pub fn build(self: *Transform, pos: Vec2, scaleFactor: Vec2, theta: f32) void {
        c.al_build_transform(@ptrCast(&self.matrix), pos.x, pos.y, scaleFactor.x, scaleFactor.y, theta);
    }

    pub fn buildCamera(self: *Transform, pos: Vec3, look: Vec3, up: Vec3) void {
        c.al_build_camera_transform(@ptrCast(&self.matrix), pos.x, pos.y, pos.z, look.x, look.y, look.z, up.x, up.y, up.z);
    }

    pub fn translate(self: *Transform, pos: Vec2) void {
        c.al_translate_transform(@ptrCast(&self.matrix), pos.x, pos.y);
    }

    pub fn rotate(self: *Transform, theta: f32) void {
        c.al_rotate_transform(@ptrCast(&self.matrix), theta);
    }

    pub fn scale(self: *Transform, scaleFactor: Vec2) void {
        c.al_scale_transform(@ptrCast(&self.matrix), scaleFactor.x, scaleFactor.y);
    }

    pub fn transformCoordinates(self: *const Transform, x: *f32, y: *f32) void {
        c.al_transform_coordinates(@ptrCast(&self.matrix), x, y);
    }

    pub fn transformPoint(self: *const Transform, point: Vec2) Vec2 {
        var x = point.x;
        var y = point.y;
        c.al_transform_coordinates(@ptrCast(&self.matrix), &x, &y);
        return .{ .x = x, .y = y };
    }

    pub fn transformCoordinates3d(self: *const Transform, x: *f32, y: *f32, z: *f32) void {
        c.al_transform_coordinates_3d(@ptrCast(&self.matrix), x, y, z);
    }

    pub fn transformPoint3d(self: *const Transform, point: Vec3) Vec3 {
        var x = point.x;
        var y = point.y;
        var z = point.z;
        c.al_transform_coordinates_3d(@ptrCast(&self.matrix), &x, &y, &z);
        return .{ .x = x, .y = y, .z = z };
    }

    pub fn transformCoordinates4d(self: *const Transform, x: *f32, y: *f32, z: *f32, w: *f32) void {
        c.al_transform_coordinates_4d(@ptrCast(&self.matrix), x, y, z, w);
    }

    pub fn transformPoint4d(self: *const Transform, point: Vec4) Vec4 {
        var x = point.x;
        var y = point.y;
        var z = point.z;
        var w = point.z;
        c.al_transform_coordinates_4d(@ptrCast(&self.matrix), &x, &y, &z, &w);
        return .{ .x = x, .y = y, .z = z, .w = w };
    }

    pub fn transformCoordinates3dProjective(self: *const Transform, x: *f32, y: *f32, z: *f32) void {
        c.al_transform_coordinates_3d_projective(@ptrCast(&self.matrix), x, y, z);
    }

    /// Transform x, y, z as homogeneous coordinates. This is the same as using al_transform_coordinates_4d
    /// with the w coordinate set to 1, then dividing x, y, z by the resulting w. This will provide the
    /// same normalized coordinates Allegro will draw to when a projective transform is in effect as set
    /// with al_use_projection_transform.
    pub fn transformPoint3dProjective(self: *const Transform, point: Vec3) Vec3 {
        var x = point.x;
        var y = point.y;
        var z = point.z;
        c.al_transform_coordinates_3d_projective(@ptrCast(&self.matrix), &x, &y, &z);
        return .{ .x = x, .y = y, .z = z };
    }

    /// Matrix multiply (self := self other)
    pub fn compose(self: *Transform, other: *const Transform) void {
        c.al_compose_transform(@ptrCast(&self.matrix), @ptrCast(&other.matrix));
    }

    pub fn orthographicTransform(self: *Transform, left: f32, top: f32, near: f32, right: f32, bottom: f32, far: f32) void {
        c.al_orthographic_transform(@ptrCast(&self.matrix), left, top, near, right, bottom, far);
    }

    pub fn perspectiveTransform(self: *Transform, left: f32, top: f32, near: f32, right: f32, bottom: f32, far: f32) void {
        c.al_perspective_transform(@ptrCast(&self.matrix), left, top, near, right, bottom, far);
    }

    pub fn translate3d(self: *Transform, pos: Vec3) void {
        c.al_translate_transform_3d(self, pos.x, pos.y, pos.z);
    }

    pub fn scale3d(self: *Transform, factors: Vec3) void {
        c.al_scale_transform_3d(self, factors.x, factors.y, factors.z);
    }

    /// The vector is assumed to be of unit length (otherwise it will also incur a scale).
    pub fn rotate3d(self: *Transform, rotateAround: Vec3, angle: f32) void {
        c.al_rotate_transform_3d(self, rotateAround.x, rotateAround.y, rotateAround.z, angle);
    }

    pub fn horizontalShear(self: *Transform, theta: f32) void {
        c.al_horizontal_shear_transform(self, theta);
    }

    pub fn verticalShear(self: *Transform, theta: f32) void {
        c.al_vertical_shear_transform(self, theta);
    }
};
