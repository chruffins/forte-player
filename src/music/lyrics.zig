//! Local sidecar lyrics parsing and read-only discovery.
const std = @import("std");

pub const Line = struct {
    text: []const u8,
    time: ?f64 = null,
};

pub const Lyrics = struct {
    lines: []const Line,
    pub fn activeLine(self: Lyrics, position: f64) ?usize {
        if (!std.math.isFinite(position)) return null;
        var active: ?usize = null;
        var active_time: f64 = -1;
        for (self.lines, 0..) |line, i| {
            const t = line.time orelse continue;
            if (t <= position and (active == null or t > active_time or (t == active_time and i > active.?))) {
                active = i;
                active_time = t;
            }
        }
        return active;
    }
};

/// Parse LRC timestamped lines and ordinary text lines. Invalid timestamp
/// tokens are ignored; lines with no valid tag remain plain lyric text.
pub fn parse(allocator: std.mem.Allocator, input: []const u8) !Lyrics {
    var lines: std.ArrayList(Line) = .empty;
    var iter = std.mem.splitScalar(u8, input, '\n');
    while (iter.next()) |raw| {
        const row = std.mem.trimEnd(u8, raw, "\r \t");
        if (row.len == 0) continue;
        var times: std.ArrayList(f64) = .empty;
        var cursor: usize = 0;
        while (cursor < row.len and row[cursor] == '[') {
            const close = std.mem.indexOfScalarPos(u8, row, cursor + 1, ']') orelse break;
            if (timestamp(row[cursor + 1 .. close])) |t| try times.append(allocator, t);
            cursor = close + 1;
        }
        const text = std.mem.trim(u8, row[cursor..], " \t");
        if (text.len == 0) continue;
        if (times.items.len == 0) {
            // Discard metadata directives such as [ar:Artist], retain other
            // malformed/untagged text as a normal lyric line.
            if (std.mem.startsWith(u8, row, "[ar:") or std.mem.startsWith(u8, row, "[ti:") or std.mem.startsWith(u8, row, "[al:") or std.mem.startsWith(u8, row, "[by:")) continue;
            try lines.append(allocator, .{ .text = try allocator.dupe(u8, text) });
        } else {
            for (times.items) |t| {
                try lines.append(allocator, .{ .text = try allocator.dupe(u8, text), .time = t });
            }
        }
        times.deinit(allocator);
    }
    // LRC timestamps need not be ordered in source text. Stable insertion sort
    // leaves later duplicate-time entries as the active line.
    var i: usize = 1;
    while (i < lines.items.len) : (i += 1) {
        var j = i;
        while (j > 0) : (j -= 1) {
            const a = lines.items[j - 1].time;
            const b = lines.items[j].time;
            if (a == null or b == null or a.? <= b.?) break;
            std.mem.swap(Line, &lines.items[j - 1], &lines.items[j]);
        }
    }
    return .{ .lines = try lines.toOwnedSlice(allocator) };
}

fn timestamp(value: []const u8) ?f64 {
    const colon = std.mem.indexOfScalar(u8, value, ':') orelse return null;
    const minutes = std.fmt.parseInt(u32, value[0..colon], 10) catch return null;
    const secs_part = value[colon + 1 ..];
    const dot = std.mem.indexOfScalar(u8, secs_part, '.') orelse secs_part.len;
    const seconds = std.fmt.parseInt(u8, secs_part[0..dot], 10) catch return null;
    if (seconds >= 60) return null;
    var fraction: f64 = 0;
    if (dot < secs_part.len) {
        const digits = secs_part.len - dot - 1;
        if (digits == 0 or digits > 3) return null;
        const value_int = std.fmt.parseInt(u16, secs_part[dot + 1 ..], 10) catch return null;
        const scale: f64 = if (digits == 1) 10 else if (digits == 2) 100 else 1000;
        fraction = @as(f64, @floatFromInt(value_int)) / scale;
    }
    return @as(f64, @floatFromInt(minutes)) * 60 + @as(f64, @floatFromInt(seconds)) + fraction;
}

const CFile = opaque {};
extern "c" fn fopen([*:0]const u8, [*:0]const u8) ?*CFile;
extern "c" fn fread(?[*]u8, usize, usize, *CFile) usize;
extern "c" fn fclose(*CFile) c_int;

/// Read at most 1 MiB from an existing sibling `.lrc` or `.txt` file.
/// Discovery only derives same-basename paths, opens read-only, and never creates files.
pub fn loadSidecar(allocator: std.mem.Allocator, track_path: []const u8) !?Lyrics {
    const slash = std.mem.lastIndexOfAny(u8, track_path, "/\\") orelse 0;
    const dot = std.mem.lastIndexOfScalar(u8, track_path, '.') orelse track_path.len;
    const stem_end = if (dot > slash) dot else track_path.len;
    for ([_][]const u8{".lrc", ".txt"}) |extension| {
        const path = try std.fmt.allocPrintSentinel(allocator, "{s}{s}", .{ track_path[0..stem_end], extension }, 0);
        defer allocator.free(path);
        const file = fopen(path, "rb") orelse continue;
        defer _ = fclose(file);
        const bytes = try allocator.alloc(u8, 1024 * 1024);
        defer allocator.free(bytes);
        const count = fread(bytes.ptr, 1, bytes.len, file);
        if (count == 0) continue;
        return try parse(allocator, bytes[0..count]);
    }
    return null;
}

test "LRC parses multiple timestamps, malformed input and active lookup" {
    const parsed = try parse(std.testing.allocator, "[00:02.50][00:01.2]hello\n[broken]bad tag\n[ar:artist]\n[00:03.00]last\n");
    defer {
        for (parsed.lines) |line| std.testing.allocator.free(line.text);
        std.testing.allocator.free(parsed.lines);
    }
    try std.testing.expectEqual(@as(usize, 4), parsed.lines.len);
    try std.testing.expectEqualStrings("hello", parsed.lines[0].text);
    try std.testing.expectEqual(@as(?usize, null), parsed.activeLine(0.9));
    try std.testing.expectEqual(@as(?usize, 0), parsed.activeLine(1.2));
    try std.testing.expectEqual(@as(?usize, 1), parsed.activeLine(2.5));
    try std.testing.expectEqual(@as(?usize, 3), parsed.activeLine(3));
}

test "plain text is preserved and has no timed active line" {
    const parsed = try parse(std.testing.allocator, "first\n\n second \r\n");
    defer {
        for (parsed.lines) |line| std.testing.allocator.free(line.text);
        std.testing.allocator.free(parsed.lines);
    }
    try std.testing.expectEqual(@as(usize, 2), parsed.lines.len);
    try std.testing.expectEqualStrings("second", parsed.lines[1].text);
    try std.testing.expectEqual(@as(?usize, null), parsed.activeLine(30));
}
