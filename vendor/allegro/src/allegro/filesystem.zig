const std = @import("std");
const c = @import("c");
const Path = @import("path.zig").Path;
const File = @import("file.zig").File;

/// Filesystem entry mode flags (returned by `FsEntry.mode`).
pub const Mode = struct {
    pub const READ = 1;
    pub const WRITE = 1 << 1;
    pub const EXECUTE = 1 << 2;
    pub const HIDDEN = 1 << 3;
    pub const ISFILE = 1 << 4;
    pub const ISDIR = 1 << 5;
};

pub fn filenameExists(path: [:0]const u8) bool {
    return c.al_filename_exists(path.ptr);
}

pub fn fsEntryExists(path: [:0]const u8) bool {
    return c.al_fs_entry_exists(path.ptr);
}

pub const FsEntryCallback = *const fn (entry: [*c]c.ALLEGRO_FS_ENTRY, extra: ?*anyopaque) callconv(.c) c_int;

/// Call `callback` for each child of the directory entry `dir`.
pub fn forEachEntry(dir: *Entry, callback: FsEntryCallback, extra: ?*anyopaque) i32 {
    return c.al_for_each_fs_entry(dir.entry, @ptrCast(callback), extra);
}

pub fn removeFilename(path: [:0]const u8) bool {
    return c.al_remove_filename(path.ptr);
}

pub fn makeDirectory(path: [:0]const u8) bool {
    return c.al_make_directory(path.ptr);
}

/// Create a temporary file. Returns a File and (optionally) the created path.
pub fn makeTempFile(template: [:0]const u8, allocator: std.mem.Allocator) !struct { file: File, path: []u8 } {
    var path: ?*c.ALLEGRO_PATH = null;
    const f = c.al_make_temp_file(template.ptr, &path) orelse return error.CreateFailed;
    const p = if (path) |pp| Path.fromCPath(pp) else null;
    var pathBuf: [4096]u8 = undefined;
    const pathStr = if (p) |pp| (pp.cstr(&pathBuf, '/') orelse "") else "";
    return .{
        .file = .{ .file = f },
        .path = try allocator.dupe(u8, pathStr),
    };
}

/// Set the standard native filesystem as the active interface.
pub fn setStandardInterface() void {
    c.al_set_standard_fs_interface();
}

/// Replace the active filesystem interface, or null to restore defaults.
pub fn setInterface(iface: *const c.ALLEGRO_FS_INTERFACE) void {
    c.al_set_fs_interface(iface);
}

pub fn getInterface() ?*const c.ALLEGRO_FS_INTERFACE {
    return c.al_get_fs_interface();
}

/// A filesystem entry (file or directory).
pub const Entry = struct {
    entry: *c.ALLEGRO_FS_ENTRY,

    pub fn create(path: [:0]const u8) !Entry {
        const e = c.al_create_fs_entry(path.ptr) orelse return error.CreateFailed;
        return .{ .entry = e };
    }

    pub fn fromCPointer(p: *c.ALLEGRO_FS_ENTRY) Entry {
        return .{ .entry = p };
    }

    pub fn destroy(self: *Entry) void {
        c.al_destroy_fs_entry(self.entry);
    }

    pub fn name(self: *const Entry) [:0]const u8 {
        return std.mem.span(c.al_get_fs_entry_name(self.entry));
    }

    pub fn mode(self: *const Entry) u32 {
        return c.al_get_fs_entry_mode(self.entry);
    }

    pub fn isDirectory(self: *const Entry) bool {
        return (c.al_get_fs_entry_mode(self.entry) & Mode.ISDIR) != 0;
    }

    pub fn isFile(self: *const Entry) bool {
        return (c.al_get_fs_entry_mode(self.entry) & Mode.ISFILE) != 0;
    }

    pub fn size(self: *const Entry) i64 {
        return c.al_get_fs_entry_size(self.entry);
    }

    pub fn atime(self: *const Entry) i64 {
        return @intCast(c.al_get_fs_entry_atime(self.entry));
    }

    pub fn mtime(self: *const Entry) i64 {
        return @intCast(c.al_get_fs_entry_mtime(self.entry));
    }

    pub fn ctime(self: *const Entry) i64 {
        return @intCast(c.al_get_fs_entry_ctime(self.entry));
    }

    pub fn update(self: *Entry) bool {
        return c.al_update_fs_entry(self.entry);
    }

    pub fn remove(self: *Entry) bool {
        return c.al_remove_fs_entry(self.entry);
    }

    /// Open this entry as a directory for iteration.
    pub fn openDirectory(self: *Entry) bool {
        return c.al_open_directory(self.entry);
    }

    /// Read the next child entry, or null at end of directory.
    pub fn readDirectory(self: *Entry) ?Entry {
        const e = c.al_read_directory(self.entry);
        return if (e) |ptr| Entry.fromCPointer(ptr) else null;
    }

    pub fn closeDirectory(self: *Entry) bool {
        return c.al_close_directory(self.entry);
    }
};

test "refAllDecls" {
    std.testing.refAllDecls(Entry);
}
