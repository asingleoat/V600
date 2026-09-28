//! Scan-finished chime: three short 880 Hz beeps, as in the Python scanner UI.
//! The audio device is opened on first use; without audio the chime is skipped.

const std = @import("std");
const c = @import("sdl_nuklear.zig").c;

const sample_rate = 48_000;
const beep_count = 3;
const beep_spacing_s = 0.2;
const beep_length_s = 0.12;
const frequency_hz = 880.0;
const start_gain = 0.4;
const end_gain = 0.001;
const chime_len: usize = @intFromFloat(((beep_count - 1) * beep_spacing_s + beep_length_s) * sample_rate);

var chime: [chime_len]f32 = undefined;
var stream: ?*c.SDL_AudioStream = null;
var open_attempted = false;
var playing = false;

pub fn playScanFinished() void {
    if (!open_attempted) {
        open_attempted = true;
        open();
    }
    const audio = stream orelse return;
    _ = c.SDL_PutAudioStreamData(audio, &chime, @intCast(@sizeOf(@TypeOf(chime))));
    playing = c.SDL_ResumeAudioStreamDevice(audio);
}

/// Pauses the device once the chime has drained, so it does not stay open
/// playing silence.
pub fn update() void {
    const audio = stream orelse return;
    if (playing and c.SDL_GetAudioStreamQueued(audio) == 0) {
        _ = c.SDL_PauseAudioStreamDevice(audio);
        playing = false;
    }
}

pub fn deinit() void {
    if (stream) |audio| c.SDL_DestroyAudioStream(audio);
    stream = null;
}

fn open() void {
    if (!c.SDL_InitSubSystem(c.SDL_INIT_AUDIO)) return;
    const spec = c.SDL_AudioSpec{ .format = c.SDL_AUDIO_F32, .channels = 1, .freq = sample_rate };
    stream = c.SDL_OpenAudioDeviceStream(c.SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK, &spec, null, null);
    if (stream != null) fillChime(&chime);
}

fn fillChime(out: []f32) void {
    const decay = @log(end_gain / start_gain) / beep_length_s;
    for (out, 0..) |*sample, index| {
        const t = @as(f64, @floatFromInt(index)) / sample_rate;
        const beep = @floor(t / beep_spacing_s);
        const local = t - beep * beep_spacing_s;
        sample.* = if (beep < beep_count and local < beep_length_s)
            @floatCast(start_gain * @exp(decay * local) * @sin(2.0 * std.math.pi * frequency_hz * local))
        else
            0.0;
    }
}
