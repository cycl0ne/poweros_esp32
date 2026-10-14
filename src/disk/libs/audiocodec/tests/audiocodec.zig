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
//!
//! The FLAC files hold `signal` (made again here, exactly): `lossless.flac`
//! 4500 frames of 16-bit stereo at 44.1 kHz (flac -8), with Vorbis
//! comments, two chapters, a PICTURE block and a seek table;
//! `mono8.flac` 3000 frames of 8-bit mono at 8 kHz in fixed predictions
//! and no seek table; `wide24.flac` 2000 frames of 24-bit stereo at 48 kHz
//! in blocks of 576. `lossy.ogg` is lossless.flac's sound in Ogg Vorbis
//! (libvorbis, quality 3) titled "Lossy", `lossy_head.raw` its first 1024
//! frames as libvorbisfile decodes them; `mono.ogg` the same at 22.05 kHz
//! in mono, 2250 frames.

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
const lossless_flac = @embedFile("lossless.flac");
const mono8_flac = @embedFile("mono8.flac");
const wide24_flac = @embedFile("wide24.flac");
const lossy_ogg = @embedFile("lossy.ogg");
const lossy_head = @embedFile("lossy_head.raw");
const mono_ogg = @embedFile("mono.ogg");

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
var lent: [3 * 1024 * 1024]u8 align(16) = undefined;

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

// --- ID3v2 tags made here ---------------------------------------------------------

/// An ID3v2 tag built frame by frame, then the sound after it.
const Id3 = struct {
    bytes: [64 * 1024]u8 = undefined,
    len: usize = 10,
    version: u8,

    fn put(t: *Id3, data: []const u8) void {
        @memcpy(t.bytes[t.len..][0..data.len], data);
        t.len += data.len;
    }

    fn size4(t: *Id3, value: usize) void {
        const v: u32 = @intCast(value);
        if (t.version == 4) {
            t.put(&.{ @truncate(v >> 21 & 0x7F), @truncate(v >> 14 & 0x7F), @truncate(v >> 7 & 0x7F), @truncate(v & 0x7F) });
        } else {
            t.put(&.{ @truncate(v >> 24), @truncate(v >> 16), @truncate(v >> 8), @truncate(v) });
        }
    }

    /// A frame: its name, its size, its flags, its body.
    fn frame(t: *Id3, id: *const [4]u8, format: u8, body: []const u8) void {
        t.put(id);
        t.size4(body.len);
        t.put(&.{ 0, format });
        t.put(body);
    }

    /// The header put in front, `flags` its flags; the tag and `sound`
    /// after it, as a file would hold them.
    fn finish(t: *Id3, flags: u8, sound: []const u8) []const u8 {
        const v: u32 = @intCast(t.len - 10);
        @memcpy(t.bytes[0..10], &[_]u8{ 'I', 'D', '3', t.version, 0, flags, @truncate(v >> 21 & 0x7F), @truncate(v >> 14 & 0x7F), @truncate(v >> 7 & 0x7F), @truncate(v & 0x7F) });
        t.put(sound);
        return t.bytes[0..t.len];
    }
};

var id3_tag: Id3 = .{ .version = 3 };

/// A picture of `count` bytes that is no picture: a pattern, with 0xFF
/// followed by what unsynchronisation guards against.
fn pictureBytes(into: []u8) void {
    for (into, 0..) |*b, i| b.* = switch (i % 7) {
        0 => 0xFF,
        1 => 0xE3,
        2 => 0xFF,
        3 => 0x00,
        else => @truncate(i),
    };
}

var picture_made: [20000]u8 = undefined;

/// The 0 after every 0xFF put in: unsynchronised.
fn unsynchronise(into: []u8, from: []const u8) usize {
    var out: usize = 0;
    for (from) |b| {
        into[out] = b;
        out += 1;
        if (b == 0xFF) {
            into[out] = 0;
            out += 1;
        }
    }
    return out;
}

fn attrs(acb: *AudioCodecBase, stream: *ac.AudioStream) struct {
    title: [*:0]const u8 = "",
    artist: [*:0]const u8 = "",
    album: [*:0]const u8 = "",
    album_artist: [*:0]const u8 = "",
    composer: [*:0]const u8 = "",
    genre: [*:0]const u8 = "",
    comment: [*:0]const u8 = "",
    year: u32 = 0,
    track: u32 = 0,
    tracks: u32 = 0,
    chapters: u32 = 0,
    chapter_list: ?[*]const ac.AudioChapter = null,
    picture: ?*const ac.AudioPicture = null,
    answered: u32 = 0,
} {
    var got: @typeInfo(@TypeOf(attrs)).@"fn".return_type.? = .{};
    got.answered = acb.GetAudioStreamAttrs(stream, &[_]utility.TagItem{
        .{ .tag = ac.ACA_Title, .data = @intFromPtr(&got.title) },
        .{ .tag = ac.ACA_Artist, .data = @intFromPtr(&got.artist) },
        .{ .tag = ac.ACA_Album, .data = @intFromPtr(&got.album) },
        .{ .tag = ac.ACA_AlbumArtist, .data = @intFromPtr(&got.album_artist) },
        .{ .tag = ac.ACA_Composer, .data = @intFromPtr(&got.composer) },
        .{ .tag = ac.ACA_Genre, .data = @intFromPtr(&got.genre) },
        .{ .tag = ac.ACA_Comment, .data = @intFromPtr(&got.comment) },
        .{ .tag = ac.ACA_Year, .data = @intFromPtr(&got.year) },
        .{ .tag = ac.ACA_Track, .data = @intFromPtr(&got.track) },
        .{ .tag = ac.ACA_Tracks, .data = @intFromPtr(&got.tracks) },
        .{ .tag = ac.ACA_Chapters, .data = @intFromPtr(&got.chapters) },
        .{ .tag = ac.ACA_ChapterList, .data = @intFromPtr(&got.chapter_list) },
        .{ .tag = ac.ACA_Picture, .data = @intFromPtr(&got.picture) },
        .{ .tag = utility.TAG_USER + 0x7777, .data = 0 },
        .{},
    });
    return got;
}

fn openTagged(acb: *AudioCodecBase, memory: *Memory, keep: bool, err: *i32) ?*ac.AudioStream {
    return acb.OpenAudioStream(&[_]utility.TagItem{
        .{ .tag = ac.ACA_ReadFunc, .data = @intFromPtr(&Memory.read) },
        .{ .tag = ac.ACA_ReadData, .data = @intFromPtr(memory) },
        .{ .tag = ac.ACA_KeepPicture, .data = @intFromBool(keep) },
        .{},
    }, err);
}

test "ID3v2.3: every name, the year, the track, the genre, a comment, chapters, and a cover past the read-ahead" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit() catch {};
    const acb = rig.acb;

    const t = &id3_tag;
    t.* = .{ .version = 3 };
    // UTF-16 with a byte-order mark: "Mix " and an emoji (a surrogate
    // pair, left out), then "Vol.2".
    t.frame("TIT2", 0, &[_]u8{ 1, 0xFF, 0xFE, 'M', 0, 'i', 0, 'x', 0, ' ', 0, 0x3D, 0xD8, 0x0A, 0xDD, ' ', 0, 'V', 0, 'o', 0, 'l', 0, '.', 0, '2', 0 });
    t.frame("TPE1", 0, "\x00Trance Hub");
    t.frame("TALB", 0, "\x00Mixes");
    t.frame("TPE2", 0, "\x00Various");
    t.frame("TCOM", 0, "\x00Someone");
    t.frame("TYER", 0, "\x002026");
    t.frame("TRCK", 0, "\x003/12");
    t.frame("TCON", 0, "\x00(17)");
    // A program's own comment first; the plain one is the one kept.
    t.frame("COMM", 0, "\x00engiTunNORM\x00 000001");
    t.frame("COMM", 0, "\x00eng\x00Nice one");
    // Two chapters, each with its title as a frame of its own.
    t.frame("CHAP", 0, "ch0\x00\x00\x00\x00\x00\x00\x00\x03\xe8\xff\xff\xff\xff\xff\xff\xff\xffTIT2\x00\x00\x00\x06\x00\x00\x00First");
    t.frame("CHAP", 0, "ch1\x00\x00\x00\x03\xe8\x00\x00\x07\xd0\xff\xff\xff\xff\xff\xff\xff\xffTIT2\x00\x00\x00\x07\x00\x00\x00Second");
    // A back cover, then the front one, larger than the read-ahead.
    t.frame("APIC", 0, "\x00image/jpeg\x00\x04back\x00\x01\x02\x03");
    pictureBytes(&picture_made);
    var head: [32]u8 = undefined;
    const head_len = (try std.fmt.bufPrint(&head, "\x00image/png\x00\x03Cover\x00", .{})).len;
    t.put("APIC");
    t.size4(head_len + picture_made.len);
    t.put(&.{ 0, 0 });
    t.put(head[0..head_len]);
    t.put(&picture_made);
    t.put(&[_]u8{0} ** 100); // padding
    const file = t.finish(0, mono_mp3);

    var err: i32 = 0;
    var memory: Memory = .{ .bytes = file };
    const stream = openTagged(acb, &memory, true, &err) orelse return error.NoStream;
    const got = attrs(acb, stream);
    try testing.expectEqual(@as(u32, 13), got.answered);
    try testing.expectEqualStrings("Mix Vol.2", std.mem.span(got.title));
    try testing.expectEqualStrings("Trance Hub", std.mem.span(got.artist));
    try testing.expectEqualStrings("Mixes", std.mem.span(got.album));
    try testing.expectEqualStrings("Various", std.mem.span(got.album_artist));
    try testing.expectEqualStrings("Someone", std.mem.span(got.composer));
    try testing.expectEqualStrings("Rock", std.mem.span(got.genre));
    try testing.expectEqualStrings("Nice one", std.mem.span(got.comment));
    try testing.expectEqual(@as(u32, 2026), got.year);
    try testing.expectEqual(@as(u32, 3), got.track);
    try testing.expectEqual(@as(u32, 12), got.tracks);
    try testing.expectEqual(@as(u32, 2), got.chapters);
    const chapters = got.chapter_list orelse return error.NoChapters;
    try testing.expectEqual(@as(u32, 1000), chapters[0].end);
    try testing.expectEqual(@as(u32, 1000), chapters[1].start);
    try testing.expectEqual(@as(u32, 2000), chapters[1].end);
    try testing.expectEqualStrings("Second", std.mem.sliceTo(&chapters[1].title, 0));
    const picture = got.picture orelse return error.NoPicture;
    try testing.expectEqual(ac.ACPIC_FRONTCOVER, picture.kind);
    try testing.expectEqualStrings("image/png", std.mem.sliceTo(&picture.mime, 0));
    try testing.expectEqualSlices(u8, &picture_made, picture.data[0..picture.size]);
    // The info's names are the same, and the sound after the tag is all
    // there.
    var info: ac.AudioStreamInfo = .{};
    acb.GetAudioStreamInfo(stream, &info);
    try testing.expectEqualStrings("Mix Vol.2", textOf(&info.title));
    try testing.expectEqual(@as(u32, mono_frames), try decodeAll(acb, stream, 1, 1000, &.{}));
    acb.CloseAudioStream(stream);

    // Not asked to keep it, the picture is passed over; the rest is the
    // same.
    memory = .{ .bytes = file };
    const plain = openTagged(acb, &memory, false, &err) orelse return error.NoStream;
    const without = attrs(acb, plain);
    try testing.expect(without.picture == null);
    try testing.expectEqualStrings("Nice one", std.mem.span(without.comment));
    try testing.expectEqual(@as(u32, mono_frames), try decodeAll(acb, plain, 1, 1000, &.{}));
    acb.CloseAudioStream(plain);
}

test "ID3v2.4 in UTF-8 with a cover unsynchronised; ID3v2.3 unsynchronised whole" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit() catch {};
    const acb = rig.acb;
    var err: i32 = 0;
    pictureBytes(&picture_made);

    // Version 4: UTF-8 with what Latin-1 lacks, a date for the year, the
    // genre by its name, and the cover's frame unsynchronised with its
    // length before that in front.
    const t = &id3_tag;
    t.* = .{ .version = 4 };
    t.frame("TIT2", 0, "\x03Caf\xc3\xa9 \xe2\x80\x93 \xe2\x80\x9cLive\xe2\x80\x9d \xf0\x9f\x92\xab \xef\xbd\x9c \xe4\xb8\xad");
    t.frame("TDRC", 0, "\x032001-05-02");
    t.frame("TCON", 0, "\x03Jazz");
    var stored: [2 * 20000 + 64]u8 = undefined;
    const body_head = "\x00image/jpeg\x00\x03\x00";
    @memcpy(stored[0..4], &[_]u8{ 0, 0, 0x9C, 0x50 }); // what the body was before: not read
    @memcpy(stored[4..][0..body_head.len], body_head);
    const stored_len = 4 + body_head.len + unsynchronise(stored[4 + body_head.len ..], &picture_made);
    t.frame("APIC", 0x03, stored[0..stored_len]);
    const file4 = t.finish(0, mono_mp3);
    var memory: Memory = .{ .bytes = file4 };
    const four = openTagged(acb, &memory, true, &err) orelse return error.NoStream;
    const got4 = attrs(acb, four);
    try testing.expectEqualStrings("Caf\xe9 - \"Live\" | ?", std.mem.span(got4.title));
    try testing.expectEqual(@as(u32, 2001), got4.year);
    try testing.expectEqualStrings("Jazz", std.mem.span(got4.genre));
    const picture4 = got4.picture orelse return error.NoPicture;
    try testing.expectEqualSlices(u8, &picture_made, picture4.data[0..picture4.size]);
    try testing.expectEqual(@as(u32, mono_frames), try decodeAll(acb, four, 1, 1000, &.{}));
    acb.CloseAudioStream(four);

    // Version 3, the whole tag unsynchronised: the frames' sizes are
    // those of their bodies before it.
    var plain: Id3 = .{ .version = 3 };
    plain.frame("TIT2", 0, "\x00Whole");
    plain.put("APIC");
    plain.size4(body_head.len + picture_made.len);
    plain.put(&.{ 0, 0 });
    plain.put(body_head);
    plain.put(&picture_made);
    plain.frame("TPE1", 0, "\x00After");
    t.* = .{ .version = 3 };
    t.len = 10 + unsynchronise(t.bytes[10..], plain.bytes[10..plain.len]);
    const file3 = t.finish(0x80, mono_mp3);
    memory = .{ .bytes = file3 };
    const three = openTagged(acb, &memory, true, &err) orelse return error.NoStream;
    const got3 = attrs(acb, three);
    try testing.expectEqualStrings("Whole", std.mem.span(got3.title));
    try testing.expectEqualStrings("After", std.mem.span(got3.artist));
    const picture3 = got3.picture orelse return error.NoPicture;
    try testing.expectEqualSlices(u8, &picture_made, picture3.data[0..picture3.size]);
    try testing.expectEqual(@as(u32, mono_frames), try decodeAll(acb, three, 1, 1000, &.{}));
    acb.CloseAudioStream(three);
}

test "ID3v1 at a file's end: its year, its comment and track (v1.1), its genre" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit() catch {};
    const acb = rig.acb;
    var err: i32 = 0;
    var tag: [128]u8 = @splat(0);
    @memcpy(tag[0..3], "TAG");
    @memcpy(tag[3..8], "Title");
    @memcpy(tag[93..97], "1999");
    @memcpy(tag[97..105], "A remark");
    tag[126] = 7;
    tag[127] = 8;
    try rig.write("WORK:v1.mp3", &.{ mono_mp3, &tag });
    const stream = openFile(acb, "WORK:v1.mp3", &err) orelse return error.NoStream;
    defer acb.CloseAudioStream(stream);
    const got = attrs(acb, stream);
    try testing.expectEqual(@as(u32, 1999), got.year);
    try testing.expectEqual(@as(u32, 7), got.track);
    try testing.expectEqualStrings("A remark", std.mem.span(got.comment));
    try testing.expectEqualStrings("Jazz", std.mem.span(got.genre));
    try testing.expect(got.picture == null and got.chapter_list == null);
}

// --- FLAC and Ogg Vorbis ----------------------------------------------------------

/// The FLAC files' sound: a triangle on each side (periods of 200 and 237
/// frames) at a quarter of full scale, and the same noise on both from a
/// 32-bit LCG, `bits` wide - brought to 16 bits as the library hands it
/// out.
fn signal(frames: usize, channels: usize, bits: u6, out: []i16) void {
    var state: u32 = 12345;
    const amp: i64 = @as(i64, 1) << (bits - 2);
    for (0..frames) |i| {
        state = state *% 1103515245 +% 12345;
        var noise: i64 = @as(i64, (state >> 16) & 0x7FFF) - 0x4000;
        noise = if (bits < 18) noise >> @intCast(18 - bits) else noise << @intCast(bits - 18);
        for (0..channels) |c| {
            const period: i64 = 200 + 37 * @as(i64, @intCast(c));
            var tri = @divTrunc(@mod(@as(i64, @intCast(i)), period) * 4 * amp, period);
            if (tri > 2 * amp) tri = 4 * amp - tri;
            tri -= amp;
            const sample = tri + noise;
            out[i * channels + c] = @intCast(if (bits >= 16) sample >> @intCast(bits - 16) else sample << @intCast(16 - bits));
        }
    }
}

test "what FLAC and Ogg are, by their first bytes" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit() catch {};
    const acb = rig.acb;

    try testing.expectEqual(ac.ACODEC_FLAC, acb.IdentifyAudio(lossless_flac, lossless_flac.len));
    try testing.expectEqual(ac.ACODEC_VORBIS, acb.IdentifyAudio(lossy_ogg, lossy_ogg.len));
    // FLAC behind an ID3v2 tag of ten bytes' body.
    const tagged = "ID3\x03\x00\x00\x00\x00\x00\x0A" ++ "\x00" ** 10 ++ "fLaC";
    try testing.expectEqual(ac.ACODEC_FLAC, acb.IdentifyAudio(tagged, tagged.len));
    // An Ogg page whose first packet is Opus's: not a kind it knows.
    var opus = lossy_ogg[0..64].*;
    @memcpy(opus[28..36], "OpusHead");
    try testing.expectEqual(ac.ACODEC_UNKNOWN, acb.IdentifyAudio(&opus, opus.len));
}

test "a FLAC through a read function: every sample as coded, its comments, chapters and cover" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit() catch {};
    const acb = rig.acb;

    var memory: Memory = .{ .bytes = lossless_flac, .piece = 777 };
    var err: i32 = 0;
    const stream = acb.OpenAudioStream(&[_]utility.TagItem{
        .{ .tag = ac.ACA_ReadFunc, .data = @intFromPtr(&Memory.read) },
        .{ .tag = ac.ACA_ReadData, .data = @intFromPtr(&memory) },
        .{ .tag = ac.ACA_KeepPicture, .data = 1 },
        .{},
    }, &err) orelse return error.NoStream;
    defer acb.CloseAudioStream(stream);

    var info: ac.AudioStreamInfo = .{};
    acb.GetAudioStreamInfo(stream, &info);
    try testing.expectEqual(ac.ACODEC_FLAC, info.codec);
    try testing.expectEqual(@as(u32, 44100), info.rate);
    try testing.expectEqual(@as(u32, 2), info.channels);
    try testing.expectEqual(@as(u32, 16), info.bits);
    // STREAMINFO says how long it is, read through a function or not.
    try testing.expectEqual(@as(u32, 4500), info.frames);
    try testing.expectEqualStrings("Lossless", textOf(&info.title));
    try testing.expectEqualStrings("PowerOS", textOf(&info.artist));
    try testing.expectEqualStrings("Tests", textOf(&info.album));

    var year: u32 = 0;
    var track: u32 = 0;
    var tracks: u32 = 0;
    var cover: ?*const ac.AudioPicture = null;
    var chapter_count: u32 = 0;
    var chapters: ?[*]const ac.AudioChapter = null;
    _ = acb.GetAudioStreamAttrs(stream, &[_]utility.TagItem{
        .{ .tag = ac.ACA_Year, .data = @intFromPtr(&year) },
        .{ .tag = ac.ACA_Track, .data = @intFromPtr(&track) },
        .{ .tag = ac.ACA_Tracks, .data = @intFromPtr(&tracks) },
        .{ .tag = ac.ACA_Picture, .data = @intFromPtr(&cover) },
        .{ .tag = ac.ACA_Chapters, .data = @intFromPtr(&chapter_count) },
        .{ .tag = ac.ACA_ChapterList, .data = @intFromPtr(&chapters) },
        .{},
    });
    try testing.expectEqual(@as(u32, 2026), year);
    try testing.expectEqual(@as(u32, 4), track);
    try testing.expectEqual(@as(u32, 9), tracks);
    const picture = cover orelse return error.NoCover;
    try testing.expectEqual(ac.ACPIC_FRONTCOVER, picture.kind);
    try testing.expectEqualStrings("image/png", std.mem.sliceTo(&picture.mime, 0));
    try testing.expectEqualStrings("tiny-png-bytes", picture.data[0..picture.size]);
    // Given second first: put in the order they start, each ending where
    // the next begins and the last at the end, 102 ms in.
    try testing.expectEqual(@as(u32, 2), chapter_count);
    const list = chapters orelse return error.NoChapters;
    try testing.expectEqualStrings("First", std.mem.sliceTo(&list[0].title, 0));
    try testing.expectEqual(@as(u32, 0), list[0].start);
    try testing.expectEqual(@as(u32, 50), list[0].end);
    try testing.expectEqualStrings("Second", std.mem.sliceTo(&list[1].title, 0));
    try testing.expectEqual(@as(u32, 50), list[1].start);
    try testing.expectEqual(@as(u32, 102), list[1].end);

    var all: [4500 * 2]i16 = undefined;
    try testing.expectEqual(@as(u32, 4500), try decodeAll(acb, stream, 2, 1999, &all));
    var expected: [4500 * 2]i16 = undefined;
    signal(4500, 2, 16, &expected);
    try testing.expectEqualSlices(i16, &expected, &all);
}

test "FLAC of 8 and of 24 bits: brought to 16" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit() catch {};
    const acb = rig.acb;
    var err: i32 = 0;

    var memory: Memory = .{ .bytes = mono8_flac, .piece = 333 };
    const mono = openMemory(acb, &memory, &err) orelse return error.NoStream;
    var mono_samples: [3000]i16 = undefined;
    try testing.expectEqual(@as(u32, 3000), try decodeAll(acb, mono, 1, 1000, &mono_samples));
    var expected_mono: [3000]i16 = undefined;
    signal(3000, 1, 8, &expected_mono);
    try testing.expectEqualSlices(i16, &expected_mono, &mono_samples);
    acb.CloseAudioStream(mono);

    memory = .{ .bytes = wide24_flac };
    const wide = openMemory(acb, &memory, &err) orelse return error.NoStream;
    var info: ac.AudioStreamInfo = .{};
    acb.GetAudioStreamInfo(wide, &info);
    try testing.expectEqual(@as(u32, 24), info.bits);
    try testing.expectEqual(@as(u32, 48000), info.rate);
    var wide_samples: [2000 * 2]i16 = undefined;
    try testing.expectEqual(@as(u32, 2000), try decodeAll(acb, wide, 2, 500, &wide_samples));
    var expected_wide: [2000 * 2]i16 = undefined;
    signal(2000, 2, 24, &expected_wide);
    try testing.expectEqualSlices(i16, &expected_wide, &wide_samples);
    acb.CloseAudioStream(wide);
}

test "FLAC on a file: an exact seek, with a seek table and without; a damaged frame is silence" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit() catch {};
    const acb = rig.acb;
    var err: i32 = 0;
    var expected: [4500 * 2]i16 = undefined;
    signal(4500, 2, 16, &expected);
    var some: [600 * 2]i16 = undefined;

    try rig.write("WORK:lossless.flac", &.{lossless_flac});
    const stream = openFile(acb, "WORK:lossless.flac", &err) orelse return error.NoStream;
    var info: ac.AudioStreamInfo = .{};
    acb.GetAudioStreamInfo(stream, &info);
    try testing.expectEqual(@as(u32, 1), info.seekable);
    try testing.expect(info.bitrate > 0);
    // Into the second block, then back into the first.
    for ([_]u32{ 4100, 1234 }) |frame| {
        try testing.expectEqual(ac.ACERR_OK, acb.SeekAudio(stream, frame));
        try testing.expectEqual(@as(i32, 300), acb.DecodeAudio(stream, &some, 300));
        try testing.expectEqualSlices(i16, expected[frame * 2 ..][0 .. 300 * 2], some[0 .. 300 * 2]);
    }
    // Past the end: nothing more.
    try testing.expectEqual(ac.ACERR_OK, acb.SeekAudio(stream, 9999));
    try testing.expectEqual(@as(i32, 0), acb.DecodeAudio(stream, &some, 300));
    acb.CloseAudioStream(stream);

    try rig.write("WORK:mono8.flac", &.{mono8_flac});
    const mono = openFile(acb, "WORK:mono8.flac", &err) orelse return error.NoStream;
    var expected_mono: [3000]i16 = undefined;
    signal(3000, 1, 8, &expected_mono);
    try testing.expectEqual(ac.ACERR_OK, acb.SeekAudio(mono, 2500));
    try testing.expectEqual(@as(i32, 500), acb.DecodeAudio(mono, &some, 600));
    try testing.expectEqualSlices(i16, expected_mono[2500..3000], some[0..500]);
    acb.CloseAudioStream(mono);

    // The last frame's CRC changed - the file's last byte: that frame is
    // silent, and the frame before it is as it was.
    var damaged = lossless_flac.*;
    damaged[damaged.len - 1] ^= 0x5A;
    var memory: Memory = .{ .bytes = &damaged };
    const broken = openMemory(acb, &memory, &err) orelse return error.NoStream;
    var all: [4500 * 2]i16 = undefined;
    try testing.expectEqual(@as(u32, 4500), try decodeAll(acb, broken, 2, 1999, &all));
    try testing.expectEqualSlices(i16, expected[0 .. 4096 * 2], all[0 .. 4096 * 2]);
    for (all[4096 * 2 ..]) |sample| try testing.expectEqual(@as(i16, 0), sample);
    acb.CloseAudioStream(broken);
}

test "FLAC the library does not decode is refused with why" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit() catch {};
    const acb = rig.acb;
    var err: i32 = 0;

    // Three channels.
    var three = lossless_flac[0..64].*;
    three[8 + 12] = (three[8 + 12] & 0xF1) | (2 << 1);
    var memory: Memory = .{ .bytes = &three };
    try testing.expect(openMemory(acb, &memory, &err) == null);
    try testing.expectEqual(ac.ACERR_UNSUPPORTED, err);

    // FLAC carried in Ogg.
    var page = lossy_ogg[0..64].*;
    @memcpy(page[28..33], "\x7FFLAC");
    memory = .{ .bytes = &page };
    try testing.expect(openMemory(acb, &memory, &err) == null);
    try testing.expectEqual(ac.ACERR_UNSUPPORTED, err);
}

test "Ogg Vorbis through a read function: within a step of libvorbis, to the exact length" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit() catch {};
    const acb = rig.acb;
    var err: i32 = 0;

    var memory: Memory = .{ .bytes = lossy_ogg, .piece = 501 };
    const stream = openMemory(acb, &memory, &err) orelse return error.NoStream;
    var info: ac.AudioStreamInfo = .{};
    acb.GetAudioStreamInfo(stream, &info);
    try testing.expectEqual(ac.ACODEC_VORBIS, info.codec);
    try testing.expectEqual(@as(u32, 44100), info.rate);
    try testing.expectEqual(@as(u32, 2), info.channels);
    // Its last page is not looked for through a function.
    try testing.expectEqual(@as(u32, 0), info.frames);
    try testing.expectEqual(@as(u32, 0), info.seekable);
    try testing.expect(info.bitrate > 0);
    try testing.expectEqualStrings("Lossy", textOf(&info.title));

    var head: [1024 * 2]i16 = undefined;
    // The last page cuts the end where the sound stopped.
    try testing.expectEqual(@as(u32, 4500), try decodeAll(acb, stream, 2, 999, &head));
    const reference: []align(1) const i16 = std.mem.bytesAsSlice(i16, lossy_head);
    for (head, reference) |ours, theirs| {
        try testing.expect(@abs(@as(i32, ours) - theirs) <= 1);
    }
    try testing.expectEqual(ac.ACERR_NOSEEK, acb.SeekAudio(stream, 0));
    acb.CloseAudioStream(stream);

    memory = .{ .bytes = mono_ogg, .piece = 4000 };
    const mono = openMemory(acb, &memory, &err) orelse return error.NoStream;
    acb.GetAudioStreamInfo(mono, &info);
    try testing.expectEqual(@as(u32, 22050), info.rate);
    try testing.expectEqual(@as(u32, 1), info.channels);
    try testing.expectEqual(@as(u32, 2250), try decodeAll(acb, mono, 1, 2000, &.{}));
    acb.CloseAudioStream(mono);
}

test "Ogg Vorbis on a file: its length from its last page, and exact seeks" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit() catch {};
    const acb = rig.acb;
    var err: i32 = 0;

    try rig.write("WORK:lossy.ogg", &.{lossy_ogg});
    const stream = openFile(acb, "WORK:lossy.ogg", &err) orelse return error.NoStream;
    defer acb.CloseAudioStream(stream);
    var info: ac.AudioStreamInfo = .{};
    acb.GetAudioStreamInfo(stream, &info);
    try testing.expectEqual(@as(u32, 1), info.seekable);
    try testing.expectEqual(@as(u32, 4500), info.frames);

    var straight: [4500 * 2]i16 = undefined;
    try testing.expectEqual(@as(u32, 4500), try decodeAll(acb, stream, 2, 1999, &straight));
    // A seek lands on the very sample decoding straight through gives;
    // back to the start, the start again.
    var some: [400 * 2]i16 = undefined;
    for ([_]u32{ 3000, 77, 0, 4400 }) |frame| {
        try testing.expectEqual(ac.ACERR_OK, acb.SeekAudio(stream, frame));
        const want: i32 = @intCast(@min(400, 4500 - frame));
        try testing.expectEqual(want, acb.DecodeAudio(stream, &some, 400));
        const count: usize = @intCast(want * 2);
        try testing.expectEqualSlices(i16, straight[frame * 2 ..][0..count], some[0..count]);
    }
}
