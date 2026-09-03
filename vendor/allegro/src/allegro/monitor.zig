const std = @import("std");
const c = @import("c");

/// A rectangle describing a monitor's desktop area.
pub const MonitorInfo = struct {
    x1: i32,
    y1: i32,
    x2: i32,
    y2: i32,
};

pub fn numVideoAdapters() i32 {
    return c.al_get_num_video_adapters();
}

/// Get the desktop area of monitor `adapter`.
pub fn getInfo(adapter: i32) ?MonitorInfo {
    var info: c.ALLEGRO_MONITOR_INFO = undefined;
    if (!c.al_get_monitor_info(adapter, &info)) return null;
    return .{
        .x1 = info.x1,
        .y1 = info.y1,
        .x2 = info.x2,
        .y2 = info.y2,
    };
}

pub fn getDpi(adapter: i32) i32 {
    return c.al_get_monitor_dpi(adapter);
}

test "refAllDecls" {
    std.testing.refAllDecls(@This());
}
