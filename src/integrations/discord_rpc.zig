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
const c = @cImport({
    @cInclude("time.h");
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
pub const Client = struct {
    app_id: u64 = 0,
    pid: u32 = 0,
    ready: bool = false,
    connected: bool = false,
    transport: Transport = Transport.init(),

    pub fn init(app_id: u64) Client {
        return .{ .app_id = app_id, .pid = currentPid() };
    }

    pub fn deinit(self: *Client) void {
        self.close();
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
        if (!self.transport.writeAll(handshake)) {
            dbg("handshake write failed", .{});
            self.close();
            return false;
        }

        // Wait briefly (bounded) for the READY ack. Best-effort: a timeout logs
        // but does not tear the connection down.
        var ready_buf: [1024]u8 = undefined;
        if (self.readFrame(1500, &ready_buf)) |len| {
            self.ready = true;
            dbg("READY (opcode 0, {d} bytes): {s}", .{ len, ready_buf[0..@min(len, 160)] });
        } else {
            dbg("no READY within 1500ms -- handshake unacknowledged", .{});
        }
        return true;
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

    /// Publish the now-playing track. Best-effort and non-blocking.
    pub fn setPresence(self: *Client, details: []const u8, state: []const u8, duration_secs: f64, cover_url: ?[]const u8) void {
        if (self.app_id == 0) return;
        if (!self.connect()) return;

        var dbuf: [160]u8 = undefined;
        var sbuf: [160]u8 = undefined;
        const ed = escapeInto(&dbuf, details);
        const es = escapeInto(&sbuf, state);

        // Optional comma-prefixed assets fragment for the album cover.
        var assets_buf: [512]u8 = undefined;
        const assets = if (cover_url) |url| blk: {
            var ubuf: [256]u8 = undefined;
            const eu = escapeInto(&ubuf, url);
            break :blk std.fmt.bufPrint(&assets_buf, ",\"assets\":{{\"large_image\":\"{s}\",\"large_text\":\"{s}\"}}", .{ eu, es }) catch "";
        } else "";

        const now: i64 = @intCast(c.time(null));
        var buf: [2048]u8 = undefined;
        const payload = (if (duration_secs > 0)
            std.fmt.bufPrint(&buf, "{{\"cmd\":\"SET_ACTIVITY\",\"args\":{{\"pid\":{d},\"activity\":{{\"type\":2,\"details\":\"{s}\",\"state\":\"{s}\",\"timestamps\":{{\"start\":{d},\"end\":{d}}}{s}}},\"nonce\":\"fp-{d}\"}}}}", .{
                self.pid, ed, es, now, now + @as(i64, @intFromFloat(duration_secs)), assets, self.pid,
            })
        else
            std.fmt.bufPrint(&buf, "{{\"cmd\":\"SET_ACTIVITY\",\"args\":{{\"pid\":{d},\"activity\":{{\"type\":2,\"details\":\"{s}\",\"state\":\"{s}\",\"timestamps\":{{\"start\":{d}}}{s}}},\"nonce\":\"fp-{d}\"}}}}", .{
                self.pid, ed, es, now, assets, self.pid,
            })) catch {
            self.close();
            return;
        };

        dbg("SET_ACTIVITY: {s}", .{payload[0..@min(payload.len, 220)]});
        if (!self.writeFrame(.frame, payload)) {
            dbg("SET_ACTIVITY write failed", .{});
            self.close();
        }
    }
};

/// Copy `src` into `dst` as a JSON string literal, escaping `"`/`\`/control
/// chars and truncating to Discord's 128-char activity field limit.
fn escapeInto(dst: []u8, src: []const u8) []const u8 {
    var n: usize = 0;
    for (src) |ch| {
        if (n >= 128) break;
        switch (ch) {
            '"', '\\', '\n', '\r', '\t' => {
                if (n + 2 >= dst.len) break;
                dst[n] = '\\';
                dst[n + 1] = switch (ch) {
                    '"' => '"',
                    '\\' => '\\',
                    '\n' => 'n',
                    '\r' => 'r',
                    else => 't',
                };
                n += 2;
            },
            else => {
                if (ch < 0x20) continue; // drop other control chars
                dst[n] = ch;
                n += 1;
            },
        }
    }
    return dst[0..n];
}

test "escapeInto escapes JSON specials and truncates" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("say \\\"hi\\\"\\\\ok\\n", escapeInto(&buf, "say \"hi\"\\ok\n"));

    var long_buf: [200]u8 = undefined;
    const many = "a" ** 200;
    const out = escapeInto(&long_buf, many);
    try std.testing.expectEqual(@as(usize, 128), out.len);
}

test "setPresence is a no-op when disabled (app_id 0)" {
    var cl = Client.init(0);
    defer cl.deinit();
    cl.setPresence("title", "artist", 100.0, null);
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
