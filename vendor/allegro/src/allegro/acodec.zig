const std = @import("std");
const c = @import("c");

pub const Error = error{ InitFailed };

/// Initialise the codec addon (adds compressed sample/stream loading).
pub fn init() !void {
    if (!c.al_init_acodec_addon()) return Error.InitFailed;
}

pub fn shutdown() void {
    c.al_shutdown_acodec_addon();
}

pub fn initialized() bool {
    return c.al_is_acodec_addon_initialized();
}

/// Return the file type identifier for a sample file (e.g. "wav", "ogg").
pub fn identifySample(filename: [:0]const u8) [:0]const u8 {
    return std.mem.span(c.al_identify_sample(filename.ptr));
}

const File = @import("file.zig").File;

/// Identify the codec for a sample open through an Allegro file handle.
pub fn identifySampleFromFile(fp: *File) [:0]const u8 {
    return std.mem.span(c.al_identify_sample_f(fp.file));
}

/// The version of the acodec addon as a packed integer.
pub fn version() u32 {
    return c.al_get_allegro_acodec_version();
}

test "refAllDecls" {
    std.testing.refAllDecls(@This());
}