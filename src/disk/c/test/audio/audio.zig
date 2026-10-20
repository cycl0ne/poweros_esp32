// SPDX-License-Identifier: MIT
//! Audio: a note out of the speaker, through audio.device. Built against
//! the SDK only.
//!
//!   Audio HZ/K/N,SECONDS/K/N,VOLUME/K/N,PAN/K/N,CHORD/S,BENCH/K/N,
//!         OUTPUTS/S,OUTPUT/K,TRIGGER/K/N,TOFILE/K
//!
//! It asks the device what the board has - the part the sound comes out
//! of, the rate the output runs at, one side or two, how far behind a
//! write is heard, the streams open and the sounds playing by trigger -
//! and says so. Then it opens a stream of 16-bit
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
//!
//! BENCH n is the measure of the mixer on the board: n streams at once (1
//! to 16), each a note a semitone above the last, for SECONDS (10). After
//! it says how many buffers the output played again because the mix was
//! late (`AudioInfo.underruns`, before and after) and what share of a core
//! the device's task took meanwhile - its own count of the time it ran
//! (`Task.timeRun`) against the cycles core 0 counted (`ReadCoreTimes`).
//!
//! OUTPUTS lists the machine's outputs instead - each one's name, its
//! number, how many sides it plays and at what rates, which is the
//! default and which plays now - and plays nothing. OUTPUT name has the
//! device play through that output from then on, for every program,
//! before the note.
//!
//! TRIGGER n plays n short clicks instead - a twentieth of a second of
//! the note each - as fast as they can be sent, each a trigger on one
//! open for triggers alone: no stream, nothing fed. It says how many
//! played to their end, how many gave way to a newer one when every
//! trigger voice was taken, how many were refused, and how many buffers
//! the output played again meanwhile.
//!
//! TOFILE name plays into a WAV file of that name instead: it makes a file
//! sink (rta.library's "file" driver), has the device play through it for
//! the note, the chord, the bench or the clicks, then goes back to the
//! output played through before and deletes the sink. The file holds
//! what the device mixed, from its first sound to the switch back.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const audio = sdk.devices.audio;
const rta = sdk.rta;
const TagItem = sdk.utility.TagItem;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const RtaBase = sdk.interface.rta.RtaBase;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "Audio";
const VERSION_STRING = "\x00$VER: Audio 2.4 (20.10.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "HZ/K/N,SECONDS/K/N,VOLUME/K/N,PAN/K/N,CHORD/S,BENCH/K/N,OUTPUTS/S,OUTPUT/K,TRIGGER/K/N,TOFILE/K";
const arg_hz = 0;
const arg_seconds = 1;
const arg_volume = 2;
const arg_pan = 3;
const arg_chord = 4;
const arg_bench = 5;
const arg_outputs = 6;
const arg_output = 7;
const arg_trigger = 8;
const arg_tofile = 9;
const arg_count = 10;

const MSG_NODEVICE = "No %s - this machine has no sound\n";
const MSG_OUTPUT = "%s: %s, %u Hz, %s, %u frames behind, %u of %u streams in use, %u sounds triggered\n";
const MSG_PLAYING = "%u Hz, volume %u%%, pan %d, %u seconds\n";
const MSG_CHORD = "%u, %u and %u Hz, volume %u%%, %u seconds\n";
const MSG_BENCH = "%u streams, a semitone apart from %u Hz, volume %u%%, %u seconds\n";
const MSG_BENCHED = "%u buffers played again, the device's task %u.%u%% of a core\n";
const MSG_BADNOTE = "%s: HZ is 20 to 2000\n";
const MSG_BADBENCH = "%s: BENCH is 1 to %u streams\n";
const MSG_BENCHNOTE = "%s: with that many streams HZ is at most %u\n";
const MSG_FAILED = "A write came back with error %d\n";
const MSG_ONEOUTPUT = "%s  number %x, %s, ";
const MSG_RATE = "%u ";
const MSG_HZ = "Hz";
const MSG_DEFAULT = ", the default";
const MSG_CURRENT = ", playing";
const MSG_NEWLINE = "\n";
const MSG_NOOUTPUT = "%s: no output %s\n";
const MSG_NOSWITCH = "%s: %s would not start\n";
const MSG_BADTRIGGER = "%s: TRIGGER is 1 to %u clicks\n";
const MSG_TRIGGERS = "%u clicks of %u Hz triggered: %u played, %u gave way, %u refused; %u buffers played again\n";
const MSG_NORTA = "%s: no %s\n";
const MSG_NOFILESINK = "%s: no file sink: %s\n";
const MSG_TOFILE = "Into %s\n";

/// One cycle of a sine, as 16-bit samples: long enough that the note is
/// a clean one.
const wave_len = 64;

/// The most streams BENCH plays.
const max_notes = audio.AUDIO_MAX_STREAMS;

/// The most clicks TRIGGER sends.
const max_clicks = 64;

/// Each of sixteen notes a semitone above the one before: 2^(n/12) in
/// thousandths, so the notes are worked out without floating point.
const semitones = [max_notes]u32{ 1000, 1059, 1122, 1189, 1260, 1335, 1414, 1498, 1587, 1682, 1782, 1888, 2000, 2119, 2245, 2378 };

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

    var argv: [arg_count]usize = @splat(0);
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
    const bench: u32 = if (argv[arg_bench] != 0) @intCast(@max(numberAt(argv[arg_bench]), 0)) else 0;
    if (argv[arg_bench] != 0 and (bench < 1 or bench > max_notes)) {
        _ = Printf(dl, MSG_BADBENCH, .{ COMMAND_NAME, @as(u32, max_notes) });
        return dos.RETURN_ERROR;
    }
    // The highest note's stream still at a rate the device takes.
    if (bench != 0 and hz * semitones[bench - 1] / 1000 * wave_len > audio.AUDIO_MAX_RATE) {
        _ = Printf(dl, MSG_BENCHNOTE, .{ COMMAND_NAME, audio.AUDIO_MAX_RATE / wave_len * 1000 / semitones[bench - 1] });
        return dos.RETURN_ERROR;
    }
    const seconds: u32 = if (argv[arg_seconds] != 0) @intCast(@max(numberAt(argv[arg_seconds]), 1)) else if (bench != 0) 10 else 2;
    const percent: u32 = if (argv[arg_volume] != 0) @intCast(@min(@max(numberAt(argv[arg_volume]), 0), 400)) else 80;
    const pan_percent: i32 = if (argv[arg_pan] != 0) @min(@max(numberAt(argv[arg_pan]), -100), 100) else 0;
    const chord = argv[arg_chord] != 0;
    const clicks: u32 = if (argv[arg_trigger] != 0) @intCast(@max(numberAt(argv[arg_trigger]), 0)) else 0;
    if (argv[arg_trigger] != 0 and (clicks < 1 or clicks > max_clicks)) {
        _ = Printf(dl, MSG_BADTRIGGER, .{ COMMAND_NAME, @as(u32, max_clicks) });
        return dos.RETURN_ERROR;
    }

    const port = sys.CreateMsgPort() orelse return dos.RETURN_FAIL;
    defer sys.DeleteMsgPort(port);

    // Into a file: the file sink played through until the program ends.
    var into_file: ?FileOutput = null;
    if (argv[arg_tofile] != 0) {
        into_file = FileOutput.begin(sys, dl, port, @ptrFromInt(argv[arg_tofile])) orelse return dos.RETURN_ERROR;
    }
    defer if (into_file) |*file_output| file_output.end(sys);

    if (clicks != 0) return triggerClicks(sys, dl, port, clicks, hz, percent, pan_percent);

    // The note, and for a chord its major third and fifth, or for a bench
    // a semitone apart: a stream each.
    var rates: [max_notes]u32 = @splat(hz);
    var count: usize = 1;
    if (bench != 0) {
        count = bench;
        for (rates[0..count], semitones[0..count]) |*rate, ratio| rate.* = hz * ratio / 1000;
    } else if (chord) {
        count = 3;
        rates[1] = hz * 5 / 4;
        rates[2] = hz * 3 / 2;
    }
    var notes: [max_notes]Note = @splat(.{});
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

    const first = notes[0].io.?;
    if (argv[arg_outputs] != 0) {
        listOutputs(sys, dl, first);
        return dos.RETURN_OK;
    }
    if (argv[arg_output] != 0) {
        const wanted: [*:0]const u8 = @ptrFromInt(argv[arg_output]);
        const id = outputNamed(sys, first, wanted) orelse {
            _ = Printf(dl, MSG_NOOUTPUT, .{ COMMAND_NAME, wanted });
            return dos.RETURN_ERROR;
        };
        first.std.req.command = audio.AUDIOCMD_SETOUTPUT;
        first.std.data = null;
        first.output = id;
        if (sys.DoIO(&first.std.req) != 0) {
            _ = Printf(dl, MSG_NOSWITCH, .{ COMMAND_NAME, wanted });
            return dos.RETURN_ERROR;
        }
    }

    // What the board has, from the first stream.
    var info: audio.AudioInfo = .{};
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
            info.triggers,
        });
    }
    if (bench != 0) {
        _ = Printf(dl, MSG_BENCH, .{ bench, hz, percent, seconds });
    } else if (chord) {
        _ = Printf(dl, MSG_CHORD, .{ rates[0], rates[1], rates[2], percent, seconds });
    } else {
        _ = Printf(dl, MSG_PLAYING, .{ hz, percent, pan_percent, seconds });
    }

    // Where the device's task and core 0 stood, for a bench.
    const before = Measure.take(sys, first, &info);

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
    if (bench != 0) {
        const after = Measure.take(sys, first, &info);
        const span = after.core -% before.core;
        const ran = after.task -% before.task;
        const tenths: u32 = if (span != 0) @intCast(@min(ran * 1000 / span, 1000)) else 0;
        _ = Printf(dl, MSG_BENCHED, .{ after.underruns -% before.underruns, tenths / 10, tenths % 10 });
    }
    return if (err == 0) dos.RETURN_OK else dos.RETURN_WARN;
}

/// `count` clicks of the note, each a trigger sent as soon as the last
/// has gone, on one open for triggers; then every one waited for, and
/// what became of them said.
fn triggerClicks(sys: *ExecBase, dl: *DosBase, port: *exec.MsgPort, count: u32, hz: u32, percent: u32, pan_percent: i32) i32 {
    var shots: [max_clicks]?*audio.IOAudio = @splat(null);
    defer for (shots[0..count]) |held| {
        if (held) |io| sys.DeleteIORequest(&io.std.req);
    };
    for (shots[0..count]) |*slot| {
        slot.* = @ptrCast(@alignCast(sys.CreateIORequest(port, @sizeOf(audio.IOAudio)) orelse return dos.RETURN_FAIL));
    }
    const opened = shots[0].?;
    if (sys.OpenDevice(audio.AUDIONAME, audio.AUDIO_UNIT_PLAY, &opened.std.req, audio.AUDIOF_TRIGGER) != 0) {
        _ = Printf(dl, MSG_NODEVICE, .{audio.AUDIONAME});
        return dos.RETURN_FAIL;
    }
    defer sys.CloseDevice(&opened.std.req);
    var info: audio.AudioInfo = .{};
    const before = Measure.take(sys, opened, &info);
    // Each a copy of the opened request: the same device and unit.
    const template_io = opened.*;
    for (shots[0..count]) |held| {
        const io = held.?;
        io.* = template_io;
        io.std.req.message.reply_port = port;
        io.std.req.command = audio.AUDIOCMD_TRIGGER;
        io.std.req.flags = 0;
        io.std.data = @ptrCast(@constCast(&wave));
        io.std.length = wave.len;
        io.format = audio.AUDIO_S16;
        io.channels = 1;
        io.rate = hz * wave_len;
        io.volume = audio.AUDIO_VOLUME_UNITY / 100 * percent;
        io.pan = @divTrunc(audio.AUDIO_PAN_FULL, 100) * pan_percent;
        // A twentieth of a second of the note.
        io.loops = @max(hz / 20, 1);
        sys.SendIO(&io.std.req);
    }
    var played: u32 = 0;
    var gave_way: u32 = 0;
    var refused: u32 = 0;
    for (shots[0..count]) |held| {
        switch (sys.WaitIO(&held.?.std.req)) {
            0 => played += 1,
            exec.IOERR_ABORTED => gave_way += 1,
            else => refused += 1,
        }
    }
    const after = Measure.take(sys, opened, &info);
    _ = Printf(dl, MSG_TRIGGERS, .{ count, hz, played, gave_way, refused, after.underruns -% before.underruns });
    return if (refused == 0) dos.RETURN_OK else dos.RETURN_WARN;
}

/// The file sink TOFILE plays into: rta.library, the sink, an open of the
/// device for the switch to it and back - for triggers, so it takes no
/// stream - and the output played through before.
const FileOutput = struct {
    rta_lib: *RtaBase,
    sink: *rta.AudioSink,
    io: *audio.IOAudio,
    before: u32,

    /// The sink made for `name` and played through, or null, said why.
    fn begin(sys: *ExecBase, dl: *DosBase, port: *exec.MsgPort, name: [*:0]const u8) ?FileOutput {
        const library = sys.OpenLibrary(rta.RTANAME, rta.RTA_VERSION) orelse {
            _ = Printf(dl, MSG_NORTA, .{ COMMAND_NAME, @as([*:0]const u8, rta.RTANAME) });
            return null;
        };
        const rta_lib: *RtaBase = @ptrCast(library);
        // At the bottom of the list: never what a program gets by default.
        const sink_tags = [_]TagItem{
            .{ .tag = rta.filesink.FILEA_Name, .data = @intFromPtr(name) },
            .{ .tag = rta.tags.RTAA_Name, .data = @intFromPtr(@as([*:0]const u8, rta.filesink.FILE_DRIVER_NAME)) },
            .{ .tag = rta.tags.RTAA_Priority, .data = @bitCast(@as(isize, -120)) },
            .{},
        };
        const sink = rta_lib.CreateSinkTagList(rta.filesink.FILE_DRIVER_NAME, &sink_tags) orelse {
            _ = Printf(dl, MSG_NOFILESINK, .{ COMMAND_NAME, rta_lib.RtaErrorText(rta_lib.RtaLastError()) });
            sys.CloseLibrary(library);
            return null;
        };
        const io: *audio.IOAudio = @ptrCast(@alignCast(sys.CreateIORequest(port, @sizeOf(audio.IOAudio)) orelse {
            rta_lib.DeleteSink(sink);
            sys.CloseLibrary(library);
            return null;
        }));
        if (sys.OpenDevice(audio.AUDIONAME, audio.AUDIO_UNIT_PLAY, &io.std.req, audio.AUDIOF_TRIGGER) != 0) {
            _ = Printf(dl, MSG_NODEVICE, .{audio.AUDIONAME});
            sys.DeleteIORequest(&io.std.req);
            rta_lib.DeleteSink(sink);
            sys.CloseLibrary(library);
            return null;
        }
        var file_output: FileOutput = .{ .rta_lib = rta_lib, .sink = sink, .io = io, .before = 0 };
        var info: audio.AudioOutputInfo = .{};
        io.std.req.command = audio.AUDIOCMD_GETOUTPUT;
        io.std.data = &info;
        io.std.length = @sizeOf(audio.AudioOutputInfo);
        if (sys.DoIO(&io.std.req) == 0) file_output.before = io.output;
        if (!switchTo(sys, io, sink.id)) {
            _ = Printf(dl, MSG_NOSWITCH, .{ COMMAND_NAME, @as([*:0]const u8, rta.filesink.FILE_DRIVER_NAME) });
            file_output.close(sys);
            return null;
        }
        _ = Printf(dl, MSG_TOFILE, .{name});
        return file_output;
    }

    /// Back to the output played through before - the file closed as the
    /// sink stops - and the sink deleted.
    fn end(file_output: *FileOutput, sys: *ExecBase) void {
        _ = switchTo(sys, file_output.io, file_output.before);
        file_output.close(sys);
    }

    fn close(file_output: *FileOutput, sys: *ExecBase) void {
        sys.CloseDevice(&file_output.io.std.req);
        sys.DeleteIORequest(&file_output.io.std.req);
        file_output.rta_lib.DeleteSink(file_output.sink);
        sys.CloseLibrary(@ptrCast(@alignCast(file_output.rta_lib)));
    }

    fn switchTo(sys: *ExecBase, io: *audio.IOAudio, id: u32) bool {
        io.std.req.command = audio.AUDIOCMD_SETOUTPUT;
        io.std.data = null;
        io.std.length = 0;
        io.output = id;
        return sys.DoIO(&io.std.req) == 0;
    }
};

/// Every output the device can play through, a line each.
fn listOutputs(sys: *ExecBase, dl: *DosBase, io: *audio.IOAudio) void {
    var info: audio.AudioOutputInfo = .{};
    io.output = 0;
    while (nextOutput(sys, io, &info)) {
        _ = Printf(dl, MSG_ONEOUTPUT, .{
            @as([*:0]const u8, @ptrCast(&info.name)),
            info.id,
            @as([*:0]const u8, if (info.channels == 1) "one side" else "two sides"),
        });
        for (info.rates[0..info.rate_count]) |rate| _ = Printf(dl, MSG_RATE, .{rate});
        _ = Printf(dl, MSG_HZ, .{});
        if (info.flags & audio.AUDIOOF_DEFAULT != 0) _ = Printf(dl, MSG_DEFAULT, .{});
        if (info.flags & audio.AUDIOOF_CURRENT != 0) _ = Printf(dl, MSG_CURRENT, .{});
        _ = Printf(dl, MSG_NEWLINE, .{});
    }
}

/// The output after the one `io.output` names into `info`, its number
/// left in `io.output`; false past the last.
fn nextOutput(sys: *ExecBase, io: *audio.IOAudio, info: *audio.AudioOutputInfo) bool {
    io.std.req.command = audio.AUDIOCMD_NEXTOUTPUT;
    io.std.data = info;
    io.std.length = @sizeOf(audio.AudioOutputInfo);
    return sys.DoIO(&io.std.req) == 0;
}

/// The number of the output of that name, its case not minded.
fn outputNamed(sys: *ExecBase, io: *audio.IOAudio, wanted: [*:0]const u8) ?u32 {
    var info: audio.AudioOutputInfo = .{};
    io.output = 0;
    while (nextOutput(sys, io, &info)) {
        if (sameName(&info.name, wanted)) return info.id;
    }
    return null;
}

fn sameName(name: []const u8, wanted: [*:0]const u8) bool {
    var at: usize = 0;
    while (at < name.len) : (at += 1) {
        if (lower(name[at]) != lower(wanted[at])) return false;
        if (name[at] == 0) return true;
    }
    return false;
}

fn lower(char: u8) u8 {
    return if (char >= 'A' and char <= 'Z') char + 32 else char;
}

/// What a bench compares: the output's count of buffers played again, the
/// cycles the device's task has run, and the cycles core 0 has counted.
const Measure = struct {
    underruns: u32 = 0,
    task: u64 = 0,
    core: u64 = 0,

    fn take(sys: *ExecBase, io: *audio.IOAudio, info: *audio.AudioInfo) Measure {
        var got: Measure = .{};
        io.std.req.command = audio.AUDIOCMD_QUERY;
        io.std.data = info;
        io.std.length = @sizeOf(audio.AudioInfo);
        if (sys.DoIO(&io.std.req) == 0) got.underruns = info.underruns;
        if (sys.FindTask(audio.AUDIONAME)) |task| got.task = task.timeRun();
        var times: exec.CoreTimes = .{};
        if (sys.ReadCoreTimes(0, &times)) got.core = times.tasks +% times.idle +% times.interrupts;
        return got;
    }
};
