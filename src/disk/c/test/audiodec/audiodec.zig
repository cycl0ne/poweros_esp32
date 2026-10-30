// SPDX-License-Identifier: MIT
//! AudioDec: a sound file decoded by audiocodec.library as fast as it
//! goes, and timed - nothing is played. Built against the SDK only.
//!
//!   AudioDec FILE/A,TO/K
//!
//! The kind, rate, channels and length the stream says are printed, then
//! how many frames came out, how long it took, and how many times faster
//! than the sound plays that is - one over the share of a core playing it
//! takes. The time includes reading the file: one in RAM: times the
//! decoding alone. TO writes the samples as they came out, 16-bit little
//! endian, the channels interleaved - what `ffmpeg -i FILE -f s16le
//! ref.raw` writes, to compare.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const ac = sdk.audiocodec;
const timer = sdk.devices.timer;
const TagItem = sdk.utility.TagItem;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const AudioCodecBase = sdk.interface.audiocodec.AudioCodecBase;
const TimerBase = timer.TimerBase;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "AudioDec";
const VERSION_STRING = "\x00$VER: AudioDec 1.0 (30.10.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "FILE/A,TO/K";
const arg_file = 0;
const arg_to = 1;

/// Frames a call asks for: 4 KiB of samples, on the stack.
const piece = 1024;

fn now(tb: *TimerBase) u64 {
    var ev: timer.EClockVal = .{};
    const rate = tb.ReadEClock(&ev);
    return ev.toTicks() * 1_000_000 / rate;
}

fn kindName(codec: u32) [*:0]const u8 {
    return switch (codec) {
        ac.ACODEC_WAV => "WAV",
        ac.ACODEC_MP3 => "MP3",
        ac.ACODEC_FLAC => "FLAC",
        ac.ACODEC_VORBIS => "Ogg Vorbis",
        ac.ACODEC_AAC => "AAC",
        ac.ACODEC_AC3 => "AC-3",
        ac.ACODEC_EAC3 => "E-AC-3",
        else => "sound",
    };
}

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(lib);
    const dl: *DosBase = @ptrCast(lib);
    var argv: [2]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_ERROR;
    };
    defer dl.FreeArgs(rda);
    const name: [*:0]const u8 = @ptrFromInt(argv[arg_file]);

    const codec_lib = sys.OpenLibrary(ac.AUDIOCODECNAME, 1) orelse {
        _ = Printf(dl, "No %s\n", .{ac.AUDIOCODECNAME});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(codec_lib);
    const acb: *AudioCodecBase = @ptrCast(codec_lib);

    var timer_req: timer.TimeRequest = .{};
    if (sys.OpenDevice(sdk.interface.timer.NAME, timer.UNIT_MICROHZ, &timer_req.node, 0) != 0) return dos.RETURN_FAIL;
    defer sys.CloseDevice(&timer_req.node);
    const tb: *TimerBase = @ptrCast(timer_req.node.device.?);

    var out: ?*dos.FileHandle = null;
    if (argv[arg_to] != 0) {
        const to: [*:0]const u8 = @ptrFromInt(argv[arg_to]);
        out = dl.Open(to, dos.MODE_NEWFILE) orelse {
            _ = Printf(dl, "%s: cannot be written\n", .{to});
            return dos.RETURN_ERROR;
        };
    }
    defer if (out) |file| {
        _ = dl.Close(file);
    };

    const started = now(tb);
    var err: i32 = 0;
    const stream = acb.OpenAudioStream(&[_]TagItem{
        .{ .tag = ac.ACA_Name, .data = @intFromPtr(name) },
        .{},
    }, &err) orelse {
        _ = Printf(dl, "%s: %s\n", .{ name, acb.AudioErrorText(err) });
        return dos.RETURN_ERROR;
    };
    defer acb.CloseAudioStream(stream);
    const opened = now(tb);
    var info: ac.AudioStreamInfo = .{};
    acb.GetAudioStreamInfo(stream, &info);
    _ = Printf(dl, "%s, %u Hz, %u channels, %u kbit/s, %u frames; opened in %lu ms\n", .{
        kindName(info.codec), info.rate, info.channels, info.bitrate / 1000, info.frames, (opened - started) / 1000,
    });

    var buffer: [piece * 2]i16 = undefined;
    var total: u64 = 0;
    var result: i32 = dos.RETURN_OK;
    while (true) {
        const got = acb.DecodeAudio(stream, &buffer, piece);
        if (got < 0) {
            _ = Printf(dl, "stopped: %s\n", .{acb.AudioErrorText(got)});
            result = dos.RETURN_WARN;
            break;
        }
        if (got == 0) break;
        total += @intCast(got);
        if (out) |file| {
            const bytes: isize = @intCast(@as(usize, @intCast(got)) * info.channels * 2);
            _ = dl.Write(file, @ptrCast(&buffer), bytes);
        }
        if (sys.SetSignal(0, exec.SIGBREAKF_CTRL_C) & exec.SIGBREAKF_CTRL_C != 0) {
            _ = Printf(dl, "***Break\n", .{});
            result = dos.RETURN_WARN;
            break;
        }
    }
    const took = @max(now(tb) - opened, 1);
    const sound_us = if (info.rate != 0) total * 1_000_000 / info.rate else 0;
    const times = sound_us * 10 / took;
    _ = Printf(dl, "%lu frames decoded in %lu.%03lu s: %lu.%lu times as fast as it plays\n", .{
        total, took / 1_000_000, took / 1000 % 1000, times / 10, times % 10,
    });
    return result;
}
