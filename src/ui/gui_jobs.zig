//! Background jobs owned by the Allegro GUI frontend.
//!
//! Workers only perform filesystem/network work and publish small results via
//! atomics. App/database/config mutation remains on the frontend thread.

const std = @import("std");
const app_mod = @import("../app.zig");
const scanner = @import("../music/scanner.zig");
const health = @import("../music/library_health.zig");
const taglib_meta = @import("../music/taglib_meta.zig");
const lastfm = @import("../integrations/lastfm.zig");

pub const ScanJob = struct {
    app: *app_mod.App,
    allocator: std.mem.Allocator,
    music_directory: []u8 = &.{},
    previous_path: []u8 = &.{},
    thread: ?std.Thread = null,
    cancel: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    status: std.atomic.Value(u8) = std.atomic.Value(u8).init(0), // idle/running/done/failed
    result: scanner.ScanResult = .{},
    scanned: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    imported: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    updated: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    removed: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    startup: bool = false,

    fn progress(ctx: *anyopaque, result: *const scanner.ScanResult) void {
        const self: *ScanJob = @ptrCast(@alignCast(ctx));
        self.scanned.store(result.scanned, .release);
        self.imported.store(result.imported, .release);
        self.updated.store(result.updated, .release);
        self.removed.store(result.removed, .release);
    }

    fn shouldCancel(ctx: *anyopaque) bool {
        return @as(*ScanJob, @ptrCast(@alignCast(ctx))).cancel.load(.acquire);
    }

    fn worker(self: *ScanJob) void {
        self.result = scanner.scanDirectoryWithOptions(&self.app.db, self.allocator, self.music_directory, taglib_meta.extractor, .{
            .ctx = self,
            .on_progress = progress,
            .should_cancel = shouldCancel,
        }) catch {
            self.status.store(3, .release);
            return;
        };
        progress(self, &self.result);
        self.status.store(2, .release);
    }

    pub fn start(self: *ScanJob, startup: bool) !void {
        if (self.status.load(.acquire) != 0) return error.AlreadyRunning;
        self.music_directory = try self.allocator.dupe(u8, self.app.config.getMusicDirectory());
        errdefer {
            self.allocator.free(self.music_directory);
            self.music_directory = &.{};
        }
        if (self.app.has_current_path) self.previous_path = try self.allocator.dupe(u8, self.app.current_path);
        errdefer if (self.previous_path.len > 0) {
            self.allocator.free(self.previous_path);
            self.previous_path = &.{};
        };
        self.app.engine.stop();
        self.startup = startup;
        self.cancel.store(false, .release);
        self.result = .{};
        self.scanned.store(0, .release);
        self.imported.store(0, .release);
        self.updated.store(0, .release);
        self.removed.store(0, .release);
        self.status.store(1, .release);
        self.thread = std.Thread.spawn(.{}, worker, .{self}) catch |err| {
            self.status.store(0, .release);
            return err;
        };
    }

    pub fn cancelScan(self: *ScanJob) void {
        if (self.status.load(.acquire) == 1) self.cancel.store(true, .release);
    }

    pub fn join(self: *ScanJob) void {
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
    }

    pub fn deinit(self: *ScanJob) void {
        self.cancelScan();
        self.join();
        if (self.music_directory.len > 0) self.allocator.free(self.music_directory);
        if (self.previous_path.len > 0) self.allocator.free(self.previous_path);
    }
};

/// Cancellable, read-only health analysis; unlike ScanJob this never touches
/// the database after receiving the caller's snapshot of known paths.
pub const HealthJob = struct {
    allocator: std.mem.Allocator,
    root: []u8 = &.{},
    known_paths: std.ArrayList([]const u8) = .empty,
    thread: ?std.Thread = null,
    cancel: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    status: std.atomic.Value(u8) = std.atomic.Value(u8).init(0), // idle/running/done/failed/cancelled
    scanned: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    report: ?health.Report = null,

    fn progress(ctx: *anyopaque, scanned: usize) void {
        @as(*HealthJob, @ptrCast(@alignCast(ctx))).scanned.store(scanned, .release);
    }
    fn shouldCancel(ctx: *anyopaque) bool {
        return @as(*HealthJob, @ptrCast(@alignCast(ctx))).cancel.load(.acquire);
    }
    fn worker(self: *HealthJob) void {
        self.report = health.generate(self.allocator, self.root, self.known_paths.items, .{
            .ctx = self,
            .on_progress = progress,
            .should_cancel = shouldCancel,
        }) catch |err| {
            self.status.store(if (err == error.Cancelled) 4 else 3, .release);
            return;
        };
        self.status.store(2, .release);
    }
    pub fn start(self: *HealthJob, root: []const u8, known_paths: []const []const u8) !void {
        if (self.status.load(.acquire) != 0) return error.AlreadyRunning;
        self.root = try self.allocator.dupe(u8, root);
        errdefer {
            self.allocator.free(self.root);
            self.root = &.{};
        }
        errdefer self.freeKnownPaths();
        for (known_paths) |path| {
            const owned = try self.allocator.dupe(u8, path);
            self.known_paths.append(self.allocator, owned) catch |err| {
                self.allocator.free(owned);
                return err;
            };
        }
        self.cancel.store(false, .release);
        self.scanned.store(0, .release);
        self.status.store(1, .release);
        self.thread = std.Thread.spawn(.{}, worker, .{self}) catch |err| {
            self.status.store(0, .release);
            return err;
        };
    }
    pub fn requestCancel(self: *HealthJob) void {
        if (self.status.load(.acquire) == 1) self.cancel.store(true, .release);
    }
    pub fn join(self: *HealthJob) void {
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
    }
    fn freeKnownPaths(self: *HealthJob) void {
        for (self.known_paths.items) |path| self.allocator.free(path);
        self.known_paths.clearRetainingCapacity();
    }
    pub fn reset(self: *HealthJob) void {
        self.requestCancel();
        self.join();
        if (self.report) |*report| report.deinit();
        self.report = null;
        self.freeKnownPaths();
        if (self.root.len > 0) self.allocator.free(self.root);
        self.root = &.{};
        self.status.store(0, .release);
    }
    pub fn deinit(self: *HealthJob) void {
        self.reset();
    }
};

pub const AuthOp = enum { begin, finish };

pub const AuthJob = struct {
    allocator: std.mem.Allocator,
    op: AuthOp = .begin,
    api_key: []u8 = &.{},
    shared_secret: []u8 = &.{},
    token: []u8 = &.{},
    result_url: []u8 = &.{},
    result_token: []u8 = &.{},
    result_session: []u8 = &.{},
    thread: ?std.Thread = null,
    status: std.atomic.Value(u8) = std.atomic.Value(u8).init(0), // idle/running/done/failed

    pub fn start(self: *AuthJob, op: AuthOp, api_key: []const u8, shared_secret: []const u8, token: []const u8) !void {
        if (self.status.load(.acquire) != 0) return error.AlreadyRunning;
        self.clearResults();
        self.api_key = try self.allocator.dupe(u8, api_key);
        errdefer {
            self.allocator.free(self.api_key);
            self.api_key = &.{};
        }
        self.shared_secret = try self.allocator.dupe(u8, shared_secret);
        errdefer {
            self.allocator.free(self.shared_secret);
            self.shared_secret = &.{};
        }
        self.token = try self.allocator.dupe(u8, token);
        errdefer {
            self.allocator.free(self.token);
            self.token = &.{};
        }
        self.op = op;
        self.status.store(1, .release);
        self.thread = std.Thread.spawn(.{}, worker, .{self}) catch |err| {
            self.status.store(0, .release);
            return err;
        };
    }

    fn worker(self: *AuthJob) void {
        switch (self.op) {
            .begin => {
                var ticket = lastfm.beginAuth(self.allocator, self.api_key, self.shared_secret) catch {
                    self.status.store(3, .release);
                    return;
                };
                self.result_url = ticket.url;
                self.result_token = ticket.token;
                ticket.url = &.{};
                ticket.token = &.{};
            },
            .finish => self.result_session = lastfm.finishAuth(self.allocator, self.api_key, self.shared_secret, self.token) catch {
                self.status.store(3, .release);
                return;
            },
        }
        self.status.store(2, .release);
    }

    pub fn join(self: *AuthJob) void {
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
    }

    pub fn clearResults(self: *AuthJob) void {
        if (self.result_url.len > 0) self.allocator.free(self.result_url);
        if (self.result_token.len > 0) self.allocator.free(self.result_token);
        if (self.result_session.len > 0) self.allocator.free(self.result_session);
        self.result_url = &.{};
        self.result_token = &.{};
        self.result_session = &.{};
    }

    pub fn deinit(self: *AuthJob) void {
        self.join();
        self.clearResults();
        if (self.api_key.len > 0) self.allocator.free(self.api_key);
        if (self.shared_secret.len > 0) self.allocator.free(self.shared_secret);
        if (self.token.len > 0) self.allocator.free(self.token);
    }
};
