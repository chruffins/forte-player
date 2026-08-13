//! TUI frontend wired onto the shared UI pipeline:
//!   engine/library -> State snapshot -> (keys -> Action -> apply -> Cmd -> engine)
//!                                            -> view.emit -> CmdList -> render
//!
//! The `ui/ui_*.zig` core is pure; this file is the thin, partially-impure glue
//! (it owns the engine/library handles and the terminal via `ui/tui_render.zig`).

const std = @import("std");
const al = @import("allegro");
const allegro_init = @import("core/allegro_init.zig");
const RealEngine = @import("core/music_engine.zig").RealEngine;
const config_mod = @import("core/config.zig");
const PlayQueue = @import("core/play_queue.zig").PlayQueue;
const db_mod = @import("music/database.zig");
const lib_mod = @import("music/library.zig");
const scanner = @import("music/scanner.zig");
const taglib_meta = @import("music/taglib_meta.zig");

const U = @import("ui/ui_state.zig");
const view = @import("ui/ui_view.zig");
const render = @import("ui/tui_render.zig");
const theme = @import("ui/theme.zig");

const PlaybackCtx = struct { lib: *lib_mod.Library, db: *db_mod.Database };

fn unixSeconds() i64 {
    const ct2 = @cImport(@cInclude("time.h"));
    return @intCast(ct2.time(null));
}

fn resolveSong(id: i32, ctx: *anyopaque) ?[:0]const u8 {
    const p: *PlaybackCtx = @ptrCast(@alignCast(ctx));
    return p.lib.songPath(@intCast(id));
}

fn onSongChanged(path: [:0]const u8, ctx: *anyopaque) void {
    const p: *PlaybackCtx = @ptrCast(@alignCast(ctx));
    const id = p.lib.songIdByPath(path) orelse return;
    p.db.markPlayed(@intCast(id), unixSeconds()) catch return;
}

fn runCmd(engine: *RealEngine, lib: *lib_mod.Library, db: *db_mod.Database, cmd: U.Cmd, current_path: *[:0]const u8) void {
    switch (cmd) {
        .none => {},
        .toggle_pause => {
            if (engine.isPlaying()) engine.pause() else engine.resumePlayback();
        },
        .toggle_favorite => {
            const id = lib.songIdByPath(current_path.*) orelse return;
            const cur = if (lib.getSongById(id)) |sg| sg.favorite != 0 else false;
            const nv = !cur;
            db.setFavorite(id, @intFromBool(nv)) catch return;
            lib.setFavorite(id, nv);
        },
        .next => _ = engine.playNext() catch {},
        .prev => engine.playPrevious() catch {},
        .vol_up => engine.setGain(@min(engine.getGain() + 0.05, 1.0)),
        .vol_down => engine.setGain(@max(engine.getGain() - 0.05, 0.0)),
        .toggle_shuffle => engine.setShuffled(!engine.isShuffled()) catch {},
        .cycle_repeat => engine.cycleRepeatMode(),
        .play_index => |i| {
            const id = lib.songIdAt(i);
            if (id < 0) return;
            const p = lib.songPath(id) orelse return;
            if (engine.playSound(p)) |_| {
                current_path.* = p;
            } else |_| {}
        },
    }
}

/// Keep the UI's transient snapshot in sync with the engine + library.
fn fillState(st: *U.State, engine: *RealEngine, lib: *lib_mod.Library, db: *db_mod.Database, current_path: [:0]const u8) void {
    st.title = current_path;
    st.artist = "";
    st.album = "";
    st.favorite = false;
    st.playing_index = null;
    if (lib.songIdByPath(current_path)) |id| {
        if (lib.getSongById(id)) |song| {
            st.title = song.title;
            st.favorite = song.favorite != 0;
        }
        if (db.getSongContext(id) catch null) |ctx| {
            st.artist = ctx.artist;
            st.album = ctx.album;
        }
        st.playing_index = lib.indexOfId(id);
    }
    st.path = current_path;
    st.position = engine.getTime();
    st.duration = engine.getDuration();
    st.playing = engine.isPlaying();
    st.volume = engine.getGain();
    st.shuffle = engine.isShuffled();
    st.repeat_mode = engine.getRepeatMode();
    st.row_count = lib.count();
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    try allegro_init.initialize();
    config_mod.initAppIdentity();

    const config_path = try config_mod.configFilePath(allocator);
    defer allocator.free(config_path);
    var config = config_mod.Config.create();
    defer config.destroy();
    try config.loadOrCreate(config_path);

    const db_path = try config_mod.databasePath(allocator);
    defer allocator.free(db_path);

    var lib = try lib_mod.Library.create(allocator);
    defer lib.destroy();
    var db = try db_mod.Database.open(lib.arena.allocator(), db_path);
    defer db.deinit();

    const music_dir = config.getMusicDirectory();
    const scan: scanner.ScanResult = scanner.scanDirectory(&db, allocator, music_dir, taglib_meta.extractor) catch .{};
    try lib.load(&db);
    if (lib.count() == 0) {
        std.debug.print("no songs in library\n", .{});
        return;
    }

    // Library display titles (parallel to lib.songIdAt order; strings are arena-owned).
    var titles = std.ArrayList([]const u8){ .items = &.{}, .capacity = 0 };
    defer titles.deinit(allocator);
    var ti: usize = 0;
    while (ti < lib.count()) : (ti += 1) {
        const id = lib.songIdAt(ti);
        if (lib.getSongById(id)) |s| try titles.append(allocator, s.title);
    }

    // Engine + queue + hooks (shared wiring with the GUI).
    var engine = try RealEngine.create(allocator);
    defer engine.destroy();
    var playback_ctx = PlaybackCtx{ .lib = lib, .db = &db };
    var play_queue = PlayQueue.init(allocator);
    defer play_queue.deinit();
    var qi: usize = 0;
    while (qi < lib.count()) : (qi += 1) try play_queue.enqueue(@intCast(lib.songIdAt(qi)));
    engine.setPlayQueue(&play_queue);
    engine.resolve_song = resolveSong;
    engine.on_song_changed = onSongChanged;
    engine.user_context = &playback_ctx;
    engine.setGain(@as(f32, @floatFromInt(config.getVolumePercent())) / 100.0);

    // Start the first playable song.
    var current_path: [:0]const u8 = undefined;
    var started = false;
    var tries: usize = 0;
    var i: usize = 0;
    while (i < lib.count() and !started and tries < 80) : (i += 1) {
        const id = lib.songIdAt(i);
        const p = lib.songPath(id) orelse continue;
        tries += 1;
        if (engine.playSound(p)) |_| {
            current_path = p;
            started = true;
        } else |_| {}
    }
    if (!started) {
        std.debug.print("no playable songs\n", .{});
        return;
    }

    render.enableRaw();
    defer render.restoreRaw();

    // theme: config override or auto-detect (dark vs light terminal)
    const theme_setting = config.getStr("ui", "theme", "auto");
    var scheme = theme.Scheme.dark;
    var auto = true;
    if (std.mem.eql(u8, theme_setting, "dark")) {
        scheme = .dark;
        auto = false;
    } else if (std.mem.eql(u8, theme_setting, "light")) {
        scheme = .light;
        auto = false;
    }
    render.setPalette(render.detectScheme(scheme, auto));

    const win = render.size();
    const width: u16 = win.w;
    const height: u16 = win.h;
    var st = U.State{};
    _ = scan;

    var quitting = false;
    while (!quitting) {
        // input
        while (render.pollKey()) |k| {
            if (k == 'q') {
                quitting = true;
                continue;
            }
            if (U.keyToAction(k)) |a| {
                const visible = view.libraryVisible(height);
                const cmd = U.apply(&st, a, visible);
                runCmd(engine, lib, &db, cmd, &current_path);
            }
        }

        // auto-advance when a track ends
        engine.update();
        if (!engine.isPlaying() and engine.getDuration() > 0 and engine.getTime() >= engine.getDuration()) {
            engine.handleAudioStreamFinished() catch {};
        }

        fillState(&st, engine, lib, &db, current_path);

        var cl = view.CmdList{};
        view.emit(&st, &cl, width, height, titles.items);
        render.render(cl.slice(), width);

        al.system.rest(0.1);
    }

    render.restoreRaw();
    std.debug.print("bye.\n", .{});
}
