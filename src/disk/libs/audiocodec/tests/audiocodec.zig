// SPDX-License-Identifier: MIT
//! audiocodec.library's host tests: the library made from its ROM tag on
//! the ROM's exec, utility and dos; streams on bytes handed over by a
//! read function, and on files on a RAM disk.
//!
//! `tone.mp3` is 0.3 s of a stereo tone with clicks, 128 kbit/s, with an
//! ID3v2 tag and an Info frame (made with lame); `tone_head.raw` its first
//! 1024 frames as mpg123 decodes them, the encoder's delay left out.
//! `mono.mp3` is 0.3 s of MPEG-2 mono at 22.05 kHz with no Info frame:
//! 14 frames of 576.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const ac = sdk.audiocodec;
const utility = sdk.utility;
const host = @import("host_rom");
const kexec = host.exec;
const audiocodec_init = @import("../audiocodec_init.zig");

const testing = std.testing;
const DosBase = sdk.interface.dos.DosBase;
const AudioCodecBase = sdk.interface.audiocodec.AudioCodecBase;

test {
    _ = @import("../audiocodec_lvo.zig");
}

const tone_mp3 = @embedFile("tone.mp3");
const tone_head = @embedFile("tone_head.raw");
const mono_mp3 = @embedFile("mono.mp3");
const tone_frames = 13230;
const mono_frames = 14 * 576;

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

/// Memory lent to exec: a stream is about 42 KiB.
var lent: [512 * 1024]u8 align(16) = undefined;

/// exec, utility and dos with memory lent; a process with WORK: behind
/// it; audiocodec.library made and opened.
const Rig = struct {
    db: *host.dos.DosBase,
    region: *exec.MemHeader = undefined,
    proc: dos.Process = .{},
    saved: ?*kexec.Task = null,
    library: *exec.Library = undefined,
    acb: *AudioCodecBase = undefined,

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

        const lib = kexec.InitResident(kexec.SysBase, &audiocodec_init.audiocodec_library_tag, null) orelse return error.NoLibrary;
        rig.library = @ptrCast(@alignCast(lib));
        rig.acb = @ptrCast(rig.sysLib().OpenLibrary(ac.AUDIOCODECNAME, 1) orelse return error.NoBase);
    }

    fn sysLib(_: *Rig) *sdk.interface.exec.ExecBase {
        return kexec.SysBase.iface();
    }

    fn dosLib(rig: *Rig) *DosBase {
        return host.dos.testBase(rig.db);
    }

    /// The library closed and expunged, the disk taken down with every
    /// library, and nothing left behind.
    fn deinit(rig: *Rig) !void {
        rig.sysLib().CloseLibrary(rig.acb.lib());
        _ = rig.sysLib().RemLibrary(rig.library);
        try testing.expect(kexec.FindName(kexec.SysBase, &kexec.SysBase.lib_list, ac.AUDIOCODECNAME) == null);
        Disk.disk.deinit();
        kexec.SysBase.cpu().this_task = rig.saved.?;
        try host.dos.testTearDown(rig.db);
        try testing.expectEqual(@intFromPtr(rig.region.upper) - @intFromPtr(rig.region.lower), rig.region.free);
        rig.sysLib().Remove(&rig.region.node);
        kexec.deinit();
    }

    /// A file on the disk, from pieces one after the other.
    fn write(rig: *Rig, name: [*:0]const u8, pieces: []const []const u8) !void {
        const dl = rig.dosLib();
        const fh = dl.Open(name, dos.MODE_NEWFILE) orelse return error.NoFile;
        defer _ = dl.Close(fh);
        for (pieces) |bytes| {
            try testing.expectEqual(@as(isize, @intCast(bytes.len)), dl.Write(fh, bytes.ptr, @intCast(bytes.len)));
        }
    }
};

/// Bytes in memory, handed over by a read function in pieces of `piece`
/// at most, so the stream refills over and over.
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

fn openMemory(acb: *AudioCodecBase, memory: *Memory, err: *i32) ?*ac.AudioStream {
    return acb.OpenAudioStream(&[_]utility.TagItem{
        .{ .tag = ac.ACA_ReadFunc, .data = @intFromPtr(&Memory.read) },
        .{ .tag = ac.ACA_ReadData, .data = @intFromPtr(memory) },
        .{},
    }, err);
}

fn openFile(acb: *AudioCodecBase, name: [*:0]const u8, err: *i32) ?*ac.AudioStream {
    return acb.OpenAudioStream(&[_]utility.TagItem{
        .{ .tag = ac.ACA_Name, .data = @intFromPtr(name) },
        .{},
    }, err);
}

/// Every frame the stream has left, in pieces of `piece` frames: how many
/// in all, and the first of them into `into`.
fn decodeAll(acb: *AudioCodecBase, stream: *ac.AudioStream, channels: u32, piece: u32, into: []i16) !u32 {
    var buffer: [2000 * 2]i16 = undefined;
    var total: u32 = 0;
    while (true) {
        const got = acb.DecodeAudio(stream, &buffer, piece);
        try testing.expect(got >= 0);
        if (got == 0) break;
        const samples: usize = @as(usize, @intCast(got)) * channels;
        const at: usize = @as(usize, total) * channels;
        if (at < into.len) {
            const fits = @min(samples, into.len - at);
            @memcpy(into[at..][0..fits], buffer[0..fits]);
        }
        total += @intCast(got);
    }
    return total;
}

fn textOf(text: *const [64]u8) []const u8 {
    return std.mem.sliceTo(text, 0);
}

// --- WAV files made here ----------------------------------------------------------

const Builder = struct {
    bytes: [16 * 1024]u8 = undefined,
    len: usize = 0,

    fn put(b: *Builder, data: []const u8) void {
        @memcpy(b.bytes[b.len..][0..data.len], data);
        b.len += data.len;
    }
    fn le16(b: *Builder, value: u16) void {
        b.put(&.{ @truncate(value), @truncate(value >> 8) });
    }
    fn le32(b: *Builder, value: u32) void {
        b.put(&.{ @truncate(value), @truncate(value >> 8), @truncate(value >> 16), @truncate(value >> 24) });
    }
    fn slice(b: *const Builder) []const u8 {
        return b.bytes[0..b.len];
    }
};

/// A WAV of `data` - samples in their file form - with a format tag, at
/// 8000 frames a second, an INFO list naming it before the data.
fn wavFile(b: *Builder, tag: u16, channels: u16, bits: u16, title: []const u8, data: []const u8) void {
    const list_len: u32 = @intCast(4 + 8 + title.len + (title.len & 1));
    b.put("RIFF");
    b.le32(@intCast(4 + 8 + 16 + 8 + list_len + 8 + data.len));
    b.put("WAVE");
    b.put("fmt ");
    b.le32(16);
    b.le16(tag);
    b.le16(channels);
    b.le32(8000);
    b.le32(8000 * @as(u32, channels) * bits / 8);
    b.le16(channels * bits / 8);
    b.le16(bits);
    b.put("LIST");
    b.le32(list_len);
    b.put("INFO");
    b.put("INAM");
    b.le32(@intCast(title.len));
    b.put(title);
    if (title.len & 1 != 0) b.put(&.{0});
    b.put("data");
    b.le32(@intCast(data.len));
    b.put(data);
}

/// 16-bit stereo frames: left counting up, right down.
fn stereo16(comptime frames: usize) [frames * 4]u8 {
    var bytes: [frames * 4]u8 = undefined;
    for (0..frames) |i| {
        const left: u16 = @bitCast(@as(i16, @intCast(i * 7)));
        const right: u16 = @bitCast(-@as(i16, @intCast(i * 5)));
        bytes[i * 4 + 0] = @truncate(left);
        bytes[i * 4 + 1] = @truncate(left >> 8);
        bytes[i * 4 + 2] = @truncate(right);
        bytes[i * 4 + 3] = @truncate(right >> 8);
    }
    return bytes;
}

// --- the tests --------------------------------------------------------------------

test "what sound is, by its first bytes" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit() catch {};
    const acb = rig.acb;

    var b: Builder = .{};
    wavFile(&b, 1, 2, 16, "x", &stereo16(4));
    try testing.expectEqual(ac.ACODEC_WAV, acb.IdentifyAudio(b.slice().ptr, @intCast(b.len)));
    try testing.expectEqual(ac.ACODEC_MP3, acb.IdentifyAudio(tone_mp3, tone_mp3.len));
    // Frames alone, no tag in front.
    try testing.expectEqual(ac.ACODEC_MP3, acb.IdentifyAudio(mono_mp3, mono_mp3.len));
    // A run of bytes that only looks like a header is not MP3.
    const lookalike = [_]u8{ 0xFF, 0xFB, 0x90, 0x64 } ++ [_]u8{0x55} ** 400;
    try testing.expectEqual(ac.ACODEC_UNKNOWN, acb.IdentifyAudio(&lookalike, lookalike.len));
    try testing.expectEqual(ac.ACODEC_UNKNOWN, acb.IdentifyAudio("hello", 5));
}

test "an MP3 through a read function: its tags, its exact length, the samples another decoder makes" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit() catch {};
    const acb = rig.acb;

    var memory: Memory = .{ .bytes = tone_mp3 };
    var err: i32 = -99;
    const stream = openMemory(acb, &memory, &err) orelse return error.NoStream;
    defer acb.CloseAudioStream(stream);
    try testing.expectEqual(ac.ACERR_OK, err);

    var info: ac.AudioStreamInfo = .{};
    acb.GetAudioStreamInfo(stream, &info);
    try testing.expectEqual(ac.ACODEC_MP3, info.codec);
    try testing.expectEqual(@as(u32, 44100), info.rate);
    try testing.expectEqual(@as(u32, 2), info.channels);
    try testing.expectEqual(@as(u32, tone_frames), info.frames);
    try testing.expectEqual(@as(u32, 0), info.seekable);
    try testing.expectEqualStrings("Test Tone", textOf(&info.title));
    try testing.expectEqualStrings("PowerOS", textOf(&info.artist));
    try testing.expectEqualStrings("Tests", textOf(&info.album));

    var head: [1024 * 2]i16 = undefined;
    const total = try decodeAll(acb, stream, 2, 1000, &head);
    try testing.expectEqual(@as(u32, tone_frames), total);
    const reference: []align(1) const i16 = std.mem.bytesAsSlice(i16, tone_head);
    for (head, reference) |ours, theirs| {
        try testing.expect(@abs(@as(i32, ours) - theirs) <= 1);
    }
    try testing.expectEqual(@as(i32, 0), acb.DecodeAudio(stream, &head, 100));
    try testing.expectEqual(ac.ACERR_NOSEEK, acb.SeekAudio(stream, 0));
}

test "MPEG-2 mono without an Info frame: its frames, as many as it has" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit() catch {};
    const acb = rig.acb;

    var memory: Memory = .{ .bytes = mono_mp3, .piece = 333 };
    var err: i32 = 0;
    const stream = openMemory(acb, &memory, &err) orelse return error.NoStream;
    defer acb.CloseAudioStream(stream);
    var info: ac.AudioStreamInfo = .{};
    acb.GetAudioStreamInfo(stream, &info);
    try testing.expectEqual(@as(u32, 22050), info.rate);
    try testing.expectEqual(@as(u32, 1), info.channels);
    // A read function says nothing about its size.
    try testing.expectEqual(@as(u32, 0), info.frames);
    try testing.expectEqual(@as(u32, mono_frames), try decodeAll(acb, stream, 1, 777, &.{}));
}

test "a WAV: its samples as they are, its name, every sample form brought to 16 bits" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit() catch {};
    const acb = rig.acb;

    const data = stereo16(1000);
    var b: Builder = .{};
    wavFile(&b, 1, 2, 16, "Wave", &data);
    var memory: Memory = .{ .bytes = b.slice() };
    var err: i32 = 0;
    const stream = openMemory(acb, &memory, &err) orelse return error.NoStream;
    var info: ac.AudioStreamInfo = .{};
    acb.GetAudioStreamInfo(stream, &info);
    try testing.expectEqual(ac.ACODEC_WAV, info.codec);
    try testing.expectEqual(@as(u32, 8000), info.rate);
    try testing.expectEqual(@as(u32, 1000), info.frames);
    try testing.expectEqual(@as(u32, 16), info.bits);
    try testing.expectEqualStrings("Wave", textOf(&info.title));
    var all: [1000 * 2]i16 = undefined;
    try testing.expectEqual(@as(u32, 1000), try decodeAll(acb, stream, 2, 300, &all));
    try testing.expectEqual(@as(i16, 999 * 7), all[999 * 2]);
    try testing.expectEqual(@as(i16, -999 * 5), all[999 * 2 + 1]);
    acb.CloseAudioStream(stream);

    // 8 bits, unsigned, one channel.
    const eight = [_]u8{ 0, 128, 255 };
    b = .{};
    wavFile(&b, 1, 1, 8, "", &eight);
    memory = .{ .bytes = b.slice() };
    const s8 = openMemory(acb, &memory, &err) orelse return error.NoStream;
    var out8: [3]i16 = undefined;
    try testing.expectEqual(@as(i32, 3), acb.DecodeAudio(s8, &out8, 10));
    try testing.expectEqualSlices(i16, &.{ -32768, 0, 32512 }, &out8);
    acb.CloseAudioStream(s8);

    // 24 bits: the top two bytes.
    const wide = [_]u8{ 0x11, 0x34, 0x12, 0xFF, 0x00, 0x80 };
    b = .{};
    wavFile(&b, 1, 1, 24, "", &wide);
    memory = .{ .bytes = b.slice() };
    const s24 = openMemory(acb, &memory, &err) orelse return error.NoStream;
    var out24: [2]i16 = undefined;
    try testing.expectEqual(@as(i32, 2), acb.DecodeAudio(s24, &out24, 10));
    try testing.expectEqualSlices(i16, &.{ 0x1234, -32768 }, &out24);
    acb.CloseAudioStream(s24);

    // 32-bit float, held at its ends.
    var floats: [3 * 4]u8 = undefined;
    for ([_]f32{ 0.5, -1.0, 2.0 }, 0..) |value, i| {
        const word: u32 = @bitCast(value);
        floats[i * 4 ..][0..4].* = .{ @truncate(word), @truncate(word >> 8), @truncate(word >> 16), @truncate(word >> 24) };
    }
    b = .{};
    wavFile(&b, 3, 1, 32, "", &floats);
    memory = .{ .bytes = b.slice() };
    const sf = openMemory(acb, &memory, &err) orelse return error.NoStream;
    var outf: [3]i16 = undefined;
    try testing.expectEqual(@as(i32, 3), acb.DecodeAudio(sf, &outf, 10));
    try testing.expectEqualSlices(i16, &.{ 16384, -32768, 32767 }, &outf);
    acb.CloseAudioStream(sf);
}

test "a WAV it does not decode, and bytes that are no sound, are refused with why" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit() catch {};
    const acb = rig.acb;
    var err: i32 = 0;

    var b: Builder = .{};
    wavFile(&b, 2, 1, 4, "", &.{ 1, 2, 3, 4 }); // ADPCM
    var memory: Memory = .{ .bytes = b.slice() };
    try testing.expect(openMemory(acb, &memory, &err) == null);
    try testing.expectEqual(ac.ACERR_UNSUPPORTED, err);

    b = .{};
    wavFile(&b, 1, 6, 16, "", &([_]u8{0} ** 24)); // six channels
    memory = .{ .bytes = b.slice() };
    try testing.expect(openMemory(acb, &memory, &err) == null);
    try testing.expectEqual(ac.ACERR_UNSUPPORTED, err);

    memory = .{ .bytes = "nothing to hear here, not even a header" };
    try testing.expect(openMemory(acb, &memory, &err) == null);
    try testing.expectEqual(ac.ACERR_UNKNOWN, err);
    try testing.expectEqualStrings("not a kind of sound the library knows", std.mem.span(acb.AudioErrorText(err)));

    // No source at all.
    try testing.expect(acb.OpenAudioStream(null, &err) == null);
    try testing.expectEqual(ac.ACERR_OPEN, err);
}

test "files: they seek; a tag at the end is no sound and names it; a WAV seeks exactly" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit() catch {};
    const acb = rig.acb;
    var err: i32 = 0;

    // ID3v1 at the end of an MP3 without an Info frame: every frame is
    // still decoded - the last one too - and the tail's names count.
    var tag: [128]u8 = @splat(0);
    @memcpy(tag[0..3], "TAG");
    @memcpy(tag[3..13], "Tail Title");
    @memcpy(tag[33..39], "Tailor");
    try rig.write("WORK:mono.mp3", &.{ mono_mp3, &tag });
    const mono = openFile(acb, "WORK:mono.mp3", &err) orelse return error.NoStream;
    var info: ac.AudioStreamInfo = .{};
    acb.GetAudioStreamInfo(mono, &info);
    try testing.expectEqual(@as(u32, 1), info.seekable);
    try testing.expectEqualStrings("Tail Title", textOf(&info.title));
    try testing.expectEqualStrings("Tailor", textOf(&info.artist));
    try testing.expect(info.frames > mono_frames / 2 and info.frames < mono_frames * 2);
    try testing.expectEqual(@as(u32, mono_frames), try decodeAll(acb, mono, 1, 1000, &.{}));
    acb.CloseAudioStream(mono);

    // A WAV moved to its 500th frame, exactly.
    const data = stereo16(1000);
    var b: Builder = .{};
    wavFile(&b, 1, 2, 16, "Wave", &data);
    try rig.write("WORK:wave.wav", &.{b.slice()});
    const wave = openFile(acb, "WORK:wave.wav", &err) orelse return error.NoStream;
    try testing.expectEqual(ac.ACERR_OK, acb.SeekAudio(wave, 500));
    var some: [4 * 2]i16 = undefined;
    try testing.expectEqual(@as(i32, 4), acb.DecodeAudio(wave, &some, 4));
    try testing.expectEqual(@as(i16, 500 * 7), some[0]);
    try testing.expectEqual(@as(i16, -503 * 5), some[7]);
    acb.CloseAudioStream(wave);

    // An MP3 moved half way: it goes on from there, to its end.
    try rig.write("WORK:tone.mp3", &.{tone_mp3});
    const tone = openFile(acb, "WORK:tone.mp3", &err) orelse return error.NoStream;
    try testing.expectEqual(ac.ACERR_OK, acb.SeekAudio(tone, tone_frames / 2));
    const rest = try decodeAll(acb, tone, 2, 1000, &.{});
    try testing.expect(rest > tone_frames / 4 and rest <= tone_frames / 2 + 1152);
    acb.CloseAudioStream(tone);
}
