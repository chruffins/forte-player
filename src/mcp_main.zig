//! Minimal MCP stdio bridge for Forte Player. The player itself owns the
//! library and engine; this process only translates MCP tools to local IPC.

const std = @import("std");
const c = @import("control_c");

const allocator = std.heap.page_allocator;
const tools_json =
    \\{"tools":[
    \\{"name":"player_status","description":"Get current playback, track, position, volume, and queue status.","inputSchema":{"type":"object","properties":{}}},
    \\{"name":"search_library","description":"Search the active player's library by title, artist, or album. Returns up to 25 matching song IDs.","inputSchema":{"type":"object","properties":{"query":{"type":"string","description":"Text to search for"}},"required":["query"]}},
    \\{"name":"play_track","description":"Play a song by the song_id returned by search_library.","inputSchema":{"type":"object","properties":{"song_id":{"type":"integer"}},"required":["song_id"]}},
    \\{"name":"pause","description":"Pause playback.","inputSchema":{"type":"object","properties":{}}},
    \\{"name":"resume","description":"Resume playback.","inputSchema":{"type":"object","properties":{}}},
    \\{"name":"next","description":"Play the next item in the active queue.","inputSchema":{"type":"object","properties":{}}},
    \\{"name":"previous","description":"Play the previous item in the active queue.","inputSchema":{"type":"object","properties":{}}},
    \\{"name":"seek","description":"Seek to an absolute position in the current track, in seconds.","inputSchema":{"type":"object","properties":{"seconds":{"type":"number","minimum":0}},"required":["seconds"]}},
    \\{"name":"set_volume","description":"Set master volume between 0.0 and 1.0.","inputSchema":{"type":"object","properties":{"volume":{"type":"number","minimum":0,"maximum":1}},"required":["volume"]}}
    \\]}
;

pub fn main() void {
    var line: [16384]u8 = undefined;
    while (true) {
        const length = c.forte_mcp_read_line(&line, line.len);
        if (length <= 0) return;
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const parsed = std.json.parseFromSlice(std.json.Value, a, line[0..@intCast(length)], .{ .allocate = .alloc_always }) catch {
            send("{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32700,\"message\":\"Parse error\"}}");
            continue;
        };
        const request = parsed.value;
        if (request != .object) {
            send("{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32600,\"message\":\"Invalid request\"}}");
            continue;
        }
        const method_value = request.object.get("method") orelse continue;
        if (method_value != .string) continue;
        const id_value = request.object.get("id");
        if (std.mem.eql(u8, method_value.string, "notifications/initialized")) continue;
        if (std.mem.eql(u8, method_value.string, "initialize")) {
            const id = encodeId(a, id_value);
            const response = std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{{\"tools\":{{}}}},\"serverInfo\":{{\"name\":\"forte-player\",\"version\":\"0.1.0\"}},\"instructions\":\"Controls the currently running Forte Player GUI or TUI. The player must already be open.\"}}}}", .{id}) catch continue;
            send(response);
        } else if (std.mem.eql(u8, method_value.string, "ping")) {
            sendResult(a, id_value, "{}");
        } else if (std.mem.eql(u8, method_value.string, "tools/list")) {
            sendResult(a, id_value, tools_json);
        } else if (std.mem.eql(u8, method_value.string, "tools/call")) {
            handleToolCall(a, id_value, request.object.get("params") orelse .null);
        } else if (id_value != null) {
            sendError(a, id_value, -32601, "Method not found");
        }
    }
}

fn handleToolCall(a: std.mem.Allocator, id: ?std.json.Value, params: std.json.Value) void {
    const name_value = objectGet(params, "name") orelse {
        sendError(a, id, -32602, "Missing tool name");
        return;
    };
    if (name_value != .string) {
        sendError(a, id, -32602, "Tool name must be a string");
        return;
    }
    const method = name_value.string;
    if (!knownTool(method)) {
        sendError(a, id, -32602, "Unknown tool");
        return;
    }
    const args: std.json.Value = objectGet(params, "arguments") orelse .{ .object = .empty };
    const wire_method = if (std.mem.eql(u8, method, "player_status")) "status" else method;
    const args_json = std.json.Stringify.valueAlloc(a, args, .{}) catch {
        sendToolError(a, id, "Could not encode tool arguments");
        return;
    };
    const request_json = std.fmt.allocPrint(a, "{{\"v\":1,\"method\":{s},\"params\":{s}}}", .{
        std.json.Stringify.valueAlloc(a, wire_method, .{}) catch return,
        args_json,
    }) catch {
        sendToolError(a, id, "Could not encode control request");
        return;
    };
    var endpoint: [512]u8 = @splat(0);
    const endpoint_length = c.forte_control_endpoint(&endpoint, endpoint.len);
    if (endpoint_length <= 0) {
        sendToolError(a, id, "Could not determine the player IPC endpoint");
        return;
    }
    endpoint[@intCast(endpoint_length)] = 0;
    var reply: [8192]u8 = undefined;
    const reply_length = c.forte_control_client_call(@ptrCast(&endpoint), request_json.ptr, request_json.len, &reply, reply.len);
    if (reply_length < 0) {
        sendToolError(a, id, "Forte Player is not reachable. Open the GUI or TUI first; this MCP server does not start a player.");
        return;
    }
    const text_json = std.json.Stringify.valueAlloc(a, reply[0..@intCast(reply_length)], .{}) catch {
        sendToolError(a, id, "Could not encode player response");
        return;
    };
    const is_error = std.mem.indexOf(u8, reply[0..@intCast(reply_length)], "\"ok\":false") != null;
    const result = std.fmt.allocPrint(a, "{{\"content\":[{{\"type\":\"text\",\"text\":{s}}}],\"isError\":{s}}}", .{ text_json, if (is_error) "true" else "false" }) catch return;
    sendResult(a, id, result);
}

fn knownTool(name: []const u8) bool {
    inline for (.{
        "player_status", "search_library", "play_track", "pause", "resume", "next", "previous", "seek", "set_volume",
    }) |tool| if (std.mem.eql(u8, name, tool)) return true;
    return false;
}

fn objectGet(value: std.json.Value, key: []const u8) ?std.json.Value {
    if (value != .object) return null;
    return value.object.get(key);
}

fn encodeId(a: std.mem.Allocator, value: ?std.json.Value) []const u8 {
    const id = value orelse return "null";
    return std.json.Stringify.valueAlloc(a, id, .{}) catch "null";
}

fn sendResult(a: std.mem.Allocator, id: ?std.json.Value, result_json: []const u8) void {
    const response = std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{s}}}", .{ encodeId(a, id), result_json }) catch return;
    send(response);
}

fn sendError(a: std.mem.Allocator, id: ?std.json.Value, code: i32, message: []const u8) void {
    const text = std.json.Stringify.valueAlloc(a, message, .{}) catch return;
    const result = std.fmt.allocPrint(a, "{{\"code\":{d},\"message\":{s}}}", .{ code, text }) catch return;
    const response = std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"error\":{s}}}", .{ encodeId(a, id), result }) catch return;
    send(response);
}

fn sendToolError(a: std.mem.Allocator, id: ?std.json.Value, message: []const u8) void {
    const text_json = std.json.Stringify.valueAlloc(a, message, .{}) catch return;
    const result = std.fmt.allocPrint(a, "{{\"content\":[{{\"type\":\"text\",\"text\":{s}}}],\"isError\":true}}", .{text_json}) catch return;
    sendResult(a, id, result);
}

fn send(line: []const u8) void {
    _ = c.forte_mcp_write_line(line.ptr, line.len);
}
