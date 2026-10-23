//! Local, single-user control endpoint shared by the GUI and TUI.
//! Requests are polled and executed on the frontend's owning thread; the IPC
//! layer never touches the engine, database, or queue from a worker thread.

const std = @import("std");
const c = @import("control_c");
const app_mod = @import("../app.zig");

const max_message = 8192;
const allocator = std.heap.page_allocator;

pub const Server = struct {
    handle: ?*anyopaque,

    pub fn init() ?Server {
        var endpoint: [512]u8 = @splat(0);
        const length = c.forte_control_endpoint(&endpoint, endpoint.len);
        if (length <= 0) {
            std.log.err("could not determine the local player-control endpoint", .{});
            return null;
        }
        endpoint[@intCast(length)] = 0;
        const handle = c.forte_control_server_create(@ptrCast(&endpoint)) orelse {
            std.log.warn("local player-control endpoint is unavailable; MCP control is disabled", .{});
            return null;
        };
        std.log.info("local player-control endpoint ready", .{});
        return .{ .handle = handle };
    }

    pub fn deinit(self: *Server) void {
        if (self.handle) |handle| c.forte_control_server_destroy(handle);
        self.handle = null;
    }

    /// Process at most one complete request. Called from each frontend's main
    /// event loop so player mutations remain serialized with UI operations.
    pub fn poll(self: *Server, app: *app_mod.App) void {
        const handle = self.handle orelse return;
        var input: [max_message]u8 = undefined;
        const length = c.forte_control_server_poll(handle, &input, input.len);
        if (length <= 0) return;
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const response = handleRequest(arena.allocator(), app, input[0..@intCast(length)]) catch |err| blk: {
            break :blk wireError(arena.allocator(), @errorName(err)) catch "{\"v\":1,\"ok\":false,\"error\":\"internal error\"}";
        };
        _ = c.forte_control_server_reply(handle, response.ptr, response.len);
    }
};

const Status = struct {
    playing: bool,
    title: []const u8,
    artist: []const u8,
    album: []const u8,
    position_seconds: f64,
    duration_seconds: f64,
    volume: f32,
    queue_length: usize,
};

const SearchHit = struct { song_id: i64, title: []const u8, artist: []const u8, album: []const u8 };
const OkResult = struct { success: bool = true, song_id: ?i64 = null };

fn handleRequest(a: std.mem.Allocator, app: *app_mod.App, input: []const u8) ![]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, a, input, .{ .allocate = .alloc_always }) catch return wireError(a, "invalid JSON request");
    const root = parsed.value;
    if (root != .object) return wireError(a, "request must be a JSON object");
    const version_value = root.object.get("v") orelse return wireError(a, "missing protocol version");
    if (version_value != .integer or version_value.integer != 1) return wireError(a, "unsupported protocol version");
    const method_value = root.object.get("method") orelse return wireError(a, "missing method");
    if (method_value != .string) return wireError(a, "method must be a string");
    const params = root.object.get("params") orelse .null;

    if (std.mem.eql(u8, method_value.string, "status")) {
        var title: []const u8 = "";
        var artist: []const u8 = "";
        var album: []const u8 = "";
        if (app.has_current_path) {
            if (app.lib.songIdByPath(app.current_path)) |id| {
                if (app.lib.getSongById(id)) |song| title = song.title;
                if (app.db.getSongContextWithAllocator(a, id) catch null) |context| {
                    artist = context.artist;
                    album = context.album;
                }
            }
        }
        const result = Status{
            .playing = app.engine.isPlaying(),
            .title = title,
            .artist = artist,
            .album = album,
            .position_seconds = app.engine.getTime(),
            .duration_seconds = app.engine.getDuration(),
            .volume = app.engine.getGain(),
            .queue_length = app.play_queue.size(),
        };
        return wireSuccess(a, result);
    }

    if (std.mem.eql(u8, method_value.string, "search_library")) {
        const query_value = getParam(params, "query") orelse return wireError(a, "search_library requires query");
        if (query_value != .string or query_value.string.len == 0) return wireError(a, "query must be a non-empty string");
        const displays = app.db.getAllSongDisplaysWithAllocator(a) catch return wireError(a, "could not query the library");
        var hits = std.ArrayList(SearchHit).empty;
        for (displays) |item| {
            if (!containsIgnoreCase(item.title, query_value.string) and
                !containsIgnoreCase(item.artist, query_value.string) and
                !containsIgnoreCase(item.album, query_value.string)) continue;
            hits.append(a, .{ .song_id = item.id, .title = item.title, .artist = item.artist, .album = item.album }) catch return wireError(a, "out of memory");
            if (hits.items.len == 25) break;
        }
        return wireSuccess(a, hits.items);
    }

    if (std.mem.eql(u8, method_value.string, "play_track")) {
        const id_value = getParam(params, "song_id") orelse return wireError(a, "play_track requires song_id");
        if (id_value != .integer or id_value.integer < std.math.minInt(i32) or id_value.integer > std.math.maxInt(i32))
            return wireError(a, "song_id must be a valid library ID");
        const id = id_value.integer;
        const song_index = app.lib.indexOfId(id) orelse return wireError(a, "song_id was not found in the active library");
        const in_queue = for (app.play_queue.items()) |queued_id| {
            if (queued_id == id) break true;
        } else false;
        if (in_queue) {
            _ = app.playSongId(id) catch return wireError(a, "could not start the requested track");
        } else {
            var ids = std.ArrayList(i64).empty;
            defer ids.deinit(a);
            for (0..app.lib.count()) |index| ids.append(a, app.lib.songIdAt(index)) catch return wireError(a, "could not build a library playback queue");
            _ = app.playSongIdsInContext(ids.items, .Individual, -1, song_index) orelse return wireError(a, "could not start the requested track");
        }
        return wireSuccess(a, OkResult{ .song_id = id });
    }

    if (std.mem.eql(u8, method_value.string, "pause")) {
        app.engine.pause();
        return wireSuccess(a, OkResult{});
    }
    if (std.mem.eql(u8, method_value.string, "resume")) {
        app.engine.resumePlayback();
        return wireSuccess(a, OkResult{});
    }
    if (std.mem.eql(u8, method_value.string, "next")) {
        const advanced = app.engine.playNext() catch return wireError(a, "could not advance to the next track");
        if (!advanced) return wireError(a, "there is no next track in the active queue");
        return wireSuccess(a, OkResult{});
    }
    if (std.mem.eql(u8, method_value.string, "previous")) {
        app.engine.playPrevious() catch return wireError(a, "could not play the previous track");
        return wireSuccess(a, OkResult{});
    }
    if (std.mem.eql(u8, method_value.string, "seek")) {
        const value = getParam(params, "seconds") orelse return wireError(a, "seek requires seconds");
        const seconds = number(value) orelse return wireError(a, "seconds must be a finite number");
        if (!std.math.isFinite(seconds) or seconds < 0) return wireError(a, "seconds must be non-negative");
        app.engine.setProgress(seconds);
        return wireSuccess(a, OkResult{});
    }
    if (std.mem.eql(u8, method_value.string, "set_volume")) {
        const value = getParam(params, "volume") orelse return wireError(a, "set_volume requires volume");
        const volume = number(value) orelse return wireError(a, "volume must be a finite number");
        if (!std.math.isFinite(volume) or volume < 0 or volume > 1) return wireError(a, "volume must be between 0 and 1");
        app.engine.setGain(@floatCast(volume));
        app.config.setVolumePercent(@intFromFloat(volume * 100));
        app.saveConfig();
        return wireSuccess(a, OkResult{});
    }

    return wireError(a, "unknown player-control method");
}

fn getParam(params: std.json.Value, name: []const u8) ?std.json.Value {
    if (params != .object) return null;
    return params.object.get(name);
}

fn number(value: std.json.Value) ?f64 {
    return switch (value) {
        .integer => |v| @floatFromInt(v),
        .float => |v| v,
        else => null,
    };
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    for (0..haystack.len - needle.len + 1) |start| {
        if (std.ascii.eqlIgnoreCase(haystack[start .. start + needle.len], needle)) return true;
    }
    return false;
}

fn wireSuccess(a: std.mem.Allocator, result: anytype) ![]const u8 {
    const encoded = try std.json.Stringify.valueAlloc(a, result, .{});
    return std.fmt.allocPrint(a, "{{\"v\":1,\"ok\":true,\"result\":{s}}}", .{encoded});
}

fn wireError(a: std.mem.Allocator, message: []const u8) ![]const u8 {
    const encoded = try std.json.Stringify.valueAlloc(a, message, .{});
    return std.fmt.allocPrint(a, "{{\"v\":1,\"ok\":false,\"error\":{s}}}", .{encoded});
}
