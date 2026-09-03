const std = @import("std");
const c = @import("c");

pub const FileError = error{ OpenFailed, NoFPPath };

pub const Seek = struct {
    pub const SET = c.ALLEGRO_SEEK_SET;
    pub const CUR = c.ALLEGRO_SEEK_CUR;
    pub const END = c.ALLEGRO_SEEK_END;
};

/// Use the standard native filesystem as the active low-level file interface.
pub fn setStandardInterface() void {
    c.al_set_standard_file_interface();
}

/// Use the PhysFS addon as the file interface.
pub fn setPhysfsInterface() void {
    c.al_set_physfs_file_interface();
}

pub fn setNewFileInterface(iface: *const c.ALLEGRO_FILE_INTERFACE) void {
    c.al_set_new_file_interface(iface);
}

pub fn getNewFileInterface() ?*const c.ALLEGRO_FILE_INTERFACE {
    return c.al_get_new_file_interface();
}

/// A file handle usable for reading, writing or seeking through the Allegro
/// virtual filesystem.
pub const File = struct {
    file: *c.ALLEGRO_FILE,

    pub fn open(path: [:0]const u8, mode: [:0]const u8) !File {
        const f = c.al_fopen(path.ptr, mode.ptr) orelse return FileError.OpenFailed;
        return .{ .file = f };
    }

    /// Open a slice of an existing file (used for sub-files / archives).
    pub fn openSlice(parent: *File, initialSize: usize, mode: [:0]const u8) !File {
        const f = c.al_fopen_slice(parent.file, initialSize, mode.ptr) orelse return FileError.OpenFailed;
        return .{ .file = f };
    }

    /// Wrap an already-open native file descriptor as an Allegro file.
    pub fn openFd(fd: i32, mode: [:0]const u8) !File {
        const f = c.al_fopen_fd(fd, mode.ptr) orelse return FileError.OpenFailed;
        return .{ .file = f };
    }

    /// Open a filesystem entry (from the filesystem module) as a File.
    pub fn openFsEntry(entry: *const anyopaque, mode: [:0]const u8) !File {
        const f = c.al_open_fs_entry(@ptrCast(@constCast(entry)), mode.ptr) orelse return FileError.OpenFailed;
        return .{ .file = f };
    }

    const Str = @import("utf8.zig").String;

    /// Read a line as a Unicode string. The returned String must be destroyed.
    pub fn readLineUstr(self: *File) ?Str {
        const u = c.al_fget_ustr(self.file);
        return if (u) |us| Str.fromCPtr(us) else null;
    }

    /// Open a memory region as a readable/writable Allegro file (memfile addon).
    pub fn openMemFile(buffer: *const anyopaque, len: i64, mode: [:0]const u8) !File {
        const f = c.al_open_memfile(@constCast(buffer), len, mode.ptr) orelse return FileError.OpenFailed;
        return .{ .file = f };
    }

    /// Wrap a custom file interface + userdata pointer into an Allegro file handle.
    pub fn createHandle(vtable: *const c.ALLEGRO_FILE_INTERFACE, userdata: ?*anyopaque) !File {
        const f = c.al_create_file_handle(vtable, userdata) orelse return FileError.OpenFailed;
        return .{ .file = f };
    }

    pub fn getUserData(self: *File) ?*anyopaque {
        return c.al_get_file_userdata(self.file);
    }

    /// Open a file through a specific low-level file interface.
    pub fn openInterface(vtable: *const c.ALLEGRO_FILE_INTERFACE, path: [:0]const u8, mode: [:0]const u8) !File {
        const f = c.al_fopen_interface(vtable, path.ptr, mode.ptr) orelse return FileError.OpenFailed;
        return .{ .file = f };
    }

    pub fn close(self: *File) bool {
        return c.al_fclose(self.file);
    }

    pub fn read(self: *File, buf: []u8) usize {
        return c.al_fread(self.file, buf.ptr, buf.len);
    }

    /// Read up to `buf.len` bytes; returns the number actually read.
    pub fn readExact(self: *File, buf: []u8) !void {
        const n = c.al_fread(self.file, buf.ptr, buf.len);
        if (n != buf.len) return error.ShortRead;
    }

    pub fn write(self: *File, data: []const u8) usize {
        return c.al_fwrite(self.file, data.ptr, data.len);
    }

    pub fn writeAll(self: *File, data: []const u8) !void {
        const n = c.al_fwrite(self.file, data.ptr, data.len);
        if (n != data.len) return error.ShortWrite;
    }

    pub fn fgetc(self: *File) ?u8 {
        const ch = c.al_fgetc(self.file);
        if (ch < 0) return null;
        return @intCast(ch);
    }

    pub fn fputc(self: *File, ch: u8) bool {
        return c.al_fputc(self.file, ch) >= 0;
    }

    pub fn fputs(self: *File, s: [:0]const u8) bool {
        return c.al_fputs(self.file, s.ptr) >= 0;
    }

    /// Read a single line (up to `max` bytes including NUL) into `buf`.
    pub fn fgets(self: *File, buf: []u8) ?[:0]u8 {
        const p = c.al_fgets(self.file, buf.ptr, buf.len);
        return if (p) |_| std.mem.span(buf[0..].ptr) else null;
    }

    pub fn ungetc(self: *File, ch: u8) bool {
        return c.al_fungetc(self.file, ch) >= 0;
    }

    pub fn flush(self: *File) bool {
        return c.al_fflush(self.file);
    }

    pub fn getError(self: *File) i32 {
        return c.al_ferror(self.file);
    }

    pub fn clearError(self: *File) void {
        c.al_fclearerr(self.file);
    }

    pub fn eof(self: *File) bool {
        return c.al_feof(self.file);
    }

    pub fn errorMessage(self: *File) [:0]const u8 {
        return std.mem.span(c.al_ferrmsg(self.file));
    }

    pub fn ftell(self: *File) i64 {
        return c.al_ftell(self.file);
    }

    pub fn fseek(self: *File, offset: i64, whence: i32) bool {
        return c.al_fseek(self.file, offset, whence);
    }

    pub fn size(self: *File) i64 {
        return c.al_fsize(self.file);
    }

    // -- Big/little endian helpers --

    pub fn read16be(self: *File) i16 {
        return c.al_fread16be(self.file);
    }

    pub fn read16le(self: *File) i16 {
        return c.al_fread16le(self.file);
    }

    pub fn read32be(self: *File) i32 {
        return c.al_fread32be(self.file);
    }

    pub fn read32le(self: *File) i32 {
        return c.al_fread32le(self.file);
    }

    pub fn write16be(self: *File, v: i16) usize {
        return c.al_fwrite16be(self.file, v);
    }

    pub fn write16le(self: *File, v: i16) usize {
        return c.al_fwrite16le(self.file, v);
    }

    pub fn write32be(self: *File, v: i32) usize {
        return c.al_fwrite32be(self.file, v);
    }

    pub fn write32le(self: *File, v: i32) usize {
        return c.al_fwrite32le(self.file, v);
    }
};

test "refAllDecls" {
    std.testing.refAllDecls(File);
}
