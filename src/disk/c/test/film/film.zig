// SPDX-License-Identifier: MIT
//! Film: a film decoded through videocodec.library as fast as it goes,
//! timed and checked - nothing is shown or played. Built against the SDK
//! only.
//!
//!   Film FILE/A,FRAME/K/N,TO/K,NOSOUND/S,SEEK/K/N,TOGETHER/S
//!
//! What the film is is printed - its pictures' codec, size and rate, its
//! length, its sound - then every frame is taken and given back: how many
//! came out, how fast, and whether their times rose. Then its sound is
//! decoded whole, timed (NOSOUND leaves it closed). TOGETHER decodes the
//! sound on a process of its own while the pictures are decoded, as a
//! player does.
//!
//! FRAME (and TO) writes that frame - counted from 0 in the order they
//! are shown - into TO as its planes are: NV12 (the brightness rows, then
//! the colour rows, each as wide as the picture) for the chip's, I420
//! for Motion JPEG and the software's H.264 and VP8. `ffmpeg -i FILE -vf "select=eq(n\,FRAME)" -frames:v 1
//! -pix_fmt nv12 -f rawvideo ref.nv12` makes ffmpeg's to compare.
//!
//! SEEK moves the film to that second at the end and says where it
//! landed, the next frame's time, and how much sound is left from there.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const vc = sdk.videocodec;
const ac = sdk.audiocodec;
const rtg = sdk.rtg;
const timer = sdk.devices.timer;
const TagItem = sdk.utility.TagItem;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const VideoCodecBase = sdk.interface.videocodec.VideoCodecBase;
const TimerBase = timer.TimerBase;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "Film";
const VERSION_STRING = "\x00$VER: Film 1.2 (31.10.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "FILE/A,FRAME/K/N,TO/K,NOSOUND/S,SEEK/K/N,TOGETHER/S";
const arg_file = 0;
const arg_frame = 1;
const arg_to = 2;
const arg_nosound = 3;
const arg_seek = 4;
const arg_together = 5;

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
        else => "sound",
    };
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
    var argv: [6]usize = @splat(0);
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
        if (vcb.DecodeVideoFrame(film, &frame) == vc.VCERR_OK) {
            _ = Printf(dl, ", the next frame at %ld ms, number %u", .{ @divTrunc(frame.time, 1000), frame.number });
            vcb.ReleaseVideoFrame(film, &frame);
        }
        _ = Printf(dl, "\n", .{});
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

/// A frame written as its planes are, each row as wide as the picture.
fn writeFrame(dl: *DosBase, to: [*:0]const u8, frame: *const vc.VideoFrame) void {
    const file = dl.Open(to, dos.MODE_NEWFILE) orelse {
        _ = Printf(dl, "%s: cannot be written\n", .{to});
        return;
    };
    defer _ = dl.Close(file);
    const p = frame.picture;
    const w: isize = @intCast(frame.width);
    const half: isize = @intCast((frame.width + 1) / 2);
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
