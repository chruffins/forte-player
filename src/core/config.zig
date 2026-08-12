//! Persistence / settings, ported from `util/config.cpp` of audio-visualizer-cpp.
//!
//! Cleaned-up and kept coupled to Allegro 5 on purpose:
//!   * The INI store is Allegro's config addon (`al.config`).
//!   * User config/data/cache dirs come from `al_get_standard_path` (which
//!     already implements XDG on Linux / AppData on Windows), so the C++
//!     `#ifdef`-heavy, hand-rolled ENV/path handling is gone.
//!   * Directory creation and existence checks go through `al.filesystem`.
//!
//! This deliberately avoids `std.fs` (deprecated in the 0.17-dev snapshot in
//! favor of the `std.Io` model), which also keeps us coupled to Allegro.

const std = @import("std");
const al = @import("allegro");

pub const app_name = "forte-player";

const path_buf_size = std.Io.Dir.max_path_bytes;

/// Call once at startup so `al_get_standard_path` returns app-scoped dirs.
pub fn initAppIdentity() void {
    al.system.setAppName(app_name);
}

// ---------------------------------------------------------------------------
// Path policy
// ---------------------------------------------------------------------------

/// Render an Allegro standard path (user settings, data, temp, home, ...) into
/// `buf`, ensure it exists, and return it. The returned slice aliases `buf`.
pub fn standardDir(id: al.system.AppId, buf: []u8) ![]const u8 {
    var p = al.system.standardPath(id) orelse return error.PathUnavailable;
    defer p.destroy();
    const s = p.cstr(buf, '/') orelse return error.PathTooLong;
    ensureDirs(s);
    return s;
}

pub fn configDirectory(buf: []u8) ![]const u8 {
    return standardDir(.user_settings_path, buf);
}
pub fn dataDirectory(buf: []u8) ![]const u8 {
    return standardDir(.user_data_path, buf);
}
pub fn cacheDirectory(buf: []u8) ![]const u8 {
    return standardDir(.temp_path, buf);
}

/// config.ini under the config directory (allocator-owned, sentinel-terminated).
pub fn configFilePath(allocator: std.mem.Allocator) ![:0]u8 {
    var dir_buf: [path_buf_size]u8 = undefined;
    const dir = trimTrailingSlash(try configDirectory(&dir_buf));
    return allocPrintZ(allocator, "{s}/config.ini", .{dir});
}

pub fn databasePath(allocator: std.mem.Allocator) ![:0]u8 {
    var dir_buf: [path_buf_size]u8 = undefined;
    const dir = trimTrailingSlash(try dataDirectory(&dir_buf));
    return allocPrintZ(allocator, "{s}/music.db", .{dir});
}

pub fn discordTokenPath(allocator: std.mem.Allocator) ![:0]u8 {
    var dir_buf: [path_buf_size]u8 = undefined;
    const dir = trimTrailingSlash(try configDirectory(&dir_buf));
    return allocPrintZ(allocator, "{s}/discord_tokens.txt", .{dir});
}

/// Relative-to-executable asset directories, most specific first.
const exe_asset_roots = [_][]const u8{ "../share/audiovis/assets", "../assets", "assets" };

/// The first existing asset root, or `<exe_dir>/../assets` as a fallback.
pub fn assetRoot(buf: []u8) ![]const u8 {
    var exe_buf: [path_buf_size]u8 = undefined;
    const exe = try exeDirectory(&exe_buf);

    for (exe_asset_roots) |rel| {
        const full = std.fmt.bufPrint(buf, "{s}/{s}", .{ exe, rel }) catch continue;
        if (isDirectory(full)) return full;
    }
    const sys = "/usr/share/audiovis/assets";
    if (isDirectory(sys)) return sys;

    return std.fmt.bufPrint(buf, "{s}/../assets", .{exe}) catch error.PathTooLong;
}

/// Resolve a (possibly `assets/`-prefixed) path against the first root that
/// contains it. Returns an allocator-owned, sentinel-terminated string.
pub fn resolveAssetPath(allocator: std.mem.Allocator, relative_path: []const u8) ![:0]u8 {
    const rel = normalizeAssetRelativePath(relative_path);

    var exe_buf: [path_buf_size]u8 = undefined;
    const exe = try exeDirectory(&exe_buf);
    var root_buf: [path_buf_size]u8 = undefined;
    const root = try assetRoot(&root_buf);

    var cand_base_buf: [path_buf_size]u8 = undefined;
    var cand_buf: [path_buf_size]u8 = undefined;

    for (exe_asset_roots) |root_rel| {
        const base = std.fmt.bufPrint(&cand_base_buf, "{s}/{s}", .{ exe, root_rel }) catch continue;
        if (!isDirectory(base)) continue;
        const candidate = std.fmt.bufPrint(&cand_buf, "{s}/{s}", .{ base, rel }) catch continue;
        if (fileExists(candidate)) {
            return allocPrintZ(allocator, "{s}/{s}", .{ base, rel });
        }
    }
    return allocPrintZ(allocator, "{s}/{s}", .{ root, rel });
}

// ---------------------------------------------------------------------------
// The config file itself (Allegro INI)
// ---------------------------------------------------------------------------

pub const Config = struct {
    inner: al.config.Config,

    pub fn create() Config {
        return .{ .inner = al.config.Config.create() };
    }

    pub fn destroy(self: *Config) void {
        self.inner.destroy();
    }

    /// Load from `path`, replacing whatever this instance held. Returns false if
    /// the file can't be read.
    pub fn load(self: *Config, path: [:0]const u8) bool {
        const loaded = al.config.Config.load(path) orelse return false;
        self.inner.destroy();
        self.inner = loaded;
        return true;
    }

    /// If `path` doesn't exist, write defaults there, then load it.
    pub fn loadOrCreate(self: *Config, path: [:0]const u8) !void {
        if (!al.filesystem.filenameExists(path)) {
            self.generateDefaults();
            if (!self.inner.save(path)) return error.SaveFailed;
        }
        if (!self.load(path)) return error.LoadFailed;
    }

    /// Fill with default values (mirrors generateDefaultConfig()).
    pub fn generateDefaults(self: *Config) void {
        var home_buf: [path_buf_size]u8 = undefined;
        const home = standardDir(.user_home_path, &home_buf) catch "~";

        var music_buf: [path_buf_size:0]u8 = undefined;
        const music = std.fmt.bufPrint(&music_buf, "{s}/Music", .{trimTrailingSlash(home)}) catch null;
        if (music) |m| {
            music_buf[m.len] = 0;
            self.setStr("paths", "music_directory", music_buf[0..m.len :0]);
        } else {
            self.setStr("paths", "music_directory", "~/Music");
        }
        self.setStr("paths", "icon_path", "logotransparent.png");
        self.setInt("display", "width", 1024);
        self.setInt("display", "height", 300);
        self.setInt("discord", "application_id", 0);
        self.setInt("audio", "volume_percent", 100);
    }

    // ---- typed accessors ----

    pub fn get(self: *const Config, section: [:0]const u8, key: [:0]const u8) ?[:0]const u8 {
        return self.inner.getValue(section, key);
    }

    pub fn getStr(self: *const Config, section: [:0]const u8, key: [:0]const u8, default: [:0]const u8) [:0]const u8 {
        return self.get(section, key) orelse default;
    }

    pub fn getInt(self: *const Config, section: [:0]const u8, key: [:0]const u8, default: i64) i64 {
        const v = self.get(section, key) orelse return default;
        return std.fmt.parseInt(i64, v, 10) catch default;
    }

    pub fn setStr(self: *Config, section: [:0]const u8, key: [:0]const u8, value: [:0]const u8) void {
        self.inner.setValue(section, key, value);
    }

    pub fn setInt(self: *Config, section: [:0]const u8, key: [:0]const u8, value: i64) void {
        var buf: [32:0]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d}", .{value}) catch unreachable;
        buf[s.len] = 0;
        self.inner.setValue(section, key, buf[0..s.len :0]);
    }

    pub fn save(self: *const Config, path: [:0]const u8) bool {
        return self.inner.save(path);
    }

    // ---- app-level conveniences ----

    pub fn getMusicDirectory(self: *const Config) [:0]const u8 {
        return self.getStr("paths", "music_directory", "~/Music");
    }

    pub fn getDiscordApplicationId(self: *const Config) u64 {
        const v = self.get("discord", "application_id") orelse return 0;
        return std.fmt.parseInt(u64, v, 10) catch 0;
    }

    pub fn getDisplayWidth(self: *const Config) i32 {
        return @intCast(clamp(self.getInt("display", "width", 800), 320, 8192));
    }

    pub fn getDisplayHeight(self: *const Config) i32 {
        return @intCast(clamp(self.getInt("display", "height", 300), 200, 8192));
    }

    pub fn getVolumePercent(self: *const Config) i32 {
        return @intCast(clamp(self.getInt("audio", "volume_percent", 100), 0, 100));
    }

    pub fn setVolumePercent(self: *Config, percent: i32) void {
        self.setInt("audio", "volume_percent", clamp(percent, 0, 100));
    }
};

// ---------------------------------------------------------------------------
// Private helpers
// ---------------------------------------------------------------------------

fn clamp(v: i64, lo: i64, hi: i64) i64 {
    return @min(@max(v, lo), hi);
}

/// Allocate a sentinel-terminated, formatted string (allocPrintZ was
/// removed in this 0.17-dev snapshot). Caller owns the result.
fn allocPrintZ(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) ![:0]u8 {
    const s = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(s);
    const z = try allocator.alloc(u8, s.len + 1);
    @memcpy(z[0..s.len], s);
    z[s.len] = 0;
    return z[0..s.len :0];
}

/// Strip a leading "../assets/" or "assets/" prefix.
fn normalizeAssetRelativePath(rel: []const u8) []const u8 {
    if (std.mem.startsWith(u8, rel, "../assets/")) return rel[10..];
    if (std.mem.startsWith(u8, rel, "assets/")) return rel[7..];
    return rel;
}

/// The directory containing the running executable.
fn exeDirectory(buf: []u8) ![]const u8 {
    var p = al.system.standardPath(.exename_path) orelse return error.PathUnavailable;
    defer p.destroy();
    const s = p.cstr(buf, '/') orelse return error.PathTooLong;
    // Drop the trailing filename component.
    if (std.mem.lastIndexOfScalar(u8, s, '/')) |idx| {
        if (idx > 0) return s[0..idx];
    }
    return s;
}

/// Strip any trailing path separators (Allegro standard paths end in '/').
fn trimTrailingSlash(s: []const u8) []const u8 {
    if (s.len == 0) return s;
    const last_idx = s.len - 1;
    if (s[last_idx] != '/') return s;
    var end = last_idx;
    while (end > 1 and s[end - 1] == '/') : (end -= 1) {}
    return s[0..end];
}

/// Copy `path` into a sentinel-terminated buffer on the caller's stack.
fn toSentinel(path: []const u8) ![:0]const u8 {
    var buf: [path_buf_size:0]u8 = undefined;
    if (path.len >= buf.len) return error.PathTooLong;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return buf[0..path.len :0];
}

fn isDirectory(path: []const u8) bool {
    var entry = al.filesystem.Entry.create(toSentinel(path) catch return false) catch return false;
    defer entry.destroy();
    return entry.isDirectory();
}

fn fileExists(path: []const u8) bool {
    return al.filesystem.fsEntryExists(toSentinel(path) catch return false);
}

/// Create `path` and any missing parents. Errors are ignored: on the standard
/// user dirs this is best-effort (XDG parents normally exist).
fn ensureDirs(full: []const u8) void {
    var buf: [path_buf_size:0]u8 = undefined;
    var len: usize = 0;

    if (full.len >= 1 and full[0] == '/') {
        buf[0] = '/';
        len = 1;
    }
    var it = std.mem.splitScalar(u8, full, '/');
    while (it.next()) |part| {
        if (part.len == 0 or len + 1 + part.len >= buf.len) continue;
        buf[len] = '/';
        len += 1;
        @memcpy(buf[len .. len + part.len], part);
        len += part.len;
        buf[len] = 0;
        _ = al.filesystem.makeDirectory(buf[0..len :0]);
    }
}

test "config: save/load round-trip and typed accessors" {
    _ = al.init() catch return error.SkipZigTest;
    const test_path = "/tmp/forte_config_test.ini";
    _ = al.filesystem.removeFilename(test_path);

    var c = Config.create();
    defer c.destroy();
    c.generateDefaults();
    c.setInt("display", "width", 1280);
    c.setInt("display", "height", 720);
    c.setInt("audio", "volume_percent", 55);
    c.setStr("paths", "music_directory", "/home/nobody/music");
    try std.testing.expect(c.save(test_path));
    try std.testing.expect(al.filesystem.filenameExists(test_path));

    var c2 = Config.create();
    defer c2.destroy();
    try c2.loadOrCreate(test_path);

    try std.testing.expectEqualStrings("/home/nobody/music", c2.getMusicDirectory());
    try std.testing.expectEqual(@as(i64, 1280), c2.getInt("display", "width", 0));
    try std.testing.expectEqual(@as(i32, 55), c2.getVolumePercent());
    try std.testing.expect(c2.getDisplayWidth() == 1280);

    // clamping
    c2.setVolumePercent(200);
    try std.testing.expectEqual(@as(i32, 100), c2.getVolumePercent());
    c2.setVolumePercent(-5);
    try std.testing.expectEqual(@as(i32, 0), c2.getVolumePercent());

    _ = al.filesystem.removeFilename(test_path);
}

test "config: getInt falls back to default on missing/parse-error" {
    var c = Config.create();
    defer c.destroy();
    // no "missing" key set
    try std.testing.expectEqual(@as(i64, 42), c.getInt("nope", "nope", 42));
    // parse error -> default
    c.setStr("s", "k", "not-a-number");
    try std.testing.expectEqual(@as(i64, 7), c.getInt("s", "k", 7));
}
