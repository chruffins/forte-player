const std = @import("std");
const c = @import("c");
const Color = @import("color.zig").Color;

pub const Error = error{ InitFailed };

pub fn init() !void {
    if (!c.al_init_primitives_addon()) return Error.InitFailed;
}

pub fn shutdown() void {
    c.al_shutdown_primitives_addon();
}

pub fn initialized() bool {
    return c.al_is_primitives_addon_initialized();
}

pub fn version() u32 {
    return c.al_get_allegro_primitives_version();
}

/// Drawing primitive types (for the low-level vertex functions).
pub const PrimitiveType = struct {
    pub const POINT_LIST = c.ALLEGRO_PRIM_POINT_LIST;
    pub const LINE_LIST = c.ALLEGRO_PRIM_LINE_LIST;
    pub const LINE_STRIP = c.ALLEGRO_PRIM_LINE_STRIP;
    pub const LINE_LOOP = c.ALLEGRO_PRIM_LINE_LOOP;
    pub const TRIANGLE_LIST = c.ALLEGRO_PRIM_TRIANGLE_LIST;
    pub const TRIANGLE_STRIP = c.ALLEGRO_PRIM_TRIANGLE_STRIP;
    pub const TRIANGLE_FAN = c.ALLEGRO_PRIM_TRIANGLE_FAN;
};

pub const BufferFlags = struct {
    pub const STATIC = c.ALLEGRO_PRIM_BUFFER_STATIC;
    pub const DYNAMIC = c.ALLEGRO_PRIM_BUFFER_DYNAMIC;
    pub const STREAM = c.ALLEGRO_PRIM_BUFFER_STREAM;
    pub const READWRITE = c.ALLEGRO_PRIM_BUFFER_READWRITE;
};

pub const LockFlags = struct {
    pub const READONLY = c.ALLEGRO_LOCK_READONLY;
    pub const READWRITE = c.ALLEGRO_LOCK_READWRITE;
    pub const WRITEONLY = c.ALLEGRO_LOCK_WRITEONLY;
};

/// Joint styles for polylines / polygons.
pub const LineJoin = struct {
    pub const NONE = c.ALLEGRO_LINE_JOIN_NONE;
    pub const MITER = c.ALLEGRO_LINE_JOIN_MITER;
    pub const MITRE = c.ALLEGRO_LINE_JOIN_MITRE;
    pub const BEVEL = c.ALLEGRO_LINE_JOIN_BEVEL;
    pub const ROUND = c.ALLEGRO_LINE_JOIN_ROUND;
};

/// Cap styles for polylines.
pub const LineCap = struct {
    pub const NONE = c.ALLEGRO_LINE_CAP_NONE;
    pub const SQUARE = c.ALLEGRO_LINE_CAP_SQUARE;
    pub const ROUND = c.ALLEGRO_LINE_CAP_ROUND;
    pub const TRIANGLE = c.ALLEGRO_LINE_CAP_TRIANGLE;
    pub const CLOSED = c.ALLEGRO_LINE_CAP_CLOSED;
};

/// A single textured, coloured vertex used with `drawPrim`.
pub const Vertex = c.ALLEGRO_VERTEX;

// ---------------------------------------------------------------------------
// Structural / outline primitives
// ---------------------------------------------------------------------------

pub fn drawRectangle(x1: f32, y1: f32, x2: f32, y2: f32, color: Color, thickness: f32) void {
    c.al_draw_rectangle(x1, y1, x2, y2, color.toAllegroColor(), thickness);
}

pub fn drawFilledRectangle(x1: f32, y1: f32, x2: f32, y2: f32, color: Color) void {
    c.al_draw_filled_rectangle(x1, y1, x2, y2, color.toAllegroColor());
}

pub fn drawRoundedRectangle(x1: f32, y1: f32, x2: f32, y2: f32, rx: f32, ry: f32, color: Color, thickness: f32) void {
    c.al_draw_rounded_rectangle(x1, y1, x2, y2, rx, ry, color.toAllegroColor(), thickness);
}

pub fn drawFilledRoundedRectangle(x1: f32, y1: f32, x2: f32, y2: f32, rx: f32, ry: f32, color: Color) void {
    c.al_draw_filled_rounded_rectangle(x1, y1, x2, y2, rx, ry, color.toAllegroColor());
}

pub fn drawTriangle(x1: f32, y1: f32, x2: f32, y2: f32, x3: f32, y3: f32, color: Color, thickness: f32) void {
    c.al_draw_triangle(x1, y1, x2, y2, x3, y3, color.toAllegroColor(), thickness);
}

pub fn drawFilledTriangle(x1: f32, y1: f32, x2: f32, y2: f32, x3: f32, y3: f32, color: Color) void {
    c.al_draw_filled_triangle(x1, y1, x2, y2, x3, y3, color.toAllegroColor());
}

pub fn drawLine(x1: f32, y1: f32, x2: f32, y2: f32, color: Color, thickness: f32) void {
    c.al_draw_line(x1, y1, x2, y2, color.toAllegroColor(), thickness);
}

pub fn drawCircle(cx: f32, cy: f32, r: f32, color: Color, thickness: f32) void {
    c.al_draw_circle(cx, cy, r, color.toAllegroColor(), thickness);
}

pub fn drawFilledCircle(cx: f32, cy: f32, r: f32, color: Color) void {
    c.al_draw_filled_circle(cx, cy, r, color.toAllegroColor());
}

pub fn drawEllipse(cx: f32, cy: f32, rx: f32, ry: f32, color: Color, thickness: f32) void {
    c.al_draw_ellipse(cx, cy, rx, ry, color.toAllegroColor(), thickness);
}

pub fn drawFilledEllipse(cx: f32, cy: f32, rx: f32, ry: f32, color: Color) void {
    c.al_draw_filled_ellipse(cx, cy, rx, ry, color.toAllegroColor());
}

pub fn drawArc(cx: f32, cy: f32, r: f32, startTheta: f32, deltaTheta: f32, color: Color, thickness: f32) void {
    c.al_draw_arc(cx, cy, r, startTheta, deltaTheta, color.toAllegroColor(), thickness);
}

pub fn drawEllipticalArc(cx: f32, cy: f32, rx: f32, ry: f32, startTheta: f32, deltaTheta: f32, color: Color, thickness: f32) void {
    c.al_draw_elliptical_arc(cx, cy, rx, ry, startTheta, deltaTheta, color.toAllegroColor(), thickness);
}

pub fn drawPieslice(cx: f32, cy: f32, r: f32, startTheta: f32, deltaTheta: f32, color: Color, thickness: f32) void {
    c.al_draw_pieslice(cx, cy, r, startTheta, deltaTheta, color.toAllegroColor(), thickness);
}

pub fn drawFilledPieslice(cx: f32, cy: f32, r: f32, startTheta: f32, deltaTheta: f32, color: Color) void {
    c.al_draw_filled_pieslice(cx, cy, r, startTheta, deltaTheta, color.toAllegroColor());
}

pub fn drawSpline(points: []const f32, color: Color, thickness: f32) void {
    c.al_draw_spline(points.ptr, color.toAllegroColor(), thickness);
}

pub fn calculateSpline(dest: []f32, stride: i32, points: []const f32, numSegments: i32) void {
    c.al_calculate_spline(dest.ptr, stride, points.ptr, numSegments, numSegments);
}

pub fn drawRibbon(points: []const f32, pointsStride: i32, color: Color, thickness: f32, numSegments: i32) void {
    c.al_draw_ribbon(points.ptr, pointsStride, color.toAllegroColor(), thickness, numSegments);
}

pub fn calculateRibbon(dest: []f32, destStride: i32, points: []const f32, pointsStride: i32, thickness: f32, numSegments: i32) void {
    c.al_calculate_ribbon(dest.ptr, destStride, points.ptr, pointsStride, thickness, numSegments);
}

pub fn drawFilledPolygon(vertices: []const f32, color: Color) void {
    c.al_draw_filled_polygon(vertices.ptr, @intCast(vertices.len), color.toAllegroColor());
}

pub fn drawFilledPolygonWithHoles(vertices: []const f32, vertexCounts: []const i32, color: Color) void {
    c.al_draw_filled_polygon_with_holes(vertices.ptr, vertexCounts.ptr, color.toAllegroColor());
}

pub fn drawPolyline(vertices: []const f32, vertexStride: i32, joinStyle: i32, color: Color, thickness: f32, miterLimit: f32) void {
    c.al_draw_polyline(vertices.ptr, vertexStride, @intCast(vertices.len), joinStyle, 0, color.toAllegroColor(), thickness, miterLimit);
}

pub fn drawPolylineCapped(vertices: []const f32, vertexStride: i32, joinStyle: i32, capStyle: i32, color: Color, thickness: f32, miterLimit: f32) void {
    c.al_draw_polyline(vertices.ptr, vertexStride, @intCast(vertices.len), joinStyle, capStyle, color.toAllegroColor(), thickness, miterLimit);
}

pub fn drawPolygon(vertices: []const f32, joinStyle: i32, color: Color, thickness: f32, miterLimit: f32) void {
    c.al_draw_polygon(vertices.ptr, @intCast(vertices.len), joinStyle, color.toAllegroColor(), thickness, miterLimit);
}

pub fn calculateArc(dest: []f32, cx: f32, cy: f32, rx: f32, ry: f32, startTheta: f32, deltaTheta: f32, thickness: f32, numPoints: i32) void {
    c.al_calculate_arc(dest.ptr, 2, cx, cy, rx, ry, startTheta, deltaTheta, thickness, numPoints);
}

pub fn triangulatePolygon(vertices: []const f32, vertexStride: usize, vertexCounts: []const i32, cb: *const fn (a: i32, b: i32, d: i32, userdata: ?*anyopaque) callconv(.c) void, userdata: ?*anyopaque) bool {
    return c.al_triangulate_polygon(vertices.ptr, vertexStride, vertexCounts.ptr, cb, userdata);
}

// ---------------------------------------------------------------------------
// Low-level Vertex / buffer drawing
// ---------------------------------------------------------------------------

/// Draw a list of vertices.
pub fn drawPrim(vertices: []const anyopaque, texture: ?*c.ALLEGRO_BITMAP, primType: c_int) i32 {
    return c.al_draw_prim(vertices.ptr, null, texture orelse null, 0, @intCast(vertices.len), primType);
}

pub fn drawIndexedPrim(vertices: []const anyopaque, texture: ?*c.ALLEGRO_BITMAP, indices: []const i32, primType: c_int) i32 {
    return c.al_draw_indexed_prim(vertices.ptr, null, texture orelse null, indices.ptr, @intCast(indices.len), primType);
}

/// A vertex buffer with a geometric declaration, stored for efficient redraws.
pub const VertexBuffer = struct {
    buffer: *c.ALLEGRO_VERTEX_BUFFER,

    pub fn create(decl: ?*VertexDecl, initialData: ?*const anyopaque, numVertices: i32, flags: i32) !VertexBuffer {
        const b = c.al_create_vertex_buffer(if (decl) |d| d.decl else null, initialData, numVertices, flags) orelse return error.CreateFailed;
        return .{ .buffer = b };
    }

    pub fn destroy(self: *VertexBuffer) void {
        c.al_destroy_vertex_buffer(self.buffer);
    }

    pub fn size(self: *const VertexBuffer) i32 {
        return c.al_get_vertex_buffer_size(self.buffer);
    }

    pub fn lock(self: *VertexBuffer, offset: i32, length: i32, flags: i32) ?*anyopaque {
        return c.al_lock_vertex_buffer(self.buffer, offset, length, flags);
    }

    pub fn unlock(self: *VertexBuffer) void {
        c.al_unlock_vertex_buffer(self.buffer);
    }

    pub fn draw(self: *VertexBuffer, texture: ?*c.ALLEGRO_BITMAP, start: i32, end: i32, primType: i32) i32 {
        return c.al_draw_vertex_buffer(self.buffer, texture orelse null, start, end, primType);
    }

    pub fn drawIndexed(self: *VertexBuffer, texture: ?*c.ALLEGRO_BITMAP, indexBuffer: *IndexBuffer, start: i32, end: i32, primType: i32) i32 {
        return c.al_draw_indexed_buffer(self.buffer, texture orelse null, indexBuffer.buffer, start, end, primType);
    }
};

/// A buffer of vertex indices.
pub const IndexBuffer = struct {
    buffer: *c.ALLEGRO_INDEX_BUFFER,

    pub fn create(indexSize: i32, initialData: ?*const anyopaque, numIndices: i32, flags: i32) !IndexBuffer {
        const b = c.al_create_index_buffer(indexSize, initialData, numIndices, flags) orelse return error.CreateFailed;
        return .{ .buffer = b };
    }

    pub fn destroy(self: *IndexBuffer) void {
        c.al_destroy_index_buffer(self.buffer);
    }

    pub fn size(self: *const IndexBuffer) i32 {
        return c.al_get_index_buffer_size(self.buffer);
    }

    pub fn lock(self: *IndexBuffer, offset: i32, length: i32, flags: i32) ?*anyopaque {
        return c.al_lock_index_buffer(self.buffer, offset, length, flags);
    }

    pub fn unlock(self: *IndexBuffer) void {
        c.al_unlock_index_buffer(self.buffer);
    }
};

/// A description of the layout of a vertex buffer's elements.
pub const VertexDecl = struct {
    decl: *c.ALLEGRO_VERTEX_DECL,

    pub fn create(elements: []const c.ALLEGRO_VERTEX_ELEMENT, stride: i32) !VertexDecl {
        const d = c.al_create_vertex_decl(elements.ptr, stride) orelse return error.CreateFailed;
        return .{ .decl = d };
    }

    pub fn destroy(self: *VertexDecl) void {
        c.al_destroy_vertex_decl(self.decl);
    }
};

test "refAllDecls" {
    std.testing.refAllDecls(Vertex);
    std.testing.refAllDecls(VertexBuffer);
    std.testing.refAllDecls(IndexBuffer);
    std.testing.refAllDecls(VertexDecl);
}
