//! Display-owned, bounded album thumbnail cache. Queries run on the frontend;
//! one worker decodes/downsizes MEMORY bitmaps. Only the frontend uploads GPU
//! resources, and rendering only looks up already-published thumbnails.
const std = @import("std");
const al = @import("allegro");
const Database = @import("../music/database.zig").Database;
const c = @import("forte_c");

pub const capacity = 48;
pub const thumbnail_size = 512;
pub const max_encoded_bytes = 16 * 1024 * 1024;
const Entry = struct {
    id: i64 = -1,
    touched: u64 = 0,
    bitmap: ?al.graphics.Bitmap = null,
};

pub const Cache = struct {
    allocator: std.mem.Allocator,
    entries: [capacity]Entry = @splat(.{}),
    clock: u64 = 0,
    thread: ?std.Thread = null,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    pending_slot: usize = 0,
    encoded: []const u8 = &.{},
    mime: []const u8 = &.{},
    result: ?al.graphics.Bitmap = null,

    pub fn get(self: *const Cache, id: i64) ?*const al.graphics.Bitmap {
        if (id < 0) return null;
        for (&self.entries) |*entry| if (entry.id == id) {
            return if (entry.bitmap) |*b| b else null;
        };
        return null;
    }

    /// Touch existing entries, or start at most one decode. Missing/invalid
    /// art is cached too, so a bad image never gets retried every frame.
    pub fn request(self: *Cache, db: *Database, id: i64) void {
        if (id < 0) return;
        self.clock +%= 1;
        for (&self.entries) |*entry| if (entry.id == id) {
            entry.touched = self.clock;
            return;
        };
        if (self.thread != null) return;
        var slot: usize = 0;
        for (self.entries, 0..) |entry, i| {
            if (entry.id < 0) {
                slot = i;
                break;
            }
            if (entry.touched < self.entries[slot].touched) slot = i;
        }
        const entry = &self.entries[slot];
        if (entry.bitmap) |*bitmap| bitmap.destroy();
        entry.* = .{ .id = id, .touched = self.clock };
        const cover = db.getAlbumThumbnailSource(self.allocator, id, max_encoded_bytes) catch return;
        if (cover == null) return;
        self.encoded = cover.?.bytes;
        self.mime = cover.?.mime;
        self.pending_slot = slot;
        self.done.store(false, .release);
        self.thread = std.Thread.spawn(.{}, worker, .{self}) catch {
            self.freeSource();
            return;
        };
    }

    fn worker(self: *Cache) void {
        self.result = decode(self.encoded, self.mime);
        self.done.store(true, .release);
    }

    pub fn poll(self: *Cache) void {
        if (self.thread == null or !self.done.load(.acquire)) return;
        self.thread.?.join();
        self.thread = null;
        self.freeSource();
        if (self.result) |*bitmap| if (c.al_get_current_display() != null) {
            // Allegro's bitmap defaults/target are thread-local. Conversion is
            // deliberately performed with the display current on this thread.
            const flags = al.graphics.getNewBitmapFlags();
            al.graphics.setNewBitmapFlags(al.graphics.BitmapFlags.VIDEO_BITMAP);
            bitmap.convert();
            al.graphics.setNewBitmapFlags(flags);
        };
        self.entries[self.pending_slot].bitmap = self.result;
        self.result = null;
    }

    fn freeSource(self: *Cache) void {
        self.allocator.free(self.encoded);
        self.allocator.free(self.mime);
        self.encoded = &.{};
        self.mime = &.{};
    }

    /// Join the memory-only worker before releasing display-owned bitmaps.
    pub fn reset(self: *Cache) void {
        if (self.thread) |thread| thread.join();
        self.thread = null;
        self.freeSource();
        if (self.result) |*bitmap| bitmap.destroy();
        self.result = null;
        for (&self.entries) |*entry| {
            if (entry.bitmap) |*bitmap| bitmap.destroy();
            entry.* = .{};
        }
    }
};

fn decode(bytes: []const u8, mime: []const u8) ?al.graphics.Bitmap {
    const flags = al.graphics.getNewBitmapFlags();
    al.graphics.setNewBitmapFlags(al.graphics.BitmapFlags.MEMORY_BITMAP);
    defer al.graphics.setNewBitmapFlags(flags);
    var file = al.file.File.openMemFile(bytes.ptr, @intCast(bytes.len), "r") catch return null;
    defer _ = file.close();
    const ident: [:0]const u8 = if (std.mem.indexOf(u8, mime, "png") != null) ".png" else if (std.mem.indexOf(u8, mime, "webp") != null) ".webp" else ".jpg";
    var source = al.graphics.Bitmap.loadFromFile(&file, ident) catch return null;
    defer source.destroy();
    const sw = source.getWidth();
    const sh = source.getHeight();
    if (sw <= 0 or sh <= 0 or sw > 8192 or sh > 8192) return null;
    const scale = @min(1.0, @as(f32, thumbnail_size) / @as(f32, @floatFromInt(@max(sw, sh))));
    const w: i32 = @intFromFloat(@max(1, @as(f32, @floatFromInt(sw)) * scale));
    const h: i32 = @intFromFloat(@max(1, @as(f32, @floatFromInt(sh)) * scale));
    var thumb = al.graphics.Bitmap.create(w, h) catch return null;
    const previous = al.graphics.getTargetBitmap();
    thumb.setTarget();
    defer if (previous) |p| @constCast(&p).setTarget() else c.al_set_target_bitmap(null);
    al.graphics.clearToColor(al.Color.fromRgba(0, 0, 0, 0));
    source.drawScaled(0, 0, @floatFromInt(sw), @floatFromInt(sh), 0, 0, @floatFromInt(w), @floatFromInt(h), 0);
    return thumb;
}

test "artwork cache bounds and missing ids" {
    var cache = Cache{ .allocator = std.testing.allocator };
    defer cache.reset();
    try std.testing.expect(cache.get(-1) == null);
    try std.testing.expect(cache.get(123) == null);
    try std.testing.expectEqual(@as(usize, 48), cache.entries.len);
}

test "thumbnail decode preserves aspect ratio, target and bitmap defaults" {
    try @import("../core/allegro_init.zig").initialize();
    const flags = al.graphics.getNewBitmapFlags();
    defer al.graphics.setNewBitmapFlags(flags);
    al.graphics.setNewBitmapFlags(al.graphics.BitmapFlags.MEMORY_BITMAP);
    var target = try al.graphics.Bitmap.create(8, 8);
    defer target.destroy();
    const previous = al.graphics.getTargetBitmap();
    target.setTarget();
    defer if (previous) |p| @constCast(&p).setTarget() else c.al_set_target_bitmap(null);
    var thumb = decode(@embedFile("testdata/artwork.png"), "image/png") orelse return error.DecodeFailed;
    defer thumb.destroy();
    try std.testing.expectEqual(@as(i32, 512), thumb.getWidth());
    try std.testing.expectEqual(@as(i32, 256), thumb.getHeight());
    try std.testing.expectEqual(target.bmp, al.graphics.getTargetBitmap().?.bmp);
    try std.testing.expectEqual(al.graphics.BitmapFlags.MEMORY_BITMAP, al.graphics.getNewBitmapFlags());
    // Pixel readback is test-only.
    try std.testing.expect(thumb.getPixel(10, 10).r > 0.9);
    try std.testing.expect(thumb.getPixel(10, 240).b > 0.9);
    try std.testing.expect(decode("not an image", "image/png") == null);
}

test "cache publishes one worker result and rejects oversized source in SQL" {
    try @import("../core/allegro_init.zig").initialize();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var db = try Database.open(arena.allocator(), null);
    defer db.deinit();
    const artist = try db.addArtist("Thumbnail test");
    const album = try db.addAlbum("Cover", artist, 2024);
    const source = @embedFile("testdata/artwork.png");
    try db.setAlbumCover(album, "image/png", source);
    try std.testing.expect((try db.getAlbumThumbnailSource(arena.allocator(), album, source.len - 1)) == null);
    var cache = Cache{ .allocator = std.testing.allocator };
    defer cache.reset();
    cache.request(&db, album);
    try std.testing.expect(cache.thread != null);
    try std.testing.expect(cache.get(album) == null);
    cache.request(&db, album + 1);
    try std.testing.expectEqual(album, cache.entries[cache.pending_slot].id);
    const deadline = al.time.getTime() + 5;
    while (!cache.done.load(.acquire)) {
        if (al.time.getTime() > deadline) return error.WorkerTimeout;
        c.al_rest(0.001);
    }
    cache.poll();
    try std.testing.expect(cache.get(album) != null);
    try std.testing.expect(cache.thread == null);
    try std.testing.expectEqual(@as(usize, 0), cache.encoded.len);
    // No decode retry after publication; touching an existing cache entry does
    // not issue another query or start a worker.
    cache.request(&db, album);
    try std.testing.expect(cache.thread == null);
    cache.reset();
    try std.testing.expect(cache.get(album) == null);
}
