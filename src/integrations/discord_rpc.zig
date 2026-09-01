//! Discord Rich Presence over the local IPC channel.
//!
//! Protocol (identical on every platform): a length-prefixed frame stream — an
//! 8-byte header (opcode u32 LE, payload length u32 LE) followed by a JSON
//! payload. We HANDSHAKE with our application id, confirm the READY ack, then
//! send SET_ACTIVITY (opcode 1) whenever the current song changes.
//!
//! Only the *transport* differs by OS:
//!   * POSIX (Linux/macOS/BSD) — a unix-domain socket at
//!     `$XDG_RUNTIME_DIR/discord-ipc-0` (fallback `/tmp/discord-ipc-0`).
//!   * Windows — a Win32 named pipe at `\\.\pipe\discord-ipc-0`.
//! The transport is selected at comptime via `builtin.os.tag`, so no POSIX
//! headers or std.posix are referenced on Windows and vice-versa.
//!
//! Everything here is best-effort and non-blocking: if Discord isn't running
//! the update is dropped silently and the connection is retried on the next
//! call. The TUI never blocks on Discord.
//!
//! Diagnostics: set `DISCORD_IPC_DEBUG=1` to print connect / READY / activity
//! traffic to stderr, which shows whether the handshake is acknowledged.

const std = @import("std");
const builtin = @import("builtin");
const os_tag = builtin.os.tag;

/// Cross-platform C imports (provided on Windows too via mingw headers).
/// Only `stdlib.h` (getenv) is needed here; wall-clock time uses std.Io.Clock.
const c = @cImport({
    @cInclude("stdlib.h");
});

/// Print IPC traffic + handshake results when `DISCORD_IPC_DEBUG` is set.
fn dbg(comptime fmt: []const u8, args: anytype) void {
    if (builtin.os.tag == .windows) return; // getenv works on both, but keep POSIX-only debug path simple
    if (c.getenv("DISCORD_IPC_DEBUG")) |_| {
        std.debug.print("discord: " ++ fmt ++ "\n", args);
    }
}

/// Application id used by the C++ original
/// (`include/core/discord_integration.hpp`: `APPLICATION_ID = 1362371550275174512`).
/// It is a Discord application's Client ID; override with your own in
/// `config.ini` under `[discord] application_id=` if/when you create a new one.
pub const default_app_id: u64 = 1362371550275174512;

const Opcode = enum(u32) {
    handshake = 0,
    frame = 1,
    close = 2,
    ping = 3,
    pong = 4,
};

/// The 8-byte IPC frame header (opcode u32 LE, payload len u32 LE).
pub const FrameHeader = struct {
    op: u32,
    len: u32,
};

pub fn decodeHeader(bytes: [8]u8) FrameHeader {
    return .{
        .op = bytes[0] | (@as(u32, bytes[1]) << 8) | (@as(u32, bytes[2]) << 16) | (@as(u32, bytes[3]) << 24),
        .len = bytes[4] | (@as(u32, bytes[5]) << 8) | (@as(u32, bytes[6]) << 16) | (@as(u32, bytes[7]) << 24),
    };
}

pub fn encodeHeader(op: u32, len: u32) [8]u8 {
    var h: [8]u8 = undefined;
    h[0] = @truncate(op);
    h[1] = @truncate(op >> 8);
    h[2] = @truncate(op >> 16);
    h[3] = @truncate(op >> 24);
    h[4] = @truncate(len);
    h[5] = @truncate(len >> 8);
    h[6] = @truncate(len >> 16);
    h[7] = @truncate(len >> 24);
    return h;
}

// ---------------------------------------------------------------------------
// POSIX transport: unix-domain socket
// ---------------------------------------------------------------------------
const posix_socket = if (os_tag != .windows) @cImport({
    @cInclude("sys/socket.h");
    @cInclude("sys/un.h");
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
    @cInclude("poll.h");
}) else @TypeOf(null);

const PosixTransport = if (os_tag != .windows) struct {
    fd: c_int = -1,

    fn init() PosixTransport {
        return .{};
    }
    fn close(self: *PosixTransport) void {
        if (self.fd >= 0) _ = posix_socket.close(self.fd);
        self.fd = -1;
    }
    fn connect(self: *PosixTransport, path: []const u8) bool {
        const fd = posix_socket.socket(posix_socket.AF_UNIX, posix_socket.SOCK_STREAM, 0);
        if (fd < 0) return false;
        // Non-blocking so a wedged client can never stall us.
        const flags = posix_socket.fcntl(fd, posix_socket.F_GETFL, @as(c_int, 0));
        _ = posix_socket.fcntl(fd, posix_socket.F_SETFL, flags | posix_socket.O_NONBLOCK);

        var addr: posix_socket.struct_sockaddr_un = std.mem.zeroes(posix_socket.struct_sockaddr_un);
        addr.sun_family = posix_socket.AF_UNIX;
        if (path.len >= addr.sun_path.len) {
            _ = posix_socket.close(fd);
            return false;
        }
        @memcpy(addr.sun_path[0..path.len], path);
        const addr_len: posix_socket.socklen_t = @intCast(@offsetOf(posix_socket.struct_sockaddr_un, "sun_path") + path.len + 1);
        if (posix_socket.connect(fd, @ptrCast(&addr), addr_len) != 0) {
            _ = posix_socket.close(fd);
            return false;
        }
        self.fd = fd;
        return true;
    }
    fn writeAll(self: *PosixTransport, bytes: []const u8) bool {
        var off: usize = 0;
        while (off < bytes.len) {
            const n = posix_socket.write(self.fd, bytes.ptr + off, bytes.len - off);
            if (n <= 0) return false;
            off += @intCast(n);
        }
        return true;
    }
    /// Poll for readability, then read once. Returns bytes read (>0) or null on
    /// timeout/error/EOF. Poll-then-read means no errno handling is required.
    fn readSome(self: *PosixTransport, buf: []u8, timeout_ms: i32) ?usize {
        var pfd = posix_socket.struct_pollfd{ .fd = self.fd, .events = posix_socket.POLLIN, .revents = 0 };
        const n = posix_socket.poll(&pfd, 1, timeout_ms);
        if (n <= 0 or (pfd.revents & posix_socket.POLLIN) == 0) return null;
        const r = posix_socket.read(self.fd, buf.ptr, buf.len);
        if (r <= 0) return null; // <=0: EOF or would-block (unlikely post-poll)
        return @intCast(r);
    }
    fn getPidOf() u32 {
        return @intCast(posix_socket.getpid());
    }
} else @TypeOf(null);

// ---------------------------------------------------------------------------
// Windows transport: named pipe (Win32 declared manually; no windows.h import)
// ---------------------------------------------------------------------------
const win = if (os_tag == .windows) struct {
    const DWORD = u32;
    const BOOL = i32;
    const HANDLE = *anyopaque;
    const LPCWSTR = [*:0]const u16;

    const GENERIC_READ: DWORD = 0x80000000;
    const GENERIC_WRITE: DWORD = 0x40000000;
    const FILE_SHARE_READ: DWORD = 0x1;
    const FILE_SHARE_WRITE: DWORD = 0x2;
    const OPEN_EXISTING: DWORD = 0x3;
    const INVALID_HANDLE_VALUE: HANDLE = @ptrFromInt(std.math.maxInt(usize));

    extern "kernel32" fn CreateFileW(lp: LPCWSTR, access: DWORD, share: DWORD, sec: ?*anyopaque, disp: DWORD, flags: DWORD, tmpl: ?*anyopaque) callconv(.winapi) HANDLE;
    extern "kernel32" fn WriteFile(h: HANDLE, buf: [*]const u8, n: DWORD, written: ?*DWORD, ov: ?*anyopaque) callconv(.winapi) BOOL;
    extern "kernel32" fn ReadFile(h: HANDLE, buf: [*]u8, n: DWORD, read: ?*DWORD, ov: ?*anyopaque) callconv(.winapi) BOOL;
    extern "kernel32" fn CloseHandle(h: HANDLE) callconv(.winapi) BOOL;
    extern "kernel32" fn SetNamedPipeHandleState(h: HANDLE, mode: ?*DWORD, max_count: ?*DWORD, timeout: ?*DWORD) callconv(.winapi) BOOL;
    extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) DWORD;
} else @TypeOf(null);

const WindowsTransport = if (os_tag == .windows) struct {
    handle: ?win.HANDLE = null,

    fn init() WindowsTransport {
        return .{};
    }
    fn close(self: *WindowsTransport) void {
        if (self.handle) |h| _ = win.CloseHandle(h);
        self.handle = null;
    }
    fn connect(self: *WindowsTransport, _: []const u8) bool {
        const name: win.LPCWSTR = @ptrCast(std.unicode.utf8ToUtf16LeStringLiteral("\\\\.\\pipe\\discord-ipc-0"));
        const h = win.CreateFileW(name, win.GENERIC_READ | win.GENERIC_WRITE, win.FILE_SHARE_READ | win.FILE_SHARE_WRITE, null, win.OPEN_EXISTING, 0, null);
        if (h == win.INVALID_HANDLE_VALUE) return false;
        self.handle = h;
        // Bound byte-mode reads so ReadFile can't block forever on a stale pipe.
        var mode: win.DWORD = 0; // PIPE_READMODE_BYTE
        var timeout: win.DWORD = 1500;
        _ = win.SetNamedPipeHandleState(h, &mode, null, &timeout);
        return true;
    }
    fn writeAll(self: *WindowsTransport, bytes: []const u8) bool {
        const h = self.handle orelse return false;
        var off: usize = 0;
        while (off < bytes.len) {
            var written: win.DWORD = 0;
            if (win.WriteFile(h, bytes.ptr + off, @intCast(bytes.len - off), &written, null) == 0) return false;
            if (written == 0) return false;
            off += written;
        }
        return true;
    }
    fn readSome(self: *WindowsTransport, buf: []u8, _: i32) ?usize {
        const h = self.handle orelse return null;
        var read: win.DWORD = 0;
        if (win.ReadFile(h, buf.ptr, @intCast(buf.len), &read, null) == 0) return null;
        if (read == 0) return null;
        return read;
    }
    fn getPidOf() u32 {
        return win.GetCurrentProcessId();
    }
} else @TypeOf(null);

const Transport = if (os_tag == .windows) WindowsTransport else PosixTransport;

fn currentPid() u32 {
    return Transport.getPidOf();
}

// ---------------------------------------------------------------------------
// Client: shared, protocol-only (handshake + READY + SET_ACTIVITY)
// ---------------------------------------------------------------------------
/// Everything Discord shows for the now-playing activity. Fill the fields you
/// want; unset/empty ones are omitted from the payload. Tweak this (or how
/// `setPresence` serializes it) to control the rich-presence display.
pub const Presence = struct {
    /// Discord's `details` field (commonly "song - artist").
    details: []const u8 = "",
    /// Discord's `state` field (commonly the artist or album).
    state: []const u8 = "",
    /// Which field Discord shows as the status text next to the music icon:
    /// 0 = app name, 1 = `state`, 2 = `details`.
    status_display_type: u8 = 2,
    /// Activity type: 0 = Playing, 2 = Listening. Defaults to Listening.
    activity_type: u8 = 2,
    /// Track duration in seconds; if > 0, start/end timestamps are sent.
    duration_secs: f64 = 0,
    // ---- Rich-Presence assets (parity with the C++ prototype's
    // `ActivityAssets`; each ships as snake_case on the wire). ----
    /// Large image (cover-art URL or an uploaded asset key).
    large_image: ?[]const u8 = null,
    /// Tooltip shown when hovering the large image (e.g. album name).
    large_text: ?[]const u8 = null,
    /// Small image (uploaded asset key such as "logo", or a URL).
    small_image: ?[]const u8 = null,
    /// Tooltip shown when hovering the small image (e.g. app name).
    small_text: ?[]const u8 = null,
    /// Click-through URL associated with the small image (e.g. the repo).
    small_url: ?[]const u8 = null,
};

pub const Client = struct {
    app_id: u64 = 0,
    pid: u32 = 0,
    ready: bool = false,
    connected: bool = false,
    transport: Transport = Transport.init(),

    // Presence writes and the READY/activity replies happen on this worker,
    // never on the playback/render thread. Only the latest pending activity is
    // retained because an older song update is no longer useful.
    allocator: std.mem.Allocator = std.heap.page_allocator,
    threaded: std.Io.Threaded,
    mutex: std.Io.Mutex = .init,
    condition: std.Io.Condition = .init,
    pending: ?[]u8 = null,
    worker: ?std.Thread = null,
    stopping: bool = false,

    pub fn init(app_id: u64) Client {
        return .{
            .app_id = app_id,
            .pid = currentPid(),
            .threaded = std.Io.Threaded.init(std.heap.page_allocator, .{}),
        };
    }

    fn syncIo(self: *Client) std.Io {
        return self.threaded.io();
    }

    pub fn deinit(self: *Client) void {
        const io = self.syncIo();
        if (self.worker) |thread| {
            self.mutex.lockUncancelable(io);
            self.stopping = true;
            if (self.pending) |payload| {
                self.allocator.free(payload);
                self.pending = null;
            }
            self.condition.broadcast(io);
            self.mutex.unlock(io);
            thread.join();
            self.worker = null;
        }
        self.close();
        self.threaded.deinit();
    }

    fn close(self: *Client) void {
        self.transport.close();
        self.connected = false;
        self.ready = false;
    }

    /// `$XDG_RUNTIME_DIR/discord-ipc-0`, or `/tmp/discord-ipc-0` as fallback.
    /// `DISCORD_IPC_SOCKET` (env) overrides the path entirely.
    fn socketPath(buf: []u8) ?[]const u8 {
        if (os_tag == .windows) return "\\\\.\\pipe\\discord-ipc-0";
        if (c.getenv("DISCORD_IPC_SOCKET")) |override| {
            const len = std.mem.len(override);
            if (len < buf.len) {
                @memcpy(buf[0..len], override[0..len]);
                return buf[0..len];
            }
            return null;
        }
        if (c.getenv("XDG_RUNTIME_DIR")) |dir| {
            const len = std.mem.len(dir);
            const path = std.fmt.bufPrint(buf, "{s}/discord-ipc-0", .{dir[0..len]}) catch return null;
            return path;
        }
        return "/tmp/discord-ipc-0";
    }

    /// Best-effort connect + handshake. Returns true if usable and READY ack'd.
    fn connect(self: *Client) bool {
        if (self.connected) return self.ready;

        var pathbuf: [512]u8 = undefined;
        const path = socketPath(&pathbuf) orelse return false;
        if (!self.transport.connect(path)) {
            dbg("connect failed ({s})", .{path});
            return false;
        }
        self.connected = true;
        dbg("connected ({s})", .{path});

        var hb: [128]u8 = undefined;
        const handshake = std.fmt.bufPrint(&hb, "{{\"v\":1,\"client_id\":\"{d}\"}}", .{self.app_id}) catch {
            self.close();
            return false;
        };
        // CRITICAL: the handshake must be a full IPC frame (8-byte header + JSON),
        // not raw JSON -- otherwise Discord reads the JSON bytes as a bogus
        // header and replies with a "protocol error" frame.
        if (!self.writeFrame(.handshake, handshake)) {
            dbg("handshake write failed", .{});
            self.close();
            return false;
        }

        // Wait briefly for the READY ack and confirm it actually says READY; a
        // malformed handshake surfaces here as an error frame.
        var ready_buf: [1024]u8 = undefined;
        if (self.readFrame(1500, &ready_buf)) |len| {
            const reply = ready_buf[0..len];
            if (std.mem.indexOf(u8, reply, "READY") != null) {
                self.ready = true;
                dbg("READY: {s}", .{reply[0..@min(reply.len, 160)]});
            } else {
                dbg("handshake rejected: {s}", .{reply[0..@min(reply.len, 160)]});
                self.close();
                return false;
            }
        } else {
            dbg("no READY within 1500ms -- handshake unacknowledged", .{});
        }

        return self.ready;
    }

    // ---- frame I/O (shared; poll-bounded so reads can't stall) ----

    fn readExact(self: *Client, buf: []u8, timeout_ms: i32) bool {
        var got: usize = 0;
        while (got < buf.len) {
            const n = self.transport.readSome(buf[got..], timeout_ms) orelse return false;
            if (n == 0) return false;
            got += n;
        }
        return true;
    }

    fn readFrame(self: *Client, timeout_ms: i32, out: []u8) ?usize {
        var hdr: [8]u8 = undefined;
        if (!self.readExact(&hdr, timeout_ms)) return null;
        const h = decodeHeader(hdr);
        if (h.len > out.len) return null;
        if (!self.readExact(out[0..h.len], timeout_ms)) return null;
        return h.len;
    }

    /// Encode + write one RPC frame as a single coalesced write.
    fn writeFrame(self: *Client, op: Opcode, payload: []const u8) bool {
        if (payload.len > 4096) return false;
        var frame: [8 + 4096]u8 = undefined;
        frame[0..8].* = encodeHeader(@intFromEnum(op), @intCast(payload.len));
        @memcpy(frame[8 .. 8 + payload.len], payload);
        return self.transport.writeAll(frame[0 .. 8 + payload.len]);
    }

    /// Publish the now-playing track. JSON construction is cheap and happens
    /// here, but all socket/pipe I/O is handed to the worker.
    pub fn setPresence(self: *Client, p: Presence) void {
        if (self.app_id == 0) return;

        var payload_buf: [4096]u8 = undefined;
        const payload = buildActivityPayload(
            p,
            self.pid,
            std.Io.Clock.real.now(std.Io.Threaded.global_single_threaded.io()).toSeconds(),
            &payload_buf,
        ) orelse {
            dbg("SET_ACTIVITY: payload too large", .{});
            return;
        };
        const owned = self.allocator.dupe(u8, payload) catch return;

        const io = self.syncIo();
        if (self.worker == null) {
            self.worker = std.Thread.spawn(.{}, workerMain, .{self}) catch {
                self.allocator.free(owned);
                return;
            };
        }
        self.mutex.lockUncancelable(io);
        if (self.stopping) {
            self.mutex.unlock(io);
            self.allocator.free(owned);
            return;
        }
        if (self.pending) |old| self.allocator.free(old);
        self.pending = owned;
        self.condition.signal(io);
        self.mutex.unlock(io);
    }

    fn workerMain(self: *Client) void {
        const io = self.syncIo();
        while (true) {
            self.mutex.lockUncancelable(io);
            while (self.pending == null and !self.stopping) {
                self.condition.waitUncancelable(io, &self.mutex);
            }
            if (self.stopping and self.pending == null) {
                self.mutex.unlock(io);
                return;
            }
            const payload = self.pending.?;
            self.pending = null;
            self.mutex.unlock(io);

            self.sendPresence(payload);
            self.allocator.free(payload);
        }
    }

    fn sendPresence(self: *Client, payload: []const u8) void {
        if (!self.connect()) return;
        dbg("SET_ACTIVITY: {s}", .{payload[0..@min(payload.len, 220)]});
        if (!self.writeFrame(.frame, payload)) {
            dbg("SET_ACTIVITY write failed", .{});
            self.close();
            return;
        }
        // Best-effort: read Discord's reply so a rejected command surfaces in
        // DISCORD_IPC_DEBUG instead of being silently dropped. This wait is
        // isolated to the worker and cannot stall playback or rendering.
        var reply: [2048]u8 = undefined;
        if (self.readFrame(500, &reply)) |reply_len| {
            dbg("SET_ACTIVITY reply: {s}", .{reply[0..@min(reply_len, 200)]});
        }
    }
};

// ---------------------------------------------------------------------------
// SET_ACTIVITY serialization (std.json streaming; escaping is automatic)
// ---------------------------------------------------------------------------

/// Serialize the SET_ACTIVITY payload for `p` into `buf` (valid JSON, strings
/// escaped by std.json.Stringify). Returns null if the payload doesn't fit.
fn buildActivityPayload(p: Presence, pid: u32, now: i64, buf: []u8) ?[]u8 {
    var w: std.Io.Writer = .fixed(buf);
    var js = std.json.Stringify{ .writer = &w };
    writeActivityJson(&js, p, pid, now) catch return null;
    return w.buffered();
}

/// Stream the SET_ACTIVITY JSON. Hard rules to never break:
///  * `nonce` must be at the TOP level (Discord rejects it inside `args`
///    with code 4000 "Payload requires a nonce").
///  * every SET_ACTIVITY frame starts with an 8-byte IPC header (writeFrame).
fn writeActivityJson(js: *std.json.Stringify, p: Presence, pid: u32, now: i64) !void {
    try js.beginObject();
    try js.objectField("cmd");
    try js.write("SET_ACTIVITY");

    try js.objectField("args");
    try js.beginObject();
    try js.objectField("pid");
    try js.write(pid);

    try js.objectField("activity");
    try js.beginObject();
    try js.objectField("type");
    try js.write(p.activity_type);
    try js.objectField("details");
    try js.write(clip(p.details, 128));
    try js.objectField("state");
    try js.write(clip(p.state, 128));
    try js.objectField("status_display_type");
    try js.write(p.status_display_type);

    // timestamps (only when we know the track length)
    if (p.duration_secs > 0) {
        try js.objectField("timestamps");
        try js.beginObject();
        try js.objectField("start");
        try js.write(now);
        try js.objectField("end");
        try js.write(now + @as(i64, @intFromFloat(p.duration_secs)));
        try js.endObject();
    }

    // assets: any subset of the five ActivityAssets fields (parity with the
    // C++ prototype's large_image/large_text/small_image/small_text/small_url).
    const AssetField = struct { key: []const u8, value: ?[]const u8, max: usize };
    const asset_fields = [_]AssetField{
        .{ .key = "large_image", .value = p.large_image, .max = 512 },
        .{ .key = "large_text", .value = p.large_text, .max = 128 },
        .{ .key = "small_image", .value = p.small_image, .max = 512 },
        .{ .key = "small_text", .value = p.small_text, .max = 128 },
        .{ .key = "small_url", .value = p.small_url, .max = 512 },
    };
    var wrote_assets = false;
    for (asset_fields) |f| {
        if (f.value) |v| {
            if (!wrote_assets) {
                try js.objectField("assets");
                try js.beginObject();
                wrote_assets = true;
            }
            try js.objectField(f.key);
            try js.write(clip(v, f.max));
        }
    }
    if (wrote_assets) try js.endObject();

    try js.endObject(); // activity
    try js.endObject(); // args

    try js.objectField("nonce");
    var nonce_buf: [32]u8 = undefined;
    const nonce = std.fmt.bufPrint(&nonce_buf, "fp-{d}", .{pid}) catch "fp-0";
    try js.write(nonce);
    try js.endObject(); // root
}

/// Byte-truncate `s` to at most `max` bytes without splitting a UTF-8
/// codepoint. Discord caps text fields at 128 chars; image URLs get more room.
fn clip(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    var end = max;
    // Back up over UTF-8 continuation bytes so the cut lands before a lead byte.
    while (end > 0 and (s[end] & 0xC0) == 0x80) : (end -= 1) {}
    return s[0..end];
}

test "buildActivityPayload emits valid, escaped JSON (round-trips)" {
    const p = Presence{
        .details = "say \"hi\"\\ok\n",
        .state = "artist \"x\"",
        .duration_secs = 100.0,
        .large_image = "https://coverartarchive.org/release-group/abc/front",
        .large_text = "Album \"title\"",
        .small_image = "logo",
        .small_text = "∫orte player",
        .small_url = "https://www.github.com/chruffins",
    };
    var buf: [4096]u8 = undefined;
    const json = buildActivityPayload(p, 1234, 1000, &buf) orelse return error.TestUnexpectedResult;

    // Full round-trip through std.json proves the payload is well-formed and
    // correctly escaped.
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqualStrings("SET_ACTIVITY", root.get("cmd").?.string);
    try std.testing.expectEqualStrings("fp-1234", root.get("nonce").?.string);

    const args = root.get("args").?.object;
    try std.testing.expectEqual(@as(i64, 1234), args.get("pid").?.integer);
    const activity = args.get("activity").?.object;
    try std.testing.expectEqual(@as(i64, 2), activity.get("type").?.integer);
    try std.testing.expectEqualStrings("say \"hi\"\\ok\n", activity.get("details").?.string);
    try std.testing.expectEqualStrings("artist \"x\"", activity.get("state").?.string);

    const ts = activity.get("timestamps").?.object;
    try std.testing.expectEqual(@as(i64, 1000), ts.get("start").?.integer);
    try std.testing.expectEqual(@as(i64, 1100), ts.get("end").?.integer);

    const assets = activity.get("assets").?.object;
    try std.testing.expectEqualStrings("https://coverartarchive.org/release-group/abc/front", assets.get("large_image").?.string);
    try std.testing.expectEqualStrings("Album \"title\"", assets.get("large_text").?.string);
    try std.testing.expectEqualStrings("logo", assets.get("small_image").?.string);
    try std.testing.expectEqualStrings("https://www.github.com/chruffins", assets.get("small_url").?.string);
}

test "buildActivityPayload clips long text and omits unset fields" {
    const p = Presence{
        .details = "a" ** 200,
        .state = "",
    };
    var buf: [4096]u8 = undefined;
    const json = buildActivityPayload(p, 7, 0, &buf) orelse return error.TestUnexpectedResult;

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    const activity = root.get("args").?.object.get("activity").?.object;
    // clipped to Discord's 128-char cap
    try std.testing.expectEqual(@as(usize, 128), activity.get("details").?.string.len);
    // no timestamps without a duration; no assets block when all unset
    try std.testing.expect(activity.get("timestamps") == null);
    try std.testing.expect(activity.get("assets") == null);
    try std.testing.expectEqualStrings("fp-7", root.get("nonce").?.string);
}

test "clip never splits a UTF-8 codepoint" {
    // '♪' is 3 bytes (E2 99 AA); a 4-byte cap must not cut inside it.
    const s = "a♪b";
    try std.testing.expectEqualStrings("a", clip(s, 2));
    try std.testing.expectEqualStrings("a", clip(s, 1));
    try std.testing.expectEqualStrings("a", clip(s, 3));
    try std.testing.expectEqualStrings("a♪", clip(s, 4));
    try std.testing.expectEqualStrings(s, clip(s, 5));
}

test "setPresence is a no-op when disabled (app_id 0)" {
    var cl = Client.init(0);
    defer cl.deinit();
    cl.setPresence(.{ .details = "title", .state = "artist", .duration_secs = 100.0 });
    try std.testing.expect(cl.connected == false);
}

test "frame header encodes and decodes (little-endian round trip)" {
    const op: u32 = 1;
    const len: u32 = 0x01020304;
    const bytes = encodeHeader(op, len);
    const h = decodeHeader(bytes);
    try std.testing.expectEqual(op, h.op);
    try std.testing.expectEqual(len, h.len);

    const op1 = encodeHeader(1, 4);
    try std.testing.expectEqual(@as(u8, 1), op1[0]);
    try std.testing.expectEqual(@as(u8, 0), op1[1]);
    try std.testing.expectEqual(@as(u8, 4), op1[4]);
}
