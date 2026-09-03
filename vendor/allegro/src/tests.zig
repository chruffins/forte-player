const std = @import("std");
const al = @import("allegro");

// Force full analysis of the entire wrapper (all namespaces, types and methods),
// so any binding/signature mistake anywhere in the library fails the build.
comptime {
    std.testing.refAllDecls(al);
}

pub fn main() void {
    std.debug.print("allegro5-zig: full wrapper surface compiled successfully\n", .{});
    _ = al.system.version();
}