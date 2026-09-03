const std = @import("std");
const c = @import("c");
const EventSource = @import("events.zig").EventSource;
const Bitmap = @import("graphics.zig").Bitmap;
const mixer_mod = @import("audio.zig");

pub const Error = error{ InitFailed, OpenFailed };

pub fn init() !void {
    if (!c.al_init_video_addon()) return Error.InitFailed;
}

pub fn shutdown() void {
    c.al_shutdown_video_addon();
}

pub fn initialized() bool {
    return c.al_is_video_addon_initialized();
}

pub fn version() u32 {
    return c.al_get_allegro_video_version();
}

pub const Position = struct {
    pub const ACTUAL = c.ALLEGRO_VIDEO_POSITION_ACTUAL;
    pub const INTENDED = c.ALLEGRO_VIDEO_POSITION_INTENDED;

    pub const Type = c.ALLEGRO_VIDEO_POSITION_TYPE;
};

/// A video player widget (set its frame bitmap as the target of your drawing
/// and use the frame event to drive playback).
pub const Video = struct {
    video: *c.ALLEGRO_VIDEO,

    pub fn open(filename: [:0]const u8) !Video {
        const v = c.al_open_video(filename.ptr) orelse return Error.OpenFailed;
        return .{ .video = v };
    }

    pub fn close(self: *Video) void {
        c.al_close_video(self.video);
    }

    pub fn start(self: *Video, mixer: ?*mixer_mod.Mixer) void {
        c.al_start_video(self.video, if (mixer) |m| m.mixer else null);
    }

    pub fn startWithVoice(self: *Video, voice: ?*mixer_mod.Voice) void {
        c.al_start_video_with_voice(self.video, if (voice) |v| v.voice else null);
    }

    pub fn eventSource(self: *Video) EventSource {
        return .{ .source = c.al_get_video_event_source(self.video) };
    }

    /// The current video frame as a bitmap.
    pub fn frame(self: *Video) ?Bitmap {
        const b = c.al_get_video_frame(self.video);
        return if (b) |ptr| Bitmap.fromCPointer(ptr) else null;
    }

    pub fn playing(self: *Video) bool {
        return c.al_is_video_playing(self.video);
    }

    pub fn setPlaying(self: *Video, val: bool) void {
        c.al_set_video_playing(self.video, val);
    }

    pub fn fps(self: *Video) f64 {
        return c.al_get_video_fps(self.video);
    }

    pub fn audioRate(self: *Video) f64 {
        return c.al_get_video_audio_rate(self.video);
    }

    pub fn scaledWidth(self: *Video) f32 {
        return c.al_get_video_scaled_width(self.video);
    }

    pub fn scaledHeight(self: *Video) f32 {
        return c.al_get_video_scaled_height(self.video);
    }

    pub fn position(self: *Video, which: c.ALLEGRO_VIDEO_POSITION_TYPE) f64 {
        return c.al_get_video_position(self.video, which);
    }

    pub fn seek(self: *Video, seconds: f64) bool {
        return c.al_seek_video(self.video, seconds);
    }
};

/// Identify a video file's format by extension ("ogv", "webm", ...).
pub fn identify(filename: [:0]const u8) [:0]const u8 {
    return std.mem.span(c.al_identify_video(filename.ptr));
}

const File = @import("file.zig").File;

/// Identify a video format by inspecting an open Allegro file handle.
pub fn identifyFromFile(fp: *File) [:0]const u8 {
    return std.mem.span(c.al_identify_video_f(fp.file));
}

test "refAllDecls" {
    std.testing.refAllDecls(Video);
}