// SPDX-License-Identifier: MIT
//! Play: a sound file out of the speaker - WAV, MP3, FLAC or Ogg Vorbis -
//! through
//! audiocodec.library and audio.device. Built against the SDK only.
//!
//!   Play FILE/A,VOLUME/K/N,START/K/N,QUIET/S
//!
//! It says what the file is - its names, its kind, rate and channels, how
//! long it is - and plays it to the end, or until Ctrl-C. VOLUME is in
//! percent of as recorded (100), START how many seconds in to begin, QUIET
//! leaves the line about the file out.
//!
//! The file is decoded as it plays: three buffers of samples go round, one
//! playing, one queued behind it, one being filled - so the sound runs
//! without a gap whatever the file's length, and a song takes no more
//! memory than a second of it.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const audio = sdk.devices.audio;
const ac = sdk.audiocodec;
const utility = sdk.utility;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const AudioCodecBase = sdk.interface.audiocodec.AudioCodecBase;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "Play";
const VERSION_STRING = "\x00$VER: Play 1.1 (14.10.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "FILE/A,VOLUME/K/N,START/K/N,QUIET/S";
const arg_file = 0;
const arg_volume = 1;
const arg_start = 2;
const arg_quiet = 3;

/// Frames a buffer holds, and how many buffers go round.
const buffer_frames = 4096;
const buffer_count = 3;

const MSG_NOLIBRARY = "%s: no %s\n";
const MSG_NOSOUND = "%s: no %s - this machine has no sound\n";
const MSG_CANNOT = "%s: %s: %s\n";
const MSG_WHAT = "%s%s%s%s%s%s\n%s, %u Hz, %s, %u kbit/s, %u:%02u\n";
const MSG_NOFORMAT = "%s: audio.device does not take %u Hz %u channels\n";
const MSG_ERROR = "%s: decoding stopped: %s\n";

fn numberAt(at: usize) i32 {
    return @as(*const i32, @ptrFromInt(at)).*;
}

fn kindName(codec: u32) [*:0]const u8 {
    return switch (codec) {
        ac.ACODEC_WAV => "WAV",
        ac.ACODEC_MP3 => "MP3",
        ac.ACODEC_FLAC => "FLAC",
        ac.ACODEC_VORBIS => "Ogg Vorbis",
        else => "sound",
    };
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
    const file: [*:0]const u8 = @ptrFromInt(argv[arg_file]);
    const percent: u32 = if (argv[arg_volume] != 0) @intCast(@min(@max(numberAt(argv[arg_volume]), 0), 400)) else 100;
    const start: u32 = if (argv[arg_start] != 0) @intCast(@max(numberAt(argv[arg_start]), 0)) else 0;

    const codec_lib = sys.OpenLibrary(ac.AUDIOCODECNAME, 1) orelse {
        _ = Printf(dl, MSG_NOLIBRARY, .{ COMMAND_NAME, ac.AUDIOCODECNAME });
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(codec_lib);
    const acb: *AudioCodecBase = @ptrCast(codec_lib);

    var err: i32 = 0;
    const stream = acb.OpenAudioStream(&[_]utility.TagItem{
        .{ .tag = ac.ACA_Name, .data = @intFromPtr(file) },
        .{},
    }, &err) orelse {
        _ = Printf(dl, MSG_CANNOT, .{ COMMAND_NAME, file, acb.AudioErrorText(err) });
        return dos.RETURN_ERROR;
    };
    defer acb.CloseAudioStream(stream);
    var info: ac.AudioStreamInfo = .{};
    acb.GetAudioStreamInfo(stream, &info);

    if (argv[arg_quiet] == 0) {
        const title: [*:0]const u8 = if (info.title[0] != 0) @ptrCast(&info.title) else file;
        const has_artist = info.artist[0] != 0;
        const has_album = info.album[0] != 0;
        const seconds = if (info.rate != 0) info.frames / info.rate else 0;
        _ = Printf(dl, MSG_WHAT, .{
            title,
            @as([*:0]const u8, if (has_artist) " - " else ""),
            @as([*:0]const u8, if (has_artist) @ptrCast(&info.artist) else ""),
            @as([*:0]const u8, if (has_album) " (" else ""),
            @as([*:0]const u8, if (has_album) @ptrCast(&info.album) else ""),
            @as([*:0]const u8, if (has_album) ")" else ""),
            kindName(info.codec),
            info.rate,
            @as([*:0]const u8, if (info.channels == 1) "mono" else "stereo"),
            info.bitrate / 1000,
            seconds / 60,
            seconds % 60,
        });
    }
    if (start != 0) _ = acb.SeekAudio(stream, start *| info.rate);

    // The samples: three buffers, a request each, all on one stream.
    const frame_samples: usize = info.channels;
    const memory = sys.AllocVec(buffer_count * buffer_frames * frame_samples * 2, exec.MEMF_ANY) orelse return dos.RETURN_FAIL;
    defer sys.FreeVec(memory);
    const samples: [*]i16 = @ptrCast(@alignCast(memory));

    const port = sys.CreateMsgPort() orelse return dos.RETURN_FAIL;
    defer sys.DeleteMsgPort(port);
    var requests: [buffer_count]?*audio.IOAudio = @splat(null);
    defer for (requests) |maybe| {
        if (maybe) |io| sys.DeleteIORequest(&io.std.req);
    };
    for (&requests) |*slot| {
        slot.* = @ptrCast(@alignCast(sys.CreateIORequest(port, @sizeOf(audio.IOAudio)) orelse return dos.RETURN_FAIL));
    }
    const first = requests[0].?;
    first.format = audio.AUDIO_S16;
    first.channels = @intCast(info.channels);
    first.rate = info.rate;
    first.volume = audio.AUDIO_VOLUME_UNITY / 100 * percent;
    const opened = sys.OpenDevice(audio.AUDIONAME, audio.AUDIO_UNIT_PLAY, &first.std.req, 0);
    if (opened != 0) {
        if (opened == audio.AUDIOERR_BADFORMAT) {
            _ = Printf(dl, MSG_NOFORMAT, .{ COMMAND_NAME, info.rate, info.channels });
        } else {
            _ = Printf(dl, MSG_NOSOUND, .{ COMMAND_NAME, audio.AUDIONAME });
        }
        return dos.RETURN_FAIL;
    }
    defer sys.CloseDevice(&first.std.req);
    // The others on the same stream: copies of the opened request.
    for (requests[1..]) |maybe| {
        const io = maybe.?;
        const own_port = io.std.req.message.reply_port;
        io.* = first.*;
        io.std.req.message.reply_port = own_port;
    }

    // A Ctrl-C from before this command started is not a request to stop it.
    _ = sys.SetSignal(0, exec.SIGBREAKF_CTRL_C);
    var sent: [buffer_count]bool = @splat(false);
    var outstanding: usize = 0;
    var ending = false;
    var stopped = false;
    var decode_error: i32 = 0;

    // Every buffer filled and sent; then, in the order they were sent -
    // which is the order they come back in - each refilled as it returns.
    for (0..buffer_count) |n| {
        if (!fillAndSend(sys, acb, stream, requests[n].?, samples + n * buffer_frames * frame_samples, &decode_error)) {
            ending = true;
            break;
        }
        sent[n] = true;
        outstanding += 1;
    }
    var next: usize = 0;
    while (outstanding > 0) {
        const io = requests[next].?;
        while (sys.CheckIO(&io.std.req) == null) {
            if (sys.Wait(port.sigMask() | exec.SIGBREAKF_CTRL_C) & exec.SIGBREAKF_CTRL_C != 0) {
                stopped = true;
                break;
            }
        }
        if (stopped) break;
        _ = sys.WaitIO(&io.std.req);
        sent[next] = false;
        outstanding -= 1;
        if (!ending) {
            if (fillAndSend(sys, acb, stream, io, samples + next * buffer_frames * frame_samples, &decode_error)) {
                sent[next] = true;
                outstanding += 1;
            } else {
                ending = true;
            }
        }
        next = (next + 1) % buffer_count;
    }
    // Stopped: what is still queued taken back.
    for (requests, sent) |maybe, busy| {
        if (!busy) continue;
        const io = maybe.?;
        _ = sys.AbortIO(&io.std.req);
        _ = sys.WaitIO(&io.std.req);
    }
    if (decode_error < 0) {
        _ = Printf(dl, MSG_ERROR, .{ COMMAND_NAME, acb.AudioErrorText(decode_error) });
        return dos.RETURN_WARN;
    }
    if (stopped) {
        _ = dl.PrintFault(dos.ERROR_BREAK, COMMAND_NAME);
        return dos.RETURN_WARN;
    }
    return dos.RETURN_OK;
}

/// The next frames decoded into `buffer` and written: false at the end of
/// the file, or when decoding failed (`decode_error`).
fn fillAndSend(sys: *ExecBase, acb: *AudioCodecBase, stream: *ac.AudioStream, io: *audio.IOAudio, buffer: [*]i16, decode_error: *i32) bool {
    const got = acb.DecodeAudio(stream, buffer, buffer_frames);
    if (got <= 0) {
        if (got < 0) decode_error.* = got;
        return false;
    }
    io.std.req.command = sdk.exec.CMD_WRITE;
    io.std.req.flags = 0;
    io.std.data = buffer;
    io.std.length = @as(u64, @intCast(got)) * io.channels * 2;
    io.loops = 1;
    sys.SendIO(&io.std.req);
    return true;
}
