//! Separate immersive frontend. Shared music engine, no gallery/dashboard.
const std = @import("std");
const al = @import("allegro");
const app_mod = @import("app.zig");
const bootstrap = @import("core/bootstrap.zig");
const jobs = @import("ui/gui_jobs.zig");
const fonts = @import("ui/gui_fonts.zig");
const input = @import("ui/gui_framework.zig");
const low = @import("ui/render.zig");
const Rect = @import("ui/ui.zig").Rect;
const db_mod = @import("music/database.zig");
const spectrum = @import("dsp/spectrum.zig");
const vocal_presence = @import("dsp/vocal_presence.zig");
const model = @import("world/model.zig");
const native = @import("world/template.zig");
const recording = @import("world/recording.zig");
const config_mod = @import("core/config.zig");
const c = @import("forte_c");

const Frontend = struct {
    app: *app_mod.App,
    scan: jobs.ScanJob,
    font: fonts.FontSet,
    display: ?*al.Display = null,
    world: native.World = .{},
    released: bool = false,
    failed: bool = false,
    quit: bool = false,
    pose: model.Pose = .{},
    view_name: []const u8 = "saved",
    record_path: ?[]u8 = null,
    notice: []const u8 = "",
    notice_until: f64 = 0,
    held: model.Held = .{},
    looking: bool = false,
    mouse_x: f32 = 0,
    mouse_y: f32 = 0,
    pressed: ?usize = null,
    hud_visible: bool = true,
    help_visible: bool = false,
    picker_open: bool = false,
    picker_input: input.TextInput = .{},
    picker_arena: std.heap.ArenaAllocator,
    picker_rows: []const db_mod.Database.SongDisplay = &.{},
    picker_indices: std.ArrayList(usize) = .empty,
    selection: usize = 0,
    picker_first: usize = 0,
    picker_status: []const u8 = "",
    current_arena: std.heap.ArenaAllocator,
    current_id: i64 = -1,
    title: []const u8 = "Choose music",
    artist: []const u8 = "Tab opens your music library",
    analyzer: spectrum.Analyzer,
    smoother: spectrum.Smoother = .{},
    glow: model.GlowEnvelope = .{},
    vocal_target: f32 = 0,
    vocal_glow: vocal_presence.Envelope = .{},
    samples: [spectrum.n_samples]f32 = undefined,
    bands: [48]f32 = @splat(0),
    last_capture: u64 = std.math.maxInt(u64),
    fft_time: f64 = 0,
    last_time: f64 = 0,
    diagnostics: bool = false,
    last_diagnostic: f64 = 0,
    diagnostic_frames: u32 = 0,
    render_seconds: f64 = 0,

    fn hud(self: *const Frontend) model.Hud {
        const d = self.display.?;
        return .{ .width = @floatFromInt(d.getWidth()), .height = @floatFromInt(d.getHeight()) };
    }
    fn filter(self: *Frontend) void {
        self.picker_indices.clearRetainingCapacity();
        for (self.picker_rows, 0..) |row, i| {
            const query = self.picker_input.text();
            if (model.matches(row.title, query) or model.matches(row.artist, query) or model.matches(row.album, query)) self.picker_indices.append(self.app.allocator, i) catch break;
        }
        self.selection = @min(self.selection, self.picker_indices.items.len -| 1);
        self.reveal();
    }
    fn reveal(self: *Frontend) void {
        if (self.display == null) return;
        const visible = self.hud().pickerVisible();
        if (self.selection < self.picker_first) self.picker_first = self.selection;
        if (self.selection >= self.picker_first + visible) self.picker_first = self.selection - visible + 1;
        self.picker_first = @min(self.picker_first, self.picker_indices.items.len -| visible);
    }
    fn openPicker(self: *Frontend) void {
        if (self.scan.status.load(.acquire) == 1) return;
        self.held = .{};
        self.looking = false;
        self.pressed = null;
        _ = self.picker_arena.reset(.retain_capacity);
        self.picker_rows = self.app.db.getAllSongDisplaysWithAllocator(self.picker_arena.allocator()) catch &.{};
        self.picker_input.setText("");
        self.selection = 0;
        self.picker_first = 0;
        self.picker_open = true;
        self.picker_status = "";
        self.filter();
    }
    fn saveView(self: *Frontend) void {
        var section_buf: [64]u8 = undefined;
        const section = std.fmt.bufPrintSentinel(&section_buf, "world_view_{s}", .{self.view_name}, 0) catch return;
        inline for (.{ "x", "y", "z", "yaw", "pitch" }) |field| {
            var value_buf: [48]u8 = undefined;
            const value = std.fmt.bufPrintSentinel(&value_buf, "{d:.8}", .{@field(self.pose, field)}, 0) catch return;
            self.app.config.setStr(section, field, value);
        }
        if (self.display) |display| {
            self.app.config.setInt(section, "width", display.getWidth());
            self.app.config.setInt(section, "height", display.getHeight());
        }
        const path = config_mod.configFilePath(self.app.allocator) catch return;
        defer self.app.allocator.free(path);
        self.notice = if (self.app.config.save(path)) "View saved · F2 records from this shot" else "Could not save viewpoint";
        self.notice_until = al.time.getTime() + 5;
    }
    fn recordTrack(self: *Frontend, path: []const u8) void {
        var section_buf: [64]u8 = undefined;
        const section = std.fmt.bufPrintSentinel(&section_buf, "world_view_{s}", .{self.view_name}, 0) catch return;
        if (self.app.config.getStr(section, "x", "").len == 0) {
            self.picker_status = "Save a shot with V before recording.";
            self.notice = self.picker_status;
            self.notice_until = al.time.getTime() + 5;
            return;
        }
        self.record_path = self.app.allocator.dupe(u8, path) catch return;
        self.quit = true;
    }
    fn recordSelected(self: *Frontend) void {
        if (self.selection >= self.picker_indices.items.len) return;
        const row = self.picker_rows[self.picker_indices.items[self.selection]];
        if (self.app.lib.songPath(row.id)) |path| self.recordTrack(path);
    }
    fn choose(self: *Frontend) void {
        if (self.selection >= self.picker_indices.items.len) return;
        const row = self.picker_rows[self.picker_indices.items[self.selection]];
        const choice = model.pickerChoice(self.app.allocator, self.picker_rows, self.picker_indices.items, self.selection) catch |err| {
            self.picker_status = "Unable to build music selection.";
            std.log.warn("world picker: {}", .{err});
            return;
        };
        defer self.app.allocator.free(choice.song_ids);
        // Library selection replaces a saved album/playlist queue transactionally.
        // Next/previous follow full library order, not the temporary search filter.
        if (self.app.playSongIdsInContext(choice.song_ids, .Individual, -1, choice.start_index) == null) {
            self.picker_status = "Playback failed; try another file or check codec support.";
            std.log.warn("world could not play library song {d}", .{row.id});
            return;
        }
        self.picker_open = false;
    }
};

fn front(ctx: *anyopaque) *Frontend {
    return @ptrCast(@alignCast(ctx));
}
fn onInit(ctx: *anyopaque, display: *al.Display) void {
    const f = front(ctx);
    f.display = display;
    _ = display.setWindowConstraints(480, 320, 0, 0);
    display.applyWindowConstraints(true);
    f.world = native.World.init(f.app.allocator) catch |err| {
        std.log.err("visualizer world: {} (compatibility OpenGL and shaders required)", .{err});
        f.failed = true;
        f.quit = true;
        return;
    };
}
fn onDeinit(ctx: *anyopaque) void {
    const f = front(ctx);
    if (f.display) |display| {
        f.app.config.setInt("world", "width", display.getWidth());
        f.app.config.setInt("world", "height", display.getHeight());
        f.app.saveConfig();
    }
    f.world.deinit();
    f.font.deinit();
    f.display = null;
    f.released = true;
}
fn onFocusLost(ctx: *anyopaque) void {
    const f = front(ctx);
    f.held = .{};
    f.looking = false;
    f.pressed = null;
}
fn pollLibraryScan(f: *Frontend) void {
    const status = f.scan.status.load(.acquire);
    if (status != 2 and status != 3) return;
    f.scan.join();
    if (status == 2) {
        f.app.finishRescan(f.scan.result, f.scan.previous_path) catch |err| std.log.err("world scan reconciliation: {}", .{err});
        f.app.restoreSavedQueueState();
        if (!f.app.has_current_path) _ = f.app.startFirstSong();
    } else std.log.err("world library scan failed", .{});
    f.scan.status.store(0, .release);
    f.current_id = -1;
}

fn updateTrackMetadata(f: *Frontend) void {
    if (!f.app.has_current_path) {
        f.current_id = -1;
        f.title = "Choose music";
        f.artist = "Tab opens your music library";
        return;
    }
    const id = f.app.lib.songIdByPath(f.app.current_path) orelse return;
    const song = f.app.lib.getSongById(id) orelse return;
    f.title = song.title;
    if (f.current_id == id) return;
    f.current_id = id;
    _ = f.current_arena.reset(.retain_capacity);
    f.artist = if (f.app.db.getSongContextWithAllocator(f.current_arena.allocator(), id) catch null) |context| context.artist else "";
    f.smoother = .{};
    f.glow = .{};
    f.bands = @splat(0);
    f.last_capture = std.math.maxInt(u64);
    f.vocal_target = 0;
    f.vocal_glow = .{};
}

fn updateSpectrum(f: *Frontend, now: f64, dt: f32) void {
    if (f.scan.status.load(.acquire) == 1 or !f.app.engine.isPlaying()) {
        f.bands = @splat(0);
        f.vocal_target = 0;
    } else if (now - f.fft_time >= 0.05) {
        f.fft_time = now;
        const sequence = f.app.engine.captureSequence();
        if (sequence != f.last_capture) {
            f.last_capture = sequence;
            const count = f.app.engine.copyRecentMono(spectrum.n_samples, &f.samples);
            f.analyzer.compute(f.samples[0..count], &f.bands);
            f.vocal_target = vocal_presence.estimate(f.samples[0..count]);
        }
    }
    f.smoother.updateTimed(&f.bands, dt);
    f.glow.update(&f.smoother.levels, dt);
    _ = f.vocal_glow.update(f.vocal_target, dt);
}

fn logDiagnostics(f: *Frontend, now: f64) void {
    f.diagnostic_frames +%= 1;
    if (!f.diagnostics or now - f.last_diagnostic < 1) return;
    const elapsed = now - f.last_diagnostic;
    const fps = @as(f64, @floatFromInt(f.diagnostic_frames)) / elapsed;
    f.last_diagnostic = now;
    f.diagnostic_frames = 0;
    var peak: f32 = 0;
    for (f.smoother.levels) |level| peak = @max(peak, level);
    std.log.info("world: playing={} position={d:.2} capture={d} level={d:.3} vocal={d:.2} fps={d:.1} draw_ms={d:.1} eye={d:.2},{d:.2}", .{ f.app.engine.isPlaying(), f.app.engine.getTime(), f.app.engine.captureSequence(), peak, f.vocal_glow.value, fps, f.render_seconds * 1000, f.pose.x, f.pose.z });
}

fn onTick(ctx: *anyopaque) void {
    const f = front(ctx);
    const now = al.time.getTime();
    const elapsed = if (f.last_time == 0) 1.0 / 60.0 else now - f.last_time;
    const dt: f32 = @floatCast(@max(0, @min(1.0, elapsed)));
    f.last_time = now;
    f.app.engine.update();
    pollLibraryScan(f);
    if (!f.picker_open) f.pose.step(f.held, dt);
    updateTrackMetadata(f);
    updateSpectrum(f, now, dt);
    logDiagnostics(f, now);
    f.reveal();
}
fn tint(r: u8, g: u8, b: u8) al.Color {
    return al.Color.fromRgb(r, g, b);
}
fn text(font: al.font.Font, r: Rect, value: []const u8, color: al.Color) void {
    if (r.w <= 0 or r.h <= 0) return;
    const previous = low.pushClip(r);
    defer low.popClip(previous);
    var buf: [1024:0]u8 = undefined;
    var n = @min(value.len, buf.len - 1);
    while (n > 0 and n < value.len and input.isUtf8Continuation(value[n])) n -= 1;
    @memcpy(buf[0..n], value[0..n]);
    buf[n] = 0;
    font.drawTextAt(color, r.x, r.y + @max(0, (r.h - @as(f32, @floatFromInt(font.getLineHeight()))) / 2), 0, buf[0..n :0]);
}
fn renderTransport(f: *Frontend, hud: model.Hud) void {
    const ink = tint(212, 231, 223);
    const muted = tint(133, 157, 150);
    text(f.font.small, .{ .x = 24, .y = 18, .w = 220, .h = 24 }, "FORTE / FIREFLIES", muted);
    const hint = if (al.time.getTime() < f.notice_until) f.notice else if (f.scan.status.load(.acquire) == 1) "Scanning music…" else "Tab music · V save shot · F2 record · F1 help";
    text(f.font.small, .{ .x = 24, .y = 42, .w = hud.width - 48, .h = 24 }, hint, muted);
    low.roundedRect(.{ .x = 16, .y = hud.height - 88, .w = hud.width - 32, .h = 66 }, 4, al.Color.fromRgba(2, 8, 12, 130));
    text(f.font.body, .{ .x = 24, .y = hud.height - 82, .w = hud.width - 180, .h = 28 }, f.title, ink);
    text(f.font.small, .{ .x = 24, .y = hud.height - 52, .w = hud.width - 180, .h = 24 }, f.artist, muted);
    for (0..3) |i| renderTransportButton(f, hud, i, ink);
    const duration = f.app.engine.getDuration();
    low.bar(hud.seek(), if (duration > 0) @floatCast(f.app.engine.getTime() / duration) else 0, tint(39, 57, 56), tint(135, 215, 163));
}

fn renderTransportButton(f: *Frontend, hud: model.Hud, index: usize, color: al.Color) void {
    const bounds = hud.control(index);
    if (f.pressed != null and f.pressed.? == index) low.roundedRect(bounds, 4, tint(32, 63, 53));
    const labels = [_][]const u8{ "‹", if (f.app.engine.isPlaying()) "II" else ">", "›" };
    text(f.font.body, bounds.inset(6), labels[index], color);
}

fn renderHelp(f: *Frontend, hud: model.Hud) void {
    const bounds = Rect{ .x = 24, .y = 76, .w = @min(480, hud.width - 48), .h = 152 };
    low.roundedRect(bounds, 5, al.Color.fromRgba(2, 8, 12, 215));
    const lines = [_][]const u8{ "WASD walk · Shift faster · R return home", "Right-drag or arrows to look around", "Space pause · N/P next/previous · +/- volume", "Tab picker · V save shot · F2 record · H HUD", "Esc closes picker, otherwise quits" };
    for (lines, 0..) |line, i| {
        const y = bounds.y + 8 + @as(f32, @floatFromInt(i)) * 28;
        text(f.font.small, .{ .x = bounds.x + 12, .y = y, .w = bounds.w - 24, .h = 24 }, line, tint(195, 218, 207));
    }
}

fn renderPicker(f: *Frontend, hud: model.Hud) void {
    const card = hud.picker();
    low.fillRect(.{ .w = hud.width, .h = hud.height }, al.Color.fromRgba(0, 4, 9, 140));
    low.roundedRect(card, 6, tint(9, 20, 24));
    text(f.font.heading, .{ .x = card.x + 16, .y = card.y + 8, .w = card.w - 32, .h = 38 }, "Choose music", tint(213, 234, 224));
    var buf: [600]u8 = undefined;
    const search = std.fmt.bufPrint(&buf, "{s}|", .{f.picker_input.text()}) catch "Search…";
    text(f.font.body, .{ .x = card.x + 16, .y = card.y + 48, .w = card.w - 32, .h = 32 }, search, tint(145, 210, 170));
    const end = @min(f.picker_indices.items.len, f.picker_first + hud.pickerVisible());
    for (f.picker_first..end) |index| renderPickerRow(f, hud, index);
    if (f.picker_indices.items.len == 0) text(f.font.body, hud.pickerRow(0), "No matching music", tint(125, 152, 144));
    const hint = if (f.picker_status.len > 0) f.picker_status else "Type to search · Enter play · F2 record · Esc return";
    text(f.font.small, .{ .x = card.x + 16, .y = card.bottom() - 28, .w = card.w - 32, .h = 24 }, hint, tint(125, 152, 144));
}

fn renderPickerRow(f: *Frontend, hud: model.Hud, index: usize) void {
    const row = f.picker_rows[f.picker_indices.items[index]];
    const bounds = hud.pickerRow(index - f.picker_first);
    if (index == f.selection) low.roundedRect(bounds, 4, tint(25, 49, 42));
    text(f.font.body, .{ .x = bounds.x + 8, .y = bounds.y, .w = bounds.w - 16, .h = 22 }, row.title, tint(207, 228, 218));
    text(f.font.small, .{ .x = bounds.x + 8, .y = bounds.y + 22, .w = bounds.w - 16, .h = 18 }, row.artist, tint(125, 152, 144));
}

fn onRender(ctx: *anyopaque) void {
    const f = front(ctx);
    const display = f.display orelse return;
    const started = if (f.diagnostics) al.time.getTime() else 0;
    defer if (f.diagnostics) {
        f.render_seconds = al.time.getTime() - started;
    };
    if (f.world.native == null) return;
    const hud = f.hud();
    al.graphics.setTargetBackbuffer(display.display);
    al.graphics.resetClipRectangle();
    al.graphics.clearToColor(tint(3, 6, 10));
    if (!f.world.draw(f.pose, &f.glow.levels, f.vocal_glow.value, al.time.getTime(), display.getWidth(), display.getHeight())) {
        f.failed = true;
        f.quit = true;
        std.log.err("world uniform upload/draw failed", .{});
        return;
    }
    if (f.hud_visible) renderTransport(f, hud);
    if (f.help_visible) renderHelp(f, hud);
    if (f.picker_open) renderPicker(f, hud);
}
fn setHeld(f: *Frontend, key: al.KeyCode, down: bool) void {
    switch (key) {
        .W => f.held.forward = down,
        .S => f.held.backward = down,
        .A => f.held.left = down,
        .D => f.held.right = down,
        .Left => f.held.look_left = down,
        .Right => f.held.look_right = down,
        .Up => f.held.look_up = down,
        .Down => f.held.look_down = down,
        .LShift, .RShift => f.held.fast = down,
        else => {},
    }
}
fn handlePickerKey(f: *Frontend, key: al.KeyCode) void {
    switch (key) {
        .Escape, .Tab => f.picker_open = false,
        .Up => f.selection -|= 1,
        .Down => f.selection = @min(f.selection + 1, f.picker_indices.items.len -| 1),
        .PgUp => f.selection -|= f.hud().pickerVisible(),
        .PgDn => f.selection = @min(f.selection + f.hud().pickerVisible(), f.picker_indices.items.len -| 1),
        .Enter, .PadEnter => f.choose(),
        .F2 => f.recordSelected(),
        .Backspace => {
            _ = f.picker_input.backspace();
            f.filter();
        },
        else => {},
    }
    f.reveal();
}

fn handleWorldKey(f: *Frontend, key: al.KeyCode) void {
    setHeld(f, key, true);
    switch (key) {
        .Escape => f.quit = true,
        .Tab => f.openPicker(),
        .F1 => f.help_visible = !f.help_visible,
        .H => {
            f.hud_visible = !f.hud_visible;
            f.pressed = null;
        },
        .R => f.pose = .{},
        .V => f.saveView(),
        .F2 => if (f.app.has_current_path) f.recordTrack(f.app.current_path),
        .Space => if (f.app.engine.isPlaying()) f.app.engine.pause() else f.app.engine.resumePlayback(),
        .N => {
            _ = f.app.engine.playNext() catch {};
        },
        .P => f.app.engine.playPrevious() catch {},
        .Equals, .PadPlus => changeVolume(f, 0.05),
        .Minus, .PadMinus => changeVolume(f, -0.05),
        else => {},
    }
}

fn onKeyDown(ctx: *anyopaque, key: al.KeyCode) void {
    const f = front(ctx);
    if (f.picker_open) return handlePickerKey(f, key);
    handleWorldKey(f, key);
}

fn changeVolume(f: *Frontend, delta: f32) void {
    f.app.engine.setGain(@max(0, @min(1, f.app.engine.getGain() + delta)));
    f.app.config.setVolumePercent(@intFromFloat(f.app.engine.getGain() * 100));
    f.app.saveConfig();
}
fn onKeyUp(ctx: *anyopaque, key: al.KeyCode) void {
    setHeld(front(ctx), key, false);
}
fn onChar(ctx: *anyopaque, cp: u32) void {
    const f = front(ctx);
    if (f.picker_open and cp >= 32 and cp != 127) {
        _ = f.picker_input.insertCodepoint(cp);
        f.selection = 0;
        f.picker_first = 0;
        f.filter();
    }
}
fn onMotion(ctx: *anyopaque, x: f32, y: f32) void {
    const f = front(ctx);
    if (f.looking and !f.picker_open) f.pose.look(x - f.mouse_x, y - f.mouse_y);
    f.mouse_x = x;
    f.mouse_y = y;
}
fn handlePickerClick(f: *Frontend, hud: model.Hud, x: f32, y: f32) void {
    for (0..hud.pickerVisible()) |visible_index| {
        if (!input.containsPoint(hud.pickerRow(visible_index), x, y)) continue;
        const selection = f.picker_first + visible_index;
        if (selection >= f.picker_indices.items.len) return;
        f.selection = selection;
        f.choose();
        return;
    }
}

fn handleTransportClick(f: *Frontend, hud: model.Hud, pressed: bool, x: f32, y: f32) void {
    if (pressed) {
        for (0..3) |index| {
            if (!input.containsPoint(hud.control(index), x, y)) continue;
            f.pressed = index;
            return;
        }
        const track = hud.seek();
        if (!(Rect{ .x = track.x, .y = track.y - 8, .w = track.w, .h = 18 }).contains(x, y)) return;
        const duration = f.app.engine.getDuration();
        if (duration > 0) f.app.engine.setProgress(@max(0, @min(1, (x - track.x) / track.w)) * duration);
        return;
    }
    const index = f.pressed orelse return;
    f.pressed = null;
    if (!input.containsPoint(hud.control(index), x, y)) return;
    const keys = [_]al.KeyCode{ .P, .Space, .N };
    handleWorldKey(f, keys[index]);
}

fn onButton(ctx: *anyopaque, button: i32, pressed: bool, x: f32, y: f32) void {
    const f = front(ctx);
    if (f.display == null) return;
    const hud = f.hud();
    if (f.picker_open) {
        if (button == 1 and pressed) handlePickerClick(f, hud, x, y);
        return;
    }
    if (button == 2) {
        f.looking = pressed;
        f.mouse_x = x;
        f.mouse_y = y;
        return;
    }
    if (button == 1 and f.hud_visible) handleTransportClick(f, hud, pressed, x, y);
}
fn onFinished(ctx: *anyopaque) void {
    front(ctx).app.engine.handleAudioStreamFinishedFromEvent() catch {};
}
fn shouldQuit(ctx: *anyopaque) bool {
    return front(ctx).quit;
}

const Command = union(enum) {
    interactive: []const u8,
    record: []const [:0]const u8,
    render_recording: []const [:0]const u8,
    help,
};

fn parseCommand(args: []const [:0]const u8) !Command {
    if (args.len == 1) return .{ .interactive = "saved" };
    if (std.mem.eql(u8, args[1], "--help")) return .help;
    if (std.mem.eql(u8, args[1], "--render-recording")) return .{ .render_recording = args };
    if (std.mem.eql(u8, args[1], "record")) return .{ .record = args[2..] };
    if (args.len == 3 and std.mem.eql(u8, args[1], "--view") and model.validViewName(args[2])) return .{ .interactive = args[2] };
    return error.InvalidWorldArguments;
}

pub fn main(init: std.process.Init) void {
    run(init) catch |err| {
        std.debug.print("forte-world: {}\n", .{err});
        std.process.exit(1);
    };
}

fn run(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    switch (try parseCommand(args)) {
        .help => {
            std.debug.print("forte-world [--view NAME] | record TRACK [--view NAME] [--output FILE] [--width W --height H --fps 30|60]\nV saves a viewpoint; F2 records the current/selected track. Python3 and FFmpeg required for export.\n", .{});
            return;
        },
        .record => |record_args| return recording.invoke(init, args[0], record_args),
        .render_recording => |render_args| return recording.render(init, render_args),
        .interactive => |view_name| return runInteractive(init, view_name, args[0]),
    }
}

fn loadSavedPose(config: *const config_mod.Config, section: [:0]const u8) model.Pose {
    var pose = model.Pose{};
    inline for (.{ "x", "y", "z", "yaw", "pitch" }) |field| {
        @field(pose, field) = std.fmt.parseFloat(f32, config.getStr(section, field, "")) catch return .{};
    }
    return if (pose.isValid()) pose else .{};
}

fn runInteractive(init: std.process.Init, view_name: []const u8, executable: []const u8) !void {
    const allocator = std.heap.page_allocator;
    var app = try app_mod.App.createDeferred(allocator, null, null);
    defer app.destroy();
    var queue = try al.EventQueue.create();
    defer {
        app.engine.event_queue = null;
        queue.destroy();
    }
    app.engine.event_queue = &queue;
    app.engine.setGain(@as(f32, @floatFromInt(app.config.getVolumePercent())) / 100);
    var f = Frontend{
        .app = app,
        .view_name = view_name,
        .scan = .{ .app = app, .allocator = allocator },
        .font = fonts.FontSet.load(allocator),
        .current_arena = std.heap.ArenaAllocator.init(allocator),
        .picker_arena = std.heap.ArenaAllocator.init(allocator),
        .analyzer = spectrum.Analyzer.init(spectrum.default_sample_rate, .a_weight),
        .diagnostics = c.getenv("FORTE_WORLD_DIAGNOSTICS") != null,
    };
    defer f.scan.deinit();
    defer if (f.record_path) |path| allocator.free(path);
    var section_buf: [64]u8 = undefined;
    const view_section = try std.fmt.bufPrintSentinel(&section_buf, "world_view_{s}", .{view_name}, 0);
    f.pose = loadSavedPose(&app.config, view_section);
    defer f.current_arena.deinit();
    defer f.picker_arena.deinit();
    defer f.picker_indices.deinit(allocator);
    defer if (!f.released) f.font.deinit();
    f.scan.start(true) catch |err| {
        std.log.err("world startup scan: {}", .{err});
        _ = app.startFirstSong();
    };
    c.al_set_new_display_option(c.ALLEGRO_DEPTH_SIZE, 24, c.ALLEGRO_REQUIRE);
    try bootstrap.run(&queue, .{
        .width = @intCast(@max(480, @min(8192, app.config.getInt("world", "width", 1280)))),
        .height = @intCast(@max(320, @min(8192, app.config.getInt("world", "height", 720)))),
        .title = "Forte / Firefly World",
        .resizable = true,
        .programmable_pipeline = true,
    }, .{
        .ctx = &f,
        .on_init_display = onInit,
        .on_deinit_display = onDeinit,
        .on_tick = onTick,
        .on_render = onRender,
        .on_key_down = onKeyDown,
        .on_key_up = onKeyUp,
        .on_key_char = onChar,
        .on_focus_lost = onFocusLost,
        .on_mouse_motion = onMotion,
        .on_mouse_button = onButton,
        .on_audio_stream_finished = onFinished,
        .should_quit = shouldQuit,
    });
    if (f.failed or !f.released) return error.WorldRendererUnavailable;
    if (f.record_path) |path| {
        app.engine.stop();
        const record_args = [_][]const u8{ path, "--view", f.view_name };
        try recording.invoke(init, executable, &record_args);
    }
}
