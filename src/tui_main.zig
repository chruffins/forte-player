//! TUI frontend wired onto the shared UI pipeline:
//!   App(engine/library) -> State snapshot -> (keys -> Action -> apply -> Cmd -> engine)
//!                                              -> view.emit -> CmdList -> render
//!
//! Shared startup (config, DB+library scan, engine+queue+hooks) lives in
//! `App`; this file only adds the TUI-specific bits (Discord presence, album
//! cover resolution, the terminal render loop). The `ui/ui_*.zig` core is pure;
//! this is the thin, partially-impure glue.

const std = @import("std");
const al = @import("allegro");
const app_mod = @import("app.zig");
const cover_resolver = @import("integrations/cover_resolver.zig");
const cover_art = @import("ui/cover_art.zig");
const discord_rpc = @import("integrations/discord_rpc.zig");
const spectrum = @import("dsp/spectrum.zig");

const U = @import("ui/ui_state.zig");
const view = @import("ui/ui_view.zig");
const render = @import("ui/tui_render.zig");
const theme = @import("ui/theme.zig");

/// Drawing is paced by an Allegro timer rather than a fixed sleep: the timer
/// ticks every `timer_interval_secs`, and we only render once the event queue
/// is drained. That gives consistent ~20 FPS for the spectrum, and lets a
/// slow frame drop instead of backing up behind the tick rate.
const timer_interval_secs: f64 = 0.05; // 20 ticks/sec
/// How often we wake while idle to poll raw terminal keys. stdin has no
/// Allegro event source headless, so keys are read directly, not from the queue.
const input_poll_secs: f32 = 0.004;

/// TUI-specific per-song extras on top of the shared `App`. `App` owns the
/// library/db/engine/current_path bookkeeping; this hooks Discord presence +
/// cover resolution onto song changes.
const TuiUser = struct {
    app: *app_mod.App,
    discord: *discord_rpc.Client,
    resolver: *cover_resolver.CoverResolver,
    details_format: []const u8,
};

fn onSongChanged(user_ctx: *anyopaque, path: [:0]const u8) void {
    const u: *TuiUser = @ptrCast(@alignCast(user_ctx));
    const app = u.app;
    const id = app.lib.songIdByPath(path) orelse return;

    var title: []const u8 = "";
    var artist: []const u8 = "";
    var album: []const u8 = "";
    var album_id: i64 = -1;
    if (app.lib.getSongById(id)) |song| {
        title = song.title;
        album_id = song.album_id;
    }
    if (app.db.getSongContext(id) catch null) |cctx| {
        artist = cctx.artist;
        album = cctx.album;
    }

    // Queue a MusicBrainz cover lookup for this album (runs on resolver.tick()).
    u.resolver.enqueue(album_id, album, artist);
    pushPresence(u, title, artist, album, album_id, app.engine.getDuration());
}

/// Render the configured presence details format (default "{song} - {artist}").
fn formatDetails(fmt: []const u8, song: []const u8, artist: []const u8, album: []const u8, buf: []u8) []const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < fmt.len) {
        if (fmt[i] == '{') {
            const close = std.mem.indexOfScalarPos(u8, fmt, i + 1, '}') orelse {
                const rest = fmt[i..];
                if (n + rest.len > buf.len) break;
                @memcpy(buf[n .. n + rest.len], rest);
                n += rest.len;
                break;
            };
            const name = fmt[i + 1 .. close];
            const val: ?[]const u8 = if (std.mem.eql(u8, name, "song")) song else if (std.mem.eql(u8, name, "artist")) artist else if (std.mem.eql(u8, name, "album")) album else null;
            if (val) |v| {
                if (n + v.len > buf.len) break;
                @memcpy(buf[n .. n + v.len], v);
                n += v.len;
            } else {
                const lit = fmt[i .. close + 1];
                if (n + lit.len > buf.len) break;
                @memcpy(buf[n .. n + lit.len], lit);
                n += lit.len;
            }
            i = close + 1;
        } else {
            if (n + 1 > buf.len) break;
            buf[n] = fmt[i];
            n += 1;
            i += 1;
        }
    }
    return buf[0..n];
}

/// Push the current song to Discord presence (best-effort).
fn pushPresence(u: *TuiUser, title: []const u8, artist: []const u8, album: []const u8, album_id: i64, duration: f64) void {
    var buf: [512]u8 = undefined;
    const details = formatDetails(u.details_format, title, artist, album, &buf);
    u.discord.setPresence(details, album, duration, u.resolver.coverUrlFor(album_id));
}

fn runCmd(app: *app_mod.App, cmd: U.Cmd) void {
    const engine = app.engine;
    const lib = app.lib;
    const db = &app.db;
    const current_path = app.current_path;
    switch (cmd) {
        .none => {},
        .toggle_pause => {
            if (engine.isPlaying()) engine.pause() else engine.resumePlayback();
        },
        .toggle_favorite => {
            const id = lib.songIdByPath(current_path) orelse return;
            const cur = if (lib.getSongById(id)) |sg| sg.favorite != 0 else false;
            const nv = !cur;
            db.setFavorite(id, @intFromBool(nv)) catch return;
            lib.setFavorite(id, nv);
        },
        .seek => |target| engine.setProgress(target),
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
            // App's shared on_song_changed hook keeps app.current_path in sync.
            if (engine.playSound(p)) |_| {} else |_| {}
        },
    }
}

/// Keep the UI's transient snapshot in sync with the engine + library.
fn fillState(st: *U.State, app: *app_mod.App) void {
    const engine = app.engine;
    const lib = app.lib;
    const db = &app.db;
    const current_path = app.current_path;
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

    var app = try app_mod.App.create(allocator, null, null);
    defer app.destroy();
    // Live audio capture for the TUI spectrum (ring fed by the mixer callback).
    app.engine.setSampleBufferCapacity(8192) catch {};

    const cfg_app_id = app.config.getDiscordApplicationId();
    var discord = discord_rpc.Client.init(if (cfg_app_id > 0) cfg_app_id else discord_rpc.default_app_id);
    defer discord.deinit();
    var resolver = cover_resolver.CoverResolver.init(allocator, &app.db) catch |e| {
        std.debug.print("cover resolver init failed: {}\n", .{e});
        return;
    };
    defer resolver.destroy();
    var tui_user = TuiUser{
        .app = app,
        .discord = &discord,
        .resolver = resolver,
        .details_format = app.config.getDiscordDetailsFormat(),
    };
    // Wire the TUI-specific per-song work (presence + cover lookup) in.
    app.ctx.user = &tui_user;
    app.ctx.song_changed = onSongChanged;

    if (app.startFirstSong() == null) {
        std.debug.print("no playable songs\n", .{});
        return;
    }
    app.engine.setGain(@as(f32, @floatFromInt(app.config.getVolumePercent())) / 100.0);

    // Library display titles (parallel to lib.songIdAt order; strings are arena-owned).
    var titles = std.ArrayList([]const u8){ .items = &.{}, .capacity = 0 };
    defer titles.deinit(allocator);
    var ti: usize = 0;
    while (ti < app.lib.count()) : (ti += 1) {
        const id = app.lib.songIdAt(ti);
        if (app.lib.getSongById(id)) |s| try titles.append(allocator, s.title);
    }

    render.enableRaw();
    defer render.restoreRaw();

    // theme: config override or auto-detect (dark vs light terminal)
    const theme_setting = app.config.getStr("ui", "theme", "auto");
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
    // Spectrum scratch (persist across frames so the smoother keeps state).
    var sample_buf: [spectrum.n_samples]f32 = undefined;
    var raw_bands: [spectrum.n_bands]f32 = undefined;
    var smoother = spectrum.Smoother{};
    // Album art scratch (persist so we fetch/decode once per album).
    const art_max_w: usize = 32;
    const art_max_h: usize = 17;
    var art_cells: [art_max_w * art_max_h]U.ArtCell = undefined;
    var art_for_album: i64 = -1;
    var art_ok = false;
    var art_w: u16 = 0;
    var art_h: u16 = 0;

    // Pace drawing with an Allegro timer (event-driven, headless-safe).
    var ticker = try al.Timer.create(timer_interval_secs);
    defer ticker.destroy();
    var tqueue = try al.EventQueue.create();
    defer tqueue.destroy();
    tqueue.registerTimer(&ticker);
    ticker.start();
    defer ticker.stop();

    var ev: al.Event = undefined;
    var frame_due = false;
    var quitting = false;
    while (!quitting) {
        // Wait for a timer tick, or the poll timeout so we can service stdin.
        if (tqueue.waitForEventTimed(&ev, input_poll_secs)) {
            if (al.eventType(ev) == .timer) frame_due = true;
        }

        // Raw terminal keys: no Allegro event source headless, so poll stdin
        // directly on every wake.
        while (render.pollKey()) |k| {
            if (k == 'q') {
                quitting = true;
                continue;
            }
            if (U.keyToAction(k)) |a| {
                const visible = view.libraryVisible(height);
                const cmd = U.apply(&st, a, visible);
                runCmd(app, cmd);
            }
        }

        // Only draw when a tick is due AND the queue is drained: if rendering
        // is slower than the timer, extra ticks pile up here and we skip them
        // (frame-dropping) rather than re-render the stale backlog.
        if (frame_due and tqueue.isEmpty()) {
            frame_due = false;

            // auto-advance when a track ends
            app.engine.update();
            if (!app.engine.isPlaying() and app.engine.getDuration() > 0 and app.engine.getTime() >= app.engine.getDuration()) {
                app.engine.handleAudioStreamFinished() catch {};
            }

            fillState(&st, app);

            // Refresh the spectrum from the newest captured mono samples.
            const got = app.engine.copyRecentMono(sample_buf.len, &sample_buf);
            if (got > 0) {
                spectrum.computeBands(sample_buf[0..got], &raw_bands);
                smoother.update(&raw_bands);
                st.spectrum = smoother.levels[0..];
            } else {
                st.spectrum = &.{};
            }

            // Album art: prefer art the scanner extracted (embedded/folder cover,
            // instant and offline); fall back to the resolved CAA URL. The album
            // guard fires before either is ready on the first frame, so re-check.
            if (app.lib.songIdByPath(st.path)) |sid| {
                if (app.lib.getSongById(sid)) |song| {
                    const aid = song.album_id;
                    if (aid != art_for_album) {
                        art_for_album = aid;
                        art_ok = false;
                    }
                    if (!art_ok) {
                        const aw: usize = @min(art_max_w, width -| 52);
                        const ah: usize = @min(art_max_h, height -| 7);
                        if (aw >= 8 and ah >= 4 and aw * ah <= art_cells.len) {
                            // 1) scanner-extracted art from the db.
                            if (app.db.getAlbumCover(aid) catch null) |cover| {
                                if (cover.bytes.len > 0) {
                                    art_w = @intCast(aw);
                                    art_h = @intCast(ah);
                                    art_ok = cover_art.renderCover(cover.bytes, aw, ah, art_cells[0 .. aw * ah]);
                                }
                            }
                            // 2) fallback: the CAA URL resolved by the MusicBrainz lookup.
                            if (!art_ok and resolver.coverUrlFor(aid) != null) {
                                if (resolver.coverImageBytes(aid)) |bytes| {
                                    if (bytes.len > 0) {
                                        art_w = @intCast(aw);
                                        art_h = @intCast(ah);
                                        art_ok = cover_art.renderCover(bytes, aw, ah, art_cells[0 .. aw * ah]);
                                    }
                                }
                            }
                        }
                    }
                }
            }
            if (art_ok) {
                st.art = .{ .w = art_w, .h = art_h, .cells = art_cells[0 .. art_w * art_h] };
            } else {
                st.art = .{};
            }

            // Cover lookups run here (rate-limited, at most one per second), never
            // inside the song-change hook. When a cover resolves for the album that
            // is currently playing, refresh the presence so the art appears.
            if (resolver.tick()) {
                if (app.lib.songIdByPath(st.path)) |sid| {
                    if (app.lib.getSongById(sid)) |song| {
                        if (resolver.coverUrlFor(song.album_id) != null) {
                            pushPresence(&tui_user, st.title, st.artist, st.album, song.album_id, st.duration);
                        }
                    }
                }
            }

            var cl = view.CmdList{};
            view.emit(&st, &cl, width, height, titles.items);
            render.render(cl.slice(), width, height);
        }
    }

    render.restoreRaw();
    std.debug.print("bye.\n", .{});
}
