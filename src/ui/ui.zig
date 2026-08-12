//! The redesigned UI layer.
//!
//! This module is intentionally a *seed*: the redesign hasn't been specced yet,
//! so this only defines the small, stable geometry types the rest of the layer
//! will build on. Everything here is pure math (no Allegro), so it's fully
//! testable headless -- keep it that way as the layer grows.
//!
//! See `ui/DESIGN.md` for the intended architecture.

const std = @import("std");

/// A rectangle in some parent's coordinate space. The C++ port used a pair of
/// "UV" corner tuples; we keep a plain (x, y, w, h) which is simpler and
/// composition-friendly. Layout and rendering feed off this same type.
pub const Rect = struct {
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,

    pub fn right(self: Rect) f32 {
        return self.x + self.w;
    }
    pub fn bottom(self: Rect) f32 {
        return self.y + self.h;
    }

    /// True if `p` lies inside the rect (inclusive of the top/left edge).
    pub fn contains(self: Rect, px: f32, py: f32) bool {
        return px >= self.x and px <= self.right() and py >= self.y and py <= self.bottom();
    }

    /// Shrink by `amount` on all sides. Returns an empty rect if it collapses.
    pub fn inset(self: Rect, amount: f32) Rect {
        const nx = self.x + amount;
        const ny = self.y + amount;
        const nw = self.w - 2 * amount;
        const nh = self.h - 2 * amount;
        if (nw <= 0 or nh <= 0) return .{};
        return .{ .x = nx, .y = ny, .w = nw, .h = nh };
    }

    /// Move the rect by an offset.
    pub fn translate(self: Rect, dx: f32, dy: f32) Rect {
        return .{ .x = self.x + dx, .y = self.y + dy, .w = self.w, .h = self.h };
    }
};

test "Rect basics" {
    const r = Rect{ .x = 10, .y = 20, .w = 100, .h = 50 };
    try std.testing.expectEqual(@as(f32, 110), r.right());
    try std.testing.expectEqual(@as(f32, 70), r.bottom());
    try std.testing.expect(r.contains(10, 20));
    try std.testing.expect(r.contains(109, 69));
    try std.testing.expect(!r.contains(9, 20));
    try std.testing.expect(!r.contains(20, 71));
}

test "Rect inset + collapse" {
    const r = Rect{ .x = 0, .y = 0, .w = 100, .h = 40 };
    const in = r.inset(5);
    try std.testing.expectEqual(Rect{ .x = 5, .y = 5, .w = 90, .h = 30 }, in);

    // Insets that collapse the rect return an empty one.
    try std.testing.expectEqual(Rect{}, r.inset(200));
    try std.testing.expectEqual(Rect{}, r.inset(30)); // 100-60=40>0? -> h:40-60=0 -> empty
}
