const std = @import("std");
const c = @import("c");

/// A portable filesystem path.
pub const Path = struct {
    path: *c.ALLEGRO_PATH,

    pub fn create(s: [:0]const u8) ?Path {
        const p = c.al_create_path(s.ptr);
        return if (p) |ptr| Path.fromCPath(ptr) else null;
    }

    pub fn createForDirectory(s: [:0]const u8) ?Path {
        const p = c.al_create_path_for_directory(s.ptr);
        return if (p) |ptr| Path.fromCPath(ptr) else null;
    }

    pub fn fromCPath(ptr: *c.ALLEGRO_PATH) Path {
        return .{ .path = ptr };
    }

    pub fn destroy(self: *Path) void {
        c.al_destroy_path(self.path);
    }

    pub fn clone(self: *const Path) ?Path {
        const p = c.al_clone_path(self.path);
        return if (p) |ptr| Path.fromCPath(ptr) else null;
    }

    pub fn numComponents(self: *const Path) i32 {
        return c.al_get_path_num_components(self.path);
    }

    pub fn component(self: *const Path, i: i32) [:0]const u8 {
        return std.mem.span(c.al_get_path_component(self.path, i));
    }

    pub fn drive(self: *const Path) [:0]const u8 {
        return std.mem.span(c.al_get_path_drive(self.path));
    }

    pub fn tail(self: *const Path) [:0]const u8 {
        return std.mem.span(c.al_get_path_tail(self.path));
    }

    pub fn basename(self: *const Path) [:0]const u8 {
        return std.mem.span(c.al_get_path_basename(self.path));
    }

    pub fn filename(self: *const Path) [:0]const u8 {
        return std.mem.span(c.al_get_path_filename(self.path));
    }

    pub fn extension(self: *const Path) [:0]const u8 {
        return std.mem.span(c.al_get_path_extension(self.path));
    }

    /// Render the path as a string into `buf` using `delim` as the separator.
    /// Returns a slice of `buf`.
    pub fn cstr(self: *const Path, buf: []u8, delim: u8) ?[:0]u8 {
        const s = c.al_path_cstr(self.path, delim);
        if (s == null) return null;
        const slice = std.mem.span(s);
        if (slice.len >= buf.len) return null;
        @memcpy(buf[0..slice.len], slice);
        buf[slice.len] = 0;
        return buf[0 .. slice.len :0];
    }

    pub fn setDrive(self: *Path, d: [:0]const u8) void {
        c.al_set_path_drive(self.path, d.ptr);
    }

    pub fn appendComponent(self: *Path, s: [:0]const u8) void {
        c.al_append_path_component(self.path, s.ptr);
    }

    pub fn insertComponent(self: *Path, i: i32, s: [:0]const u8) void {
        c.al_insert_path_component(self.path, i, s.ptr);
    }

    pub fn removeComponent(self: *Path, i: i32) void {
        c.al_remove_path_component(self.path, i);
    }

    pub fn replaceComponent(self: *Path, i: i32, s: [:0]const u8) void {
        c.al_replace_path_component(self.path, i, s.ptr);
    }

    pub fn setFilename(self: *Path, fname: [:0]const u8) void {
        c.al_set_path_filename(self.path, fname.ptr);
    }

    pub fn setExtension(self: *Path, ext: [:0]const u8) bool {
        return c.al_set_path_extension(self.path, ext.ptr);
    }

    pub fn dropTail(self: *Path) void {
        c.al_drop_path_tail(self.path);
    }

    pub fn joinPaths(self: *Path, tailPath: *const Path) bool {
        return c.al_join_paths(self.path, tailPath.path);
    }

    pub fn canonical(self: *Path) bool {
        return c.al_make_path_canonical(self.path);
    }

    const Str = @import("utf8.zig").String;

    /// Rebuild this path against the given head path (e.g. mounting a resource dir).
    pub fn rebase(self: *Path, head: *const Path) bool {
        return c.al_rebase_path(head.path, self.path);
    }

    /// Render the path into a mutable Unicode string.
    pub fn toUstr(self: *const Path, dest: *Str) void {
        c.al_path_ustr(self.path, dest.us);
    }
};

test "refAllDecls" {
    std.testing.refAllDecls(Path);
}
