const std = @import("std");
const c = @import("c");

/// Errors thrown by system-level initialisation.
pub const SystemError = error{ InitFailed };

/// Initialise the Allegro system. Call once at program start.
/// Equivalent to Allegro's `al_init()` / `al_install_system(ALLEGRO_VERSION_INT, NULL)`.
pub fn init() !void {
    if (!c.al_install_system(c.ALLEGRO_VERSION_INT, null)) return SystemError.InitFailed;
}

/// Shut down the Allegro system. Call at program exit (usually redundant because
/// a `null` atexit callback is installed by `init`, but exposed for completeness).
pub fn uninstall() void {
    c.al_uninstall_system();
}

pub fn isInstalled() bool {
    return c.al_is_system_installed();
}

/// The installed Allegro version as a packed integer.
/// Use `versionToString` to render it.
pub fn version() u32 {
    return c.al_get_allegro_version();
}

/// Render a packed version integer as e.g. "5.2.9".
pub fn versionToString(v: u32, buf: []u8) []const u8 {
    const major: u8 = @truncate(v >> 24);
    const sub: u8 = @truncate((v >> 16) & 0xff);
    const wip: u8 = @truncate((v >> 8) & 0xff);
    const rel: u8 = @truncate(v & 0xff);
    return std.fmt.bufPrint(buf, "{d}.{d}.{d} r{d}", .{ major, sub, wip, rel }) catch buf[0..0];
}

pub const AppId = enum(c_int) {
    resources_path = c.ALLEGRO_RESOURCES_PATH,
    temp_path = c.ALLEGRO_TEMP_PATH,
    user_data_path = c.ALLEGRO_USER_DATA_PATH,
    user_home_path = c.ALLEGRO_USER_HOME_PATH,
    user_settings_path = c.ALLEGRO_USER_SETTINGS_PATH,
    user_documents_path = c.ALLEGRO_USER_DOCUMENTS_PATH,
    exename_path = c.ALLEGRO_EXENAME_PATH,
};

pub fn setAppName(name: [:0]const u8) void {
    c.al_set_app_name(name.ptr);
}

pub fn setOrgName(name: [:0]const u8) void {
    c.al_set_org_name(name.ptr);
}

pub fn setExeName(path: [:0]const u8) void {
    c.al_set_exe_name(path.ptr);
}

pub fn appName() [:0]const u8 {
    return std.mem.span(c.al_get_app_name());
}

pub fn orgName() [:0]const u8 {
    return std.mem.span(c.al_get_org_name());
}

/// Get a standard path. The caller receives ownership of the returned Path.
pub fn standardPath(id: AppId) ?Path {
    const p = c.al_get_standard_path(@intFromEnum(id));
    return if (p) |ptr| Path.fromCPath(ptr) else null;
}

pub fn currentDirectory() ![]u8 {
    const p = c.al_get_current_directory();
    if (p == null) return error.NoCurrentDirectory;
    const alloc = std.heap.page_allocator;
    const slice = std.mem.span(p);
    const out = try alloc.dupe(u8, slice);
    c.al_free(p);
    return out;
}

pub fn changeDirectory(path: [:0]const u8) bool {
    return c.al_change_directory(path.ptr);
}

/// Sleep for the given number of seconds.
pub fn rest(seconds: f64) void {
    c.al_rest(seconds);
}

const Path = @import("path.zig").Path;

test "refAllDecls" {
    std.testing.refAllDecls(@This());
}
