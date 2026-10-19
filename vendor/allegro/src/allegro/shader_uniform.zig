//! Pure validation for the scalar-slice uniform upload API.
const std = @import("std");

/// Allegro expects a vector count, not the length of the scalar slice.
pub fn vectorCount(components: i32, len: usize) ?i32 {
    if (components < 1 or components > 4) return null;
    const width: usize = @intCast(components);
    if (len % width != 0 or len / width > std.math.maxInt(i32)) return null;
    return @intCast(len / width);
}

test "vector uniform counts use vectors rather than scalar length" {
    try std.testing.expectEqual(@as(?i32, 1), vectorCount(4, 4));
    try std.testing.expectEqual(@as(?i32, 1), vectorCount(2, 2));
    try std.testing.expectEqual(@as(?i32, 2), vectorCount(3, 6));
    try std.testing.expectEqual(@as(?i32, 12), vectorCount(4, 48));
    try std.testing.expectEqual(@as(?i32, 48), vectorCount(1, 48));
    try std.testing.expect(vectorCount(2, 3) == null);
    try std.testing.expect(vectorCount(0, 2) == null);
    try std.testing.expect(vectorCount(5, 10) == null);
    try std.testing.expect(vectorCount(1, @as(usize, std.math.maxInt(i32)) + 1) == null);
}
