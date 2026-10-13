// SPDX-License-Identifier: MIT
//! Audio: a note out of the speaker, through audio.device. Built against
//! the SDK only.
//!
//!   Audio HZ/K/N,SECONDS/K/N,VOLUME/K/N,PAN/K/N,CHORD/S
//!
//! It asks the device what the board has - the part the sound comes out
//! of, the rate the output runs at, one side or two, how far behind a
//! write is heard - and says so. Then it opens a stream of 16-bit
//! samples, one channel, writes one cycle of a sine to it and lets it play
//! for as long as it was told: a write played `loops` times over, so the
//! device plays it round and round without the program feeding it.
//!
//! The pitch is the stream's rate: a cycle of `wave_len` samples played at
//! `hz * wave_len` frames a second is a note of `hz`, 20 to 2000 - a
//! chord's fifth is half again as high, and a stream's rate goes to
//! 192 kHz. VOLUME is in percent of as recorded (80), PAN from -100 (left
//! only) to 100 (right only).
//!
//! CHORD plays a major chord instead - the note, its third and its fifth -
//! as three streams, three opens of the device, each at its own rate,
//! which the device mixes into one.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const audio = sdk.devices.audio;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "Audio";
const VERSION_STRING = "\x00$VER: Audio 2.0 (13.10.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "HZ/K/N,SECONDS/K/N,VOLUME/K/N,PAN/K/N,CHORD/S";
const arg_hz = 0;
const arg_seconds = 1;
const arg_volume = 2;
const arg_pan = 3;
const arg_chord = 4;

const MSG_NODEVICE = "No %s - this machine has no sound\n";
const MSG_OUTPUT = "%s: %s, %u Hz, %s, %u frames behind, %u of %u streams in use\n";
const MSG_PLAYING = "%u Hz, volume %u%%, pan %d, %u seconds\n";
const MSG_CHORD = "%u, %u and %u Hz, volume %u%%, %u seconds\n";
const MSG_BADNOTE = "%s: HZ is 20 to 2000\n";
const MSG_FAILED = "A write came back with error %d\n";

/// One cycle of a sine, as 16-bit samples: long enough that the note is
/// a clean one.
const wave_len = 64;

/// The cycle, worked out while compiling.
const wave: [wave_len * 2]u8 = blk: {
    @setEvalBranchQuota(10_000);
    var bytes: [wave_len * 2]u8 = undefined;
    for (0..wave_len) |i| {
        const angle = 2.0 * 3.141592653589793 * @as(f64, @floatFromInt(i)) / wave_len;
        const sample: i16 = @intFromFloat(@round(@sin(angle) * 32000.0));
        const word: u16 = @bitCast(sample);
        bytes[i * 2] = @truncate(word);
        bytes[i * 2 + 1] = @truncate(word >> 8);
    }
    break :blk bytes;
};

fn numberAt(at: usize) i32 {
    return @as(*const i32, @ptrFromInt(at)).*;
}

/// A stream: a request opened on the device, and the write it plays.
const Note = struct {
    io: ?*audio.IOAudio = null,
    opened: bool = false,
    sent: bool = false,
};

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(dos_lib);
    const dl: *DosBase = @ptrCast(dos_lib);

    var argv: [5]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);

    const hz: u32 = if (argv[arg_hz] != 0) @intCast(@max(numberAt(argv[arg_hz]), 0)) else 440;
    if (hz < 20 or hz > 2000) {
        _ = Printf(dl, MSG_BADNOTE, .{COMMAND_NAME});
        return dos.RETURN_ERROR;
    }
    const seconds: u32 = if (argv[arg_seconds] != 0) @intCast(@max(numberAt(argv[arg_seconds]), 1)) else 2;
    const percent: u32 = if (argv[arg_volume] != 0) @intCast(@min(@max(numberAt(argv[arg_volume]), 0), 400)) else 80;
    const pan_percent: i32 = if (argv[arg_pan] != 0) @min(@max(numberAt(argv[arg_pan]), -100), 100) else 0;
    const chord = argv[arg_chord] != 0;

    const port = sys.CreateMsgPort() orelse return dos.RETURN_FAIL;
    defer sys.DeleteMsgPort(port);

    // The note, and for a chord its major third and fifth: a stream each.
    const rates = [3]u32{ hz, hz * 5 / 4, hz * 3 / 2 };
    const count: usize = if (chord) 3 else 1;
    var notes: [3]Note = @splat(.{});
    defer for (&notes) |*note| {
        const io = note.io orelse continue;
        if (note.opened) sys.CloseDevice(&io.std.req);
        sys.DeleteIORequest(&io.std.req);
    };
    for (notes[0..count], 0..) |*note, n| {
        const io: *audio.IOAudio = @ptrCast(@alignCast(sys.CreateIORequest(port, @sizeOf(audio.IOAudio)) orelse return dos.RETURN_FAIL));
        note.io = io;
        io.format = audio.AUDIO_S16;
        io.channels = 1;
        io.rate = rates[n] * wave_len;
        // Three notes together are three times as loud: each a third.
        io.volume = audio.AUDIO_VOLUME_UNITY / 100 * percent / @as(u32, @intCast(count));
        io.pan = @divTrunc(audio.AUDIO_PAN_FULL, 100) * pan_percent;
        if (sys.OpenDevice(audio.AUDIONAME, audio.AUDIO_UNIT_PLAY, &io.std.req, 0) != 0) {
            _ = Printf(dl, MSG_NODEVICE, .{audio.AUDIONAME});
            return dos.RETURN_FAIL;
        }
        note.opened = true;
    }

    // What the board has, from the first stream.
    var info: audio.AudioInfo = .{};
    const first = notes[0].io.?;
    first.std.req.command = audio.AUDIOCMD_QUERY;
    first.std.data = &info;
    first.std.length = @sizeOf(audio.AudioInfo);
    if (sys.DoIO(&first.std.req) == 0) {
        _ = Printf(dl, MSG_OUTPUT, .{
            audio.AUDIONAME,
            info.output orelse "?",
            info.rate,
            @as([*:0]const u8, if (info.channels == 1) "one side" else "two sides"),
            info.latency,
            info.streams,
            info.max_streams,
        });
    }
    if (chord) {
        _ = Printf(dl, MSG_CHORD, .{ rates[0], rates[1], rates[2], percent, seconds });
    } else {
        _ = Printf(dl, MSG_PLAYING, .{ hz, percent, pan_percent, seconds });
    }

    // Each stream's cycle, played round for the seconds asked, the streams
    // started together.
    for (notes[0..count], 0..) |*note, n| {
        const io = note.io.?;
        io.std.req.command = exec.CMD_WRITE;
        io.std.req.flags = 0;
        io.std.data = @ptrCast(@constCast(&wave));
        io.std.length = wave.len;
        io.loops = rates[n] * seconds;
        sys.SendIO(&io.std.req);
        note.sent = true;
    }
    var err: i32 = 0;
    for (notes[0..count]) |*note| {
        if (!note.sent) continue;
        const result = sys.WaitIO(&note.io.?.std.req);
        if (result != 0) err = result;
    }
    if (err != 0) _ = Printf(dl, MSG_FAILED, .{err});
    return if (err == 0) dos.RETURN_OK else dos.RETURN_WARN;
}
