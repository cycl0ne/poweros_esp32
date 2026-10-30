// SPDX-License-Identifier: MIT
//! media.library's host tests: the library made from its ROM tag on the
//! ROM's exec, utility and dos; files on a RAM disk, and bytes handed over
//! by a read function.
//!
//! `film.mp4` is 0.8 s made with ffmpeg, its index first (faststart): a
//! picture of 64x48 at 25 frames a second in H.264 (libx264, Main, two
//! B-frames, a key frame every ten), in a timescale of 12800 with an edit
//! of 1024 ticks for the frames shown after they are decoded; sound of
//! 440 Hz in mono AAC at 44.1 kHz, 36 packets, the first of them the
//! encoder's priming of 1024 frames; the chapter track ffmpeg makes, and
//! Nero's list - "Leaving" at 0 and "Arriving" at 0.4 s; iTunes's items.
//! The sizes, the times and the flags below are what ffprobe says of it.
//! `tail.m4a` is 0.2 s of mono AAC at 22.05 kHz, its index after its
//! packets. `film.mkv` is film.mp4's two tracks remuxed by ffmpeg into
//! Matroska - the same packets, times in milliseconds, the encoder's
//! priming as the sound's CodecDelay, CRCs in the elements, its cues and
//! its chapters; and `Maker` builds a Matroska file by hand for what
//! ffmpeg does not write.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const media = sdk.media;
const utility = sdk.utility;
const host = @import("host_rom");
const kexec = host.exec;
const media_init = @import("../media_init.zig");

const testing = std.testing;
const DosBase = sdk.interface.dos.DosBase;
const MediaBase = sdk.interface.media.MediaBase;

test {
    _ = @import("../media_lvo.zig");
    _ = @import("../mp4/cursor.zig");
    _ = @import("../mkv/ebml.zig");
}

const film_mp4 = @embedFile("film.mp4");
const tail_m4a = @embedFile("tail.m4a");
const film_mkv = @embedFile("film.mkv");
/// When film.mkv's blocks of sound are due, in milliseconds - ffmpeg's
/// rounding of the MP4's times, the priming's 23 added.
const sound_ms = [_]i64{ 0, 23, 46, 69, 93, 116, 139, 162, 186, 209, 232, 255, 278, 302, 325, 348, 371, 395, 418, 441, 464, 487, 511, 534, 557, 580, 603, 627, 650, 673, 696, 720, 743, 766, 789, 812 };
/// film.mkv's sound's CodecDelay: 1024 frames at 44.1 kHz.
const priming_ns = 23_219_955;

const picture_sizes = [_]u32{ 1278, 72, 12, 12, 100, 14, 12, 95, 14, 12, 652, 70, 12, 12, 81, 14, 13, 44, 14, 12 };
/// When each picture is shown, in its ticks of 1/12800 s.
const picture_shown = [_]i64{ 0, 1536, 512, 1024, 3072, 2048, 2560, 4608, 3584, 4096, 5120, 6656, 5632, 6144, 8192, 7168, 7680, 9728, 8704, 9216 };
const sound_sizes = [_]u32{ 209, 203, 120, 132, 150, 128, 133, 121, 165, 154, 129, 163, 169, 103, 165, 102, 128, 142, 159, 151, 147, 144, 99, 166, 111, 148, 141, 163, 148, 175, 116, 124, 175, 143, 113, 135 };

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
var lent: [2 * 1024 * 1024]u8 align(16) = undefined;

/// exec, utility and dos with memory lent; a process with WORK: behind
/// it; media.library made and opened.
const Rig = struct {
    db: *host.dos.DosBase,
    region: *exec.MemHeader = undefined,
    proc: dos.Process = .{},
    saved: ?*kexec.Task = null,
    library: *exec.Library = undefined,
    mb: *MediaBase = undefined,

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

        const lib = kexec.InitResident(kexec.SysBase, &media_init.media_library_tag, null) orelse return error.NoLibrary;
        rig.library = @ptrCast(@alignCast(lib));
        rig.mb = @ptrCast(rig.sysLib().OpenLibrary(media.MEDIANAME, 1) orelse return error.NoBase);
    }

    fn sysLib(_: *Rig) *sdk.interface.exec.ExecBase {
        return kexec.SysBase.iface();
    }

    fn dosLib(rig: *Rig) *DosBase {
        return host.dos.testBase(rig.db);
    }

    /// The library closed and expunged, the disk taken down, and nothing
    /// left behind.
    fn deinit(rig: *Rig) !void {
        rig.sysLib().CloseLibrary(rig.mb.lib());
        _ = rig.sysLib().RemLibrary(rig.library);
        try testing.expect(kexec.FindName(kexec.SysBase, &kexec.SysBase.lib_list, media.MEDIANAME) == null);
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
};

/// Bytes in memory, handed over by a read function in pieces of `piece`
/// at most.
const Memory = struct {
    bytes: []const u8,
    at: usize = 0,
    piece: usize = 700,

    fn read(data: ?*anyopaque, buffer: [*]u8, length: u32) callconv(.c) i32 {
        const memory: *Memory = @ptrCast(@alignCast(data.?));
        const count = @min(@as(usize, length), memory.piece, memory.bytes.len - memory.at);
        @memcpy(buffer[0..count], memory.bytes[memory.at..][0..count]);
        memory.at += count;
        return @intCast(count);
    }
};

fn openMemory(mb: *MediaBase, memory: *Memory, err: *i32) ?*media.MediaFile {
    return mb.OpenMedia(&[_]utility.TagItem{
        .{ .tag = media.MDA_ReadFunc, .data = @intFromPtr(&Memory.read) },
        .{ .tag = media.MDA_ReadData, .data = @intFromPtr(memory) },
        .{},
    }, err);
}

fn openFile(mb: *MediaBase, name: [*:0]const u8, err: *i32) ?*media.MediaFile {
    return mb.OpenMedia(&[_]utility.TagItem{
        .{ .tag = media.MDA_Name, .data = @intFromPtr(name) },
        .{ .tag = media.MDA_KeepPicture, .data = 1 },
        .{},
    }, err);
}

fn textOf(text: []const u8) []const u8 {
    return std.mem.sliceTo(text, 0);
}

fn micros(ticks: i64, timescale: i64) i64 {
    return @divFloor(ticks * 1_000_000, timescale);
}

// --- the tests --------------------------------------------------------------------

test "what a file is, by its first bytes" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit() catch {};
    const mb = rig.mb;
    try testing.expectEqual(media.MEDIA_MP4, mb.IdentifyMedia(film_mp4, media.MEDIA_IDENTIFY_BYTES));
    try testing.expectEqual(media.MEDIA_MP4, mb.IdentifyMedia(tail_m4a, 16));
    try testing.expectEqual(media.MEDIA_UNKNOWN, mb.IdentifyMedia("RIFF\x10\x00\x00\x00WAVEfmt ", 16));
    try testing.expectEqual(media.MEDIA_UNKNOWN, mb.IdentifyMedia(film_mp4, 4));

    var err: i32 = 0;
    var memory: Memory = .{ .bytes = "ID3\x03\x00\x00\x00\x00\x00\x00 not a film at all" };
    try testing.expect(openMemory(mb, &memory, &err) == null);
    try testing.expectEqual(media.MERR_UNKNOWN, err);
    try testing.expectEqualStrings("the track has no more packets", std.mem.span(mb.MediaErrorText(media.MERR_END)));
}

test "a film on a file: its tracks, every packet of each as ffprobe has them, its tags and chapters" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit() catch {};
    const mb = rig.mb;
    try rig.write("WORK:film.mp4", film_mp4);
    var err: i32 = -1;
    const film = openFile(mb, "WORK:film.mp4", &err) orelse return error.NoFile;
    defer mb.CloseMedia(film);
    try testing.expectEqual(media.MERR_OK, err);

    var info: media.MediaInfo = .{};
    mb.GetMediaInfo(film, &info);
    try testing.expectEqual(media.MEDIA_MP4, info.kind);
    try testing.expectEqual(@as(u32, 3), info.tracks);
    try testing.expectEqual(@as(u64, 800_000), info.duration);
    try testing.expectEqual(@as(u32, 1), info.seekable);
    try testing.expectEqual(@as(u32, 0), info.video);
    try testing.expectEqual(@as(u32, 1), info.audio);
    try testing.expectEqualStrings("Trip", textOf(&info.title));
    try testing.expectEqualStrings("The Testers", textOf(&info.artist));
    try testing.expectEqualStrings("Small Films", textOf(&info.album));

    var picture: media.MediaTrack = .{};
    try testing.expectEqual(media.MERR_OK, mb.GetMediaTrack(film, 0, &picture));
    try testing.expectEqual(media.MTRACK_VIDEO, picture.kind);
    try testing.expectEqual(media.MCODEC_H264, picture.codec);
    try testing.expectEqual(@as(u32, 1), picture.id);
    try testing.expectEqual(@as(u32, 64), picture.width);
    try testing.expectEqual(@as(u32, 48), picture.height);
    try testing.expectEqual(@as(u32, 25_000), picture.frame_rate);
    try testing.expectEqual(@as(u32, 20), picture.packets);
    try testing.expectEqual(@as(u32, 12800), picture.timescale);
    try testing.expectEqual(@as(u32, 1024), picture.delay);
    try testing.expectEqual(@as(u64, 10240), picture.length);
    try testing.expectEqual(@as(u64, 800_000), picture.duration);
    try testing.expectEqual(@as(u32, 1278), picture.max_packet);
    try testing.expectEqualStrings("und", textOf(&picture.language));
    try testing.expectEqualStrings("VideoHandler", textOf(&picture.name));
    // avcC: version 1, Main profile (77), level 1.0.
    try testing.expect(picture.config_size > 8);
    try testing.expectEqual(@as(u8, 1), picture.config.?[0]);
    try testing.expectEqual(@as(u8, 77), picture.config.?[1]);

    var sound: media.MediaTrack = .{};
    try testing.expectEqual(media.MERR_OK, mb.GetMediaTrack(film, 1, &sound));
    try testing.expectEqual(media.MTRACK_AUDIO, sound.kind);
    try testing.expectEqual(media.MCODEC_AAC, sound.codec);
    try testing.expectEqual(@as(u32, 44100), sound.rate);
    try testing.expectEqual(@as(u32, 1), sound.channels);
    try testing.expectEqual(@as(u32, 0), sound.bits);
    try testing.expectEqual(@as(u32, 36), sound.packets);
    try testing.expectEqual(@as(u32, 44100), sound.timescale);
    try testing.expectEqual(@as(u32, 1024), sound.delay);
    try testing.expectEqual(@as(u64, 35280), sound.length);
    try testing.expectEqual(@as(u32, 50280), sound.bitrate);
    // The AudioSpecificConfig: AAC-LC, 44.1 kHz, one channel, and the
    // extension saying there is no SBR.
    try testing.expectEqual(@as(u32, 5), sound.config_size);
    try testing.expectEqualSlices(u8, &.{ 0x12, 0x08, 0x56, 0xE5, 0x00 }, sound.config.?[0..5]);

    var text: media.MediaTrack = .{};
    try testing.expectEqual(media.MERR_OK, mb.GetMediaTrack(film, 2, &text));
    try testing.expectEqual(media.MTRACK_TEXT, text.kind);
    try testing.expectEqual(media.MCODEC_TEXT, text.codec);
    try testing.expectEqual(@as(u32, 2), text.packets);
    try testing.expectEqualStrings("eng", textOf(&text.language));
    try testing.expectEqual(media.MERR_NOTRACK, mb.GetMediaTrack(film, 3, &text));

    // Every picture, in the order they are decoded: the shown times run
    // ahead of the decode times by the edit, the B-frames shown before
    // the frame decoded ahead of them.
    var packet: media.MediaPacket = .{};
    for (picture_sizes, picture_shown, 0..) |size, shown, n| {
        try testing.expectEqual(media.MERR_OK, mb.ReadMediaPacket(film, 0, &packet));
        try testing.expectEqual(size, packet.size);
        try testing.expectEqual(@as(u32, @intCast(n)), packet.index);
        try testing.expectEqual(n % 10 == 0, packet.flags & media.MPKT_KEY != 0);
        try testing.expectEqual(micros(shown, 12800), packet.pts);
        try testing.expectEqual(micros(@as(i64, @intCast(n)) * 512 - 1024, 12800), packet.dts);
        try testing.expectEqual(@as(u64, n * 512), packet.ticks);
        try testing.expectEqual(@as(u32, 40_000), packet.duration);
    }
    try testing.expectEqual(media.MERR_END, mb.ReadMediaPacket(film, 0, &packet));

    // The first picture is an IDR slice behind its 4-byte length.
    try testing.expectEqual(media.MERR_OK, mb.SeekMedia(film, 0, 0));
    try testing.expectEqual(media.MERR_OK, mb.ReadMediaPacket(film, 0, &packet));
    try testing.expectEqual(@as(u32, 0), packet.index);
    const first_unit = packet.data.?[4] & 0x1F;
    try testing.expect(first_unit == 5 or first_unit == 6);

    // The sound: the priming first, before the start; every packet a key.
    for (sound_sizes, 0..) |size, n| {
        try testing.expectEqual(media.MERR_OK, mb.ReadMediaPacket(film, 1, &packet));
        try testing.expectEqual(size, packet.size);
        try testing.expect(packet.flags & media.MPKT_KEY != 0);
        try testing.expectEqual(micros(@as(i64, @intCast(n)) * 1024 - 1024, 44100), packet.pts);
        try testing.expectEqual(packet.pts, packet.dts);
    }
    try testing.expectEqual(media.MERR_END, mb.ReadMediaPacket(film, 1, &packet));

    // Moved: half a second in is the key frame of picture 10, shown at
    // 0.4 s; the sound's start is its second packet.
    try testing.expectEqual(media.MERR_OK, mb.SeekMedia(film, 0, 500_000));
    try testing.expectEqual(media.MERR_OK, mb.ReadMediaPacket(film, 0, &packet));
    try testing.expectEqual(@as(u32, 10), packet.index);
    try testing.expectEqual(@as(i64, 400_000), packet.pts);
    try testing.expectEqual(@as(u32, 652), packet.size);
    try testing.expectEqual(media.MERR_OK, mb.SeekMedia(film, 1, 0));
    try testing.expectEqual(media.MERR_OK, mb.ReadMediaPacket(film, 1, &packet));
    try testing.expectEqual(@as(u32, 1), packet.index);
    try testing.expectEqual(@as(i64, 0), packet.pts);
    try testing.expectEqual(media.MERR_OK, mb.SeekMedia(film, 1, 10_000_000));
    try testing.expectEqual(media.MERR_OK, mb.ReadMediaPacket(film, 1, &packet));
    try testing.expectEqual(@as(u32, 35), packet.index);
    try testing.expectEqual(media.MERR_OK, mb.SeekMedia(film, 1, -5_000_000));
    try testing.expectEqual(media.MERR_OK, mb.ReadMediaPacket(film, 1, &packet));
    try testing.expectEqual(@as(u32, 0), packet.index);
    try testing.expectEqual(media.MERR_NOTRACK, mb.SeekMedia(film, 7, 0));

    var year: u32 = 0;
    var track: u32 = 0;
    var tracks: u32 = 0;
    var genre: [*:0]const u8 = "";
    var chapters: u32 = 0;
    var list: ?[*]const media.MediaChapter = null;
    var cover: ?*const media.MediaPicture = null;
    var subtitles: u32 = 0;
    try testing.expectEqual(@as(u32, 8), mb.GetMediaAttrs(film, &[_]utility.TagItem{
        .{ .tag = media.MDA_Year, .data = @intFromPtr(&year) },
        .{ .tag = media.MDA_Track, .data = @intFromPtr(&track) },
        .{ .tag = media.MDA_Tracks, .data = @intFromPtr(&tracks) },
        .{ .tag = media.MDA_Genre, .data = @intFromPtr(&genre) },
        .{ .tag = media.MDA_Chapters, .data = @intFromPtr(&chapters) },
        .{ .tag = media.MDA_ChapterList, .data = @intFromPtr(&list) },
        .{ .tag = media.MDA_Picture, .data = @intFromPtr(&cover) },
        .{ .tag = media.MDA_Subtitles, .data = @intFromPtr(&subtitles) },
        .{ .tag = utility.TAG_USER, .data = @intFromPtr(&year) },
        .{},
    }));
    // An MP4 marks no subtitles to be shown.
    try testing.expectEqual(~@as(u32, 0), subtitles);
    try testing.expectEqual(@as(u32, 2026), year);
    try testing.expectEqual(@as(u32, 3), track);
    try testing.expectEqual(@as(u32, 12), tracks);
    try testing.expectEqualStrings("Road", std.mem.span(genre));
    try testing.expect(cover == null);
    try testing.expectEqual(@as(u32, 2), chapters);
    try testing.expectEqualStrings("Leaving", textOf(&list.?[0].title));
    try testing.expectEqual(@as(u32, 0), list.?[0].start);
    try testing.expectEqual(@as(u32, 400), list.?[0].end);
    try testing.expectEqualStrings("Arriving", textOf(&list.?[1].title));
    try testing.expectEqual(@as(u32, 400), list.?[1].start);
    try testing.expectEqual(@as(u32, 800), list.?[1].end);
}

test "a film through a read function: one track read front to back, nothing behind it" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit() catch {};
    const mb = rig.mb;
    var err: i32 = 0;
    var memory: Memory = .{ .bytes = film_mp4, .piece = 333 };
    const film = openMemory(mb, &memory, &err) orelse return error.NoFile;
    defer mb.CloseMedia(film);
    var info: media.MediaInfo = .{};
    mb.GetMediaInfo(film, &info);
    try testing.expectEqual(@as(u32, 0), info.seekable);
    try testing.expectEqual(@as(u32, 3), info.tracks);

    // The sound, whole; the pictures lie behind it then.
    var packet: media.MediaPacket = .{};
    for (sound_sizes) |size| {
        try testing.expectEqual(media.MERR_OK, mb.ReadMediaPacket(film, 1, &packet));
        try testing.expectEqual(size, packet.size);
    }
    try testing.expectEqual(media.MERR_END, mb.ReadMediaPacket(film, 1, &packet));
    try testing.expectEqual(media.MERR_NOSEEK, mb.ReadMediaPacket(film, 0, &packet));
    try testing.expectEqual(media.MERR_NOSEEK, mb.SeekMedia(film, 1, 0));
}

test "an index after the packets: read from a file, refused through a read function" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit() catch {};
    const mb = rig.mb;
    var err: i32 = 0;
    var memory: Memory = .{ .bytes = tail_m4a };
    try testing.expect(openMemory(mb, &memory, &err) == null);
    try testing.expectEqual(media.MERR_UNSUPPORTED, err);

    try rig.write("WORK:tail.m4a", tail_m4a);
    const song = openFile(mb, "WORK:tail.m4a", &err) orelse return error.NoFile;
    defer mb.CloseMedia(song);
    var info: media.MediaInfo = .{};
    mb.GetMediaInfo(song, &info);
    try testing.expectEqual(@as(u32, 1), info.tracks);
    try testing.expectEqual(@as(u32, 0), info.audio);
    try testing.expectEqual(~@as(u32, 0), info.video);
    try testing.expectEqualStrings("Tail", textOf(&info.title));
    var track: media.MediaTrack = .{};
    try testing.expectEqual(media.MERR_OK, mb.GetMediaTrack(song, 0, &track));
    try testing.expectEqual(@as(u32, 22050), track.rate);
    try testing.expectEqual(@as(u32, 6), track.packets);
    try testing.expectEqual(@as(u64, 4410), track.length);
    var packet: media.MediaPacket = .{};
    var count: u32 = 0;
    while (mb.ReadMediaPacket(song, 0, &packet) == media.MERR_OK) count += 1;
    try testing.expectEqual(@as(u32, 6), count);

    try testing.expect(openFile(mb, "WORK:nothing.mp4", &err) == null);
    try testing.expectEqual(media.MERR_OPEN, err);
    try testing.expect(mb.OpenMedia(null, &err) == null);
    try testing.expectEqual(media.MERR_OPEN, err);
}

// --- Matroska ---------------------------------------------------------------------

/// The pts of a block of film.mkv's sound due at `ms`: its time less the
/// priming, in microseconds rounded down.
fn soundPts(ms: i64) i64 {
    return @divFloor(ms * 1_000_000 - priming_ns, 1000);
}

test "Matroska: what a file is, by its first bytes" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit() catch {};
    const mb = rig.mb;
    try testing.expectEqual(media.MEDIA_MKV, mb.IdentifyMedia(film_mkv, media.MEDIA_IDENTIFY_BYTES));
    try testing.expectEqual(media.MEDIA_MKV, mb.IdentifyMedia(film_mkv, 4));
    // EBML's header of another DocType.
    try testing.expectEqual(media.MEDIA_UNKNOWN, mb.IdentifyMedia("\x1A\x45\xDF\xA3\x88\x42\x82\x85other", 13));
    var err: i32 = 0;
    var memory: Memory = .{ .bytes = "\x1A\x45\xDF\xA3\x88\x42\x82\x85other and more" };
    try testing.expect(openMemory(mb, &memory, &err) == null);
    try testing.expectEqual(media.MERR_UNKNOWN, err);
}

test "Matroska: a film on a file - its tracks, every packet as ffmpeg wrote it, its tags, chapters and seeks" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit() catch {};
    const mb = rig.mb;
    try rig.write("WORK:film.mkv", film_mkv);
    var err: i32 = -1;
    const film = openFile(mb, "WORK:film.mkv", &err) orelse return error.NoFile;
    defer mb.CloseMedia(film);
    try testing.expectEqual(media.MERR_OK, err);

    var info: media.MediaInfo = .{};
    mb.GetMediaInfo(film, &info);
    try testing.expectEqual(media.MEDIA_MKV, info.kind);
    try testing.expectEqual(@as(u32, 2), info.tracks);
    try testing.expectEqual(@as(u64, 823_000), info.duration);
    try testing.expectEqual(@as(u32, 1), info.seekable);
    try testing.expectEqual(@as(u32, 0), info.video);
    try testing.expectEqual(@as(u32, 1), info.audio);
    try testing.expectEqualStrings("Trip", textOf(&info.title));
    try testing.expectEqualStrings("The Testers", textOf(&info.artist));
    try testing.expectEqualStrings("Small Films", textOf(&info.album));

    var picture: media.MediaTrack = .{};
    try testing.expectEqual(media.MERR_OK, mb.GetMediaTrack(film, 0, &picture));
    try testing.expectEqual(media.MTRACK_VIDEO, picture.kind);
    try testing.expectEqual(media.MCODEC_H264, picture.codec);
    try testing.expectEqual(@as(u32, 1), picture.id);
    try testing.expectEqual(@as(u32, 64), picture.width);
    try testing.expectEqual(@as(u32, 48), picture.height);
    try testing.expectEqual(@as(u32, 25_000), picture.frame_rate);
    try testing.expectEqual(@as(u32, 0), picture.packets);
    try testing.expectEqual(@as(u32, 1000), picture.timescale);
    try testing.expectEqual(@as(u32, 0), picture.delay);
    try testing.expectEqual(@as(u64, 800), picture.length);
    try testing.expectEqual(@as(u64, 800_000), picture.duration);
    try testing.expectEqualStrings("und", textOf(&picture.language));
    try testing.expectEqual(@as(u8, 1), picture.config.?[0]);
    try testing.expectEqual(@as(u8, 77), picture.config.?[1]);

    var sound: media.MediaTrack = .{};
    try testing.expectEqual(media.MERR_OK, mb.GetMediaTrack(film, 1, &sound));
    try testing.expectEqual(media.MTRACK_AUDIO, sound.kind);
    try testing.expectEqual(media.MCODEC_AAC, sound.codec);
    try testing.expectEqual(@as(u32, 44100), sound.rate);
    try testing.expectEqual(@as(u32, 1), sound.channels);
    try testing.expectEqual(@as(u32, 0), sound.bits);
    // Counted in its rate: the priming is 1024 frames exactly.
    try testing.expectEqual(@as(u32, 44100), sound.timescale);
    try testing.expectEqual(@as(u32, 1024), sound.delay);
    // The segment lasts 823 ms to the millisecond, the priming with it:
    // 799.78 ms are presented.
    try testing.expectEqual(@as(u64, 35270), sound.length);
    try testing.expectEqual(@as(u64, 799_780), sound.duration);
    try testing.expectEqual(@as(u32, 5), sound.config_size);
    try testing.expectEqualSlices(u8, &.{ 0x12, 0x08, 0x56, 0xE5, 0x00 }, sound.config.?[0..5]);
    try testing.expectEqual(media.MERR_NOTRACK, mb.GetMediaTrack(film, 2, &sound));

    // Every picture as it was in the MP4: Matroska keeps when each is
    // shown, so its dts is its pts.
    var packet: media.MediaPacket = .{};
    for (picture_sizes, picture_shown, 0..) |size, shown, n| {
        try testing.expectEqual(media.MERR_OK, mb.ReadMediaPacket(film, 0, &packet));
        try testing.expectEqual(size, packet.size);
        try testing.expectEqual(@as(u32, @intCast(n)), packet.index);
        try testing.expectEqual(n % 10 == 0, packet.flags & media.MPKT_KEY != 0);
        try testing.expectEqual(micros(shown, 12800), packet.pts);
        try testing.expectEqual(packet.pts, packet.dts);
        try testing.expectEqual(@as(u64, @intCast(@divExact(shown * 1000, 12800))), packet.ticks);
        try testing.expectEqual(@as(u32, 40_000), packet.duration);
    }
    try testing.expectEqual(media.MERR_END, mb.ReadMediaPacket(film, 0, &packet));

    // The sound, its priming before the start; the last block a group
    // that says it lasts 11 ms.
    for (sound_sizes, sound_ms, 0..) |size, ms, n| {
        try testing.expectEqual(media.MERR_OK, mb.ReadMediaPacket(film, 1, &packet));
        try testing.expectEqual(size, packet.size);
        try testing.expect(packet.flags & media.MPKT_KEY != 0);
        try testing.expectEqual(soundPts(ms), packet.pts);
        try testing.expectEqual(@as(u64, @intCast(@divFloor(ms * 44100, 1000))), packet.ticks);
        try testing.expectEqual(@as(u32, if (n == 35) 11_000 else 23_219), packet.duration);
    }
    try testing.expectEqual(media.MERR_END, mb.ReadMediaPacket(film, 1, &packet));

    // Moved: half a second in is the key frame shown at 0.4 s, which the
    // cues name; the sound to that time lands on its block at or before
    // it, its priming counted.
    try testing.expectEqual(media.MERR_OK, mb.SeekMedia(film, 0, 500_000));
    try testing.expectEqual(media.MERR_OK, mb.ReadMediaPacket(film, 0, &packet));
    try testing.expectEqual(@as(u32, 10), packet.index);
    try testing.expectEqual(@as(i64, 400_000), packet.pts);
    try testing.expectEqual(@as(u32, 652), packet.size);
    try testing.expectEqual(media.MERR_OK, mb.ReadMediaPacket(film, 0, &packet));
    try testing.expectEqual(@as(u32, 70), packet.size);
    try testing.expectEqual(media.MERR_OK, mb.SeekMedia(film, 1, 400_000));
    try testing.expectEqual(media.MERR_OK, mb.ReadMediaPacket(film, 1, &packet));
    try testing.expectEqual(soundPts(418), packet.pts);
    try testing.expectEqual(media.MERR_OK, mb.SeekMedia(film, 1, 0));
    try testing.expectEqual(media.MERR_OK, mb.ReadMediaPacket(film, 1, &packet));
    try testing.expectEqual(soundPts(23), packet.pts);
    try testing.expectEqual(media.MERR_OK, mb.SeekMedia(film, 1, 10_000_000));
    try testing.expectEqual(media.MERR_OK, mb.ReadMediaPacket(film, 1, &packet));
    try testing.expectEqual(soundPts(812), packet.pts);
    try testing.expectEqual(media.MERR_END, mb.ReadMediaPacket(film, 1, &packet));
    try testing.expectEqual(media.MERR_OK, mb.SeekMedia(film, 0, 0));
    try testing.expectEqual(media.MERR_OK, mb.ReadMediaPacket(film, 0, &packet));
    try testing.expectEqual(@as(u32, 1278), packet.size);

    var year: u32 = 0;
    var track: u32 = 0;
    var tracks: u32 = 0;
    var genre: [*:0]const u8 = "";
    var chapters: u32 = 0;
    var list: ?[*]const media.MediaChapter = null;
    _ = mb.GetMediaAttrs(film, &[_]utility.TagItem{
        .{ .tag = media.MDA_Year, .data = @intFromPtr(&year) },
        .{ .tag = media.MDA_Track, .data = @intFromPtr(&track) },
        .{ .tag = media.MDA_Tracks, .data = @intFromPtr(&tracks) },
        .{ .tag = media.MDA_Genre, .data = @intFromPtr(&genre) },
        .{ .tag = media.MDA_Chapters, .data = @intFromPtr(&chapters) },
        .{ .tag = media.MDA_ChapterList, .data = @intFromPtr(&list) },
        .{},
    });
    try testing.expectEqual(@as(u32, 2026), year);
    try testing.expectEqual(@as(u32, 3), track);
    try testing.expectEqual(@as(u32, 12), tracks);
    try testing.expectEqualStrings("Road", std.mem.span(genre));
    try testing.expectEqual(@as(u32, 2), chapters);
    try testing.expectEqualStrings("Leaving", textOf(&list.?[0].title));
    try testing.expectEqual(@as(u32, 0), list.?[0].start);
    try testing.expectEqual(@as(u32, 400), list.?[0].end);
    try testing.expectEqualStrings("Arriving", textOf(&list.?[1].title));
    try testing.expectEqual(@as(u32, 400), list.?[1].start);
    try testing.expectEqual(@as(u32, 800), list.?[1].end);
}

test "Matroska: a film through a read function - what lies before the clusters, one track front to back" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit() catch {};
    const mb = rig.mb;
    var err: i32 = 0;
    var memory: Memory = .{ .bytes = film_mkv, .piece = 333 };
    const film = openMemory(mb, &memory, &err) orelse return error.NoFile;
    defer mb.CloseMedia(film);
    var info: media.MediaInfo = .{};
    mb.GetMediaInfo(film, &info);
    try testing.expectEqual(@as(u32, 0), info.seekable);
    try testing.expectEqual(@as(u32, 2), info.tracks);
    try testing.expectEqualStrings("Trip", textOf(&info.title));
    var chapters: u32 = 0;
    _ = mb.GetMediaAttrs(film, &[_]utility.TagItem{ .{ .tag = media.MDA_Chapters, .data = @intFromPtr(&chapters) }, .{} });
    try testing.expectEqual(@as(u32, 2), chapters);

    var packet: media.MediaPacket = .{};
    for (sound_sizes) |size| {
        try testing.expectEqual(media.MERR_OK, mb.ReadMediaPacket(film, 1, &packet));
        try testing.expectEqual(size, packet.size);
    }
    try testing.expectEqual(media.MERR_END, mb.ReadMediaPacket(film, 1, &packet));
    try testing.expectEqual(media.MERR_NOSEEK, mb.ReadMediaPacket(film, 0, &packet));
    try testing.expectEqual(media.MERR_NOSEEK, mb.SeekMedia(film, 1, 0));
}

/// A Matroska file built by hand, element by element: a master's size
/// is eight bytes, filled in when it ends; another element's one or two.
const Maker = struct {
    bytes: [4096]u8 = undefined,
    len: usize = 0,

    fn put(m: *Maker, data: []const u8) void {
        @memcpy(m.bytes[m.len..][0..data.len], data);
        m.len += data.len;
    }

    fn id(m: *Maker, value: u32) void {
        var n: u5 = if (value > 0xFF_FFFF) 4 else if (value > 0xFFFF) 3 else if (value > 0xFF) 2 else 1;
        while (n > 0) {
            n -= 1;
            m.put(&.{@truncate(value >> (@as(u5, 8) * n))});
        }
    }

    fn element(m: *Maker, value: u32, data: []const u8) void {
        m.id(value);
        if (data.len < 127) {
            m.put(&.{@as(u8, @intCast(data.len)) | 0x80});
        } else {
            m.put(&.{ @as(u8, @intCast(data.len >> 8)) | 0x40, @truncate(data.len) });
        }
        m.put(data);
    }

    fn uint(m: *Maker, value: u32, number: u64) void {
        var data: [8]u8 = undefined;
        std.mem.writeInt(u64, &data, number, .big);
        var first: usize = 0;
        while (first < 7 and data[first] == 0) first += 1;
        m.element(value, data[first..]);
    }

    fn float(m: *Maker, value: u32, number: f64) void {
        var data: [8]u8 = undefined;
        std.mem.writeInt(u64, &data, @bitCast(number), .big);
        m.element(value, &data);
    }

    /// A master begun: where its size is, for `end`.
    fn begin(m: *Maker, value: u32) usize {
        m.id(value);
        const at = m.len;
        m.put(&.{ 0x01, 0, 0, 0, 0, 0, 0, 0 });
        return at;
    }

    fn end(m: *Maker, at: usize) void {
        const size: u64 = m.len - at - 8;
        var data: [8]u8 = undefined;
        std.mem.writeInt(u64, &data, size, .big);
        @memcpy(m.bytes[at + 1 ..][0..7], data[1..]);
    }

    /// A master of a size not known.
    fn open(m: *Maker, value: u32) void {
        m.id(value);
        m.put(&.{ 0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF });
    }

    /// A SimpleBlock's or a Block's: its track, its time from the
    /// cluster's, its flags and its bytes.
    fn block(m: *Maker, value: u32, number: u8, relative: i16, flags: u8, data: []const u8) void {
        var head: [4]u8 = .{ 0x80 | number, 0, 0, flags };
        std.mem.writeInt(i16, head[1..3], relative, .big);
        var whole: [512]u8 = undefined;
        @memcpy(whole[0..4], &head);
        @memcpy(whole[4..][0..data.len], data);
        m.element(value, whole[0 .. 4 + data.len]);
    }

    fn track(m: *Maker, number: u8, kind: u8, codec: []const u8) usize {
        const entry = m.begin(0xAE);
        m.uint(0xD7, number);
        m.uint(0x73C5, 100 + @as(u64, number));
        m.uint(0x83, kind);
        m.element(0x86, codec);
        return entry;
    }

    fn sound(m: *Maker, rate: f64, channels: u8) void {
        const audio = m.begin(0xE1);
        m.float(0xB5, rate);
        m.uint(0x9F, channels);
        m.end(audio);
    }

    fn tag(m: *Maker, level: u64, uid: u64, name: []const u8, text: []const u8) void {
        const tag_at = m.begin(0x7373);
        const targets = m.begin(0x63C0);
        if (level != 0) m.uint(0x68CA, level);
        if (uid != 0) m.uint(0x63C5, uid);
        m.end(targets);
        const simple = m.begin(0x67C8);
        m.element(0x45A3, name);
        m.element(0x4487, text);
        m.end(simple);
        m.end(tag_at);
    }

    fn chapter(m: *Maker, start_ns: u64, end_ns: u64, hidden: bool, name: []const u8) void {
        const atom = m.begin(0xB6);
        m.uint(0x91, start_ns);
        if (end_ns != 0) m.uint(0x92, end_ns);
        if (hidden) m.uint(0x98, 1);
        const display = m.begin(0x80);
        m.element(0x85, name);
        m.end(display);
        m.end(atom);
    }

    /// The file: six tracks - MP3 its frames' first two bytes left out,
    /// SubRip, AAC named by its profile, Opus with its OpusHead and a
    /// delay, VP9, ASS compressed by zlib - in a segment and a first
    /// cluster of sizes not known; blocks laced Xiph's way, EBML's and
    /// all of a size; groups with a duration and a reference; the cues
    /// and the chapters behind the clusters, found by the seek head.
    fn make(m: *Maker) void {
        const header = m.begin(0x1A45DFA3);
        m.element(0x4282, "matroska");
        m.end(header);
        m.open(0x18538067);
        const segment = m.len;

        const seek_head = m.begin(0x114D9B74);
        var seeks: [2]usize = undefined;
        for ([_]u32{ 0x1C53BB6B, 0x1043A770 }, 0..) |named, n| {
            const seek = m.begin(0x4DBB);
            var named_bytes: [4]u8 = undefined;
            std.mem.writeInt(u32, &named_bytes, named, .big);
            m.element(0x53AB, &named_bytes);
            m.id(0x53AC);
            m.put(&.{0x88});
            seeks[n] = m.len;
            m.put(&.{ 0, 0, 0, 0, 0, 0, 0, 0 });
            m.end(seek);
        }
        m.end(seek_head);

        const info = m.begin(0x1549A966);
        m.uint(0x2AD7B1, 1_000_000);
        m.float(0x4489, 2100);
        m.element(0x7BA9, "Hand made");
        m.end(info);

        const tracks = m.begin(0x1654AE6B);
        var entry = m.track(1, 2, "A_MPEG/L3");
        m.uint(0x88, 0);
        m.uint(0x23E383, 24_000_000);
        m.element(0x22B59C, "ger");
        m.sound(48000, 2);
        const encodings = m.begin(0x6D80);
        const encoding = m.begin(0x6240);
        const compression = m.begin(0x5034);
        m.uint(0x4254, 3);
        m.element(0x4255, "\xFF\xFB");
        m.end(compression);
        m.end(encoding);
        m.end(encodings);
        m.end(entry);
        entry = m.track(2, 0x11, "S_TEXT/UTF8");
        m.uint(0x88, 0);
        m.element(0x536E, "Deutsch");
        m.element(0x22B59C, "ger");
        m.end(entry);
        entry = m.track(3, 2, "A_AAC/MPEG4/LC");
        m.element(0x22B59C, "jpn");
        m.sound(44100, 2);
        m.end(entry);
        entry = m.track(4, 2, "A_OPUS");
        m.uint(0x88, 1);
        m.element(0x63A2, "OpusHead\x01\x02\x38\x01\x80\xBB\x00\x00\x00\x00\x00");
        m.uint(0x56AA, 6_500_000);
        m.sound(48000, 2);
        m.end(entry);
        entry = m.track(5, 1, "V_VP9");
        m.uint(0x23E383, 40_000_000);
        const video = m.begin(0xE0);
        m.uint(0xB0, 320);
        m.uint(0xBA, 240);
        m.end(video);
        m.end(entry);
        entry = m.track(6, 0x11, "S_TEXT/ASS");
        m.element(0x63A2, "[Script Info]");
        const zlib = m.begin(0x6D80);
        const zlib_encoding = m.begin(0x6240);
        const zlib_compression = m.begin(0x5034);
        m.end(zlib_compression);
        m.end(zlib_encoding);
        m.end(zlib);
        m.end(entry);
        m.end(tracks);

        const tags = m.begin(0x1254C367);
        m.tag(50, 0, "TITLE", "Laced");
        m.tag(30, 0, "ARTIST", "Hand");
        m.tag(0, 103, "NUMBER_OF_FRAMES", "6");
        m.tag(0, 103, "BPS", "1234");
        m.end(tags);

        // The first cluster, its end where the next begins.
        const first = m.len;
        m.open(0x1F43B675);
        const first_body = m.len;
        m.uint(0xE7, 1000);
        // Xiph's lacing: 300 (255 and 45), 2, and the rest 5.
        var laced: [320]u8 = undefined;
        laced[0] = 2;
        laced[1] = 255;
        laced[2] = 45;
        laced[3] = 2;
        @memset(laced[4..304], 'A');
        @memcpy(laced[304..306], "BB");
        @memcpy(laced[306..311], "CCCCC");
        m.block(0xA3, 1, 0, 0x80 | 0x02, laced[0..311]);
        // EBML's: 10, then 12 (+2), 9 (-3), and the rest 7.
        m.block(0xA3, 3, 5, 0x80 | 0x06, "\x03\x8A\xC1\xBC" ++ "a" ** 10 ++ "b" ** 12 ++ "c" ** 9 ++ "d" ** 7);
        const group = m.begin(0xA0);
        m.block(0xA1, 2, 10, 0, "Hello");
        m.uint(0x9B, 1500);
        m.end(group);
        const frame0 = m.len - first_body;
        m.block(0xA3, 5, 20, 0x80, "frame0");
        // All of a size: two of four.
        m.block(0xA3, 3, 30, 0x80 | 0x04, "\x01eeeeffff");
        m.block(0xA3, 4, 0, 0x80, "opus0");
        m.block(0xA3, 6, 0, 0x80, "zz");

        const second = m.len;
        const cluster = m.begin(0x1F43B675);
        const second_body = m.len;
        m.uint(0xE7, 2000);
        m.element(0xEC, "\x00\x00");
        const referring = m.begin(0xA0);
        m.block(0xA1, 5, 0, 0, "frame1");
        m.element(0xFB, "\xD8");
        m.end(referring);
        m.block(0xA3, 1, 0, 0x80, "DDD");
        const frame2 = m.len - second_body;
        m.block(0xA3, 5, 40, 0x80, "frame2");
        m.end(cluster);

        std.mem.writeInt(u64, m.bytes[seeks[0]..][0..8], m.len - segment, .big);
        const cues = m.begin(0x1C53BB6B);
        for ([_][3]u64{ .{ 1020, first - segment, frame0 }, .{ 2040, second - segment, frame2 } }) |cue| {
            const point = m.begin(0xBB);
            m.uint(0xB3, cue[0]);
            const position = m.begin(0xB7);
            m.uint(0xF7, 5);
            m.uint(0xF1, cue[1]);
            m.uint(0xF0, cue[2]);
            m.end(position);
            m.end(point);
        }
        m.end(cues);

        std.mem.writeInt(u64, m.bytes[seeks[1]..][0..8], m.len - segment, .big);
        const chapters = m.begin(0x1043A770);
        const hidden = m.begin(0x45B9);
        m.uint(0x45BD, 1);
        m.chapter(0, 0, false, "Hidden edition");
        m.end(hidden);
        const edition = m.begin(0x45B9);
        m.uint(0x45DB, 1);
        m.chapter(0, 0, false, "Erstes");
        m.chapter(500_000_000, 0, true, "Hidden");
        m.chapter(1_500_000_000, 1_800_000_000, false, "Zweites");
        m.end(edition);
        m.end(chapters);
    }
};

/// The next packet of a track, checked: its bytes, when it is due and
/// whether a decoder can start at it.
fn expectPacket(mb: *MediaBase, file: *media.MediaFile, track: u32, bytes: []const u8, pts: i64, key: bool) !void {
    var packet: media.MediaPacket = .{};
    try testing.expectEqual(media.MERR_OK, mb.ReadMediaPacket(file, track, &packet));
    try testing.expectEqualSlices(u8, bytes, packet.data.?[0..packet.size]);
    try testing.expectEqual(pts, packet.pts);
    try testing.expectEqual(key, packet.flags & media.MPKT_KEY != 0);
}

test "Matroska by hand: lacing, header stripping, sizes not known, setups made, tracks it cannot read, cues and chapters" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit() catch {};
    const mb = rig.mb;
    var maker: Maker = .{};
    maker.make();
    const bytes = maker.bytes[0..maker.len];
    try rig.write("WORK:laced.mka", bytes);
    var err: i32 = -1;
    const file = openFile(mb, "WORK:laced.mka", &err) orelse return error.NoFile;
    defer mb.CloseMedia(file);
    try testing.expectEqual(media.MERR_OK, err);

    var info: media.MediaInfo = .{};
    mb.GetMediaInfo(file, &info);
    try testing.expectEqual(@as(u32, 6), info.tracks);
    try testing.expectEqual(@as(u64, 2_100_000), info.duration);
    // The first sound marked to be played - not the first, which is not.
    try testing.expectEqual(@as(u32, 2), info.audio);
    try testing.expectEqual(@as(u32, 4), info.video);
    try testing.expectEqualStrings("Hand made", textOf(&info.title));
    try testing.expectEqualStrings("Hand", textOf(&info.artist));

    var track: media.MediaTrack = .{};
    try testing.expectEqual(media.MERR_OK, mb.GetMediaTrack(file, 0, &track));
    try testing.expectEqual(media.MCODEC_MP3, track.codec);
    try testing.expectEqual(@as(u32, 48000), track.timescale);
    try testing.expectEqualStrings("ger", textOf(&track.language));
    try testing.expectEqual(media.MERR_OK, mb.GetMediaTrack(file, 1, &track));
    try testing.expectEqual(media.MTRACK_TEXT, track.kind);
    try testing.expectEqual(media.MCODEC_SRT, track.codec);
    try testing.expectEqualStrings("Deutsch", textOf(&track.name));
    // AAC-LC at 44.1 kHz in stereo, made from its profile.
    try testing.expectEqual(media.MERR_OK, mb.GetMediaTrack(file, 2, &track));
    try testing.expectEqual(media.MCODEC_AAC, track.codec);
    try testing.expectEqualSlices(u8, &.{ 0x12, 0x10 }, track.config.?[0..track.config_size]);
    try testing.expectEqual(@as(u32, 6), track.packets);
    try testing.expectEqual(@as(u32, 1234), track.bitrate);
    try testing.expectEqualStrings("jpn", textOf(&track.language));
    // OpusHead made dOps: big-endian, its pre-skip 312, 48 kHz; the
    // delay 6.5 ms in frames.
    try testing.expectEqual(media.MERR_OK, mb.GetMediaTrack(file, 3, &track));
    try testing.expectEqual(media.MCODEC_OPUS, track.codec);
    try testing.expectEqualSlices(u8, &.{ 0, 2, 0x01, 0x38, 0, 0, 0xBB, 0x80, 0, 0, 0 }, track.config.?[0..track.config_size]);
    try testing.expectEqual(@as(u32, 312), track.delay);
    try testing.expectEqual(media.MERR_OK, mb.GetMediaTrack(file, 4, &track));
    try testing.expectEqual(media.MCODEC_VP9, track.codec);
    try testing.expectEqual(@as(u32, 320), track.width);
    try testing.expectEqual(@as(u32, 240), track.height);
    try testing.expectEqual(@as(u32, 25_000), track.frame_rate);
    try testing.expectEqual(media.MERR_OK, mb.GetMediaTrack(file, 5, &track));
    try testing.expectEqual(media.MCODEC_ASS, track.codec);
    try testing.expectEqualStrings("[Script Info]", track.config.?[0..track.config_size]);

    // The frames of a block laced Xiph's way, the bytes left out put back,
    // each due a frame after the one before; the next in the second
    // cluster, past the first's end that was not said.
    try expectPacket(mb, file, 0, "\xFF\xFB" ++ "A" ** 300, 1_000_000, true);
    try expectPacket(mb, file, 0, "\xFF\xFBBB", 1_024_000, true);
    try expectPacket(mb, file, 0, "\xFF\xFBCCCCC", 1_048_000, true);
    try expectPacket(mb, file, 0, "\xFF\xFBDDD", 2_000_000, true);
    var packet: media.MediaPacket = .{};
    try testing.expectEqual(media.MERR_END, mb.ReadMediaPacket(file, 0, &packet));

    // A group's: how long it lasts.
    try testing.expectEqual(media.MERR_OK, mb.ReadMediaPacket(file, 1, &packet));
    try testing.expectEqualStrings("Hello", packet.data.?[0..packet.size]);
    try testing.expectEqual(@as(i64, 1_010_000), packet.pts);
    try testing.expectEqual(@as(u32, 1_500_000), packet.duration);
    try testing.expectEqual(media.MERR_END, mb.ReadMediaPacket(file, 1, &packet));

    // EBML's lacing, then all of a size: AAC's frames 1024 samples apart.
    try expectPacket(mb, file, 2, "a" ** 10, 1_005_000, true);
    try expectPacket(mb, file, 2, "b" ** 12, 1_028_219, true);
    try expectPacket(mb, file, 2, "c" ** 9, 1_051_439, true);
    try expectPacket(mb, file, 2, "d" ** 7, 1_074_659, true);
    try expectPacket(mb, file, 2, "eeee", 1_030_000, true);
    try expectPacket(mb, file, 2, "ffff", 1_053_219, true);
    try testing.expectEqual(media.MERR_END, mb.ReadMediaPacket(file, 2, &packet));

    // Opus: due its delay before its block's time.
    try expectPacket(mb, file, 3, "opus0", 993_500, true);

    // Pictures: a group with a reference is no key.
    try expectPacket(mb, file, 4, "frame0", 1_020_000, true);
    try expectPacket(mb, file, 4, "frame1", 2_000_000, false);
    try expectPacket(mb, file, 4, "frame2", 2_040_000, true);
    try testing.expectEqual(media.MERR_END, mb.ReadMediaPacket(file, 4, &packet));
    try testing.expectEqual(media.MERR_UNSUPPORTED, mb.ReadMediaPacket(file, 5, &packet));

    // Moves: by the pictures' own cues - 2.0 s is frame0's, frame1 at it
    // no key; another track from the cue before the time.
    try testing.expectEqual(media.MERR_OK, mb.SeekMedia(file, 4, 2_100_000));
    try expectPacket(mb, file, 4, "frame2", 2_040_000, true);
    try testing.expectEqual(media.MERR_OK, mb.SeekMedia(file, 4, 2_000_000));
    try expectPacket(mb, file, 4, "frame0", 1_020_000, true);
    try testing.expectEqual(media.MERR_OK, mb.SeekMedia(file, 4, 0));
    try expectPacket(mb, file, 4, "frame0", 1_020_000, true);
    try testing.expectEqual(media.MERR_OK, mb.SeekMedia(file, 0, 1_030_000));
    try expectPacket(mb, file, 0, "\xFF\xFB" ++ "A" ** 300, 1_000_000, true);
    try testing.expectEqual(media.MERR_OK, mb.SeekMedia(file, 0, 5_000_000));
    try expectPacket(mb, file, 0, "\xFF\xFBDDD", 2_000_000, true);

    // The default edition's chapters, the hidden one passed over: the
    // first ends where the next begins, the second where it says. The
    // subtitles marked: the ASS, default as Matroska has it when it says
    // nothing - the SubRip says it is not.
    var chapters: u32 = 0;
    var list: ?[*]const media.MediaChapter = null;
    var subtitles: u32 = 0;
    _ = mb.GetMediaAttrs(file, &[_]utility.TagItem{
        .{ .tag = media.MDA_Chapters, .data = @intFromPtr(&chapters) },
        .{ .tag = media.MDA_ChapterList, .data = @intFromPtr(&list) },
        .{ .tag = media.MDA_Subtitles, .data = @intFromPtr(&subtitles) },
        .{},
    });
    try testing.expectEqual(@as(u32, 5), subtitles);
    try testing.expectEqual(@as(u32, 2), chapters);
    try testing.expectEqualStrings("Erstes", textOf(&list.?[0].title));
    try testing.expectEqual(@as(u32, 1500), list.?[0].end);
    try testing.expectEqualStrings("Zweites", textOf(&list.?[1].title));
    try testing.expectEqual(@as(u32, 1500), list.?[1].start);
    try testing.expectEqual(@as(u32, 1800), list.?[1].end);

    // Through a read function in pieces of 7: no cues, no chapters; one
    // track read, the others behind it.
    var memory: Memory = .{ .bytes = bytes, .piece = 7 };
    const read = openMemory(mb, &memory, &err) orelse return error.NoFile;
    defer mb.CloseMedia(read);
    try expectPacket(mb, read, 4, "frame0", 1_020_000, true);
    try expectPacket(mb, read, 4, "frame1", 2_000_000, false);
    try expectPacket(mb, read, 4, "frame2", 2_040_000, true);
    try testing.expectEqual(media.MERR_NOSEEK, mb.ReadMediaPacket(read, 0, &packet));
    chapters = 9;
    _ = mb.GetMediaAttrs(read, &[_]utility.TagItem{ .{ .tag = media.MDA_Chapters, .data = @intFromPtr(&chapters) }, .{} });
    try testing.expectEqual(@as(u32, 0), chapters);
}
