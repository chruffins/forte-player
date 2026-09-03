const std = @import("std");
const c = @import("c");

const SRC = "allegro5-zig/memory.zig";

/// Allocate raw memory through Allegro's memory manager.
pub fn malloc(size: usize) ?*anyopaque {
    return c.al_malloc_with_context(size, 0, SRC, "malloc");
}

/// Allocate zero-initialised memory.
pub fn calloc(count: usize, size: usize) ?*anyopaque {
    return c.al_calloc_with_context(count, size, 0, SRC, "calloc");
}

/// Resize previously allocated memory.
pub fn realloc(ptr: ?*anyopaque, size: usize) ?*anyopaque {
    return c.al_realloc_with_context(ptr, size, 0, SRC, "realloc");
}

pub fn free(ptr: ?*anyopaque) void {
    c.al_free_with_context(ptr, 0, SRC, "free");
}

/// Replace Allegro's global memory allocator with a custom implementation.
pub fn setInterface(iface: *c.ALLEGRO_MEMORY_INTERFACE) void {
    c.al_set_memory_interface(iface);
}

test "refAllDecls" {
    std.testing.refAllDecls(@This());
}
