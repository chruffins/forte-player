const std = @import("std");
const c = @import("c");
const EventSource = @import("events.zig").EventSource;
const File = @import("file.zig").File;

pub const AudioError = error{ InitFailed, CreateFailed, AttachFailed, ReserveFailed };

/// Audio sample depths.
pub const Depth = struct {
    pub const UINT8 = c.ALLEGRO_AUDIO_DEPTH_UINT8;
    pub const INT16 = c.ALLEGRO_AUDIO_DEPTH_INT16;
    pub const INT24 = c.ALLEGRO_AUDIO_DEPTH_INT24;
    pub const INT32 = c.ALLEGRO_AUDIO_DEPTH_INT32;
    pub const FLOAT32 = c.ALLEGRO_AUDIO_DEPTH_FLOAT32;

    pub fn sizeOf(d: c.ALLEGRO_AUDIO_DEPTH) usize {
        return c.al_get_audio_depth_size(d);
    }
};

/// Channel configurations.
pub const ChannelConf = struct {
    pub const P1 = c.ALLEGRO_CHANNEL_CONF_1;
    pub const P2 = c.ALLEGRO_CHANNEL_CONF_2;
    pub const P3 = c.ALLEGRO_CHANNEL_CONF_3;
    pub const P4 = c.ALLEGRO_CHANNEL_CONF_4;
    pub const P5_1 = c.ALLEGRO_CHANNEL_CONF_5_1;
    pub const P6_1 = c.ALLEGRO_CHANNEL_CONF_6_1;
    pub const P7_1 = c.ALLEGRO_CHANNEL_CONF_7_1;
};

/// Playback modes.
pub const Playmode = struct {
    pub const ONCE = c.ALLEGRO_PLAYMODE_ONCE;
    pub const LOOP = c.ALLEGRO_PLAYMODE_LOOP;
    pub const BIDIR = c.ALLEGRO_PLAYMODE_BIDIR;
    pub const STREAM_ONCE = c.ALLEGRO_PLAYMODE_STREAM_ONCE;
    pub const STREAM_ONEDIR = c.ALLEGRO_PLAYMODE_STREAM_ONEDIR;
    pub const STREAM_LOOP_ONCE = c.ALLEGRO_PLAYMODE_STREAM_LOOP_ONCE;
};

/// Mixer interpolation quality.
pub const MixerQuality = struct {
    pub const POINT = c.ALLEGRO_MIXER_QUALITY_POINT;
    pub const LINEAR = c.ALLEGRO_MIXER_QUALITY_LINEAR;
    pub const CUBIC = c.ALLEGRO_MIXER_QUALITY_CUBIC;
};

pub const panNone = c.ALLEGRO_AUDIO_PAN_NONE;

// ---------------------------------------------------------------------------
// System-level
// ---------------------------------------------------------------------------

pub fn init() !void {
    if (!c.al_install_audio()) return AudioError.InitFailed;
}

pub fn uninstall() void {
    c.al_uninstall_audio();
}

pub fn installed() bool {
    return c.al_is_audio_installed();
}

/// Reserve mixing slots for one-shot samples.
pub fn reserveSamples(n: i32) !void {
    if (!c.al_reserve_samples(n)) return AudioError.ReserveFailed;
}

pub fn version() u32 {
    return c.al_get_allegro_audio_version();
}

/// Number of channels in a channel configuration (e.g. 2 for stereo).
pub fn channelCount(conf: c.ALLEGRO_CHANNEL_CONF) usize {
    return c.al_get_channel_count(conf);
}

/// Fill a raw audio buffer with silence.
pub fn fillSilence(buf: []u8, samples: u32, depth: c.ALLEGRO_AUDIO_DEPTH, chanConf: c.ALLEGRO_CHANNEL_CONF) void {
    c.al_fill_silence(buf.ptr, samples, depth, chanConf);
}

pub fn getNumAudioOutputDevices() i32 {
    return c.al_get_num_audio_output_devices();
}

pub fn getAudioOutputDevice(index: i32) ?*const c.ALLEGRO_AUDIO_DEVICE {
    return c.al_get_audio_output_device(index);
}

/// Human-readable name of an audio output device.
pub fn audioDeviceName(device: *const c.ALLEGRO_AUDIO_DEVICE) [:0]const u8 {
    return std.mem.span(c.al_get_audio_device_name(device));
}

// ---------------------------------------------------------------------------
// Voice: an audio output (sound card channel)
// ---------------------------------------------------------------------------

pub const Voice = struct {
    voice: *c.ALLEGRO_VOICE,

    pub fn create(freq: u32, depth: c.ALLEGRO_AUDIO_DEPTH, chanConf: c.ALLEGRO_CHANNEL_CONF) !Voice {
        const v = c.al_create_voice(freq, depth, chanConf) orelse return AudioError.CreateFailed;
        return .{ .voice = v };
    }

    pub fn destroy(self: *Voice) void {
        c.al_destroy_voice(self.voice);
    }

    pub fn getFrequency(self: *const Voice) u32 {
        return c.al_get_voice_frequency(self.voice);
    }

    pub fn getDepth(self: *const Voice) c.ALLEGRO_AUDIO_DEPTH {
        return c.al_get_voice_depth(self.voice);
    }

    pub fn getChannels(self: *const Voice) c.ALLEGRO_CHANNEL_CONF {
        return c.al_get_voice_channels(self.voice);
    }

    pub fn getPlaying(self: *const Voice) bool {
        return c.al_get_voice_playing(self.voice);
    }

    pub fn setPlaying(self: *Voice, val: bool) bool {
        return c.al_set_voice_playing(self.voice, val);
    }

    pub fn getPosition(self: *const Voice) u32 {
        return c.al_get_voice_position(self.voice);
    }

    pub fn setPosition(self: *Voice, val: u32) bool {
        return c.al_set_voice_position(self.voice, val);
    }

    pub fn detach(self: *Voice) void {
        c.al_detach_voice(self.voice);
    }

    pub fn hasAttachments(self: *const Voice) bool {
        return c.al_voice_has_attachments(self.voice);
    }
};

pub fn getDefaultVoice() ?Voice {
    const v = c.al_get_default_voice();
    return if (v) |ptr| .{ .voice = ptr } else null;
}

pub fn setDefaultVoice(voice: ?*Voice) void {
    c.al_set_default_voice(if (voice) |v| v.voice else null);
}

// ---------------------------------------------------------------------------
// Mixer: mixes multiple inputs into a single output
// ---------------------------------------------------------------------------

pub const Mixer = struct {
    mixer: *c.ALLEGRO_MIXER,

    pub fn create(freq: u32, depth: c.ALLEGRO_AUDIO_DEPTH, chanConf: c.ALLEGRO_CHANNEL_CONF) !Mixer {
        const m = c.al_create_mixer(freq, depth, chanConf) orelse return AudioError.CreateFailed;
        return .{ .mixer = m };
    }

    pub fn destroy(self: *Mixer) void {
        c.al_destroy_mixer(self.mixer);
    }

    pub fn attachToVoice(self: *Mixer, voice: *Voice) !void {
        if (!c.al_attach_mixer_to_voice(self.mixer, voice.voice)) return AudioError.AttachFailed;
    }

    pub fn attachToMixer(self: *Mixer, parent: *Mixer) !void {
        if (!c.al_attach_mixer_to_mixer(self.mixer, parent.mixer)) return AudioError.AttachFailed;
    }

    pub fn detach(self: *Mixer) bool {
        return c.al_detach_mixer(self.mixer);
    }

    pub fn getFrequency(self: *const Mixer) u32 {
        return c.al_get_mixer_frequency(self.mixer);
    }

    pub fn setFrequency(self: *Mixer, val: u32) bool {
        return c.al_set_mixer_frequency(self.mixer, val);
    }

    pub fn getDepth(self: *const Mixer) c.ALLEGRO_AUDIO_DEPTH {
        return c.al_get_mixer_depth(self.mixer);
    }

    pub fn getChannels(self: *const Mixer) c.ALLEGRO_CHANNEL_CONF {
        return c.al_get_mixer_channels(self.mixer);
    }

    pub fn getGain(self: *const Mixer) f32 {
        return c.al_get_mixer_gain(self.mixer);
    }

    pub fn setGain(self: *Mixer, val: f32) bool {
        return c.al_set_mixer_gain(self.mixer, val);
    }

    pub fn getPlaying(self: *const Mixer) bool {
        return c.al_get_mixer_playing(self.mixer);
    }

    pub fn setPlaying(self: *Mixer, val: bool) bool {
        return c.al_set_mixer_playing(self.mixer, val);
    }

    pub fn getQuality(self: *const Mixer) c.ALLEGRO_MIXER_QUALITY {
        return c.al_get_mixer_quality(self.mixer);
    }

    pub fn setQuality(self: *Mixer, val: c.ALLEGRO_MIXER_QUALITY) bool {
        return c.al_set_mixer_quality(self.mixer, val);
    }

    pub fn hasAttachments(self: *const Mixer) bool {
        return c.al_mixer_has_attachments(self.mixer);
    }

    pub fn isAttached(self: *const Mixer) bool {
        return c.al_get_mixer_attached(self.mixer);
    }

    /// Install a post-processing callback that runs on each chunk of mixed audio.
    pub fn setPostProcessCallback(self: *Mixer, callback: ?*const fn (buf: ?*anyopaque, samples: u32, data: ?*anyopaque) callconv(.c) void, data: ?*anyopaque) bool {
        return c.al_set_mixer_postprocess_callback(self.mixer, callback, data);
    }
};

pub fn getDefaultMixer() ?Mixer {
    const m = c.al_get_default_mixer();
    return if (m) |ptr| .{ .mixer = ptr } else null;
}

pub fn setDefaultMixer(mixer: ?*Mixer) bool {
    return c.al_set_default_mixer(if (mixer) |m| m.mixer else null);
}

pub fn restoreDefaultMixer() bool {
    return c.al_restore_default_mixer();
}

// ---------------------------------------------------------------------------
// Sample: a fixed chunk of audio data in memory
// ---------------------------------------------------------------------------

pub const Sample = struct {
    sample: *c.ALLEGRO_SAMPLE,

    pub fn create(data: ?*anyopaque, samples: u32, freq: u32, depth: c.ALLEGRO_AUDIO_DEPTH, chanConf: c.ALLEGRO_CHANNEL_CONF, freeBuf: bool) !Sample {
        const s = c.al_create_sample(data, samples, freq, depth, chanConf, freeBuf) orelse return AudioError.CreateFailed;
        return .{ .sample = s };
    }

    /// Load a sample from a file (requires the acodec addon for compressed formats).
    pub fn load(filename: [:0]const u8) !Sample {
        const s = c.al_load_sample(filename.ptr) orelse return error.LoadFailed;
        return .{ .sample = s };
    }

    pub fn loadFromFile(fp: *File, ident: [:0]const u8) !Sample {
        const s = c.al_load_sample_f(fp.file, ident.ptr) orelse return error.LoadFailed;
        return .{ .sample = s };
    }

    /// Save a sample to a file (requires the acodec addon for compressed formats).
    pub fn saveToFile(self: *const Sample, fp: *File, ident: [:0]const u8) bool {
        return c.al_save_sample_f(fp.file, ident.ptr, self.sample);
    }

    pub fn destroy(self: *Sample) void {
        c.al_destroy_sample(self.sample);
    }

    /// Play this sample once on the default mixer.
    pub fn play(self: *Sample, gain: f32, pan: f32, speed: f32) ?SampleId {
        var id: c.ALLEGRO_SAMPLE_ID = undefined;
        if (!c.al_play_sample(self.sample, gain, pan, speed, c.ALLEGRO_PLAYMODE_ONCE, &id)) return null;
        return .{ .id = id };
    }

    pub fn playLooped(self: *Sample, gain: f32, pan: f32, speed: f32) ?SampleId {
        var id: c.ALLEGRO_SAMPLE_ID = undefined;
        if (!c.al_play_sample(self.sample, gain, pan, speed, c.ALLEGRO_PLAYMODE_LOOP, &id)) return null;
        return .{ .id = id };
    }

    pub fn getSamples(self: *const Sample) u32 {
        return c.al_get_sample_length(self.sample);
    }

    pub fn getFrequency(self: *const Sample) u32 {
        return c.al_get_sample_frequency(self.sample);
    }

    pub fn getDepth(self: *const Sample) c.ALLEGRO_AUDIO_DEPTH {
        return c.al_get_sample_depth(self.sample);
    }

    pub fn getChannels(self: *const Sample) c.ALLEGRO_CHANNEL_CONF {
        return c.al_get_sample_channels(self.sample);
    }

    pub fn getData(self: *const Sample) ?*anyopaque {
        return c.al_get_sample_data(self.sample);
    }

    pub fn save(self: *const Sample, filename: [:0]const u8) bool {
        return c.al_save_sample(filename.ptr, self.sample);
    }
};

pub const SampleId = struct {
    id: c.ALLEGRO_SAMPLE_ID,

    pub fn stop(self: SampleId) void {
        c.al_stop_sample(&self.id);
    }
};

pub fn stopSamples() void {
    c.al_stop_samples();
}

// ---------------------------------------------------------------------------
// SampleInstance: a playable reference to a Sample
// ---------------------------------------------------------------------------

pub const SampleInstance = struct {
    inst: *c.ALLEGRO_SAMPLE_INSTANCE,

    pub fn create(sample: ?*Sample) !SampleInstance {
        const s = c.al_create_sample_instance(if (sample) |sm| sm.sample else null) orelse return AudioError.CreateFailed;
        return .{ .inst = s };
    }

    pub fn destroy(self: *SampleInstance) void {
        c.al_destroy_sample_instance(self.inst);
    }

    pub fn setSample(self: *SampleInstance, sample: *Sample) bool {
        return c.al_set_sample(self.inst, sample.sample);
    }

    pub fn attachToMixer(self: *SampleInstance, mixer: *Mixer) !void {
        if (!c.al_attach_sample_instance_to_mixer(self.inst, mixer.mixer)) return AudioError.AttachFailed;
    }

    pub fn attachToVoice(self: *SampleInstance, voice: *Voice) !void {
        if (!c.al_attach_sample_instance_to_voice(self.inst, voice.voice)) return AudioError.AttachFailed;
    }

    pub fn detach(self: *SampleInstance) bool {
        return c.al_detach_sample_instance(self.inst);
    }

    pub fn play(self: *SampleInstance) bool {
        return c.al_play_sample_instance(self.inst);
    }

    pub fn stop(self: *SampleInstance) bool {
        return c.al_stop_sample_instance(self.inst);
    }

    pub fn playing(self: *const SampleInstance) bool {
        return c.al_get_sample_instance_playing(self.inst);
    }

    pub fn setPlaying(self: *SampleInstance, val: bool) bool {
        return c.al_set_sample_instance_playing(self.inst, val);
    }

    pub fn gain(self: *const SampleInstance) f32 {
        return c.al_get_sample_instance_gain(self.inst);
    }

    pub fn setGain(self: *SampleInstance, val: f32) bool {
        return c.al_set_sample_instance_gain(self.inst, val);
    }

    pub fn pan(self: *const SampleInstance) f32 {
        return c.al_get_sample_instance_pan(self.inst);
    }

    pub fn setPan(self: *SampleInstance, val: f32) bool {
        return c.al_set_sample_instance_pan(self.inst, val);
    }

    pub fn speed(self: *const SampleInstance) f32 {
        return c.al_get_sample_instance_speed(self.inst);
    }

    pub fn setSpeed(self: *SampleInstance, val: f32) bool {
        return c.al_set_sample_instance_speed(self.inst, val);
    }

    pub fn position(self: *const SampleInstance) u32 {
        return c.al_get_sample_instance_position(self.inst);
    }

    pub fn setPosition(self: *SampleInstance, val: u32) bool {
        return c.al_set_sample_instance_position(self.inst, val);
    }

    pub fn playmode(self: *const SampleInstance) c.ALLEGRO_PLAYMODE {
        return c.al_get_sample_instance_playmode(self.inst);
    }

    pub fn setPlaymode(self: *SampleInstance, val: c.ALLEGRO_PLAYMODE) bool {
        return c.al_set_sample_instance_playmode(self.inst, val);
    }

    pub fn length(self: *const SampleInstance) u32 {
        return c.al_get_sample_instance_length(self.inst);
    }

    pub fn setLength(self: *SampleInstance, val: u32) bool {
        return c.al_set_sample_instance_length(self.inst, val);
    }

    pub fn frequency(self: *const SampleInstance) u32 {
        return c.al_get_sample_instance_frequency(self.inst);
    }

    /// Playback time in seconds (courtesy of the mixer).
    pub fn time(self: *const SampleInstance) f32 {
        return c.al_get_sample_instance_time(self.inst);
    }

    pub fn attached(self: *const SampleInstance) bool {
        return c.al_get_sample_instance_attached(self.inst);
    }

    pub fn channels(self: *const SampleInstance) c.ALLEGRO_CHANNEL_CONF {
        return c.al_get_sample_instance_channels(self.inst);
    }

    /// The underlying Sample data, if one is set.
    pub fn getSample(self: *const SampleInstance) ?Sample {
        const s = c.al_get_sample(self.inst);
        return if (s) |sp| Sample{ .sample = sp } else null;
    }

    pub fn sampleDepth(self: *const SampleInstance) c.ALLEGRO_AUDIO_DEPTH {
        return c.al_get_sample_instance_depth(self.inst);
    }
};

// ---------------------------------------------------------------------------
// AudioStream: streaming audio from disk
// ---------------------------------------------------------------------------

pub const AudioStream = struct {
    stream: *c.ALLEGRO_AUDIO_STREAM,

    pub fn create(bufferCount: usize, samples: u32, freq: u32, sampleDepth: c.ALLEGRO_AUDIO_DEPTH, chanConf: c.ALLEGRO_CHANNEL_CONF) !AudioStream {
        const s = c.al_create_audio_stream(bufferCount, samples, freq, sampleDepth, chanConf) orelse return AudioError.CreateFailed;
        return .{ .stream = s };
    }

    /// Load a streaming audio file (requires the acodec addon for compressed formats).
    pub fn load(filename: [:0]const u8, bufferCount: usize, samples: u32) !AudioStream {
        const s = c.al_load_audio_stream(filename.ptr, bufferCount, samples) orelse return error.LoadFailed;
        return .{ .stream = s };
    }

    pub fn loadFromFile(fp: *File, ident: [:0]const u8, bufferCount: usize, samples: u32) !AudioStream {
        const s = c.al_load_audio_stream_f(fp.file, ident.ptr, bufferCount, samples) orelse return error.LoadFailed;
        return .{ .stream = s };
    }

    pub fn destroy(self: *AudioStream) void {
        c.al_destroy_audio_stream(self.stream);
    }

    pub fn eventSource(self: *AudioStream) EventSource {
        return .{ .source = c.al_get_audio_stream_event_source(self.stream) };
    }

    pub fn attachToMixer(self: *AudioStream, mixer: *Mixer) !void {
        if (!c.al_attach_audio_stream_to_mixer(self.stream, mixer.mixer)) return AudioError.AttachFailed;
    }

    pub fn attachToVoice(self: *AudioStream, voice: *Voice) !void {
        if (!c.al_attach_audio_stream_to_voice(self.stream, voice.voice)) return AudioError.AttachFailed;
    }

    pub fn detach(self: *AudioStream) bool {
        return c.al_detach_audio_stream(self.stream);
    }

    pub fn playing(self: *const AudioStream) bool {
        return c.al_get_audio_stream_playing(self.stream);
    }

    pub fn setPlaying(self: *AudioStream, val: bool) bool {
        return c.al_set_audio_stream_playing(self.stream, val);
    }

    pub fn playmode(self: *const AudioStream) c.ALLEGRO_PLAYMODE {
        return c.al_get_audio_stream_playmode(self.stream);
    }

    pub fn setPlaymode(self: *AudioStream, val: c.ALLEGRO_PLAYMODE) bool {
        return c.al_set_audio_stream_playmode(self.stream, val);
    }

    pub fn gain(self: *const AudioStream) f32 {
        return c.al_get_audio_stream_gain(self.stream);
    }

    pub fn setGain(self: *AudioStream, val: f32) bool {
        return c.al_set_audio_stream_gain(self.stream, val);
    }

    pub fn pan(self: *const AudioStream) f32 {
        return c.al_get_audio_stream_pan(self.stream);
    }

    pub fn setPan(self: *AudioStream, val: f32) bool {
        return c.al_set_audio_stream_pan(self.stream, val);
    }

    pub fn speed(self: *const AudioStream) f32 {
        return c.al_get_audio_stream_speed(self.stream);
    }

    pub fn setSpeed(self: *AudioStream, val: f32) bool {
        return c.al_set_audio_stream_speed(self.stream, val);
    }

    pub fn frequency(self: *const AudioStream) u32 {
        return c.al_get_audio_stream_frequency(self.stream);
    }

    pub fn depth(self: *const AudioStream) c.ALLEGRO_AUDIO_DEPTH {
        return c.al_get_audio_stream_depth(self.stream);
    }

    pub fn channels(self: *const AudioStream) c.ALLEGRO_CHANNEL_CONF {
        return c.al_get_audio_stream_channels(self.stream);
    }

    pub fn length(self: *const AudioStream) u32 {
        return c.al_get_audio_stream_length(self.stream);
    }

    pub fn lengthSecs(self: *AudioStream) f64 {
        return c.al_get_audio_stream_length_secs(self.stream);
    }

    pub fn positionSecs(self: *AudioStream) f64 {
        return c.al_get_audio_stream_position_secs(self.stream);
    }

    pub fn seekSecs(self: *AudioStream, time: f64) bool {
        return c.al_seek_audio_stream_secs(self.stream, time);
    }

    pub fn loopSecs(self: *AudioStream, start: f64, end: f64) bool {
        return c.al_set_audio_stream_loop_secs(self.stream, start, end);
    }

    pub fn rewind(self: *AudioStream) bool {
        return c.al_rewind_audio_stream(self.stream);
    }

    pub fn drain(self: *AudioStream) void {
        c.al_drain_audio_stream(self.stream);
    }

    pub fn fragments(self: *const AudioStream) u32 {
        return c.al_get_audio_stream_fragments(self.stream);
    }

    pub fn availableFragments(self: *const AudioStream) u32 {
        return c.al_get_available_audio_stream_fragments(self.stream);
    }

    pub fn attached(self: *const AudioStream) bool {
        return c.al_get_audio_stream_attached(self.stream);
    }

    pub fn playedSamples(self: *const AudioStream) u64 {
        return c.al_get_audio_stream_played_samples(self.stream);
    }

    /// Get a writable fragment buffer for streaming raw audio data.
    pub fn getFragment(self: *const AudioStream) ?*anyopaque {
        return c.al_get_audio_stream_fragment(self.stream);
    }

    pub fn setFragment(self: *AudioStream, fragment: ?*anyopaque) bool {
        return c.al_set_audio_stream_fragment(self.stream, fragment);
    }
};

// -- Plugin registration (custom sample/stream codecs) --

pub const SampleLoader = *const fn (filename: [*:0]const u8) callconv(.c) ?*c.ALLEGRO_SAMPLE;
pub const SampleLoaderF = *const fn (fp: ?*c.ALLEGRO_FILE) callconv(.c) ?*c.ALLEGRO_SAMPLE;
pub const SampleSaver = *const fn (filename: [*:0]const u8, spl: ?*c.ALLEGRO_SAMPLE) callconv(.c) bool;
pub const SampleSaverF = *const fn (fp: ?*c.ALLEGRO_FILE, spl: ?*c.ALLEGRO_SAMPLE) callconv(.c) bool;
pub const SampleIdentifier = *const fn (fp: ?*c.ALLEGRO_FILE) callconv(.c) bool;
pub const StreamLoader = *const fn (filename: [*:0]const u8, bufferCount: usize, samples: u32) callconv(.c) ?*c.ALLEGRO_AUDIO_STREAM;
pub const StreamLoaderF = *const fn (fp: ?*c.ALLEGRO_FILE, bufferCount: usize, samples: u32) callconv(.c) ?*c.ALLEGRO_AUDIO_STREAM;

pub fn registerSampleLoader(ext: [:0]const u8, loader: SampleLoader) bool {
    return c.al_register_sample_loader(ext.ptr, @ptrCast(loader));
}

pub fn registerSampleLoaderFromFile(ext: [:0]const u8, loader: SampleLoaderF) bool {
    return c.al_register_sample_loader_f(ext.ptr, @ptrCast(loader));
}

pub fn registerSampleSaver(ext: [:0]const u8, saver: SampleSaver) bool {
    return c.al_register_sample_saver(ext.ptr, @ptrCast(saver));
}

pub fn registerSampleSaverToFile(ext: [:0]const u8, saver: SampleSaverF) bool {
    return c.al_register_sample_saver_f(ext.ptr, @ptrCast(saver));
}

pub fn registerSampleIdentifier(ext: [:0]const u8, identifier: SampleIdentifier) bool {
    return c.al_register_sample_identifier(ext.ptr, @ptrCast(identifier));
}

pub fn registerAudioStreamLoader(ext: [:0]const u8, loader: StreamLoader) bool {
    return c.al_register_audio_stream_loader(ext.ptr, @ptrCast(loader));
}

pub fn registerAudioStreamLoaderFromFile(ext: [:0]const u8, loader: StreamLoaderF) bool {
    return c.al_register_audio_stream_loader_f(ext.ptr, @ptrCast(loader));
}

test "refAllDecls" {
    std.testing.refAllDecls(Voice);
    std.testing.refAllDecls(Mixer);
    std.testing.refAllDecls(Sample);
    std.testing.refAllDecls(SampleInstance);
    std.testing.refAllDecls(AudioStream);
}