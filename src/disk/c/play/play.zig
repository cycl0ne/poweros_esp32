// SPDX-License-Identifier: MIT
//! Play: a sound file out of the speaker - WAV, MP3, FLAC, Ogg Vorbis or
//! AAC (an `.aac` file, or an `.m4a` through media.library) - or a
//! station, through audiocodec.library and audio.device. Built against
//! the SDK only.
//!
//!   Play FILE/A,VOLUME/K/N,START/K/N,QUIET/S
//!
//! It says what the file is - its names, its kind, rate and channels, how
//! long it is - and plays it to the end, or until Ctrl-C. VOLUME is in
//! percent of as recorded (100), START how many seconds in to begin, QUIET
//! leaves the lines about what plays out. A chained Ogg file plays song
//! after song, each said as it begins.
//!
//! **A FILE that is an `http://` or `https://` address** is a station:
//! its sound - MP3 or Ogg Vorbis - is read on a process of its own into a
//! ring (station.zig) and played a few seconds behind, so the network's
//! hiccups are not heard. Play says the station's name, and each title
//! its metadata names as it changes - or, from an Ogg station, each song's
//! own names. It plays until the station ends the stream, the connection
//! is lost - said why - or Ctrl-C; START is a file's only.
//!
//! The sound is decoded as it plays: three buffers of samples go round,
//! one playing, one queued behind it, one being filled - so the sound runs
//! without a gap whatever the file's length, and a song takes no more
//! memory than a second of it. A song of a chained file or station at
//! another rate waits for the one before it to be played out.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const audio = sdk.devices.audio;
const audiocontrol = sdk.devices.audiocontrol;
const ac = sdk.audiocodec;
const utility = sdk.utility;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const AudioCodecBase = sdk.interface.audiocodec.AudioCodecBase;
const Printf = dos.stdio.Printf;
const station_zig = @import("station.zig");
const Station = station_zig.Station;

pub const COMMAND_NAME = "Play";
const VERSION_STRING = "\x00$VER: Play 1.4 (29.10.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "FILE/A,VOLUME/K/N,START/K/N,QUIET/S";
const arg_file = 0;
const arg_volume = 1;
const arg_start = 2;
const arg_quiet = 3;

/// Frames a buffer holds, and how many buffers go round.
const buffer_frames = 4096;
const buffer_count = 3;
/// The samples a frame holds at the most.
const channels_most = 2;

const MSG_NOLIBRARY = "%s: no %s\n";
const MSG_NOMEMORY = "%s: no memory\n";
const MSG_NOSOUND = "%s: no %s - this machine has no sound\n";
const MSG_CANNOT = "%s: %s: %s\n";
const MSG_WHAT = "%s%s%s%s%s%s\n%s, %u Hz, %s, %u kbit/s, %u:%02u\n";
const MSG_STATION = "%s\n%s, %u Hz, %s, %u kbit/s\n";
const MSG_NOW = "Now playing: %s%s%s\n";
const MSG_NOFORMAT = "%s: audio.device does not take %u Hz %u channels\n";
const MSG_ERROR = "%s: decoding stopped: %s\n";
const MSG_LOST = "%s: %s\n";
const MSG_NOTHING = "the station sent no sound";

fn numberAt(at: usize) i32 {
    return @as(*const i32, @ptrFromInt(at)).*;
}

fn kindName(codec: u32) [*:0]const u8 {
    return switch (codec) {
        ac.ACODEC_WAV => "WAV",
        ac.ACODEC_MP3 => "MP3",
        ac.ACODEC_FLAC => "FLAC",
        ac.ACODEC_VORBIS => "Ogg Vorbis",
        ac.ACODEC_AAC => "AAC",
        else => "sound",
    };
}

/// Whether `name` is a station's address: `http://` or `https://`, in
/// any case.
fn isAddress(name: [*:0]const u8) bool {
    for ([_][]const u8{ "http://", "https://" }) |scheme| {
        var at: usize = 0;
        while (at < scheme.len and name[at] != 0 and (name[at] | 0x20) == scheme[at]) at += 1;
        if (at == scheme.len) return true;
    }
    return false;
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
    const quiet = argv[arg_quiet] != 0;

    const codec_lib = sys.OpenLibrary(ac.AUDIOCODECNAME, 1) orelse {
        _ = Printf(dl, MSG_NOLIBRARY, .{ COMMAND_NAME, ac.AUDIOCODECNAME });
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(codec_lib);
    const acb: *AudioCodecBase = @ptrCast(codec_lib);

    // A Ctrl-C from before this command started is not a request to stop it.
    _ = sys.SetSignal(0, exec.SIGBREAKF_CTRL_C);

    // A station: its reader started, and two seconds of its sound waited
    // for before the stream is opened on the ring.
    var station: ?*Station = null;
    defer if (station) |started| started.free();
    var facts: station_zig.Facts = .{};
    if (isAddress(file)) {
        const started = Station.start(sys, dl, file) orelse {
            _ = Printf(dl, MSG_NOMEMORY, .{COMMAND_NAME});
            return dos.RETURN_FAIL;
        };
        station = started;
        while (!started.wakeAt(started.startBytes())) {
            if (sys.Wait(started.signal() | exec.SIGBREAKF_CTRL_C) & exec.SIGBREAKF_CTRL_C != 0) {
                _ = dl.PrintFault(dos.ERROR_BREAK, COMMAND_NAME);
                return dos.RETURN_WARN;
            }
        }
        started.facts(&facts);
        if (!facts.heard) {
            const why: [*:0]const u8 = if (facts.why[0] != 0) &facts.why else MSG_NOTHING;
            _ = Printf(dl, MSG_CANNOT, .{ COMMAND_NAME, file, why });
            return dos.RETURN_ERROR;
        }
    }

    var err: i32 = 0;
    const opened_stream = if (station) |started| acb.OpenAudioStream(&[_]utility.TagItem{
        .{ .tag = ac.ACA_ReadFunc, .data = @intFromPtr(&station_zig.read) },
        .{ .tag = ac.ACA_ReadData, .data = @intFromPtr(started) },
        .{ .tag = ac.ACA_Codec, .data = started.codecOf() },
        .{},
    }, &err) else acb.OpenAudioStream(&[_]utility.TagItem{
        .{ .tag = ac.ACA_Name, .data = @intFromPtr(file) },
        .{},
    }, &err);
    const stream = opened_stream orelse {
        if (sys.SetSignal(0, 0) & exec.SIGBREAKF_CTRL_C != 0) {
            _ = dl.PrintFault(dos.ERROR_BREAK, COMMAND_NAME);
            return dos.RETURN_WARN;
        }
        _ = Printf(dl, MSG_CANNOT, .{ COMMAND_NAME, file, acb.AudioErrorText(err) });
        return dos.RETURN_ERROR;
    };
    defer acb.CloseAudioStream(stream);
    var info: ac.AudioStreamInfo = .{};
    acb.GetAudioStreamInfo(stream, &info);
    if (!quiet) {
        if (station != null) {
            const name: [*:0]const u8 = if (facts.name[0] != 0) &facts.name else file;
            const kbps = if (facts.kbps != 0) facts.kbps else info.bitrate / 1000;
            _ = Printf(dl, MSG_STATION, .{ name, kindName(info.codec), info.rate, channelsName(info.channels), kbps });
            // An Ogg station's song names itself; a title from the metadata
            // follows as it comes.
            if (info.title[0] != 0) sayNow(dl, &info);
        } else {
            sayFile(dl, &info, file);
        }
    }
    if (start != 0 and station == null) _ = acb.SeekAudio(stream, start *| info.rate);

    // The samples: three buffers, a request each, all on one stream.
    const memory = sys.AllocVec(buffer_count * buffer_frames * channels_most * 2, exec.MEMF_ANY) orelse return dos.RETURN_FAIL;
    defer sys.FreeVec(memory);

    const port = sys.CreateMsgPort() orelse return dos.RETURN_FAIL;
    defer sys.DeleteMsgPort(port);
    var made: [buffer_count]?*audio.IOAudio = @splat(null);
    defer for (made) |maybe| {
        if (maybe) |io| sys.DeleteIORequest(&io.std.req);
    };
    for (&made) |*slot| {
        slot.* = @ptrCast(@alignCast(sys.CreateIORequest(port, @sizeOf(audio.IOAudio)) orelse return dos.RETURN_FAIL));
    }
    var requests: [buffer_count]*audio.IOAudio = undefined;
    for (&requests, made) |*slot, maybe| slot.* = maybe.?;
    const first = requests[0];
    first.format = audio.AUDIO_S16;
    first.channels = @intCast(info.channels);
    first.rate = info.rate;
    first.volume = audiocontrol.volumeOf(percent);
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
    for (requests[1..]) |io| {
        const own_port = io.std.req.message.reply_port;
        io.* = first.*;
        io.std.req.message.reply_port = own_port;
    }

    var sound: Sound = .{
        .sys = sys,
        .dl = dl,
        .acb = acb,
        .stream = stream,
        .port = port,
        .requests = requests,
        .samples = @ptrCast(@alignCast(memory)),
        .station = station,
        .quiet = quiet,
        .volume = first.volume,
        .rate = info.rate,
        .channels = info.channels,
        .name = file,
    };
    // A Ctrl-C a station's ring was waited for with ends the decoding
    // there, and is left set.
    const stopped = !sound.play() or sys.SetSignal(0, exec.SIGBREAKF_CTRL_C) & exec.SIGBREAKF_CTRL_C != 0;
    if (stopped) {
        _ = dl.PrintFault(dos.ERROR_BREAK, COMMAND_NAME);
        return dos.RETURN_WARN;
    }
    if (sound.decode_error < 0) {
        _ = Printf(dl, MSG_ERROR, .{ COMMAND_NAME, acb.AudioErrorText(sound.decode_error) });
        return dos.RETURN_WARN;
    }
    if (station) |started| {
        started.facts(&facts);
        if (facts.why[0] != 0) {
            _ = Printf(dl, MSG_LOST, .{ COMMAND_NAME, &facts.why });
            return dos.RETURN_WARN;
        }
    }
    return dos.RETURN_OK;
}

/// The sound going out: the stream decoded into the buffers going round,
/// and the form the device plays it in.
const Sound = struct {
    sys: *ExecBase,
    dl: *DosBase,
    acb: *AudioCodecBase,
    stream: *ac.AudioStream,
    port: *exec.MsgPort,
    requests: [buffer_count]*audio.IOAudio,
    samples: [*]i16,
    station: ?*Station,
    quiet: bool,
    volume: u32,
    /// The rate and channels the device plays.
    rate: u32,
    channels: u32,
    /// What a song of a chained file is called when it names nothing.
    name: [*:0]const u8,
    /// The song being decoded, as ACA_Link counts them.
    link: u32 = 0,
    /// The request that comes back next - they come back in the order
    /// they were sent - and how many are out.
    oldest: usize = 0,
    outstanding: usize = 0,
    /// A buffer of a song at another rate, kept until the device has
    /// played what it holds, and its frames.
    held: ?usize = null,
    held_frames: u32 = 0,
    /// Nothing more to decode.
    ending: bool = false,
    /// The station's ring ran low: nothing decoded until it holds what a
    /// start wants.
    starved: bool = false,
    decode_error: i32 = 0,
    /// The station's titles said so far.
    titles: u32 = 0,

    /// Played to the end: false at Ctrl-C, what is still queued taken
    /// back.
    fn play(sound: *Sound) bool {
        const sys = sound.sys;
        const news: u32 = if (sound.station) |started| started.signal() else 0;
        while (true) {
            if (sound.held) |slot| {
                if (sound.outstanding == 0) {
                    sound.held = null;
                    sound.setForm(slot);
                    sound.send(slot, sound.held_frames);
                }
            }
            sound.fillFree();
            if (sound.outstanding == 0 and sound.held == null and !sound.starved) return true;
            sound.sayTitle();
            if (sys.Wait(sound.port.sigMask() | news | exec.SIGBREAKF_CTRL_C) & exec.SIGBREAKF_CTRL_C != 0) {
                for (0..sound.outstanding) |n| {
                    const io = sound.requests[(sound.oldest + n) % buffer_count];
                    _ = sys.AbortIO(&io.std.req);
                    _ = sys.WaitIO(&io.std.req);
                }
                return false;
            }
            while (sound.outstanding > 0) {
                const io = sound.requests[sound.oldest];
                if (sys.CheckIO(&io.std.req) == null) break;
                _ = sys.WaitIO(&io.std.req);
                sound.outstanding -= 1;
                sound.oldest = (sound.oldest + 1) % buffer_count;
            }
        }
    }

    /// Every free buffer filled and sent, in turn after those out - while
    /// there is something to decode, and a station's ring holds what a
    /// decoding reads.
    fn fillFree(sound: *Sound) void {
        while (!sound.ending and sound.held == null and sound.outstanding < buffer_count) {
            if (sound.station) |started| {
                if (!sound.starved and !started.holds(station_zig.decode_least)) sound.starved = true;
                if (sound.starved) {
                    if (!started.wakeAt(started.startBytes())) return;
                    sound.starved = false;
                }
            }
            sound.fill((sound.oldest + sound.outstanding) % buffer_count);
        }
    }

    /// The next frames decoded into buffer `slot` and sent - or, the first
    /// of a song at another rate, held until those before them are played.
    fn fill(sound: *Sound, slot: usize) void {
        const got = sound.acb.DecodeAudio(sound.stream, sound.buffer(slot), buffer_frames);
        if (got <= 0) {
            if (got < 0) sound.decode_error = got;
            sound.ending = true;
            return;
        }
        const frames: u32 = @intCast(got);
        if (sound.linkBegun()) |info| {
            if (info.rate != sound.rate and sound.outstanding > 0) {
                sound.rate = info.rate;
                sound.channels = info.channels;
                sound.held = slot;
                sound.held_frames = frames;
                return;
            }
            sound.rate = info.rate;
            sound.channels = info.channels;
            sound.setForm(slot);
        }
        sound.send(slot, frames);
    }

    fn buffer(sound: *Sound, slot: usize) [*]i16 {
        return sound.samples + slot * buffer_frames * channels_most;
    }

    fn send(sound: *Sound, slot: usize, frames: u32) void {
        const io = sound.requests[slot];
        io.std.req.command = exec.CMD_WRITE;
        io.std.req.flags = 0;
        io.std.data = sound.buffer(slot);
        io.std.length = @as(u64, frames) * sound.channels * 2;
        io.loops = 1;
        sound.sys.SendIO(&io.std.req);
        sound.outstanding += 1;
    }

    /// The device told the rate and channels from now on, through the
    /// free request `slot`.
    fn setForm(sound: *Sound, slot: usize) void {
        const io = sound.requests[slot];
        io.std.req.command = audio.AUDIOCMD_SETPARAMS;
        io.format = audio.AUDIO_S16;
        io.channels = @intCast(sound.channels);
        io.rate = sound.rate;
        io.volume = sound.volume;
        io.pan = 0;
        _ = sound.sys.DoIO(&io.std.req);
    }

    /// The song the frames just decoded are of, when it is another than
    /// before - a chained file's or station's next: its info, said.
    fn linkBegun(sound: *Sound) ?ac.AudioStreamInfo {
        var link = sound.link;
        _ = sound.acb.GetAudioStreamAttrs(sound.stream, &[_]utility.TagItem{
            .{ .tag = ac.ACA_Link, .data = @intFromPtr(&link) },
            .{},
        });
        if (link == sound.link) return null;
        sound.link = link;
        var info: ac.AudioStreamInfo = .{};
        sound.acb.GetAudioStreamInfo(sound.stream, &info);
        if (!sound.quiet) {
            if (sound.station != null) {
                if (info.title[0] != 0) sayNow(sound.dl, &info);
            } else {
                sayFile(sound.dl, &info, sound.name);
            }
        }
        return info;
    }

    /// A station's new title, when its metadata named one since the last.
    fn sayTitle(sound: *Sound) void {
        const started = sound.station orelse return;
        var facts: station_zig.Facts = undefined;
        started.facts(&facts);
        if (facts.titles == sound.titles) return;
        sound.titles = facts.titles;
        if (sound.quiet or facts.title[0] == 0) return;
        _ = Printf(sound.dl, MSG_NOW, .{ @as([*:0]const u8, &facts.title), @as([*:0]const u8, ""), @as([*:0]const u8, "") });
    }
};

fn channelsName(channels: u32) [*:0]const u8 {
    return if (channels == 1) "mono" else "stereo";
}

/// What a file - or a chained file's song - is: its names, or `file`
/// without; its kind, rate, channels and length.
fn sayFile(dl: *DosBase, info: *const ac.AudioStreamInfo, file: [*:0]const u8) void {
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
        channelsName(info.channels),
        info.bitrate / 1000,
        seconds / 60,
        seconds % 60,
    });
}

/// A station's song as its own tags name it: the artist, then the title,
/// as a station's metadata gives them.
fn sayNow(dl: *DosBase, info: *const ac.AudioStreamInfo) void {
    const has_artist = info.artist[0] != 0;
    _ = Printf(dl, MSG_NOW, .{
        @as([*:0]const u8, if (has_artist) @ptrCast(&info.artist) else ""),
        @as([*:0]const u8, if (has_artist) " - " else ""),
        @as([*:0]const u8, @ptrCast(&info.title)),
    });
}
