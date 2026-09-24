// SPDX-License-Identifier: MIT
//! Audio: a note out of the speaker, through audio.device. Built against
//! the SDK only.
//!
//!   Audio HZ/K/N,SECONDS/K/N,VOLUME/K/N,CHANNELS/K/N
//!
//! It allocates the channels asked for (one by default), writes a sine
//! wave of one cycle to them, and lets it play for as long as it was
//! told - a write of `cycles` times over, so the device plays it round
//! and round without the program having to feed it. Then the channels are
//! freed, which is what stops the sound.
//!
//! The note's pitch is the period: a period of `n` plays a sample every
//! `n` ticks of the audio clock, so a wave of `samples` samples comes out
//! at `clock / (period * samples)` hertz.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const audio = sdk.devices.audio;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "Audio";
const VERSION_STRING = "\x00$VER: Audio 1.0 (23.9.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "HZ/K/N,SECONDS/K/N,VOLUME/K/N,CHANNELS/K/N";
const arg_hz = 0;
const arg_seconds = 1;
const arg_volume = 2;
const arg_channels = 3;

const MSG_NODEVICE = "No %s - this machine has no sound\n";
const MSG_NOCHANNELS = "No channels free\n";
const MSG_PLAYING = "%d Hz on channels %x, volume %d, %d seconds\n";
const MSG_FAILED = "The write came back with error %d\n";

/// One cycle of a sine, as signed 8-bit samples. The longer the wave the
/// truer the note, and 64 samples is enough for a speaker this size.
const wave_len = 64;

/// A quarter of a sine, to a scale of 127. The rest is this mirrored,
/// which is what a sine is.
const quarter = [_]i8{
    0,  12, 25,  37,  49,  60,  71,  81,
    90, 98, 106, 112, 117, 122, 125, 126,
};

fn sineWave(into: *[wave_len]i8) void {
    for (0..wave_len) |i| {
        const step = i % 16;
        const part = i / 16;
        into[i] = switch (part) {
            0 => quarter[step],
            1 => quarter[15 - step],
            2 => -quarter[step],
            else => -quarter[15 - step],
        };
    }
}

fn numberAt(at: usize) i32 {
    return @as(*const i32, @ptrFromInt(at)).*;
}

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(dos_lib);
    const dl: *DosBase = @ptrCast(dos_lib);

    var argv: [4]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);

    const hz: u32 = if (argv[arg_hz] != 0) @intCast(@max(numberAt(argv[arg_hz]), 1)) else 440;
    const seconds: u32 = if (argv[arg_seconds] != 0) @intCast(@max(numberAt(argv[arg_seconds]), 1)) else 2;
    const volume: u16 = if (argv[arg_volume] != 0) @intCast(@min(@max(numberAt(argv[arg_volume]), 0), 64)) else 48;
    const wanted: u32 = if (argv[arg_channels] != 0) @intCast(@max(numberAt(argv[arg_channels]), 1)) else 1;

    var wave: [wave_len]i8 = undefined;
    sineWave(&wave);

    const port = sys.CreateMsgPort() orelse return dos.RETURN_FAIL;
    defer sys.DeleteMsgPort(port);
    const io: *audio.IOAudio = @ptrCast(@alignCast(sys.CreateIORequest(port, @sizeOf(audio.IOAudio)) orelse
        return dos.RETURN_FAIL));
    defer sys.DeleteIORequest(&io.req);

    if (sys.OpenDevice(audio.AUDIONAME, 0, &io.req, 0) != 0) {
        _ = Printf(dl, MSG_NODEVICE, .{audio.AUDIONAME});
        return dos.RETURN_FAIL;
    }
    defer sys.CloseDevice(&io.req);

    // The channels: the combinations this program would take, in the
    // order it prefers them. One channel is any one of the four; two are
    // one of each side, so a note is heard on both.
    const one = [_]i8{ 0x01, 0x02, 0x04, 0x08 };
    const two = [_]i8{ 0x03, 0x05, 0x0A, 0x0C };
    const combinations: []const i8 = if (wanted >= 2) &two else &one;

    io.req.command = audio.ADCMD_ALLOCATE;
    io.req.flags = audio.ADIOF_NOWAIT;
    io.req.message.node.pri = 0;
    io.data = combinations.ptr;
    io.length = @intCast(combinations.len);
    io.alloc_key = 0;
    if (sys.DoIO(&io.req) != 0) {
        _ = dl.PutStr(MSG_NOCHANNELS);
        return dos.RETURN_WARN;
    }

    // The period that makes the note: the clock over the rate the wave
    // has to be played at.
    const period: u16 = @intCast(@max(audio.AUDIO_CLOCK / (hz * wave_len), audio.AUDIO_MINPERIOD));
    const rate = audio.AUDIO_CLOCK / (@as(u32, period) * wave_len);
    const cycles = rate * seconds;
    _ = Printf(dl, MSG_PLAYING, .{ rate, io.channels, @as(u32, volume), seconds });

    io.req.command = exec.CMD_WRITE;
    io.req.flags = audio.ADIOF_PERVOL;
    io.data = &wave;
    io.length = wave.len;
    io.period = period;
    io.volume = volume;
    io.cycles = @intCast(@min(cycles, 0xFFFF));
    const err = sys.DoIO(&io.req);
    if (err != 0) _ = Printf(dl, MSG_FAILED, .{@as(i32, err)});

    io.req.command = audio.ADCMD_FREE;
    io.req.flags = 0;
    _ = sys.DoIO(&io.req);
    return if (err == 0) dos.RETURN_OK else dos.RETURN_WARN;
}
