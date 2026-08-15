//! Minimal Discord Rich Presence over the local IPC socket.
//!
//! The Discord desktop client exposes a unix domain socket
//! (`$XDG_RUNTIME_DIR/discord-ipc-0`, falling back to `/tmp/discord-ipc-0`).
//! The RPC protocol is a length-prefixed frame stream: an 8-byte header
//! (opcode u32 LE, payload length u32 LE) followed by a JSON payload. We do a
//! HANDSHAKE with our application id, confirm the READY ack, then send
//! SET_ACTIVITY frames (opcode 1) whenever the current song changes.
//!
//! Everything here is best-effort and non-blocking: if Discord isn't running,
//! or the socket is momentarily busy, the update is dropped silently and the
//! connection is retried on the next call. The TUI never blocks on Discord.
//!
//! Diagnostics: set `DISCORD_IPC_DEBUG=1` to print connect / READY / activity
//! traffic to stderr, which shows whether the socket handshake is actually
//! acknowledged.

const std = @import("std");

const c = @cImport({
    @cInclude("sys/socket.h");
    @cInclude("sys/un.h");
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
    @cInclude("stdlib.h");
    @cInclude("time.h");
});

/// Application id used by the C++ original
/// (`include/core/discord_integration.hpp`: `APPLICATION_ID = 1362371550275174512`).
/// It is a Discord application's Client ID; override with your own in
/// `config.ini` under `[discord] application_id=` if/when you create a new one.
pub const default_app_id: u64 = 1362371550275174512;

/// Print IPC traffic + handshake results when `DISCORD_IPC_DEBUG` is set.
fn dbg(comptime fmt: []const u8, args: anytype) void {
    if (c.getenv("DISCORD_IPC_DEBUG")) |_| {
        std.debug.print("discord: " ++ fmt ++ "\n", args);
    }
}

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

pub const Client = struct {
    app_id: u64 = 0,
    pid: c_int = 0,
    fd: c_int = -1,
    /// True once the socket handshake has been acknowledged with a READY frame.
    ready: bool = false,

    pub fn init(app_id: u64) Client {
        return .{ .app_id = app_id, .pid = @intCast(c.getpid()) };
    }

    pub fn deinit(self: *Client) void {
        self.closeFd();
    }

    fn closeFd(self: *Client) void {
        if (self.fd >= 0) _ = c.close(self.fd);
        self.fd = -1;
        self.ready = false;
    }

    /// `$XDG_RUNTIME_DIR/discord-ipc-0`, or `/tmp/discord-ipc-0` as fallback.
    /// `DISCORD_IPC_SOCKET` (env) overrides the path entirely (handy for tests
    /// or custom setups).
    fn socketPath(buf: []u8) ?[]const u8 {
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

    /// Best-effort connect + handshake. Returns true if the socket is usable
    /// and the handshake was acknowledged with a READY frame.
    fn connect(self: *Client) bool {
        if (self.fd >= 0) return self.ready;

        var pathbuf: [512]u8 = undefined;
        const path = socketPath(&pathbuf) orelse return false;

        const fd = c.socket(c.AF_UNIX, c.SOCK_STREAM, 0);
        if (fd < 0) return false;
        // Non-blocking so a wedged Discord client can never stall the TUI.
        const flags = c.fcntl(fd, c.F_GETFL, @as(c_int, 0));
        _ = c.fcntl(fd, c.F_SETFL, flags | c.O_NONBLOCK);

        var addr: c.struct_sockaddr_un = std.mem.zeroes(c.struct_sockaddr_un);
        addr.sun_family = c.AF_UNIX;
        if (path.len >= addr.sun_path.len) {
            _ = c.close(fd);
            return false;
        }
        @memcpy(addr.sun_path[0..path.len], path);
        const addr_len: c.socklen_t = @intCast(@offsetOf(c.struct_sockaddr_un, "sun_path") + path.len + 1);
        if (c.connect(fd, @ptrCast(&addr), addr_len) != 0) {
            dbg("connect to {s} failed", .{path});
            _ = c.close(fd);
            return false;
        }
        self.fd = fd;
        dbg("connected to {s}", .{path});

        var hb: [128]u8 = undefined;
        const handshake = std.fmt.bufPrint(&hb, "{{\"v\":1,\"client_id\":\"{d}\"}}", .{self.app_id}) catch {
            self.closeFd();
            return false;
        };
        if (!self.writeFrame(.handshake, handshake)) {
            dbg("handshake write failed", .{});
            self.closeFd();
            return false;
        }

        // Wait briefly (bounded) for the READY ack so we know the handshake
        // actually connected. Best-effort: a timeout logs but does not tear the
        // connection down (classic presence clients still send on the socket).
        var ready_buf: [1024]u8 = undefined;
        if (self.readFrame(1500, &ready_buf)) |len| {
            self.ready = true;
            dbg("READY (opcode 0, {d} bytes): {s}", .{ len, ready_buf[0..@min(len, 160)] });
        } else {
            dbg("no READY within 1500ms -- handshake unacknowledged", .{});
        }
        return true;
    }

    // ---- frame I/O (non-blocking; poll-bounded so reads can't stall) ----

    fn waitReadable(self: *Client, timeout_ms: i32) bool {
        if (self.fd < 0) return false;
        var pfd = [_]std.posix.pollfd{.{ .fd = self.fd, .events = std.posix.POLL.IN, .revents = 0 }};
        const n = std.posix.poll(&pfd, timeout_ms) catch return false;
        if (n == 0) return false;
        return (pfd[0].revents & (std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR)) != 0;
    }

    /// Read exactly `buf.len` bytes, looping over partial / EAGAIN reads.
    fn readExact(self: *Client, buf: []u8, timeout_repeat_ms: i32) bool {
        var got: usize = 0;
        while (got < buf.len) {
            if (!self.waitReadable(timeout_repeat_ms)) return false;
            const n = std.posix.read(self.fd, buf[got..]) catch |e| switch (e) {
                error.WouldBlock => continue, // std.posix retries EINTR internally
                else => return false,
            };
            if (n == 0) return false; // peer closed
            got += n;
        }
        return true;
    }

    /// Read a single IPC frame into `out`, returning the payload length (or
    /// null on timeout/error).
    fn readFrame(self: *Client, timeout_ms: i32, out: []u8) ?usize {
        var hdr: [8]u8 = undefined;
        if (!self.readExact(&hdr, timeout_ms)) return null;
        const h = decodeHeader(hdr);
        if (h.len > out.len) return null;
        if (!self.readExact(out[0..h.len], timeout_ms)) return null;
        return h.len;
    }

    /// Encode + write one RPC frame as a single coalesced write (header + JSON
    /// payload in one buffer) so a stream socket can never see a partial frame.
    fn writeFrame(self: *Client, op: Opcode, payload: []const u8) bool {
        if (payload.len > 4096) return false;
        var frame: [8 + 4096]u8 = undefined;
        frame[0..8].* = encodeHeader(@intFromEnum(op), @intCast(payload.len));
        @memcpy(frame[8 .. 8 + payload.len], payload);
        const total = 8 + payload.len;
        const n = c.write(self.fd, &frame, total);
        if (n < 0 or @as(usize, @intCast(n)) != total) return false;
        return true;
    }

    /// Publish the now-playing track. Best-effort and non-blocking: if Discord
    /// is absent or busy, the update is dropped silently and retried next call.
    /// `cover_url` (when non-null) is sent as the activity's large image.
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
            self.closeFd();
            return;
        };

        dbg("SET_ACTIVITY: {s}", .{payload[0..@min(payload.len, 220)]});
        if (!self.writeFrame(.frame, payload)) {
            dbg("SET_ACTIVITY write failed", .{});
            self.closeFd();
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

    // Truncates at Discord's 128-char field cap.
    var long_buf: [200]u8 = undefined;
    const many = "a" ** 200;
    const out = escapeInto(&long_buf, many);
    try std.testing.expectEqual(@as(usize, 128), out.len);
}

test "setPresence is a no-op when disabled (app_id 0)" {
    var cl = Client.init(0);
    defer cl.deinit();
    cl.setPresence("title", "artist", 100.0, null); // must not crash or touch the fd
    try std.testing.expectEqual(@as(c_int, -1), cl.fd);
}

test "frame header encodes and decodes (little-endian round trip)" {
    const op: u32 = 1;
    const len: u32 = 0x01020304;
    const bytes = encodeHeader(op, len);
    const h = decodeHeader(bytes);
    try std.testing.expectEqual(op, h.op);
    try std.testing.expectEqual(len, h.len);

    // Spot-check byte layout: opcode 1 (SET_ACTIVITY) => [1,0,0,0, ...].
    const op1 = encodeHeader(1, 4);
    try std.testing.expectEqual(@as(u8, 1), op1[0]);
    try std.testing.expectEqual(@as(u8, 0), op1[1]);
    try std.testing.expectEqual(@as(u8, 4), op1[4]);
}
