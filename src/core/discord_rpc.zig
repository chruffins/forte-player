//! Minimal Discord Rich Presence over the local IPC socket.
//!
//! The Discord desktop client exposes a unix domain socket
//! (`$XDG_RUNTIME_DIR/discord-ipc-0`, falling back to `/tmp/discord-ipc-0`).
//! The RPC protocol is a length-prefixed frame stream: an 8-byte header
//! (opcode u32 LE, payload length u32 LE) followed by a JSON payload. We do a
//! HANDSHAKE with our application id, then send SET_ACTIVITY frames (opcode 1)
//! whenever the current song changes.
//!
//! Everything here is best-effort and non-blocking: if Discord isn't running,
//! or the socket is momentarily busy, the update is dropped silently and the
//! connection is retried on the next call. The TUI never blocks on Discord.

const std = @import("std");

const c = @cImport({
    @cInclude("sys/socket.h");
    @cInclude("sys/un.h");
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
    @cInclude("stdlib.h");
    @cInclude("time.h");
});

/// Application id used by the C++ original. Used when config.ini's
/// `[discord] application_id` is unset/0; override with your own app there.
pub const default_app_id: u64 = 1362371550275174512;

const Opcode = enum(u32) {
    handshake = 0,
    frame = 1,
    close = 2,
    ping = 3,
    pong = 4,
};

pub const Client = struct {
    app_id: u64 = 0,
    pid: c_int = 0,
    fd: c_int = -1,

    pub fn init(app_id: u64) Client {
        return .{ .app_id = app_id, .pid = @intCast(c.getpid()) };
    }

    pub fn deinit(self: *Client) void {
        self.closeFd();
    }

    fn closeFd(self: *Client) void {
        if (self.fd >= 0) _ = c.close(self.fd);
        self.fd = -1;
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

    /// Best-effort connect + handshake. Returns true if `fd` is usable.
    fn connect(self: *Client) bool {
        if (self.fd >= 0) return true;

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
            _ = c.close(fd);
            return false;
        }
        self.fd = fd;

        var hb: [128]u8 = undefined;
        const handshake = std.fmt.bufPrint(&hb, "{{\"v\":1,\"client_id\":\"{d}\"}}", .{self.app_id}) catch {
            self.closeFd();
            return false;
        };
        if (!self.writeFrame(.handshake, handshake)) {
            self.closeFd();
            return false;
        }
        // Drain whatever Discord replies (READY). Non-blocking: a missing or
        // not-yet-arrived reply is fine.
        var drain: [256]u8 = undefined;
        _ = c.read(self.fd, &drain, drain.len);
        return true;
    }

    /// Encode + write one RPC frame (8-byte LE header + JSON payload).
    fn writeFrame(self: *Client, op: Opcode, payload: []const u8) bool {
        const op32: u32 = @intFromEnum(op);
        const len32: u32 = @intCast(payload.len);
        var hdr: [8]u8 = undefined;
        hdr[0] = @intCast(op32 & 0xff);
        hdr[1] = @intCast((op32 >> 8) & 0xff);
        hdr[2] = @intCast((op32 >> 16) & 0xff);
        hdr[3] = @intCast((op32 >> 24) & 0xff);
        hdr[4] = @intCast(len32 & 0xff);
        hdr[5] = @intCast((len32 >> 8) & 0xff);
        hdr[6] = @intCast((len32 >> 16) & 0xff);
        hdr[7] = @intCast((len32 >> 24) & 0xff);

        const hw = c.write(self.fd, &hdr, hdr.len);
        if (hw < 0 or @as(usize, @intCast(hw)) != hdr.len) return false;
        const pw = c.write(self.fd, payload.ptr, payload.len);
        if (pw < 0 or @as(usize, @intCast(pw)) != payload.len) return false;
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
            }))
        catch {
            self.closeFd();
            return;
        };

        if (!self.writeFrame(.frame, payload)) self.closeFd();
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
