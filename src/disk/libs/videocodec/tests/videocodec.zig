// SPDX-License-Identifier: MIT
//! videocodec.library's host tests: the library made from its ROM tag on
//! the host's exec, with media.library and audiocodec.library beside it,
//! the codec modules chip.vcodec, mjpeg.vcodec and h264.vcodec made from
//! theirs and given as the table LIBS:codecs/ would make
//! (`_codec.test_modules`), the films on a RAM disk behind WORK:.
//!
//! The host has no chip decoder - chip.vcodec opens none - so the films
//! decoded here are Motion JPEG and H.264 in software, made with ffmpeg from its `testsrc2` pattern: `clip.mov` 96 x 64
//! at 10 frames a second for a second, its colour halved both ways, with
//! a second of AAC at 22050 Hz mono - its index at the end, as ffmpeg
//! writes a MOV; `clip.mp4` 48 x 32 at 5 a second with sound, MPEG-4's
//! `mp4v` entry naming JPEG, its index in front (`-movflags +faststart`);
//! `wide.mov` and `full.mov` 90 x 60 with the colour halved across only
//! and kept whole; `grey.mov` 64 x 48 grey pictures (written by Pillow,
//! put into a MOV by ffmpeg as they are). `tiny.mp4` is five H.264
//! pictures of 64 x 48 (High profile, three B pictures between its I and
//! its P). The `_ref` files are ffmpeg's own decode of the same pictures
//! (`-f rawvideo -pix_fmt yuvj420p`, `yuvj422p`, `yuvj444p`, `gray`,
//! `yuv420p`): `clip_ref.yuv` frames 0 and 9, `tiny_ref.yuv` all five,
//! the others frame 0.
//! `clip.mkv` is clip.mov's tracks remuxed into Matroska by ffmpeg.
//! `subs.mkv` is clip.mkv's with more tracks, muxed by ffmpeg: AC-3 mono
//! at 48 kHz ("deu", "Kommentar") and Opus, then subtitles - SubRip
//! ("eng", default), SubStation Alpha ("deu", default and forced: two
//! lines, a sign, a drawing) and a Blu-ray's pictures (PGS, a .sup made
//! by hand: a 4 x 2 picture at 0.2 s, an 8 x 4 one cropped to 6 x 4 on a
//! canvas twice the film's at 0.5 s, cleared at 0.7 s); `subs_ac3_ref.raw`
//! ffmpeg's decode of its AC-3, the first 4096 frames.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const vc = sdk.videocodec;
const ac = sdk.audiocodec;
const media = sdk.media;
const rtg = sdk.rtg;
const utility = sdk.utility;
const host = @import("host_rom");
const kexec = host.exec;
const videocodec_init = @import("../videocodec_init.zig");
const media_init = @import("../../media/media_init.zig");
const audiocodec_init = @import("../../audiocodec/audiocodec_init.zig");
const chip_init = @import("../../codecs/chip/chip_init.zig");
const mjpeg_init = @import("../../codecs/mjpeg/mjpeg_init.zig");
const h264_init = @import("../../codecs/h264/h264_init.zig");
const module = @import("../../codecs/module.zig");
const _codec = @import("../codec/_codec.zig");
const vcodec = sdk.vcodec;
const loadfile = dos.loadfile;

const testing = std.testing;
const DosBase = sdk.interface.dos.DosBase;
const VideoCodecBase = sdk.interface.videocodec.VideoCodecBase;

test {
    _ = @import("../videocodec_lvo.zig");
    _ = @import("../../codecs/chip/annexb.zig");
    _ = @import("../../codecs/module.zig");
}

const clip_mov = @embedFile("clip.mov");
const clip_mp4 = @embedFile("clip.mp4");
const clip_ref = @embedFile("clip_ref.yuv");
const wide_mov = @embedFile("wide.mov");
const wide_ref = @embedFile("wide_ref.yuv");
const full_mov = @embedFile("full.mov");
const full_ref = @embedFile("full_ref.yuv");
const grey_mov = @embedFile("grey.mov");
const grey_ref = @embedFile("grey_ref.y");
const tiny_mp4 = @embedFile("tiny.mp4");
const tiny_ref = @embedFile("tiny_ref.yuv");
const clip_mkv = @embedFile("clip.mkv");
const subs_mkv = @embedFile("subs.mkv");
const subs_ac3_ref = @embedFile("subs_ac3_ref.raw");
const subtitle = @import("../subtitle/_subtitle.zig");

/// How far a sample of ours may be from ffmpeg's: two decoders' inverse
/// transforms round apart.
const near = 3;

// --- the rig ----------------------------------------------------------------------

/// The RAM disk behind WORK:, answering the test process's packets.
const Disk = struct {
    var port: exec.MsgPort = undefined;
    var disk: host.ram.RamDisk = undefined;
    var dl: *DosBase = undefined;

    fn wait(proc: *dos.Process, sys: *sdk.interface.exec.ExecBase) callconv(.c) *exec.Message {
        const pkt = dos.DosPacket.fromMessage(sys.GetMsg(&port).?);
        const reply = disk.answer(pkt);
        dl.ReplyPkt(pkt, reply.res1, reply.res2);
        return sys.GetMsg(&proc.msg_port).?;
    }
};

/// Memory lent to exec.
var lent: [3 * 1024 * 1024]u8 align(16) = undefined;

/// exec, utility and dos with memory lent; a process with WORK: behind
/// it; videocodec.library, media.library and audiocodec.library made, and
/// videocodec opened.
const Rig = struct {
    db: *host.dos.DosBase,
    region: *exec.MemHeader = undefined,
    proc: dos.Process = .{},
    saved: ?*kexec.Task = null,
    library: *exec.Library = undefined,
    media_library: *exec.Library = undefined,
    audio_library: *exec.Library = undefined,
    chip_library: *exec.Library = undefined,
    mjpeg_library: *exec.Library = undefined,
    h264_library: *exec.Library = undefined,
    vcb: *VideoCodecBase = undefined,

    fn init(rig: *Rig) !void {
        rig.* = .{ .db = try host.dos.testSetUp() };
        rig.region = rig.sysLib().AddMemList(lent.len, exec.MEMF_ANY, 0, &lent, "lent").?;
        rig.proc.task.node.name = "test process";
        host.dos_process.initMsgPort(&rig.proc);
        rig.saved = kexec.SysBase.cpu().this_task;
        kexec.SysBase.cpu().this_task = &rig.proc.task;

        const dl = rig.dosLib();
        Disk.dl = dl;
        Disk.port = .{ .flags = exec.PA_IGNORE };
        Disk.port.msg_list.init(.message);
        Disk.disk = try host.ram.RamDisk.init(rig.db.sys_base, dl, rig.db.utility_base, &Disk.port);
        const node = dl.MakeDosEntry("WORK", dos.DLT_DEVICE).?;
        node.task = &Disk.port;
        try testing.expect(dl.AddDosEntry(node));
        rig.proc.pkt_wait = &Disk.wait;

        rig.library = @ptrCast(@alignCast(kexec.InitResident(kexec.SysBase, &videocodec_init.videocodec_library_tag, null) orelse return error.NoLibrary));
        rig.media_library = @ptrCast(@alignCast(kexec.InitResident(kexec.SysBase, &media_init.media_library_tag, null) orelse return error.NoLibrary));
        rig.audio_library = @ptrCast(@alignCast(kexec.InitResident(kexec.SysBase, &audiocodec_init.audiocodec_library_tag, null) orelse return error.NoLibrary));
        rig.chip_library = @ptrCast(@alignCast(kexec.InitResident(kexec.SysBase, &chip_init.chip_vcodec_tag.resident, null) orelse return error.NoLibrary));
        rig.mjpeg_library = @ptrCast(@alignCast(kexec.InitResident(kexec.SysBase, &mjpeg_init.mjpeg_vcodec_tag.resident, null) orelse return error.NoLibrary));
        rig.h264_library = @ptrCast(@alignCast(kexec.InitResident(kexec.SysBase, &h264_init.h264_vcodec_tag.resident, null) orelse return error.NoLibrary));
        _codec.test_modules = &modules;
        rig.vcb = @ptrCast(rig.sysLib().OpenLibrary(vc.VIDEOCODECNAME, 1) orelse return error.NoBase);
    }

    fn sysLib(_: *Rig) *sdk.interface.exec.ExecBase {
        return kexec.SysBase.iface();
    }

    fn dosLib(rig: *Rig) *DosBase {
        return host.dos.testBase(rig.db);
    }

    /// The libraries closed and expunged, the disk taken down, and
    /// nothing left behind.
    fn deinit(rig: *Rig) !void {
        rig.sysLib().CloseLibrary(rig.vcb.lib());
        _ = rig.sysLib().RemLibrary(rig.library);
        try testing.expect(kexec.FindName(kexec.SysBase, &kexec.SysBase.lib_list, vc.VIDEOCODECNAME) == null);
        _ = rig.sysLib().RemLibrary(rig.audio_library);
        try testing.expect(kexec.FindName(kexec.SysBase, &kexec.SysBase.lib_list, ac.AUDIOCODECNAME) == null);
        _ = rig.sysLib().RemLibrary(rig.media_library);
        try testing.expect(kexec.FindName(kexec.SysBase, &kexec.SysBase.lib_list, media.MEDIANAME) == null);
        _ = rig.sysLib().RemLibrary(rig.chip_library);
        try testing.expect(kexec.FindName(kexec.SysBase, &kexec.SysBase.lib_list, chip_init.LIBRARY_NAME) == null);
        _ = rig.sysLib().RemLibrary(rig.mjpeg_library);
        try testing.expect(kexec.FindName(kexec.SysBase, &kexec.SysBase.lib_list, mjpeg_init.LIBRARY_NAME) == null);
        _ = rig.sysLib().RemLibrary(rig.h264_library);
        try testing.expect(kexec.FindName(kexec.SysBase, &kexec.SysBase.lib_list, h264_init.LIBRARY_NAME) == null);
        _codec.test_modules = null;
        Disk.disk.deinit();
        kexec.SysBase.cpu().this_task = rig.saved.?;
        try host.dos.testTearDown(rig.db);
        try testing.expectEqual(@intFromPtr(rig.region.upper) - @intFromPtr(rig.region.lower), rig.region.free);
        rig.sysLib().Remove(&rig.region.node);
        kexec.deinit();
    }

    /// A file on the disk.
    fn write(rig: *Rig, name: [*:0]const u8, bytes: []const u8) !void {
        const dl = rig.dosLib();
        const fh = dl.Open(name, dos.MODE_NEWFILE) orelse return error.NoFile;
        defer _ = dl.Close(fh);
        try testing.expectEqual(@as(isize, @intCast(bytes.len)), dl.Write(fh, bytes.ptr, @intCast(bytes.len)));
    }

    fn open(rig: *Rig, name: [*:0]const u8, err: *i32) ?*vc.VideoStream {
        return rig.vcb.OpenVideoStream(&[_]utility.TagItem{
            .{ .tag = vc.VCA_Name, .data = @intFromPtr(name) },
            .{},
        }, err);
    }
};

/// A module of the table as LIBS:codecs/ would make it from its tag, by
/// the name the host's exec finds it under.
fn moduleOf(name: []const u8, tag: *const vcodec.ResidentVCodec) _codec.Module {
    var made: _codec.Module = .{ .codecs = tag.codecs, .kind = tag.kind, .priority = tag.priority, .version = tag.resident.version };
    @memcpy(made.name[0..name.len], name);
    return made;
}

/// The modules on the disk: the chip's, Motion JPEG's and H.264's.
const modules = [_]_codec.Module{
    moduleOf(chip_init.LIBRARY_NAME, &chip_init.chip_vcodec_tag),
    moduleOf(mjpeg_init.LIBRARY_NAME, &mjpeg_init.mjpeg_vcodec_tag),
    moduleOf(h264_init.LIBRARY_NAME, &h264_init.h264_vcodec_tag),
};

/// Bytes in memory, handed over by a read function in pieces.
const Memory = struct {
    bytes: []const u8,
    at: usize = 0,

    fn read(data: ?*anyopaque, buffer: [*]u8, length: u32) callconv(.c) i32 {
        const memory: *Memory = @ptrCast(@alignCast(data.?));
        const count = @min(@as(usize, length), 1000, memory.bytes.len - memory.at);
        @memcpy(buffer[0..count], memory.bytes[memory.at..][0..count]);
        memory.at += count;
        return @intCast(count);
    }
};

/// A plane of ours - `pitch` bytes a row - against ffmpeg's, `width` by
/// `height`, rows `step` apart in it: no sample further than `near`.
fn expectPlane(ours: [*]const u8, pitch: u32, reference: []const u8, width: usize, height: usize, step: usize) !void {
    var worst: u32 = 0;
    for (0..height) |y| {
        for (0..width) |x| {
            const a = ours[y * pitch + x];
            const b = reference[y * step * width + x];
            worst = @max(worst, @abs(@as(i32, a) - b));
        }
    }
    if (worst > near) {
        std.debug.print("a sample {d} from ffmpeg's\n", .{worst});
        return error.TooFar;
    }
}

/// A frame of an I420 picture against ffmpeg's yuvj420p frame.
fn expectFrame(frame: *const vc.VideoFrame, reference: []const u8) !void {
    const w: usize = frame.width;
    const h: usize = frame.height;
    const p = frame.picture;
    try testing.expectEqual(rtg.RTGYUV_I420, p.layout);
    try testing.expectEqual(rtg.RTGYUV_BT601 | rtg.RTGYUV_FULL, p.colors);
    try expectPlane(p.y, p.y_pitch, reference[0 .. w * h], w, h, 1);
    const cw = (w + 1) / 2;
    const ch = (h + 1) / 2;
    try expectPlane(p.cb, p.c_pitch, reference[w * h ..][0 .. cw * ch], cw, ch, 1);
    try expectPlane(p.cr.?, p.c_pitch, reference[w * h + cw * ch ..][0 .. cw * ch], cw, ch, 1);
}

// --- the tests --------------------------------------------------------------------

test "IdentifyVideo: H.264, MJPEG in MPEG-4's entry, an index at the end, not a film" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit() catch |e| std.debug.panic("deinit: {}", .{e});
    const vcb = rig.vcb;
    try testing.expectEqual(vc.VCODEC_H264, vcb.IdentifyVideo(tiny_mp4, tiny_mp4.len));
    try testing.expectEqual(vc.VCODEC_MJPEG, vcb.IdentifyVideo(clip_mp4, clip_mp4.len));
    // The index behind the bytes given: nothing yet.
    try testing.expectEqual(vc.VCODEC_UNKNOWN, vcb.IdentifyVideo(clip_mov, 4096));
    try testing.expectEqual(vc.VCODEC_MJPEG, vcb.IdentifyVideo(clip_mov, clip_mov.len));
    try testing.expectEqual(vc.VCODEC_UNKNOWN, vcb.IdentifyVideo(tiny_mp4, 64));
    try testing.expectEqual(vc.VCODEC_UNKNOWN, vcb.IdentifyVideo("RIFF....WAVEfmt ", 16));
}

test "a Motion JPEG film with sound: its info, every frame near ffmpeg's, its sound, the end" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit() catch |e| std.debug.panic("deinit: {}", .{e});
    const vcb = rig.vcb;
    try rig.write("WORK:clip.mov", clip_mov);
    var err: i32 = -99;
    const film = rig.open("WORK:clip.mov", &err) orelse return error.NoStream;
    defer vcb.CloseVideoStream(film);
    try testing.expectEqual(vc.VCERR_OK, err);

    var info: vc.VideoStreamInfo = .{};
    vcb.GetVideoStreamInfo(film, &info);
    try testing.expectEqual(vc.VCODEC_MJPEG, info.codec);
    try testing.expectEqual(@as(u32, 96), info.width);
    try testing.expectEqual(@as(u32, 64), info.height);
    try testing.expectEqual(@as(u32, 10), info.rate_num);
    try testing.expectEqual(@as(u32, 1), info.rate_den);
    try testing.expectEqual(@as(u32, 10), info.frames);
    try testing.expectEqual(@as(u64, 1_000_000), info.duration);
    try testing.expectEqual(@as(u32, 1), info.seekable);
    try testing.expectEqual(ac.ACODEC_AAC, info.sound_codec);
    try testing.expectEqual(@as(u32, 22050), info.sound_rate);
    try testing.expectEqual(@as(u32, 1), info.sound_channels);

    const frame_bytes = 96 * 64 * 3 / 2;
    var frame: vc.VideoFrame = .{};
    for (0..10) |n| {
        try testing.expectEqual(vc.VCERR_OK, vcb.DecodeVideoFrame(film, &frame));
        try testing.expectEqual(@as(u32, @intCast(n)), frame.number);
        try testing.expectEqual(@as(i64, @intCast(n * 100_000)), frame.time);
        try testing.expectEqual(@as(u32, 96), frame.width);
        try testing.expectEqual(@as(u32, 64), frame.height);
        if (n == 0) try expectFrame(&frame, clip_ref[0..frame_bytes]);
        if (n == 9) try expectFrame(&frame, clip_ref[frame_bytes..]);
        vcb.ReleaseVideoFrame(film, &frame);
        try testing.expectEqual(@as(u32, 0), frame.private[1]);
    }
    try testing.expectEqual(vc.VCERR_END, vcb.DecodeVideoFrame(film, &frame));
    try testing.expectEqual(vc.VCERR_END, vcb.DecodeVideoFrame(film, &frame));

    // The sound: the whole second, then the end.
    var samples: [1000]i16 = undefined;
    var total: u32 = 0;
    while (true) {
        const got = vcb.DecodeVideoSound(film, &samples, samples.len);
        try testing.expect(got >= 0);
        if (got == 0) break;
        total += @intCast(got);
    }
    try testing.expectEqual(@as(u32, 22050), total);
}

test "a Motion JPEG film in Matroska: what it is by its tracks, every frame as the MOV's, its sound to the millisecond" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit() catch |e| std.debug.panic("deinit: {}", .{e});
    const vcb = rig.vcb;
    try testing.expectEqual(vc.VCODEC_MJPEG, vcb.IdentifyVideo(clip_mkv, clip_mkv.len));
    // Its tracks cut off: nothing yet.
    try testing.expectEqual(vc.VCODEC_UNKNOWN, vcb.IdentifyVideo(clip_mkv, 300));

    try rig.write("WORK:clip.mkv", clip_mkv);
    var err: i32 = -99;
    const film = rig.open("WORK:clip.mkv", &err) orelse return error.NoStream;
    defer vcb.CloseVideoStream(film);
    var info: vc.VideoStreamInfo = .{};
    vcb.GetVideoStreamInfo(film, &info);
    try testing.expectEqual(vc.VCODEC_MJPEG, info.codec);
    try testing.expectEqual(@as(u32, 96), info.width);
    try testing.expectEqual(@as(u32, 64), info.height);
    try testing.expectEqual(@as(u32, 10), info.rate_num);
    try testing.expectEqual(@as(u32, 1), info.rate_den);
    try testing.expectEqual(@as(u32, 1), info.seekable);
    try testing.expectEqual(ac.ACODEC_AAC, info.sound_codec);
    try testing.expectEqual(@as(u32, 22050), info.sound_rate);
    try testing.expectEqual(@as(u32, 1), info.sound_channels);

    const frame_bytes = 96 * 64 * 3 / 2;
    var frame: vc.VideoFrame = .{};
    for (0..10) |n| {
        try testing.expectEqual(vc.VCERR_OK, vcb.DecodeVideoFrame(film, &frame));
        try testing.expectEqual(@as(i64, @intCast(n * 100_000)), frame.time);
        if (n == 0) try expectFrame(&frame, clip_ref[0..frame_bytes]);
        if (n == 9) try expectFrame(&frame, clip_ref[frame_bytes..]);
        vcb.ReleaseVideoFrame(film, &frame);
    }
    try testing.expectEqual(vc.VCERR_END, vcb.DecodeVideoFrame(film, &frame));

    // The sound's track lasts 1046 ms to the millisecond, its priming of
    // 46.44 ms with it: 22040 frames of the 22050.
    var samples: [1000]i16 = undefined;
    var total: u32 = 0;
    while (true) {
        const got = vcb.DecodeVideoSound(film, &samples, samples.len);
        try testing.expect(got >= 0);
        if (got == 0) break;
        total += @intCast(got);
    }
    try testing.expectEqual(@as(u32, 22040), total);
}

test "frames held and given back; a seek moves the pictures and the sound together" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit() catch |e| std.debug.panic("deinit: {}", .{e});
    const vcb = rig.vcb;
    try rig.write("WORK:clip.mov", clip_mov);
    var err: i32 = 0;
    const film = rig.open("WORK:clip.mov", &err) orelse return error.NoStream;
    defer vcb.CloseVideoStream(film);

    var frames: [vc.VIDEO_HELD_FRAMES]vc.VideoFrame = @splat(.{});
    for (&frames, 0..) |*frame, n| {
        try testing.expectEqual(vc.VCERR_OK, vcb.DecodeVideoFrame(film, frame));
        try testing.expectEqual(@as(i64, @intCast(n * 100_000)), frame.time);
    }
    // Each frame its own planes, as they were.
    try testing.expect(frames[0].picture.y != frames[1].picture.y);
    var extra: vc.VideoFrame = .{};
    try testing.expectEqual(vc.VCERR_BUSY, vcb.DecodeVideoFrame(film, &extra));
    var first = frames[0];
    vcb.ReleaseVideoFrame(film, &frames[0]);
    // Given back twice, or a copy of one given back: passed by.
    vcb.ReleaseVideoFrame(film, &frames[0]);
    vcb.ReleaseVideoFrame(film, &first);
    try testing.expectEqual(vc.VCERR_OK, vcb.DecodeVideoFrame(film, &extra));
    try testing.expectEqual(@as(i64, 300_000), extra.time);
    vcb.ReleaseVideoFrame(film, &extra);
    vcb.ReleaseVideoFrame(film, &frames[1]);

    // Every picture is a key frame: a seek lands on the one at or before.
    try testing.expectEqual(@as(i64, 400_000), vcb.SeekVideo(film, 450_000));
    try testing.expectEqual(vc.VCERR_OK, vcb.DecodeVideoFrame(film, &extra));
    try testing.expectEqual(@as(i64, 400_000), extra.time);
    try testing.expectEqual(@as(u32, 0), extra.number);
    vcb.ReleaseVideoFrame(film, &extra);
    // The sound from 0.4 s on.
    var samples: [1000]i16 = undefined;
    var total: u32 = 0;
    while (true) {
        const got = vcb.DecodeVideoSound(film, &samples, samples.len);
        try testing.expect(got >= 0);
        if (got == 0) break;
        total += @intCast(got);
    }
    try testing.expectEqual(@as(u32, 22050 - 8820), total);
    // Before the start: the first.
    try testing.expectEqual(@as(i64, 0), vcb.SeekVideo(film, -5_000_000));
    try testing.expectEqual(vc.VCERR_OK, vcb.DecodeVideoFrame(film, &extra));
    try testing.expectEqual(@as(i64, 0), extra.time);
    vcb.ReleaseVideoFrame(film, &extra);
    // Closed with a frame still lent: it goes with the stream.
    try testing.expectEqual(vc.VCERR_OK, vcb.DecodeVideoFrame(film, &extra));
}

/// Every plane of a Motion JPEG frame, and each of its rows, starts on 16
/// bytes, as a display's video layer reads them.
fn expectLayerReads(picture: *const rtg.RtgYuv) !void {
    try testing.expectEqual(@as(usize, 0), @intFromPtr(picture.y) % 16);
    try testing.expectEqual(@as(usize, 0), @intFromPtr(picture.cb) % 16);
    try testing.expectEqual(@as(usize, 0), @intFromPtr(picture.cr.?) % 16);
    try testing.expectEqual(@as(u32, 0), picture.y_pitch % 16);
    try testing.expectEqual(@as(u32, 0), picture.c_pitch % 16);
}

test "colour halved across, kept whole, and none: the frame in I420 all the same" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit() catch |e| std.debug.panic("deinit: {}", .{e});
    const vcb = rig.vcb;
    var err: i32 = 0;
    var frame: vc.VideoFrame = .{};
    const w = 90;
    const h = 60;

    // 4:2:2: every other colour row of ffmpeg's.
    try rig.write("WORK:wide.mov", wide_mov);
    const wide = rig.open("WORK:wide.mov", &err) orelse return error.NoStream;
    try testing.expectEqual(vc.VCERR_OK, vcb.DecodeVideoFrame(wide, &frame));
    try testing.expectEqual(@as(u32, w), frame.width);
    try expectPlane(frame.picture.y, frame.picture.y_pitch, wide_ref[0 .. w * h], w, h, 1);
    try expectPlane(frame.picture.cb, frame.picture.c_pitch, wide_ref[w * h ..][0 .. 45 * 60], 45, 30, 2);
    try expectPlane(frame.picture.cr.?, frame.picture.c_pitch, wide_ref[w * h + 45 * 60 ..][0 .. 45 * 60], 45, 30, 2);
    try expectLayerReads(&frame.picture);
    vcb.ReleaseVideoFrame(wide, &frame);
    vcb.CloseVideoStream(wide);

    // 4:4:4: ffmpeg's colour averaged two by two.
    try rig.write("WORK:full.mov", full_mov);
    const full = rig.open("WORK:full.mov", &err) orelse return error.NoStream;
    try testing.expectEqual(vc.VCERR_OK, vcb.DecodeVideoFrame(full, &frame));
    try expectPlane(frame.picture.y, frame.picture.y_pitch, full_ref[0 .. w * h], w, h, 1);
    // Its rows on 16 bytes, where a video layer reads them.
    try testing.expectEqual(@as(u32, 48), frame.picture.c_pitch);
    try expectLayerReads(&frame.picture);
    var halved: [2][45 * 30]u8 = undefined;
    for (0..2) |plane| {
        const from = full_ref[w * h * (plane + 1) ..][0 .. w * h];
        for (0..30) |y| {
            for (0..45) |x| {
                const sum = @as(u32, from[2 * y * w + 2 * x]) + from[2 * y * w + 2 * x + 1] +
                    from[(2 * y + 1) * w + 2 * x] + from[(2 * y + 1) * w + 2 * x + 1];
                halved[plane][y * 45 + x] = @intCast((sum + 2) / 4);
            }
        }
    }
    try expectPlane(frame.picture.cb, frame.picture.c_pitch, &halved[0], 45, 30, 1);
    try expectPlane(frame.picture.cr.?, frame.picture.c_pitch, &halved[1], 45, 30, 1);
    vcb.ReleaseVideoFrame(full, &frame);
    vcb.CloseVideoStream(full);

    // Grey: its brightness, and the colour planes the middle.
    try rig.write("WORK:grey.mov", grey_mov);
    const grey = rig.open("WORK:grey.mov", &err) orelse return error.NoStream;
    defer vcb.CloseVideoStream(grey);
    for (0..2) |n| {
        try testing.expectEqual(vc.VCERR_OK, vcb.DecodeVideoFrame(grey, &frame));
        try testing.expectEqual(@as(u32, 64), frame.width);
        if (n == 0) try expectPlane(frame.picture.y, frame.picture.y_pitch, grey_ref, 64, 48, 1);
        try expectLayerReads(&frame.picture);
        for (0..24) |y| {
            for (0..32) |x| {
                try testing.expectEqual(@as(u8, 128), frame.picture.cb[y * frame.picture.c_pitch + x]);
                try testing.expectEqual(@as(u8, 128), frame.picture.cr.?[y * frame.picture.c_pitch + x]);
            }
        }
        vcb.ReleaseVideoFrame(grey, &frame);
    }
}

test "H.264 in software: every frame as ffmpeg's, in the order shown, at its time; a seek back to the start" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit() catch |e| std.debug.panic("deinit: {}", .{e});
    const vcb = rig.vcb;
    try rig.write("WORK:tiny.mp4", tiny_mp4);
    var err: i32 = -99;
    const film = rig.open("WORK:tiny.mp4", &err) orelse return error.NoStream;
    defer vcb.CloseVideoStream(film);
    try testing.expectEqual(vc.VCERR_OK, err);

    var info: vc.VideoStreamInfo = .{};
    vcb.GetVideoStreamInfo(film, &info);
    try testing.expectEqual(vc.VCODEC_H264, info.codec);
    try testing.expectEqual(@as(u32, 64), info.width);
    try testing.expectEqual(@as(u32, 48), info.height);
    try testing.expectEqual(@as(u32, 5), info.frames);

    const frame_bytes = 64 * 48 * 3 / 2;
    var frame: vc.VideoFrame = .{};
    for (0..2) |round| {
        for (0..5) |n| {
            try testing.expectEqual(vc.VCERR_OK, vcb.DecodeVideoFrame(film, &frame));
            try testing.expectEqual(@as(i64, @intCast(n * 100_000)), frame.time);
            try testing.expectEqual(@as(u32, 64), frame.width);
            try testing.expectEqual(@as(u32, 48), frame.height);
            const p = frame.picture;
            try testing.expectEqual(rtg.RTGYUV_I420, p.layout);
            // No VUI and fewer than 720 rows: BT.601, video's range.
            try testing.expectEqual(rtg.RTGYUV_BT601, p.colors);
            const reference = tiny_ref[n * frame_bytes ..][0..frame_bytes];
            for (0..48) |y| try testing.expectEqualSlices(u8, reference[y * 64 ..][0..64], p.y[y * p.y_pitch ..][0..64]);
            for (0..24) |y| {
                try testing.expectEqualSlices(u8, reference[64 * 48 + y * 32 ..][0..32], p.cb[y * p.c_pitch ..][0..32]);
                try testing.expectEqualSlices(u8, reference[64 * 48 * 5 / 4 + y * 32 ..][0..32], p.cr.?[y * p.c_pitch ..][0..32]);
            }
            vcb.ReleaseVideoFrame(film, &frame);
        }
        try testing.expectEqual(vc.VCERR_END, vcb.DecodeVideoFrame(film, &frame));
        if (round == 0) try testing.expectEqual(@as(i64, 0), vcb.SeekVideo(film, 0));
    }
}

test "what does not open, and a film through a read function: pictures alone, no seek" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit() catch |e| std.debug.panic("deinit: {}", .{e});
    const vcb = rig.vcb;
    var err: i32 = 0;

    // H.264 with no module for it.
    try rig.write("WORK:tiny.mp4", tiny_mp4);
    const chip_mjpeg = modules[0..2];
    _codec.test_modules = chip_mjpeg;
    try testing.expect(rig.open("WORK:tiny.mp4", &err) == null);
    try testing.expectEqual(vc.VCERR_NOCODEC, err);
    _codec.test_modules = &modules;
    // Not a film; no file; no source.
    try rig.write("WORK:text", "Not a film at all, only words.");
    try testing.expect(rig.open("WORK:text", &err) == null);
    try testing.expectEqual(vc.VCERR_UNKNOWN, err);
    try testing.expect(rig.open("WORK:nothing", &err) == null);
    try testing.expectEqual(vc.VCERR_OPEN, err);
    try testing.expect(vcb.OpenVideoStream(null, &err) == null);
    try testing.expectEqual(vc.VCERR_OPEN, err);

    // Its sound left out by VCA_Sound.
    try rig.write("WORK:clip.mp4", clip_mp4);
    const quiet = vcb.OpenVideoStream(&[_]utility.TagItem{
        .{ .tag = vc.VCA_Name, .data = @intFromPtr("WORK:clip.mp4") },
        .{ .tag = vc.VCA_Sound, .data = 0 },
        .{},
    }, &err) orelse return error.NoStream;
    var info: vc.VideoStreamInfo = .{};
    vcb.GetVideoStreamInfo(quiet, &info);
    try testing.expectEqual(vc.VCODEC_MJPEG, info.codec);
    try testing.expectEqual(@as(u32, 0), info.sound_codec);
    var samples: [100]i16 = undefined;
    try testing.expectEqual(vc.VCERR_NOSOUND, vcb.DecodeVideoSound(quiet, &samples, samples.len));
    vcb.CloseVideoStream(quiet);

    // Through a read function: every picture, no sound, no seek.
    var memory: Memory = .{ .bytes = clip_mp4 };
    const film = vcb.OpenVideoStream(&[_]utility.TagItem{
        .{ .tag = vc.VCA_ReadFunc, .data = @intFromPtr(&Memory.read) },
        .{ .tag = vc.VCA_ReadData, .data = @intFromPtr(&memory) },
        .{},
    }, &err) orelse return error.NoStream;
    defer vcb.CloseVideoStream(film);
    vcb.GetVideoStreamInfo(film, &info);
    try testing.expectEqual(@as(u32, 48), info.width);
    try testing.expectEqual(@as(u32, 0), info.seekable);
    try testing.expectEqual(@as(u32, 0), info.sound_codec);
    try testing.expectEqual(vc.VCERR_NOSEEK, vcb.SeekVideo(film, 0));
    var frame: vc.VideoFrame = .{};
    var count: u32 = 0;
    while (vcb.DecodeVideoFrame(film, &frame) == vc.VCERR_OK) : (count += 1) {
        try testing.expectEqual(@as(i64, count * 200_000), frame.time);
        vcb.ReleaseVideoFrame(film, &frame);
    }
    try testing.expectEqual(@as(u32, 5), count);
}

/// What shows at `time`: text, its flags and when it shows from and to.
fn expectText(vcb: *VideoCodecBase, film: *vc.VideoStream, time: i64, want: []const u8, flags: u32, start: i64, end: i64) !void {
    var shown: vc.VideoSubtitle = .{};
    try testing.expectEqual(vc.VCERR_OK, vcb.GetVideoSubtitle(film, time, &shown));
    try testing.expectEqualStrings(want, std.mem.span(shown.text.?));
    try testing.expectEqual(flags, shown.flags);
    try testing.expectEqual(start, shown.start);
    try testing.expectEqual(end, shown.end);
}

fn expectNothing(vcb: *VideoCodecBase, film: *vc.VideoStream, time: i64) !void {
    var shown: vc.VideoSubtitle = .{ .flags = 99 };
    try testing.expectEqual(vc.VCERR_END, vcb.GetVideoSubtitle(film, time, &shown));
    try testing.expectEqual(@as(u32, 0), shown.flags);
}

test "a film's tracks: listed, what decodes them; subtitles of each kind at their times; another sound, another track" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit() catch |e| std.debug.panic("deinit: {}", .{e});
    // The host's exec runs no processes: the subtitles are read in line.
    subtitle.read_inline = true;
    defer subtitle.read_inline = false;
    const vcb = rig.vcb;
    try rig.write("WORK:subs.mkv", subs_mkv);
    var err: i32 = -99;
    const film = rig.open("WORK:subs.mkv", &err) orelse return error.NoStream;
    defer vcb.CloseVideoStream(film);

    // The pictures and the marked sound chosen; of the subtitles the ASS,
    // marked forced, before the SubRip marked only default. Opus is not
    // decoded here.
    const decoded: i32 = vc.VTRK_DECODED;
    const both: i32 = vc.VTRK_DECODED | vc.VTRK_CHOSEN;
    const expected = [_]struct { kind: u32, flags: i32 }{
        .{ .kind = media.MTRACK_VIDEO, .flags = both },
        .{ .kind = media.MTRACK_AUDIO, .flags = both },
        .{ .kind = media.MTRACK_AUDIO, .flags = decoded },
        .{ .kind = media.MTRACK_AUDIO, .flags = 0 },
        .{ .kind = media.MTRACK_TEXT, .flags = decoded },
        .{ .kind = media.MTRACK_TEXT, .flags = both },
        .{ .kind = media.MTRACK_TEXT, .flags = decoded },
    };
    var track: media.MediaTrack = .{};
    for (expected, 0..) |want, number| {
        try testing.expectEqual(want.flags, vcb.GetVideoTrack(film, @intCast(number), &track));
        try testing.expectEqual(want.kind, track.kind);
    }
    try testing.expectEqual(vc.VCERR_END, vcb.GetVideoTrack(film, 7, &track));
    _ = vcb.GetVideoTrack(film, 2, &track);
    try testing.expectEqualStrings("deu", std.mem.sliceTo(&track.language, 0));
    try testing.expectEqualStrings("Kommentar", std.mem.sliceTo(&track.name, 0));

    // SubStation Alpha: a line with italics in it; two at once, joined -
    // from the later start to the earlier end; the sign and the drawing
    // left out; a style's italics.
    try expectText(vcb, film, 100_000, "Erste schräg Zeile", vc.VSUB_TEXT, 0, 600_000);
    try expectText(vcb, film, 300_000, "Erste schräg Zeile\nGedacht", vc.VSUB_TEXT, 200_000, 600_000);
    try expectText(vcb, film, 450_000, "Erste schräg Zeile\nGedacht", vc.VSUB_TEXT, 200_000, 600_000);
    try expectText(vcb, film, 650_000, "Gedacht", vc.VSUB_TEXT | vc.VSUB_ITALIC, 200_000, 800_000);
    try expectNothing(vcb, film, 850_000);

    // SubRip, chosen from the start.
    try testing.expectEqual(vc.VCERR_OK, vcb.SelectVideoTrack(film, 4, 0));
    try testing.expectEqual(both, vcb.GetVideoTrack(film, 4, &track));
    try testing.expectEqual(decoded, vcb.GetVideoTrack(film, 5, &track));
    try expectText(vcb, film, 200_000, "Hello", vc.VSUB_TEXT | vc.VSUB_ITALIC, 100_000, 400_000);
    try expectNothing(vcb, film, 450_000);
    try expectText(vcb, film, 600_000, "Two\nlines", vc.VSUB_TEXT, 500_000, 900_000);

    // Pictures: each shows until the next set; the second's canvas is
    // twice the film's, and it is fitted to it.
    try testing.expectEqual(vc.VCERR_OK, vcb.SelectVideoTrack(film, 6, 0));
    try expectNothing(vcb, film, 100_000);
    const white: u32 = 0xFFFFFFFF;
    const half: u32 = 0x80000000;
    var shown: vc.VideoSubtitle = .{};
    try testing.expectEqual(vc.VCERR_OK, vcb.GetVideoSubtitle(film, 300_000, &shown));
    try testing.expectEqual(vc.VSUB_BITMAP, shown.flags);
    try testing.expectEqual(@as(i64, 200_000), shown.start);
    try testing.expectEqual(@as(i64, 500_000), shown.end);
    try testing.expectEqual([4]u32{ 10, 40, 4, 2 }, [4]u32{ shown.x, shown.y, shown.width, shown.height });
    try testing.expectEqualSlices(u32, &.{ white, white, half, half, 0, 0, 0, 0 }, shown.pixels.?[0..8]);
    try testing.expectEqual(vc.VCERR_OK, vcb.GetVideoSubtitle(film, 600_000, &shown));
    try testing.expectEqual(@as(i64, 500_000), shown.start);
    try testing.expectEqual(@as(i64, 700_000), shown.end);
    try testing.expectEqual([4]u32{ 20, 40, 3, 2 }, [4]u32{ shown.x, shown.y, shown.width, shown.height });
    try testing.expectEqualSlices(u32, &.{ white, white, half, 0, 0, 0 }, shown.pixels.?[0..6]);
    try expectNothing(vcb, film, 750_000);

    // None; and what cannot be chosen, what was chosen kept.
    try testing.expectEqual(vc.VCERR_OK, vcb.SelectVideoTrack(film, vc.VIDEO_NO_TRACK, 0));
    try expectNothing(vcb, film, 300_000);
    try testing.expectEqual(decoded, vcb.GetVideoTrack(film, 6, &track));
    try testing.expectEqual(vc.VCERR_UNSUPPORTED, vcb.SelectVideoTrack(film, 0, 0));
    try testing.expectEqual(vc.VCERR_NOCODEC, vcb.SelectVideoTrack(film, 3, 0));
    try testing.expectEqual(vc.VCERR_END, vcb.SelectVideoTrack(film, 7, 0));
    try testing.expectEqual(both, vcb.GetVideoTrack(film, 1, &track));

    // After a seek the lines still showing where it lands are read too.
    try testing.expectEqual(vc.VCERR_OK, vcb.SelectVideoTrack(film, 5, 0));
    try testing.expectEqual(@as(i64, 500_000), vcb.SeekVideo(film, 500_000));
    try expectText(vcb, film, 550_000, "Erste schräg Zeile\nGedacht", vc.VSUB_TEXT, 200_000, 600_000);

    // The AC-3 commentary from the start: its rate and its one channel,
    // ffmpeg's samples; the AAC no longer chosen.
    try testing.expectEqual(vc.VCERR_OK, vcb.SelectVideoTrack(film, 2, 0));
    var info: vc.VideoStreamInfo = .{};
    vcb.GetVideoStreamInfo(film, &info);
    try testing.expectEqual(ac.ACODEC_AC3, info.sound_codec);
    try testing.expectEqual(@as(u32, 48000), info.sound_rate);
    try testing.expectEqual(@as(u32, 1), info.sound_channels);
    try testing.expectEqual(both, vcb.GetVideoTrack(film, 2, &track));
    try testing.expectEqual(decoded, vcb.GetVideoTrack(film, 1, &track));
    var samples: [4096]i16 = undefined;
    try testing.expectEqual(@as(i32, 4096), vcb.DecodeVideoSound(film, &samples, samples.len));
    var worst: u32 = 0;
    for (samples, 0..) |sample, n| {
        const reference = std.mem.readInt(i16, subs_ac3_ref[n * 2 ..][0..2], .little);
        worst = @max(worst, @abs(@as(i32, sample) - reference));
    }
    try testing.expect(worst <= 1);
    // From half way: the rest of its second.
    try testing.expectEqual(vc.VCERR_OK, vcb.SelectVideoTrack(film, 1, 0));
    try testing.expectEqual(vc.VCERR_OK, vcb.SelectVideoTrack(film, 2, 500_000));
    var total: u32 = 0;
    while (true) {
        const got = vcb.DecodeVideoSound(film, &samples, samples.len);
        try testing.expect(got >= 0);
        if (got == 0) break;
        total += @intCast(got);
    }
    try testing.expectEqual(@as(u32, 32 * 1536 - 24000), total);
}

/// A module of the tests' own, which claims Motion JPEG and decodes
/// nothing: how often each call was made, and what OpenVCodec answers.
const Fake = struct {
    var opened: u32 = 0;
    var closed: u32 = 0;
    var sent: u32 = 0;
    var received: u32 = 0;
    /// A decoder (VCERR_OK), or this error.
    var open_answer: i32 = vc.VCERR_OK;
    var decoder: u8 = 0;

    fn reset(answer: i32) void {
        opened = 0;
        closed = 0;
        sent = 0;
        received = 0;
        open_answer = answer;
    }

    pub fn GetVCodecInfo(_: *module.Base, _: *vcodec.VCodecDecoder, _: *vcodec.VCodecInfo) i32 {
        return vc.VCERR_NEED_DATA;
    }
    pub fn OpenVCodec(_: *module.Base, _: *const vcodec.VCodecParams, err: ?*i32) ?*vcodec.VCodecDecoder {
        opened += 1;
        if (err) |out| out.* = open_answer;
        return if (open_answer == vc.VCERR_OK) @ptrCast(&decoder) else null;
    }
    pub fn CloseVCodec(_: *module.Base, _: ?*vcodec.VCodecDecoder) void {
        closed += 1;
    }
    pub fn SendVCodecPacket(_: *module.Base, _: *vcodec.VCodecDecoder, _: *const vcodec.VCodecPacket) i32 {
        sent += 1;
        return vc.VCERR_OK;
    }
    /// A packet asked for, and once it has one the stream refused - as the
    /// chip does a stream it reads it cannot decode.
    pub fn ReceiveVCodecFrame(_: *module.Base, _: *vcodec.VCodecDecoder, _: *vc.VideoFrame) i32 {
        received += 1;
        return if (sent == 0) vc.VCERR_NEED_DATA else vc.VCERR_UNSUPPORTED;
    }
    pub fn ReleaseVCodecFrame(_: *module.Base, _: *vcodec.VCodecDecoder, _: *vc.VideoFrame) void {}
    pub fn FlushVCodec(_: *module.Base, _: *vcodec.VCodecDecoder) void {}
};

const FakeModule = module.Module(0, Fake);

const fake_tag: vcodec.ResidentVCodec = .{
    .resident = .{
        .match_tag = @ptrCast(&fake_tag),
        .flags = exec.RTF_AUTOINIT,
        .version = 1,
        .type = .library,
        .name = "fake.vcodec",
        .id_string = "fake.vcodec 1.0 (30.10.2026)\r\n",
        .init = &FakeModule.init_table,
    },
    .codecs = vcodec.codecBit(vc.VCODEC_MJPEG),
    .kind = vcodec.VCMOD_CHIP,
};

/// The fake module in the table as `kind` with `priority`.
fn fakeAs(kind: u32, priority: i32) _codec.Module {
    var made = moduleOf("fake.vcodec", &fake_tag);
    made.kind = kind;
    made.priority = priority;
    return made;
}

/// clip.mov's ten frames from the start, frame 0 near ffmpeg's.
fn expectClip(vcb: *VideoCodecBase, film: *vc.VideoStream) !void {
    var frame: vc.VideoFrame = .{};
    for (0..10) |n| {
        try testing.expectEqual(vc.VCERR_OK, vcb.DecodeVideoFrame(film, &frame));
        try testing.expectEqual(@as(i64, @intCast(n * 100_000)), frame.time);
        if (n == 0) try expectFrame(&frame, clip_ref[0 .. 96 * 64 * 3 / 2]);
        vcb.ReleaseVideoFrame(film, &frame);
    }
    try testing.expectEqual(vc.VCERR_END, vcb.DecodeVideoFrame(film, &frame));
}

test "the codec modules: a chip's first, software by priority; one that opens nothing, or refuses the stream, gives way to the next" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit() catch |e| std.debug.panic("deinit: {}", .{e});
    const fake_library: *exec.Library = @ptrCast(@alignCast(kexec.InitResident(kexec.SysBase, &fake_tag.resident, null) orelse return error.NoLibrary));
    defer _ = rig.sysLib().RemLibrary(fake_library);
    const vcb = rig.vcb;
    try rig.write("WORK:clip.mov", clip_mov);
    var err: i32 = 0;

    // A chip's, listed after software: tried first; it takes a packet,
    // then refuses the stream, and Motion JPEG's decodes it from the
    // start.
    const chip_first = [_]_codec.Module{ modules[1], fakeAs(vcodec.VCMOD_CHIP, 0) };
    _codec.test_modules = &chip_first;
    Fake.reset(vc.VCERR_OK);
    {
        const film = rig.open("WORK:clip.mov", &err) orelse return error.NoStream;
        defer vcb.CloseVideoStream(film);
        try expectClip(vcb, film);
        try testing.expectEqual(@as(u32, 1), Fake.opened);
        try testing.expectEqual(@as(u32, 1), Fake.sent);
        try testing.expectEqual(@as(u32, 2), Fake.received);
        try testing.expectEqual(@as(u32, 1), Fake.closed);
    }

    // One that opens no decoder here - the board has not its chip.
    Fake.reset(vc.VCERR_NOCODEC);
    {
        const film = rig.open("WORK:clip.mov", &err) orelse return error.NoStream;
        defer vcb.CloseVideoStream(film);
        try expectClip(vcb, film);
        try testing.expectEqual(@as(u32, 1), Fake.opened);
        try testing.expectEqual(@as(u32, 0), Fake.closed);
    }

    // Software among software: the higher priority first, and a lower
    // one never asked.
    const higher = [_]_codec.Module{ modules[1], fakeAs(vcodec.VCMOD_SOFTWARE, 5) };
    _codec.test_modules = &higher;
    Fake.reset(vc.VCERR_OK);
    {
        const film = rig.open("WORK:clip.mov", &err) orelse return error.NoStream;
        defer vcb.CloseVideoStream(film);
        try expectClip(vcb, film);
        try testing.expectEqual(@as(u32, 1), Fake.opened);
    }
    const lower = [_]_codec.Module{ fakeAs(vcodec.VCMOD_SOFTWARE, -5), modules[1] };
    _codec.test_modules = &lower;
    Fake.reset(vc.VCERR_OK);
    {
        const film = rig.open("WORK:clip.mov", &err) orelse return error.NoStream;
        defer vcb.CloseVideoStream(film);
        try expectClip(vcb, film);
        try testing.expectEqual(@as(u32, 0), Fake.opened);
    }

    // Nothing after it: the refusal is the program's.
    const alone = [_]_codec.Module{fakeAs(vcodec.VCMOD_CHIP, 0)};
    _codec.test_modules = &alone;
    Fake.reset(vc.VCERR_OK);
    {
        const film = rig.open("WORK:clip.mov", &err) orelse return error.NoStream;
        defer vcb.CloseVideoStream(film);
        var frame: vc.VideoFrame = .{};
        try testing.expectEqual(vc.VCERR_UNSUPPORTED, vcb.DecodeVideoFrame(film, &frame));
    }
    // A film read through a function cannot be read again from its key
    // packet: the refusal stays, though Motion JPEG's would take it.
    _codec.test_modules = &chip_first;
    Fake.reset(vc.VCERR_OK);
    {
        var memory: Memory = .{ .bytes = clip_mp4 };
        const film = vcb.OpenVideoStream(&[_]utility.TagItem{
            .{ .tag = vc.VCA_ReadFunc, .data = @intFromPtr(&Memory.read) },
            .{ .tag = vc.VCA_ReadData, .data = @intFromPtr(&memory) },
            .{},
        }, &err) orelse return error.NoStream;
        defer vcb.CloseVideoStream(film);
        var frame: vc.VideoFrame = .{};
        try testing.expectEqual(vc.VCERR_UNSUPPORTED, vcb.DecodeVideoFrame(film, &frame));
    }

    // No module opens a decoder: the first refusal that is not "not
    // here", else "not here"; and none at all for the codec.
    Fake.reset(vc.VCERR_BUSY);
    _codec.test_modules = &alone;
    try testing.expect(rig.open("WORK:clip.mov", &err) == null);
    try testing.expectEqual(vc.VCERR_BUSY, err);
    const nothing = [_]_codec.Module{modules[0]};
    _codec.test_modules = &nothing;
    try testing.expect(rig.open("WORK:clip.mov", &err) == null);
    try testing.expectEqual(vc.VCERR_NOCODEC, err);
    _codec.test_modules = &modules;
}

fn put32(into: []u8, at: usize, value: u32) void {
    std.mem.writeInt(u32, into[at..][0..4], value, .little);
}

test "a codec module's tag read from its load file: what it decodes, its kind, priority and version; nothing else is one" {
    // The header, then a data segment of 160 bytes with a library's tag
    // at 32 (as a 32-bit file has it: its name at offset 16, its ID string
    // at 20, the module's words from 28 on), the name at 96, the ID
    // string at 112.
    var file: [20 + 16 + 160]u8 = @splat(0);
    @memcpy(file[0..4], &loadfile.MAGIC);
    std.mem.writeInt(u16, file[4..6], loadfile.VERSION, .little);
    std.mem.writeInt(u16, file[6..8], 1, .little);
    std.mem.writeInt(u16, file[10..12], loadfile.native_machine, .little);
    file[16] = 4;
    file[20] = @intFromEnum(loadfile.SegmentKind.data);
    put32(&file, 24, 160);
    put32(&file, 28, 160);
    const seg = 36;
    const tag = seg + 32;
    std.mem.writeInt(u16, file[tag..][0..2], 0x4AFC, .little);
    put32(&file, tag + 4, 32);
    file[tag + 12] = exec.RTF_AUTOINIT;
    file[tag + 13] = 1;
    file[tag + 14] = @intFromEnum(exec.NodeType.library);
    put32(&file, tag + 16, 96);
    put32(&file, tag + 20, 112);
    put32(&file, tag + 28, vcodec.VCODEC_MAGIC);
    put32(&file, tag + 32, vcodec.codecBit(vc.VCODEC_H264));
    put32(&file, tag + 36, vcodec.VCMOD_SOFTWARE);
    put32(&file, tag + 40, @bitCast(@as(i32, -3)));
    @memcpy(file[seg + 96 ..][0..12], "h264.vcodec\x00");
    @memcpy(file[seg + 112 ..][0..29], "h264.vcodec 1.2 (30.10.2026)\x00");

    var bytes = loadfile.Bytes{ .data = &file };
    var found: _codec.Module = .{};
    try testing.expect(_codec.readTag(bytes.source(), &found, "h264.vcodec"));
    try testing.expectEqual(vcodec.codecBit(vc.VCODEC_H264), found.codecs);
    try testing.expectEqual(vcodec.VCMOD_SOFTWARE, found.kind);
    try testing.expectEqual(@as(i32, -3), found.priority);
    try testing.expectEqual(@as(u8, 1), found.version);
    try testing.expectEqual(@as(u16, 2), found.revision);
    // Named otherwise than its file: ramlib would not load it by that.
    try testing.expect(!_codec.readTag(bytes.source(), &found, "hevc.vcodec"));
    // A library's tag without the module's words; a device's.
    put32(&file, tag + 28, 0);
    try testing.expect(!_codec.readTag(bytes.source(), &found, "h264.vcodec"));
    put32(&file, tag + 28, vcodec.VCODEC_MAGIC);
    file[tag + 14] = @intFromEnum(exec.NodeType.device);
    try testing.expect(!_codec.readTag(bytes.source(), &found, "h264.vcodec"));
}

test "every error code says something of its own" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit() catch |e| std.debug.panic("deinit: {}", .{e});
    var code: i32 = vc.VCERR_FULL;
    while (code <= vc.VCERR_OK) : (code += 1) {
        try testing.expect(!std.mem.eql(u8, "unknown error", std.mem.span(rig.vcb.VideoErrorText(code))));
    }
    try testing.expectEqualStrings("unknown error", std.mem.span(rig.vcb.VideoErrorText(-100)));
}
