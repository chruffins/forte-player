//! Read-only library health reporting. This deliberately does not share the
//! mutating scanner's reconciliation path.
const std = @import("std");
const al = @import("allegro");
const scanner = @import("scanner.zig");
const taglib_meta = @import("taglib_meta.zig");

pub const CancelFn = *const fn (ctx: *anyopaque) bool;
pub const ProgressFn = *const fn (ctx: *anyopaque, scanned: usize) void;
pub const Options = struct { ctx: ?*anyopaque = null, should_cancel: ?CancelFn = null, on_progress: ?ProgressFn = null };
pub const MissingTag = enum { title, artist, album };
pub const Finding = union(enum) {
    missing_file: []const u8,
    duplicate: []const []const u8,
    missing_tag: struct { path: []const u8, tag: MissingTag },
};
pub const Report = struct {
    allocator: std.mem.Allocator,
    findings: std.ArrayList(Finding) = .empty,
    scanned: usize = 0,
    pub fn deinit(self: *Report) void {
        for (self.findings.items) |finding| switch (finding) {
            .missing_file => |path| self.allocator.free(path),
            .missing_tag => |value| self.allocator.free(value.path),
            .duplicate => |paths| {
                for (paths) |path| self.allocator.free(path);
                self.allocator.free(paths);
            },
        };
        self.findings.deinit(self.allocator);
    }
};
const FileInfo = struct { path: []const u8, size: i64, hash: u64 };
const audio_exts = [_][]const u8{ ".mp3", ".flac", ".ogg", ".wav", ".m4a", ".mp4", ".aac", ".opus" };

/// Reconcile known paths only in memory; any traversal error aborts the report,
/// so inaccessible roots/subtrees can never be misreported as missing files.
pub fn generate(allocator: std.mem.Allocator, root: []const u8, known_paths: []const []const u8, options: Options) !Report {
    var report = Report{ .allocator = allocator };
    errdefer report.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var files: std.ArrayList(FileInfo) = .empty;
    try walk(a, root, &files, &report, options);

    var seen = std.StringHashMap(void).init(a);
    for (files.items) |file| try seen.put(file.path, {});
    for (known_paths) |path| if (!seen.contains(path)) {
        try report.findings.append(allocator, .{ .missing_file = try allocator.dupe(u8, path) });
    };

    var i: usize = 0;
    while (i < files.items.len) : (i += 1) {
        var already_grouped = false;
        for (files.items[0..i]) |prior| if (prior.size == files.items[i].size and prior.hash == files.items[i].hash) {
            already_grouped = true;
            break;
        };
        if (already_grouped) continue;
        var matches: std.ArrayList([]const u8) = .empty;
        try matches.append(a, files.items[i].path);
        var j = i + 1;
        while (j < files.items.len) : (j += 1) {
            if (files.items[i].size == files.items[j].size and files.items[i].hash == files.items[j].hash)
                try matches.append(a, files.items[j].path);
        }
        if (matches.items.len > 1) {
            var owned = try allocator.alloc([]const u8, matches.items.len);
            for (matches.items, 0..) |path, index| owned[index] = try allocator.dupe(u8, path);
            try report.findings.append(allocator, .{ .duplicate = owned });
        }
    }
    return report;
}

fn walk(a: std.mem.Allocator, dir: []const u8, files: *std.ArrayList(FileInfo), report: *Report, options: Options) !void {
    if (options.should_cancel) |cancel| if (cancel(options.ctx orelse return error.InvalidOptions)) return error.Cancelled;
    var dirbuf: [std.Io.Dir.max_path_bytes:0]u8 = undefined;
    const dirz = sentinel(&dirbuf, dir) orelse return error.PathTooLong;
    var entry = al.filesystem.Entry.create(dirz) catch return error.FilesystemFailure;
    defer entry.destroy();
    if (!entry.update() or !entry.isDirectory() or !entry.openDirectory()) return error.FilesystemFailure;
    defer _ = entry.closeDirectory();
    while (true) {
        if (options.should_cancel) |cancel| if (cancel(options.ctx orelse return error.InvalidOptions)) return error.Cancelled;
        const child = entry.readDirectory() orelse break;
        var c = child;
        defer c.destroy();
        const path = c.name();
        const base = basename(path);
        if (std.mem.eql(u8, base, ".") or std.mem.eql(u8, base, "..")) continue;
        if (c.isDirectory()) {
            try walk(a, path, files, report, options);
        } else if (isAudio(base)) {
            const owned_path = try a.dupe(u8, path);
            const size = c.size();
            try files.append(a, .{ .path = owned_path, .size = size, .hash = try fullHash(path, size) });
            report.scanned += 1;
            if (options.on_progress) |progress| progress(options.ctx orelse return error.InvalidOptions, report.scanned);
            const tags = taglib_meta.rawTagSignals(path) orelse taglib_meta.RawTagSignals{};
            if (!tags.title) try report.findings.append(report.allocator, .{ .missing_tag = .{ .path = try report.allocator.dupe(u8, path), .tag = .title } });
            if (!tags.artist) try report.findings.append(report.allocator, .{ .missing_tag = .{ .path = try report.allocator.dupe(u8, path), .tag = .artist } });
            if (!tags.album) try report.findings.append(report.allocator, .{ .missing_tag = .{ .path = try report.allocator.dupe(u8, path), .tag = .album } });
        }
    }
}

fn fullHash(path: []const u8, size: i64) !u64 {
    var pathbuf: [std.Io.Dir.max_path_bytes:0]u8 = undefined;
    const pathz = sentinel(&pathbuf, path) orelse return error.PathTooLong;
    var file = al.file.File.open(pathz, "r") catch return error.FilesystemFailure;
    defer _ = file.close();
    var hash = std.hash.Wyhash.init(0);
    var buffer: [16384]u8 = undefined;
    var total: i64 = 0;
    while (true) {
        const count = file.read(&buffer);
        if (count == 0) break;
        total += @intCast(count);
        hash.update(buffer[0..count]);
    }
    if (total != size) return error.FilesystemFailure;
    return hash.final();
}
fn sentinel(buf: [:0]u8, value: []const u8) ?[:0]const u8 {
    if (value.len >= buf.len) return null;
    @memcpy(buf[0..value.len], value);
    buf[value.len] = 0;
    return buf[0..value.len :0];
}
fn basename(path: []const u8) []const u8 {
    return path[(if (std.mem.lastIndexOfAny(u8, path, "/\\")) |index| index + 1 else 0)..];
}
fn isAudio(name: []const u8) bool {
    for (audio_exts) |ext| if (std.ascii.endsWithIgnoreCase(name, ext)) return true;
    return false;
}

test "tag presence does not treat display fallback values as tags" {
    const raw = taglib_meta.RawTagSignals{};
    try std.testing.expect(!raw.title and !raw.artist and !raw.album);
}

test "audio extension detection" {
    try std.testing.expect(isAudio("song.FLAC"));
    try std.testing.expect(!isAudio("song.txt"));
}

fn cancelImmediately(_: *anyopaque) bool {
    return true;
}
test "health report cancellation is distinct from an empty successful report" {
    var context: u8 = 0;
    try std.testing.expectError(error.Cancelled, generate(std.testing.allocator, "/path/not/opened", &.{}, .{
        .ctx = &context,
        .should_cancel = cancelImmediately,
    }));
}

test "an inaccessible root is an error, not a clean missing-file report" {
    try std.testing.expectError(error.FilesystemFailure, generate(std.testing.allocator, "/path/that/does/not/exist/forte", &.{"known.mp3"}, .{}));
}
