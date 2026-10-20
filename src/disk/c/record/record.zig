// SPDX-License-Identifier: MIT
//! Record: sound from the board's way in - its microphone - into a WAV
//! file, through audio.device. Built against the SDK only.
//!
//!   Record FILE/A,SECONDS/K/N,RATE/K/N,CHANNELS/K/N,BITS/K/N,VOLUME/K/N,QUIET/S
//!
//! It records until SECONDS have been recorded, or until Ctrl-C. RATE is
//! in frames a second - by default the rate the output runs at, which a
//! way in of the same part runs at too, so nothing is converted; CHANNELS
//! 1 or 2 - by default as many as the way in hears; BITS 8, 16 (the
//! default) or 32; VOLUME in percent of as heard (100), up to 400. QUIET
//! leaves out the lines about what is recorded.
//!
//! Four reads go round: each is written to the file as it comes back and
//! sent again, so the recording runs without a gap however long it is,
//! and a write to the file may take a second without anything being
//! lost. The file's header goes first with its lengths open, and is
//! filled in at the end.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const audio = sdk.devices.audio;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "Record";
const VERSION_STRING = "\x00$VER: Record 1.0 (20.10.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "FILE/A,SECONDS/K/N,RATE/K/N,CHANNELS/K/N,BITS/K/N,VOLUME/K/N,QUIET/S";
const arg_file = 0;
const arg_seconds = 1;
const arg_rate = 2;
const arg_channels = 3;
const arg_bits = 4;
const arg_volume = 5;
const arg_quiet = 6;

/// Bytes a read holds at most - whole frames of it - and how many go
/// round.
const read_bytes = 32 * 1024;
const read_count = 4;

/// A WAV file's header: RIFF, the format chunk, the data chunk's head.
const header_bytes = 44;

/// The rate when neither RATE nor the output gives one.
const usual_rate: u32 = 48_000;

const MSG_NOINPUT = "%s: no way in - this machine has nothing to record from\n";
const MSG_BUSY = "%s: something else is recording\n";
const MSG_NOSOUND = "%s: no %s - this machine has no sound\n";
const MSG_NOFORMAT = "%s: audio.device does not take %u Hz %u channels\n";
const MSG_BADARG = "%s: CHANNELS is 1 or 2, BITS 8, 16 or 32\n";
const MSG_WHAT = "Recording from %s, %u Hz, %s, %u bits, into %s\n";
const MSG_DONE = "%u:%02u recorded";
const MSG_LOST = ", %u buffers lost";

fn numberAt(at: usize) i32 {
    return @as(*const i32, @ptrFromInt(at)).*;
}

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(dos_lib);
    const dl: *DosBase = @ptrCast(dos_lib);

    var argv: [7]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);
    const name: [*:0]const u8 = @ptrFromInt(argv[arg_file]);
    const seconds: u32 = if (argv[arg_seconds] != 0) @intCast(@max(numberAt(argv[arg_seconds]), 0)) else 0;
    const bits: u32 = if (argv[arg_bits] != 0) @intCast(@max(numberAt(argv[arg_bits]), 0)) else 16;
    const percent: u32 = if (argv[arg_volume] != 0) @intCast(@min(@max(numberAt(argv[arg_volume]), 0), 400)) else 100;
    const asked_channels: u32 = if (argv[arg_channels] != 0) @intCast(@max(numberAt(argv[arg_channels]), 0)) else 0;
    const format: u8 = switch (bits) {
        8 => audio.AUDIO_S8,
        16 => audio.AUDIO_S16,
        32 => audio.AUDIO_S32,
        else => 0,
    };
    if (format == 0 or asked_channels > 2) {
        _ = Printf(dl, MSG_BADARG, .{COMMAND_NAME});
        return dos.RETURN_ERROR;
    }

    const port = sys.CreateMsgPort() orelse return dos.RETURN_FAIL;
    defer sys.DeleteMsgPort(port);
    var requests: [read_count]?*audio.IOAudio = @splat(null);
    defer for (requests) |maybe| {
        if (maybe) |io| sys.DeleteIORequest(&io.std.req);
    };
    for (&requests) |*slot| {
        slot.* = @ptrCast(@alignCast(sys.CreateIORequest(port, @sizeOf(audio.IOAudio)) orelse return dos.RETURN_FAIL));
    }
    const first = requests[0].?;
    first.format = format;
    first.channels = if (asked_channels != 0) @intCast(asked_channels) else 1;
    first.rate = if (argv[arg_rate] != 0) @intCast(@max(numberAt(argv[arg_rate]), 0)) else usual_rate;
    first.volume = audio.AUDIO_VOLUME_UNITY / 100 * percent;
    const opened = sys.OpenDevice(audio.AUDIONAME, audio.AUDIO_UNIT_RECORD, &first.std.req, 0);
    if (opened != 0) {
        switch (opened) {
            audio.AUDIOERR_NOINPUT => _ = Printf(dl, MSG_NOINPUT, .{COMMAND_NAME}),
            audio.AUDIOERR_NOSTREAM => _ = Printf(dl, MSG_BUSY, .{COMMAND_NAME}),
            audio.AUDIOERR_BADFORMAT => _ = Printf(dl, MSG_NOFORMAT, .{ COMMAND_NAME, first.rate, @as(u32, first.channels) }),
            else => _ = Printf(dl, MSG_NOSOUND, .{ COMMAND_NAME, audio.AUDIONAME }),
        }
        return dos.RETURN_FAIL;
    }
    defer sys.CloseDevice(&first.std.req);

    // What the way in is, and the defaults it gives: the output's rate, as
    // many channels as it hears.
    var before: audio.AudioInfo = .{};
    query(sys, first, &before);
    var wanted_rate = first.rate;
    var wanted_channels: u32 = first.channels;
    if (argv[arg_rate] == 0 and before.rate != 0) wanted_rate = before.rate;
    if (asked_channels == 0 and before.input_channels != 0) wanted_channels = @min(before.input_channels, 2);
    if (wanted_rate != first.rate or wanted_channels != first.channels) {
        first.rate = wanted_rate;
        first.channels = @intCast(wanted_channels);
        first.std.req.command = audio.AUDIOCMD_SETPARAMS;
        first.std.req.flags = 0;
        if (sys.DoIO(&first.std.req) != 0) {
            _ = Printf(dl, MSG_NOFORMAT, .{ COMMAND_NAME, first.rate, @as(u32, first.channels) });
            return dos.RETURN_FAIL;
        }
    }
    const frame = audio.frameBytes(first.format, first.channels);
    const rate = first.rate;
    if (argv[arg_quiet] == 0) {
        _ = Printf(dl, MSG_WHAT, .{
            before.input orelse "?",
            rate,
            @as([*:0]const u8, if (first.channels == 1) "mono" else "stereo"),
            bits,
            name,
        });
    }

    const file = dl.Open(name, dos.MODE_NEWFILE) orelse {
        _ = dl.PrintFault(dl.IoErr(), name);
        return dos.RETURN_FAIL;
    };
    var head: [header_bytes]u8 = undefined;
    waveHeader(&head, first.channels, rate, bits, 0);
    if (dl.Write(file, &head, header_bytes) != header_bytes) {
        _ = dl.PrintFault(dl.IoErr(), name);
        _ = dl.Close(file);
        return dos.RETURN_FAIL;
    }

    // The reads: a buffer each, all on the recording.
    const each: u32 = read_bytes / frame * frame;
    const memory = sys.AllocVec(read_count * each, exec.MEMF_ANY) orelse {
        _ = dl.Close(file);
        return dos.RETURN_FAIL;
    };
    defer sys.FreeVec(memory);
    const buffers: [*]u8 = @ptrCast(memory);
    for (requests[1..]) |maybe| {
        const io = maybe.?;
        const own_port = io.std.req.message.reply_port;
        io.* = first.*;
        io.std.req.message.reply_port = own_port;
    }

    // A Ctrl-C from before this command started is not a request to stop it.
    _ = sys.SetSignal(0, exec.SIGBREAKF_CTRL_C);
    var left: u64 = if (seconds != 0) @as(u64, seconds) * rate * frame else ~@as(u64, 0);
    var sent: [read_count]bool = @splat(false);
    var outstanding: usize = 0;
    var written: u64 = 0;
    var failed = false;
    var stopped = false;

    for (0..read_count) |n| {
        if (!sendRead(sys, requests[n].?, buffers + n * each, each, &left)) break;
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
        if (!keep(dl, file, io, bits, &written)) {
            failed = true;
            break;
        }
        if (sendRead(sys, io, buffers + next * each, each, &left)) {
            sent[next] = true;
            outstanding += 1;
        }
        next = (next + 1) % read_count;
    }
    // Stopped: the reads still out taken back, in the order they were
    // sent, and what each holds kept.
    for (0..read_count) |k| {
        const at = (next + k) % read_count;
        if (!sent[at]) continue;
        const io = requests[at].?;
        _ = sys.AbortIO(&io.std.req);
        _ = sys.WaitIO(&io.std.req);
        if (!failed and !keep(dl, file, io, bits, &written)) failed = true;
    }

    // The lengths filled in.
    waveHeader(&head, first.channels, rate, bits, @intCast(@min(written, 0xFFFF_FFFF - header_bytes)));
    if (!failed) {
        _ = dl.Seek(file, 0, dos.OFFSET_BEGINNING);
        if (dl.Write(file, &head, header_bytes) != header_bytes) failed = true;
    }
    if (failed) _ = dl.PrintFault(dl.IoErr(), name);
    _ = dl.Close(file);

    if (argv[arg_quiet] == 0) {
        var after: audio.AudioInfo = .{};
        query(sys, first, &after);
        const recorded: u32 = @intCast(written / frame / rate);
        _ = Printf(dl, MSG_DONE, .{ recorded / 60, recorded % 60 });
        const lost = after.overruns -% before.overruns;
        if (lost != 0) _ = Printf(dl, MSG_LOST, .{lost});
        _ = Printf(dl, "\n", .{});
    }
    if (failed) return dos.RETURN_ERROR;
    if (stopped and seconds != 0) {
        _ = dl.PrintFault(dos.ERROR_BREAK, COMMAND_NAME);
        return dos.RETURN_WARN;
    }
    return dos.RETURN_OK;
}

/// The device's answer to AUDIOCMD_QUERY, on the recording `io` opened.
fn query(sys: *ExecBase, io: *audio.IOAudio, info: *audio.AudioInfo) void {
    var ask = io.*;
    ask.std.req.command = audio.AUDIOCMD_QUERY;
    ask.std.req.flags = 0;
    ask.std.data = info;
    ask.std.length = @sizeOf(audio.AudioInfo);
    _ = sys.DoIO(&ask.std.req);
}

/// A read of up to `each` bytes into `buffer` sent, as long as some of
/// the recording is `left`: false once none is.
fn sendRead(sys: *ExecBase, io: *audio.IOAudio, buffer: [*]u8, each: u32, left: *u64) bool {
    if (left.* == 0) return false;
    const length: u32 = @intCast(@min(left.*, each));
    left.* -= length;
    io.std.req.command = exec.CMD_READ;
    io.std.req.flags = 0;
    io.std.data = buffer;
    io.std.length = length;
    sys.SendIO(&io.std.req);
    return true;
}

/// What a read that came back holds written to the file - 8-bit samples
/// made unsigned, as a WAV file has them - and counted: false when the
/// file would not take it.
fn keep(dl: *DosBase, file: *dos.FileHandle, io: *audio.IOAudio, bits: u32, written: *u64) bool {
    const count: usize = @intCast(io.std.actual);
    if (count == 0) return true;
    const bytes: [*]u8 = @ptrCast(io.std.data.?);
    if (bits == 8) {
        for (bytes[0..count]) |*byte| byte.* ^= 0x80;
    }
    if (dl.Write(file, bytes, @intCast(count)) != count) return false;
    written.* += count;
    return true;
}

/// A WAV header for `data_bytes` bytes of PCM.
fn waveHeader(head: *[header_bytes]u8, channels: u32, rate: u32, bits: u32, data_bytes: u32) void {
    const block = channels * (bits / 8);
    @memcpy(head[0..4], "RIFF");
    put32(head[4..8], data_bytes + header_bytes - 8);
    @memcpy(head[8..12], "WAVE");
    @memcpy(head[12..16], "fmt ");
    put32(head[16..20], 16);
    put16(head[20..22], 1);
    put16(head[22..24], channels);
    put32(head[24..28], rate);
    put32(head[28..32], rate * block);
    put16(head[32..34], block);
    put16(head[34..36], bits);
    @memcpy(head[36..40], "data");
    put32(head[40..44], data_bytes);
}

fn put16(into: *[2]u8, value: u32) void {
    into[0] = @truncate(value);
    into[1] = @truncate(value >> 8);
}

fn put32(into: *[4]u8, value: u32) void {
    into[0] = @truncate(value);
    into[1] = @truncate(value >> 8);
    into[2] = @truncate(value >> 16);
    into[3] = @truncate(value >> 24);
}
