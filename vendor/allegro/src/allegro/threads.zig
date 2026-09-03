const std = @import("std");
const c = @import("c");
const Timeout = @import("time.zig").Timeout;

/// The C callback signature for a thread entry point.
pub const Proc = *const fn (thread: ?*c.ALLEGRO_THREAD, arg: ?*anyopaque) callconv(.c) ?*anyopaque;
/// The C callback signature for a detached thread entry point.
pub const DetachedProc = *const fn (arg: ?*anyopaque) callconv(.c) ?*anyopaque;

pub const ThreadError = error{ CreateFailed };

pub const Thread = struct {
    thread: *c.ALLEGRO_THREAD,
    freeArg: bool = false,

    pub fn create(proc: Proc, arg: ?*anyopaque) !Thread {
        const t = c.al_create_thread(proc, arg) orelse return ThreadError.CreateFailed;
        return .{ .thread = t, .freeArg = false };
    }

    pub fn start(self: *Thread) void {
        c.al_start_thread(self.thread);
    }

    /// Block until the thread finishes, returning its result pointer.
    pub fn join(self: *Thread) ?*anyopaque {
        var ret: ?*anyopaque = null;
        c.al_join_thread(self.thread, &ret);
        return ret;
    }

    pub fn destroy(self: *Thread) void {
        c.al_destroy_thread(self.thread);
        self.freeArg = false;
    }

    pub fn shouldStop(self: *Thread) bool {
        return c.al_get_thread_should_stop(self.thread);
    }

    pub fn requestStop(self: *Thread) void {
        c.al_set_thread_should_stop(self.thread);
    }
};

/// Run a function on a new thread without keeping a handle to it.
pub fn runDetached(proc: DetachedProc, arg: ?*anyopaque) void {
    c.al_run_detached_thread(proc, arg);
}

pub const Mutex = struct {
    mutex: *c.ALLEGRO_MUTEX,

    pub fn create() !Mutex {
        const m = c.al_create_mutex() orelse return error.CreateFailed;
        return .{ .mutex = m };
    }

    pub fn createRecursive() !Mutex {
        const m = c.al_create_mutex_recursive() orelse return error.CreateFailed;
        return .{ .mutex = m };
    }

    pub fn destroy(self: *Mutex) void {
        c.al_destroy_mutex(self.mutex);
    }

    pub fn lock(self: *Mutex) void {
        c.al_lock_mutex(self.mutex);
    }

    pub fn unlock(self: *Mutex) void {
        c.al_unlock_mutex(self.mutex);
    }
};

pub const Cond = struct {
    cond: *c.ALLEGRO_COND,

    pub fn create() !Cond {
        const cnd = c.al_create_cond() orelse return error.CreateFailed;
        return .{ .cond = cnd };
    }

    pub fn destroy(self: *Cond) void {
        c.al_destroy_cond(self.cond);
    }

    pub fn wait(self: *Cond, mutex: *Mutex) void {
        c.al_wait_cond(self.cond, mutex.mutex);
    }

    pub fn waitUntil(self: *Cond, mutex: *Mutex, timeout: *const Timeout) bool {
        return c.al_wait_cond_until(self.cond, mutex.mutex, &timeout.timeout) != 0;
    }

    pub fn signal(self: *Cond) void {
        c.al_signal_cond(self.cond);
    }

    pub fn broadcast(self: *Cond) void {
        c.al_broadcast_cond(self.cond);
    }
};

test "refAllDecls" {
    std.testing.refAllDecls(Thread);
    std.testing.refAllDecls(Mutex);
    std.testing.refAllDecls(Cond);
}
