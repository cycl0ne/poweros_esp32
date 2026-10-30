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
//! packets.

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
}

const film_mp4 = @embedFile("film.mp4");
const tail_m4a = @embedFile("tail.m4a");

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
    try testing.expectEqual(@as(u32, 7), mb.GetMediaAttrs(film, &[_]utility.TagItem{
        .{ .tag = media.MDA_Year, .data = @intFromPtr(&year) },
        .{ .tag = media.MDA_Track, .data = @intFromPtr(&track) },
        .{ .tag = media.MDA_Tracks, .data = @intFromPtr(&tracks) },
        .{ .tag = media.MDA_Genre, .data = @intFromPtr(&genre) },
        .{ .tag = media.MDA_Chapters, .data = @intFromPtr(&chapters) },
        .{ .tag = media.MDA_ChapterList, .data = @intFromPtr(&list) },
        .{ .tag = media.MDA_Picture, .data = @intFromPtr(&cover) },
        .{ .tag = utility.TAG_USER, .data = @intFromPtr(&year) },
        .{},
    }));
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
