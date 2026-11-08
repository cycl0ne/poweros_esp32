// SPDX-License-Identifier: MIT
//! Film: a film decoded through videocodec.library as fast as it goes,
//! timed and checked - nothing is shown or played. Built against the SDK
//! only.
//!
//!   Film FILE/A,FRAME/K/N,TO/K,NOSOUND/S,SEEK/K/N,TOGETHER/S,TRACKS/S,
//!        SUBS/K/N,PACKETS/K/N
//!
//! What the film is is printed - its pictures' codec, size and rate, its
//! length, its sound - then every frame is taken and given back: how many
//! came out, how fast, and whether their times rose. The first picture
//! says what its numbers mean as well: its layout, matrix, curve,
//! primaries, range and depth, and the light it was mastered for, which
//! is what graphics and a video layer go by. Then its sound is
//! decoded whole, timed (NOSOUND leaves it closed). TOGETHER decodes the
//! sound on a process of its own while the pictures are decoded, as a
//! player does.
//!
//! FRAME (and TO) writes that frame - counted from 0 in the order they
//! are shown - into TO as its planes are: NV12 (the brightness rows, then
//! the colour rows, each as wide as the picture) for the chip's, I420 for
//! Motion JPEG's and the software decoders'. A film of ten bits is
//! written as the decoder hands it out, two bytes a sample, little endian
//! - ffmpeg's `yuv420p10le`. `ffmpeg -i FILE -vf "select=eq(n\,FRAME)" -frames:v 1
//! -pix_fmt nv12 -f rawvideo ref.nv12` makes ffmpeg's to compare.
//!
//! SEEK moves the film to that second at the end and says where it
//! landed, the next frame's time, and how much sound is left from there;
//! with TO and no FRAME, that next frame is what TO is written with.
//!
//! TRACKS lists every track instead of decoding: its kind, its codec, its
//! language and name, how long it lasts, and whether something here
//! decodes it (GetVideoTrack's VTRK_DECODED - what Movie greys an item
//! out by) and whether it is the one chosen. SUBS is a text track to
//! show: it is selected at SEEK's second, or the start, and the
//! subtitles GetVideoSubtitle hands out over the next two minutes of the
//! film are printed as they come - a line's text, or a picture's size and
//! place. PACKETS is a track whose packets are read through media.library
//! itself, from SEEK's second: where each is due, how long it lasts, how
//! large it is and its first bytes - what a codec is handed. None of the
//! three decodes a frame.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const media = sdk.media;
const vc = sdk.videocodec;
const ac = sdk.audiocodec;
const rtg = sdk.rtg;
const timer = sdk.devices.timer;
const TagItem = sdk.utility.TagItem;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const VideoCodecBase = sdk.interface.videocodec.VideoCodecBase;
const MediaBase = sdk.interface.media.MediaBase;
const TimerBase = timer.TimerBase;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "Film";
const VERSION_STRING = "\x00$VER: Film 1.5 (08.11.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "FILE/A,FRAME/K/N,TO/K,NOSOUND/S,SEEK/K/N,TOGETHER/S,TRACKS/S,SUBS/K/N,PACKETS/K/N";
const arg_file = 0;
const arg_frame = 1;
const arg_to = 2;
const arg_nosound = 3;
const arg_seek = 4;
const arg_together = 5;
const arg_tracks = 6;
const arg_subs = 7;
const arg_packets = 8;

/// How many packets PACKETS reads, and the bytes of each it shows.
const packets_read = 12;
const packet_head = 16;

/// How far into the film SUBS looks for subtitles, and the step it asks
/// in: a line lasts seconds, a picture longer.
const subs_window: i64 = 120 * 1_000_000;
const subs_step: i64 = 250_000;

/// Sound frames a call asks for: 4 KiB of stereo samples, on the stack.
const piece = 1024;

fn now(tb: *TimerBase) u64 {
    var ev: timer.EClockVal = .{};
    const rate = tb.ReadEClock(&ev);
    return ev.toTicks() * 1_000_000 / rate;
}

fn codecName(codec: u32) [*:0]const u8 {
    return switch (codec) {
        vc.VCODEC_H264 => "H.264",
        vc.VCODEC_H265 => "H.265",
        vc.VCODEC_MJPEG => "Motion JPEG",
        vc.VCODEC_MPEG4V => "MPEG-4 Part 2",
        vc.VCODEC_VP8 => "VP8",
        vc.VCODEC_VP9 => "VP9",
        vc.VCODEC_AV1 => "AV1",
        else => "pictures",
    };
}

fn soundName(codec: u32) [*:0]const u8 {
    return switch (codec) {
        ac.ACODEC_AAC => "AAC",
        ac.ACODEC_MP3 => "MP3",
        ac.ACODEC_FLAC => "FLAC",
        ac.ACODEC_VORBIS => "Vorbis",
        ac.ACODEC_AC3 => "AC-3",
        ac.ACODEC_EAC3 => "E-AC-3",
        ac.ACODEC_OPUS => "Opus",
        ac.ACODEC_DTS => "DTS",
        else => "sound",
    };
}

fn kindName(kind: u32) [*:0]const u8 {
    return switch (kind) {
        media.MTRACK_VIDEO => "pictures",
        media.MTRACK_AUDIO => "sound",
        media.MTRACK_TEXT => "text",
        else => "other",
    };
}

/// A container's codec by name, whatever kind of track it is on.
fn trackName(codec: u32) [*:0]const u8 {
    return switch (codec) {
        media.MCODEC_H264 => "H.264",
        media.MCODEC_H265 => "H.265",
        media.MCODEC_MJPEG => "Motion JPEG",
        media.MCODEC_MPEG4V => "MPEG-4 Part 2",
        media.MCODEC_VP8 => "VP8",
        media.MCODEC_VP9 => "VP9",
        media.MCODEC_AV1 => "AV1",
        media.MCODEC_AAC => "AAC",
        media.MCODEC_MP3 => "MP3",
        media.MCODEC_ALAC => "ALAC",
        media.MCODEC_AC3 => "AC-3",
        media.MCODEC_EAC3 => "E-AC-3",
        media.MCODEC_OPUS => "Opus",
        media.MCODEC_FLAC => "FLAC",
        media.MCODEC_VORBIS => "Vorbis",
        media.MCODEC_DTS => "DTS",
        media.MCODEC_TEXT => "plain text",
        media.MCODEC_SRT => "SubRip",
        media.MCODEC_ASS => "SubStation Alpha",
        media.MCODEC_PGS => "Blu-ray pictures (PGS)",
        else => "a codec it has no name for",
    };
}

fn text(name: anytype) [*:0]const u8 {
    return @ptrCast(name);
}

/// Every track of the film: what it is, and what videocodec.library makes
/// of it.
fn listTracks(dl: *DosBase, vcb: *VideoCodecBase, film: *vc.VideoStream) void {
    var number: u32 = 0;
    while (true) : (number += 1) {
        var track: media.MediaTrack = .{};
        const flags = vcb.GetVideoTrack(film, number, &track);
        if (flags < 0) break;
        const marks: u32 = @intCast(flags);
        _ = Printf(dl, "track %u: %s, %s, %s \"%s\", %lu ms, %s%s\n", .{
            number,
            kindName(track.kind),
            trackName(track.codec),
            text(&track.language),
            text(&track.name),
            track.duration / 1000,
            if (marks & vc.VTRK_DECODED != 0) "decoded here" else "nothing here decodes it",
            if (marks & vc.VTRK_CHOSEN != 0) ", chosen" else "",
        });
    }
}

/// The subtitles of `track` from `from`, as GetVideoSubtitle hands them
/// out while the film's time goes on.
fn showSubtitles(sys: *ExecBase, dl: *DosBase, vcb: *VideoCodecBase, film: *vc.VideoStream, track: u32, from: i64) void {
    const chose = vcb.SelectVideoTrack(film, track, from);
    _ = Printf(dl, "subtitles on track %u from %lu ms: %s\n", .{ track, @divTrunc(from, 1000), vcb.VideoErrorText(chose) });
    if (chose != vc.VCERR_OK) return;
    var at = from;
    var last: i64 = -1;
    var count: u32 = 0;
    while (at < from + subs_window and !stopped(sys)) : (at += subs_step) {
        var sub: vc.VideoSubtitle = .{};
        // The reader reads ahead on a process of its own: a moment at each
        // step is all it needs for a track as sparse as this one.
        dl.Delay(1);
        if (vcb.GetVideoSubtitle(film, at, &sub) != vc.VCERR_OK) continue;
        if (sub.start == last) continue;
        last = sub.start;
        count += 1;
        if (sub.flags & vc.VSUB_BITMAP != 0) {
            _ = Printf(dl, "%lu to %lu ms: a picture %u x %u at %u, %u\n", .{
                @divTrunc(sub.start, 1000), @divTrunc(sub.end, 1000), sub.width, sub.height, sub.x, sub.y,
            });
        } else {
            _ = Printf(dl, "%lu to %lu ms: %s\n", .{ @divTrunc(sub.start, 1000), @divTrunc(sub.end, 1000), sub.text });
        }
    }
    _ = Printf(dl, "%u subtitles in %lu s of the film\n", .{ count, @divTrunc(at - from, 1_000_000) });
}

/// A track's packets as media.library reads them, from `from`: the film
/// is opened again through media.library alone, as a decoder's module
/// sees it.
fn dumpPackets(sys: *ExecBase, dl: *DosBase, name: [*:0]const u8, track: u32, from: i64) void {
    const lib = sys.OpenLibrary(media.MEDIANAME, 1) orelse {
        _ = Printf(dl, "No %s\n", .{media.MEDIANAME});
        return;
    };
    defer sys.CloseLibrary(lib);
    const mb: *MediaBase = @ptrCast(lib);
    var err: i32 = 0;
    const file = mb.OpenMedia(&[_]TagItem{
        .{ .tag = media.MDA_Name, .data = @intFromPtr(name) },
        .{},
    }, &err) orelse {
        _ = Printf(dl, "%s: %s\n", .{ name, mb.MediaErrorText(err) });
        return;
    };
    defer mb.CloseMedia(file);
    var info: media.MediaTrack = .{};
    if (mb.GetMediaTrack(file, track, &info) != media.MERR_OK) {
        _ = Printf(dl, "no track %u\n", .{track});
        return;
    }
    _ = Printf(dl, "track %u: %s, %s, %u ticks a second, %u packets\n", .{
        track, kindName(info.kind), trackName(info.codec), info.timescale, info.packets,
    });
    if (from > 0) {
        const moved = mb.SeekMedia(file, track, from);
        _ = Printf(dl, "moved to %lu ms: %s\n", .{ @divTrunc(from, 1000), mb.MediaErrorText(moved) });
        if (moved != media.MERR_OK) return;
    }
    var number: u32 = 0;
    while (number < packets_read and !stopped(sys)) : (number += 1) {
        var packet: media.MediaPacket = .{};
        const got = mb.ReadMediaPacket(file, track, &packet);
        if (got != media.MERR_OK) {
            _ = Printf(dl, "after %u packets: %s\n", .{ number, mb.MediaErrorText(got) });
            return;
        }
        var head: [3 * packet_head + 1]u8 = @splat(0);
        if (packet.data) |data| {
            for (data[0..@min(packet.size, packet_head)], 0..) |byte, at| {
                head[at * 3] = hex(byte >> 4);
                head[at * 3 + 1] = hex(byte & 15);
                head[at * 3 + 2] = ' ';
            }
        }
        _ = Printf(dl, "%lu ms, %u ms long, %u bytes: %s\n", .{
            @divTrunc(packet.pts, 1000), packet.duration / 1000, packet.size, text(&head),
        });
    }
}

fn hex(nibble: u8) u8 {
    return if (nibble < 10) '0' + nibble else 'a' + nibble - 10;
}

fn stopped(sys: *ExecBase) bool {
    return sys.SetSignal(0, exec.SIGBREAKF_CTRL_C) & exec.SIGBREAKF_CTRL_C != 0;
}

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(lib);
    const dl: *DosBase = @ptrCast(lib);
    var argv: [9]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_ERROR;
    };
    defer dl.FreeArgs(rda);
    const name: [*:0]const u8 = @ptrFromInt(argv[arg_file]);
    const wanted: ?u32 = if (argv[arg_frame] != 0) @bitCast(@as(*const i32, @ptrFromInt(argv[arg_frame])).*) else null;

    const codec_lib = sys.OpenLibrary(vc.VIDEOCODECNAME, 1) orelse {
        _ = Printf(dl, "No %s\n", .{vc.VIDEOCODECNAME});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(codec_lib);
    const vcb: *VideoCodecBase = @ptrCast(codec_lib);

    var timer_req: timer.TimeRequest = .{};
    if (sys.OpenDevice(sdk.interface.timer.NAME, timer.UNIT_MICROHZ, &timer_req.node, 0) != 0) return dos.RETURN_FAIL;
    defer sys.CloseDevice(&timer_req.node);
    const tb: *TimerBase = @ptrCast(timer_req.node.device.?);

    const started = now(tb);
    var err: i32 = 0;
    const film = vcb.OpenVideoStream(&[_]TagItem{
        .{ .tag = vc.VCA_Name, .data = @intFromPtr(name) },
        .{ .tag = vc.VCA_Sound, .data = @intFromBool(argv[arg_nosound] == 0) },
        .{},
    }, &err) orelse {
        _ = Printf(dl, "%s: %s\n", .{ name, vcb.VideoErrorText(err) });
        return dos.RETURN_ERROR;
    };
    defer vcb.CloseVideoStream(film);
    var info: vc.VideoStreamInfo = .{};
    vcb.GetVideoStreamInfo(film, &info);
    _ = Printf(dl, "%s %u x %u, %u/%u frames a second, %u frames, %lu ms; opened in %lu ms\n", .{
        codecName(info.codec), info.width,           info.height,                info.rate_num, info.rate_den,
        info.frames,           info.duration / 1000, (now(tb) - started) / 1000,
    });
    if (info.sound_codec != 0) {
        _ = Printf(dl, "%s sound, %u Hz, %u channels\n", .{ soundName(info.sound_codec), info.sound_rate, info.sound_channels });
    } else {
        _ = Printf(dl, "no sound\n", .{});
    }

    if (argv[arg_packets] != 0) {
        const track: u32 = @bitCast(@as(*const i32, @ptrFromInt(argv[arg_packets])).*);
        const second: i64 = if (argv[arg_seek] != 0) @as(*const i32, @ptrFromInt(argv[arg_seek])).* else 0;
        dumpPackets(sys, dl, name, track, @max(second, 0) * 1_000_000);
    }
    if (argv[arg_tracks] != 0) listTracks(dl, vcb, film);
    if (argv[arg_subs] != 0) {
        const track: u32 = @bitCast(@as(*const i32, @ptrFromInt(argv[arg_subs])).*);
        const second: i64 = if (argv[arg_seek] != 0) @as(*const i32, @ptrFromInt(argv[arg_seek])).* else 0;
        showSubtitles(sys, dl, vcb, film, track, @max(second, 0) * 1_000_000);
    }
    if (argv[arg_tracks] != 0 or argv[arg_subs] != 0 or argv[arg_packets] != 0) return dos.RETURN_OK;

    // The sound on a process of its own, while the pictures are decoded.
    var job: SoundJob = .{ .vcb = vcb, .film = film };
    var ended: exec.Message = .{};
    const port = sys.CreateMsgPort() orelse return dos.RETURN_FAIL;
    defer sys.DeleteMsgPort(port);
    const together = argv[arg_together] != 0 and info.sound_codec != 0;
    if (together) {
        ended = .{ .reply_port = port };
        const tags = [_]TagItem{
            .{ .tag = dos.NP_Entry, .data = @intFromPtr(&soundEntry) },
            .{ .tag = dos.NP_Name, .data = @intFromPtr("Film sound") },
            .{ .tag = dos.NP_UserData, .data = @intFromPtr(&job) },
            .{ .tag = dos.NP_StackSize, .data = 4096 * @sizeOf(usize) },
            .{ .tag = dos.NP_EndMsg, .data = @intFromPtr(&ended) },
            .{},
        };
        if (dl.CreateNewProc(&tags) == null) return dos.RETURN_FAIL;
    }

    // The pictures.
    var result: i32 = dos.RETURN_OK;
    var frame: vc.VideoFrame = .{};
    var frames: u32 = 0;
    var out_of_order: u32 = 0;
    var last: i64 = -1 << 62;
    var slowest: u64 = 0;
    const decoding = now(tb);
    while (true) {
        const asked = now(tb);
        const got = vcb.DecodeVideoFrame(film, &frame);
        if (got == vc.VCERR_END) break;
        if (got != vc.VCERR_OK) {
            _ = Printf(dl, "frame %u: %s\n", .{ frames, vcb.VideoErrorText(got) });
            if (got == vc.VCERR_CORRUPT) continue;
            result = dos.RETURN_WARN;
            break;
        }
        slowest = @max(slowest, now(tb) - asked);
        if (frames == 0) sayColours(dl, &frame.picture);
        if (frame.time <= last) out_of_order += 1;
        last = frame.time;
        if (wanted) |number| {
            if (frame.number == number and argv[arg_to] != 0) writeFrame(dl, @ptrFromInt(argv[arg_to]), &frame);
        }
        vcb.ReleaseVideoFrame(film, &frame);
        frames += 1;
        if (stopped(sys)) {
            _ = Printf(dl, "***Break\n", .{});
            result = dos.RETURN_WARN;
            break;
        }
    }
    const took = @max(now(tb) - decoding, 1);
    const per_100s = @as(u64, frames) * 100_000_000 / took;
    _ = Printf(dl, "%u frames in %lu ms: %lu.%02lu frames a second, the slowest %lu ms; the last at %ld ms", .{
        frames, took / 1000, per_100s / 100, per_100s % 100, slowest / 1000, @divTrunc(last, 1000),
    });
    if (out_of_order != 0) _ = Printf(dl, ", %u out of order", .{out_of_order});
    _ = Printf(dl, "\n", .{});

    if (together) {
        _ = sys.WaitPort(port);
        _ = sys.GetMsg(port);
        const sound_ms = @divTrunc(job.total * 1000, info.sound_rate);
        if (job.failed < 0) {
            _ = Printf(dl, "sound stopped: %s\n", .{vcb.VideoErrorText(job.failed)});
            result = dos.RETURN_WARN;
        }
        _ = Printf(dl, "%lu sound frames (%lu ms) decoded beside them, in %lu ms\n", .{ job.total, sound_ms, (now(tb) - decoding) / 1000 });
    } else if (info.sound_codec != 0) {
        // The sound.
        const total = soundLeft(dl, vcb, film, tb, info);
        if (total < 0) result = dos.RETURN_WARN;
    }

    if (argv[arg_seek] != 0) {
        const second = @as(*const i32, @ptrFromInt(argv[arg_seek])).*;
        const landed = vcb.SeekVideo(film, @as(i64, second) * 1_000_000);
        if (landed < 0) {
            _ = Printf(dl, "seek: %s\n", .{vcb.VideoErrorText(@intCast(landed))});
            return dos.RETURN_WARN;
        }
        _ = Printf(dl, "seek to %ld s: landed at %ld ms", .{ @as(i64, second), @divTrunc(landed, 1000) });
        const next = vcb.DecodeVideoFrame(film, &frame) == vc.VCERR_OK;
        if (next) _ = Printf(dl, ", the next frame at %ld ms, number %u", .{ @divTrunc(frame.time, 1000), frame.number });
        _ = Printf(dl, "\n", .{});
        if (next) {
            if (wanted == null and argv[arg_to] != 0) writeFrame(dl, @ptrFromInt(argv[arg_to]), &frame);
            vcb.ReleaseVideoFrame(film, &frame);
        }
        if (info.sound_codec != 0) _ = soundLeft(dl, vcb, film, tb, info);
    }
    return result;
}

/// What the sound process is given, and what it says back.
const SoundJob = struct {
    vcb: *VideoCodecBase,
    film: *vc.VideoStream,
    total: u64 = 0,
    failed: i32 = 0,
};

/// The sound process: the film's sound decoded to its end.
fn soundEntry(sys: *ExecBase) callconv(.c) void {
    const job: *SoundJob = @ptrCast(@alignCast(sys.FindTask(null).?.user_data.?));
    var buffer: [piece * 2]i16 = undefined;
    while (true) {
        const got = job.vcb.DecodeVideoSound(job.film, &buffer, piece);
        if (got <= 0) {
            job.failed = got;
            return;
        }
        job.total += @intCast(got);
    }
}

/// The sound decoded to its end, timed: how many frames, below 0 when it
/// stopped.
fn soundLeft(dl: *DosBase, vcb: *VideoCodecBase, film: *vc.VideoStream, tb: *TimerBase, info: vc.VideoStreamInfo) i64 {
    var buffer: [piece * 2]i16 = undefined;
    var total: u64 = 0;
    const started = now(tb);
    while (true) {
        const got = vcb.DecodeVideoSound(film, &buffer, piece);
        if (got < 0) {
            _ = Printf(dl, "sound stopped: %s\n", .{vcb.VideoErrorText(got)});
            return -1;
        }
        if (got == 0) break;
        total += @intCast(got);
    }
    const took = @max(now(tb) - started, 1);
    const times = (total * 1_000_000 / info.sound_rate) * 10 / took;
    _ = Printf(dl, "%lu sound frames (%lu ms) in %lu ms: %lu.%lu times as fast as it plays\n", .{
        total, total * 1000 / info.sound_rate, took / 1000, times / 10, times % 10,
    });
    return @intCast(total);
}

/// What the pictures say their numbers mean - said once, of the first.
/// An ordinary film is BT.709, the ordinary curve, video's range and
/// eight bits; a film of high dynamic range says PQ or HLG, usually in
/// BT.2020's primaries and ten bits, and what it was mastered for.
fn sayColours(dl: *DosBase, p: *const rtg.RtgYuv) void {
    const matrix: [*:0]const u8 = switch (p.matrix) {
        rtg.RTGYUV_BT601 => "BT.601",
        rtg.RTGYUV_BT709 => "BT.709",
        rtg.RTGYUV_BT2020 => "BT.2020",
        else => "an unknown",
    };
    const transfer: [*:0]const u8 = switch (p.transfer) {
        rtg.RTGYUV_SDR => "the ordinary curve",
        rtg.RTGYUV_PQ => "PQ (ST 2084)",
        rtg.RTGYUV_HLG => "HLG",
        else => "an unknown curve",
    };
    const primaries: [*:0]const u8 = switch (p.primaries) {
        rtg.RTGYUV_BT709 => "BT.709",
        rtg.RTGYUV_BT2020 => "BT.2020",
        rtg.RTGYUV_P3 => "P3",
        else => "unknown",
    };
    const layout: [*:0]const u8 = if (p.layout == rtg.RTGYUV_NV12) "NV12" else "I420";
    const range: [*:0]const u8 = if (p.range == rtg.RTGYUV_FULL) "the whole" else "video's";
    _ = Printf(dl, "pictures %s, %s matrix, %s, %s primaries, %s range, %u bits", .{
        layout, matrix, transfer, primaries, range, p.depth,
    });
    if (p.peak != 0) _ = Printf(dl, ", mastered for %u candelas", .{p.peak});
    _ = Printf(dl, "\n", .{});
}

/// A frame written as its planes are, each row as wide as the picture -
/// two bytes a sample where the picture is of ten bits.
fn writeFrame(dl: *DosBase, to: [*:0]const u8, frame: *const vc.VideoFrame) void {
    const file = dl.Open(to, dos.MODE_NEWFILE) orelse {
        _ = Printf(dl, "%s: cannot be written\n", .{to});
        return;
    };
    defer _ = dl.Close(file);
    const p = frame.picture;
    const unit: isize = if (p.depth > 8) 2 else 1;
    const w: isize = @as(isize, @intCast(frame.width)) * unit;
    const half: isize = @as(isize, @intCast((frame.width + 1) / 2)) * unit;
    const h = frame.height;
    for (0..h) |y| _ = dl.Write(file, p.y + y * p.y_pitch, w);
    const rows = (h + 1) / 2;
    if (p.layout == rtg.RTGYUV_NV12) {
        for (0..rows) |y| _ = dl.Write(file, p.cb + y * p.c_pitch, half * 2);
    } else {
        for (0..rows) |y| _ = dl.Write(file, p.cb + y * p.c_pitch, half);
        for (0..rows) |y| _ = dl.Write(file, p.cr.? + y * p.c_pitch, half);
    }
    _ = Printf(dl, "frame %u (at %ld ms) written to %s\n", .{ frame.number, @divTrunc(frame.time, 1000), to });
}
