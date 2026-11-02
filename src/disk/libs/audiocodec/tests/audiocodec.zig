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
//! in mono, 2250 frames, with no names. Their serials differ, so the two
//! one after the other are a chain of two links.
//!
//! The AAC files are a second of a stereo signal - two gliding tones, high
//! partials alike on both sides, a click in the middle, noise in the
//! second half - coded by ffmpeg's encoder (AAC-LC; M/S, intensity
//! stereo, PNS and TNS all on): `lossy.m4a` at 128 kbit/s and 44.1 kHz,
//! its index in front, with iTunes's tags and a PNG cover; `low.aac` the
//! first 0.6 s at 48 kHz in ADTS at 40 kbit/s; `mono.aac` the same second
//! in mono at 22.05 kHz in ADTS. The `_ref.raw` files are ffmpeg's
//! decoding of them: frames 0 and 21504 of lossy.m4a (the edit applied),
//! 0 and 20480 of low.aac, 0 of mono.aac, 2048 each.
//!
//! The `.mka` files are Matroska, remuxed by ffmpeg with no tags:
//! `lossless.mka` lossless.flac's frames and its two chapters;
//! `vorbis.mka` lossy.ogg's packets, its length set to 102 ms (ffmpeg
//! wrote 27 hours); `tone.mka` tone.mp3's frames without its Info frame,
//! so the encoder's delay is sound; `aac.mka` lossy.m4a's packets, the
//! priming its CodecDelay. `layer2.mka` is 50 ms of MPEG audio layer II,
//! `opus.mka` 50 ms of stereo Opus, `opus_mka_ref.raw` its frames as
//! libopus decodes them (through ffmpeg).
//!
//! The DTS files are in the DTS section; ffmpeg's encoder made them, but
//! `syntax.dts`, whose frames a script of random numbers made.
//!
//! The Opus files are coded by libopus through ffmpeg: `stereo.opus` a
//! second of two gliding tones, a click, a high tone and noise, at
//! 64 kbit/s, titled "Opus Tone" by "PowerOS"; `voice.opus` half a second
//! of a voice-like hum in mono at 12 kbit/s for speech (SILK) - both in
//! pages of 100 ms;
//! `six.opus` 0.3 s of six quiet tones in 5.1 (mapping family 1);
//! `voice.mp4` voice.opus's packets in an MP4, its pre-skip the edit's
//! start. `stereo_ref.raw` holds frames 0 and 30000 of stereo.opus as
//! libopus decodes them, 2048 each; `voice_ref.raw` frames 0 and 12000 of
//! voice.opus; `six_opus_ref.raw` frames 0 and 8000 of six.opus's channels as
//! libopus decodes them in float, mixed as audiocodec mixes them and
//! rounded.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const ac = sdk.audiocodec;
const acodec = sdk.acodec;
const loadfile = dos.loadfile;
const modtable = dos.modtable;
const sound_table = @import("../modules/_modules.zig");
const utility = sdk.utility;
const host = @import("host_rom");
const kexec = host.exec;
const audiocodec_init = @import("../audiocodec_init.zig");
const sound_modules = @import("modules.zig");
const Bits = @import("../aac/bits.zig").Bits;
const media_init = @import("../../media/media_init.zig");
const container_modules = @import("../../media/tests/modules.zig");
const media = sdk.media;

const testing = std.testing;
const DosBase = sdk.interface.dos.DosBase;
const AudioCodecBase = sdk.interface.audiocodec.AudioCodecBase;

test {
    _ = @import("../audiocodec_lvo.zig");
    _ = @import("../aac/bits.zig");
    _ = @import("../aac/huffman.zig");
    _ = @import("../aac/ics.zig");
    _ = @import("../aac/filterbank.zig");
    _ = @import("../aac/config.zig");
    _ = @import("../ac3/header.zig");
    _ = @import("../ac3/frame.zig");
    _ = @import("../dts/header.zig");
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
const chain_ogg = lossy_ogg.* ++ mono_ogg.*;

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
    media_library: *exec.Library = undefined,
    modules: sound_modules.Made = undefined,
    containers: container_modules.Made = undefined,
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
        // media.library, which an MP4 is opened through.
        const media_lib = kexec.InitResident(kexec.SysBase, &media_init.media_library_tag, null) orelse return error.NoLibrary;
        rig.media_library = @ptrCast(@alignCast(media_lib));
        try sound_modules.make(kexec, &rig.modules);
        try container_modules.make(kexec, &rig.containers);
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
        _ = rig.sysLib().RemLibrary(rig.media_library);
        sound_modules.take(rig.sysLib(), &rig.modules);
        container_modules.take(rig.sysLib(), &rig.containers);
        try testing.expect(kexec.FindName(kexec.SysBase, &kexec.SysBase.lib_list, media.MEDIANAME) == null);
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

/// A sound module's load file, as one is on a disk: a header, one data
/// segment, and a library tag in it with ACODEC_MAGIC and its words after
/// the Resident. The layout is a 32-bit file's, which is what
/// videocodec's own tag test writes.
fn acodecFile(into: []u8, name: []const u8, id: []const u8, codecs: u32, kind: u32, priority: i32) void {
    @memset(into, 0);
    @memcpy(into[0..4], &loadfile.MAGIC);
    std.mem.writeInt(u16, into[4..6], loadfile.VERSION, .little);
    std.mem.writeInt(u16, into[6..8], 1, .little);
    std.mem.writeInt(u16, into[10..12], loadfile.native_machine, .little);
    into[16] = 4;
    into[20] = @intFromEnum(loadfile.SegmentKind.data);
    put32(into, 24, 160);
    put32(into, 28, 160);
    const seg = 36;
    const tag = seg + 32;
    std.mem.writeInt(u16, into[tag..][0..2], 0x4AFC, .little);
    put32(into, tag + 4, 32);
    into[tag + 12] = exec.RTF_AUTOINIT;
    into[tag + 13] = 1;
    into[tag + 14] = @intFromEnum(exec.NodeType.library);
    put32(into, tag + 16, 96);
    put32(into, tag + 20, 112);
    put32(into, tag + 28, acodec.ACODEC_MAGIC);
    put32(into, tag + 32, codecs);
    put32(into, tag + 36, kind);
    put32(into, tag + 40, @bitCast(priority));
    @memcpy(into[seg + 96 ..][0..name.len], name);
    @memcpy(into[seg + 112 ..][0..id.len], id);
}

fn put32(into: []u8, at: usize, value: u32) void {
    std.mem.writeInt(u32, into[at..][0..4], value, .little);
}

test "the modules of a directory, found by the tag in each file: what they decode, and not read again while their files are as they were" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit() catch {};
    const dl = rig.dosLib();

    // A directory of modules, as LIBS:codecs/ is: two that are sound
    // modules, one named otherwise inside than its file (ramlib would not
    // load it by that name), one whose suffix is another kind's, and one
    // that is no load file at all.
    // CreateDir hands back a lock of its own, and it is an exclusive one:
    // let it go, or nothing can look in the directory afterwards.
    dl.UnLock(dl.CreateDir("WORK:codecs") orelse return error.NoDirectory);
    var file: [20 + 16 + 160]u8 = undefined;
    acodecFile(&file, "one.acodec\x00", "one.acodec 1.3 (02.11.2026)\x00", 0b110, acodec.ACMOD_SOFTWARE, -2);
    try rig.write("WORK:codecs/one.acodec", &.{&file});
    acodecFile(&file, "two.acodec\x00", "two.acodec 2.0 (02.11.2026)\x00", 0b1000, acodec.ACMOD_CHIP, 5);
    try rig.write("WORK:codecs/two.acodec", &.{&file});
    acodecFile(&file, "elsewhere.acodec\x00", "elsewhere.acodec 1.0 (02.11.2026)\x00", 0b1, acodec.ACMOD_SOFTWARE, 0);
    try rig.write("WORK:codecs/three.acodec", &.{&file});
    acodecFile(&file, "four.container\x00", "four.container 1.0 (02.11.2026)\x00", 0b1, acodec.ACMOD_SOFTWARE, 0);
    try rig.write("WORK:codecs/four.container", &.{&file});
    try rig.write("WORK:codecs/five.acodec", &.{"not a load file at all"});

    const looking: modtable.Kind = .{
        .dir = "WORK:codecs",
        .prefix = "codecs/",
        .suffix = ".acodec",
        .magic = acodec.ACODEC_MAGIC,
        .words = 3,
    };
    var table: [8]modtable.Found = @splat(.{});
    var none: [0]modtable.Found = .{};
    const count = modtable.scan(dl, looking, &table, &none);
    try testing.expectEqual(@as(u32, 2), count);

    // Each is named as OpenLibrary is given it, and its words are its
    // tag's. The order is the directory's, so they are looked for by name.
    var seen_one = false;
    var seen_two = false;
    for (table[0..count]) |*found| {
        const name = std.mem.sliceTo(&found.name, 0);
        if (std.mem.eql(u8, name, "codecs/one.acodec")) {
            seen_one = true;
            try testing.expectEqual(@as(u32, 0b110), sound_table.codecsOf(found));
            try testing.expectEqual(acodec.ACMOD_SOFTWARE, sound_table.kindOf(found));
            try testing.expectEqual(@as(i32, -2), sound_table.priorityOf(found));
            try testing.expectEqual(@as(u8, 1), found.version);
            try testing.expectEqual(@as(u16, 3), found.revision);
        } else if (std.mem.eql(u8, name, "codecs/two.acodec")) {
            seen_two = true;
            try testing.expectEqual(@as(u32, 0b1000), sound_table.codecsOf(found));
            try testing.expectEqual(acodec.ACMOD_CHIP, sound_table.kindOf(found));
            try testing.expectEqual(@as(i32, 5), sound_table.priorityOf(found));
            try testing.expectEqual(@as(u16, 0), found.revision);
        } else {
            std.debug.panic("a module that should not be there: {s}", .{name});
        }
    }
    try testing.expect(seen_one and seen_two);

    // Read again with the first table as what is known: the same answer,
    // and this time out of it - the files have not changed.
    var again: [8]modtable.Found = @splat(.{});
    try testing.expectEqual(@as(u32, 2), modtable.scan(dl, looking, &again, table[0..count]));
    for (again[0..2]) |*found| {
        const was = modtable.known(table[0..count], &found.name, found.date, found.size);
        try testing.expect(was != null);
        try testing.expectEqual(sound_table.codecsOf(found), sound_table.codecsOf(&was.?));
    }

    // A file put in place of a module is read again: its size differs, so
    // what was known of it is not taken.
    acodecFile(&file, "one.acodec\x00", "one.acodec 9.9 (02.11.2026)\x00", 0b1_0000, acodec.ACMOD_SOFTWARE, 7);
    try rig.write("WORK:codecs/one.acodec", &.{ &file, "a tail, so the size differs" });
    var third: [8]modtable.Found = @splat(.{});
    try testing.expectEqual(@as(u32, 2), modtable.scan(dl, looking, &third, again[0..2]));
    for (third[0..2]) |*found| {
        if (!std.mem.eql(u8, std.mem.sliceTo(&found.name, 0), "codecs/one.acodec")) continue;
        try testing.expectEqual(@as(u32, 0b1_0000), sound_table.codecsOf(found));
        try testing.expectEqual(@as(i32, 7), sound_table.priorityOf(found));
        try testing.expectEqual(@as(u16, 9), found.revision);
    }
}

test "ACA_Codecs: the kinds whose modules are here, with no stream and with one" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit() catch {};
    const acb = rig.acb;

    // The host test makes every module under the name ramlib would find
    // it by (tests/modules.zig), so every kind this library knows is
    // here. A board whose disk holds fewer answers with fewer: that is
    // the point of the tag, and what its version cannot say.
    var kinds: u32 = 0;
    try testing.expectEqual(@as(u32, 1), acb.GetAudioStreamAttrs(null, &[_]utility.TagItem{
        .{ .tag = ac.ACA_Codecs, .data = @intFromPtr(&kinds) },
        .{},
    }));
    const every = [_]u32{
        ac.ACODEC_WAV,  ac.ACODEC_MP3,  ac.ACODEC_FLAC, ac.ACODEC_VORBIS,
        ac.ACODEC_AAC,  ac.ACODEC_AC3,  ac.ACODEC_EAC3, ac.ACODEC_OPUS,
        ac.ACODEC_DTS,
    };
    var wanted: u32 = 0;
    for (every) |kind| wanted |= @as(u32, 1) << @intCast(kind);
    try testing.expectEqual(wanted, kinds);
    // Nothing is said of a kind that is no kind.
    try testing.expectEqual(@as(u32, 0), kinds & 1);

    // A stream's tags asked with no stream are left as they were and not
    // counted; the library's own is answered all the same.
    var title: [*:0]const u8 = "untouched";
    kinds = 0;
    try testing.expectEqual(@as(u32, 1), acb.GetAudioStreamAttrs(null, &[_]utility.TagItem{
        .{ .tag = ac.ACA_Title, .data = @intFromPtr(&title) },
        .{ .tag = ac.ACA_Codecs, .data = @intFromPtr(&kinds) },
        .{},
    }));
    try testing.expectEqualStrings("untouched", std.mem.span(title));
    try testing.expectEqual(wanted, kinds);

    // With a stream the one answer is the same, beside the stream's own.
    const data = stereo16(16);
    var b: Builder = .{};
    wavFile(&b, 1, 2, 16, "Name", &data);
    try rig.write("WORK:kinds.wav", &.{b.slice()});
    var err: i32 = -99;
    const stream = openFile(acb, "WORK:kinds.wav", &err) orelse return error.NoStream;
    defer acb.CloseAudioStream(stream);
    var with: u32 = 0;
    var name: [*:0]const u8 = "";
    try testing.expectEqual(@as(u32, 2), acb.GetAudioStreamAttrs(stream, &[_]utility.TagItem{
        .{ .tag = ac.ACA_Codecs, .data = @intFromPtr(&with) },
        .{ .tag = ac.ACA_Title, .data = @intFromPtr(&name) },
        .{},
    }));
    try testing.expectEqual(wanted, with);
    try testing.expectEqualStrings("Name", std.mem.span(name));
}

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

/// A WAV's header and then silence, `total` bytes in all, handed over in
/// pieces of 1000 at most; how far it has been read.
const Silence = struct {
    header: []const u8,
    total: usize,
    at: usize = 0,

    fn read(data: ?*anyopaque, buffer: [*]u8, length: u32) callconv(.c) i32 {
        const source: *Silence = @ptrCast(@alignCast(data.?));
        const count = @min(@as(usize, length), 1000, source.total - source.at);
        for (buffer[0..count], source.at..) |*byte, at| byte.* = if (at < source.header.len) source.header[at] else 0;
        source.at += count;
        return @intCast(count);
    }
};

test "a read function is asked for no more than AUDIO_READ_AHEAD past what was used" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit() catch {};
    const acb = rig.acb;

    // A WAV that says it holds 50000 frames, 16-bit stereo, whose data
    // is not in the builder: the read function hands it out.
    const frames = 50_000;
    var b: Builder = .{};
    wavFile(&b, 1, 2, 16, "", &.{});
    std.mem.writeInt(u32, b.bytes[4..8], @intCast(b.len - 8 + frames * 4), .little);
    std.mem.writeInt(u32, b.bytes[b.len - 4 ..][0..4], frames * 4, .little);
    var source: Silence = .{ .header = b.slice(), .total = b.len + frames * 4 };
    var err: i32 = 0;
    const stream = acb.OpenAudioStream(&[_]utility.TagItem{
        .{ .tag = ac.ACA_ReadFunc, .data = @intFromPtr(&Silence.read) },
        .{ .tag = ac.ACA_ReadData, .data = @intFromPtr(&source) },
        .{},
    }, &err) orelse return error.NoStream;
    defer acb.CloseAudioStream(stream);
    try testing.expect(source.at <= b.len + ac.AUDIO_READ_AHEAD);

    var buffer: [4096 * 2]i16 = undefined;
    var decoded: usize = 0;
    while (decoded < 30_000) {
        const got = acb.DecodeAudio(stream, &buffer, 4096);
        try testing.expect(got > 0);
        decoded += @intCast(got);
        try testing.expect(source.at <= b.len + decoded * 4 + ac.AUDIO_READ_AHEAD);
    }
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

test "two modules for one kind: the one that refuses gives way to the next, which is read the sound again" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit() catch {};
    const acb = rig.acb;
    // refuse.acodec claims WAV above wav.acodec and takes nothing.
    try sound_modules.addRefuser(kexec);
    defer sound_modules.dropRefuser(rig.sysLib());

    const data = stereo16(200);
    var b: Builder = .{};
    wavFile(&b, 1, 2, 16, "Twice", &data);
    try rig.write("WORK:two.wav", &.{b.slice()});

    var err: i32 = -99;
    const stream = openFile(acb, "WORK:two.wav", &err) orelse return error.NoStream;
    try testing.expectEqual(ac.ACERR_OK, err);
    // It was tried first, and the sound is wav.acodec's all the same: the
    // bytes the one before it read were read again for it.
    try testing.expectEqual(@as(u32, 1), sound_modules.refused());
    var info: ac.AudioStreamInfo = .{};
    acb.GetAudioStreamInfo(stream, &info);
    try testing.expectEqual(ac.ACODEC_WAV, info.codec);
    try testing.expectEqual(@as(u32, 200), info.frames);
    try testing.expectEqualStrings("Twice", textOf(&info.title));
    var all: [200 * 2]i16 = undefined;
    try testing.expectEqual(@as(u32, 200), try decodeAll(acb, stream, 2, 64, &all));
    try testing.expectEqual(@as(i16, 199 * 7), all[199 * 2]);
    try testing.expectEqual(@as(i16, -199 * 5), all[199 * 2 + 1]);
    acb.CloseAudioStream(stream);

    // Sound read through a function cannot be read again: the refusal of
    // the module that read it stands.
    var memory: Memory = .{ .bytes = b.slice() };
    try testing.expect(openMemory(acb, &memory, &err) == null);
    try testing.expectEqual(ac.ACERR_UNSUPPORTED, err);
    try testing.expectEqual(@as(u32, 2), sound_modules.refused());
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

    // Back to its start: the encoder's delay left out again, every frame
    // there, the first as another decoder makes them.
    try testing.expectEqual(ac.ACERR_OK, acb.SeekAudio(tone, 0));
    var head: [1024 * 2]i16 = undefined;
    try testing.expectEqual(@as(u32, tone_frames), try decodeAll(acb, tone, 2, 1000, &head));
    const reference: []align(1) const i16 = std.mem.bytesAsSlice(i16, tone_head);
    for (head, reference) |ours, theirs| {
        try testing.expect(@abs(@as(i32, ours) - theirs) <= 1);
    }
    acb.CloseAudioStream(tone);
}

test "a stream opened by one process is decoded, moved and closed by another" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit() catch {};
    const acb = rig.acb;
    var err: i32 = 0;
    try rig.write("WORK:tone.mp3", &.{tone_mp3});
    const tone = openFile(acb, "WORK:tone.mp3", &err) orelse return error.NoStream;

    // The other process, with WORK: behind it as well.
    var other: dos.Process = .{};
    other.task.node.name = "other process";
    host.dos_process.initMsgPort(&other);
    other.pkt_wait = &Disk.wait;
    kexec.SysBase.cpu().this_task = &other.task;
    defer kexec.SysBase.cpu().this_task = &rig.proc.task;

    var head: [1024 * 2]i16 = undefined;
    try testing.expectEqual(@as(u32, tone_frames), try decodeAll(acb, tone, 2, 1000, &head));
    try testing.expectEqual(ac.ACERR_OK, acb.SeekAudio(tone, 0));
    try testing.expectEqual(@as(u32, tone_frames), try decodeAll(acb, tone, 2, 1000, &.{}));
    acb.CloseAudioStream(tone);
    const reference: []align(1) const i16 = std.mem.bytesAsSlice(i16, tone_head);
    for (head, reference) |ours, theirs| {
        try testing.expect(@abs(@as(i32, ours) - theirs) <= 1);
    }
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
    // An Ogg page whose first packet is Opus's (SINCE 1.9).
    var opus = lossy_ogg[0..64].*;
    @memcpy(opus[28..36], "OpusHead");
    try testing.expectEqual(ac.ACODEC_OPUS, acb.IdentifyAudio(&opus, opus.len));
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

/// The link of a chain being decoded.
fn linkOf(acb: *AudioCodecBase, stream: *ac.AudioStream) u32 {
    var link: u32 = 99;
    _ = acb.GetAudioStreamAttrs(stream, &[_]utility.TagItem{
        .{ .tag = ac.ACA_Link, .data = @intFromPtr(&link) },
        .{},
    });
    return link;
}

/// The frames of the link being decoded, in pieces of `piece`, up to the
/// call that hands out fewer - its last: how many, the first of them into
/// `into`.
fn decodeLink(acb: *AudioCodecBase, stream: *ac.AudioStream, channels: u32, piece: u32, into: []i16) !u32 {
    var buffer: [2000 * 2]i16 = undefined;
    var total: u32 = 0;
    while (true) {
        const got = acb.DecodeAudio(stream, &buffer, piece);
        try testing.expect(got > 0);
        const samples: usize = @as(usize, @intCast(got)) * channels;
        const at: usize = @as(usize, total) * channels;
        if (at < into.len) {
            const fits = @min(samples, into.len - at);
            @memcpy(into[at..][0..fits], buffer[0..fits]);
        }
        total += @intCast(got);
        if (got < piece) return total;
    }
}

/// An Ogg page's CRC, its own four bytes as zeros.
fn oggCrc(page: []const u8) u32 {
    var crc: u32 = 0;
    for (page, 0..) |byte, i| {
        crc ^= @as(u32, if (i >= 22 and i < 26) 0 else byte) << 24;
        for (0..8) |_| crc = if (crc & 0x8000_0000 != 0) (crc << 1) ^ 0x04C1_1DB7 else crc << 1;
    }
    return crc;
}

test "a chained Ogg stream: link after link, each with its own rate, channels and tags" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit() catch {};
    const acb = rig.acb;
    var err: i32 = 0;

    // The second link alone, to hold it against.
    var alone: [2250]i16 = undefined;
    var memory: Memory = .{ .bytes = mono_ogg, .piece = 4000 };
    const mono = openMemory(acb, &memory, &err) orelse return error.NoStream;
    try testing.expectEqual(@as(u32, 2250), try decodeAll(acb, mono, 1, 2000, &alone));
    acb.CloseAudioStream(mono);

    memory = .{ .bytes = &chain_ogg, .piece = 501 };
    const stream = openMemory(acb, &memory, &err) orelse return error.NoStream;
    defer acb.CloseAudioStream(stream);
    var info: ac.AudioStreamInfo = .{};
    acb.GetAudioStreamInfo(stream, &info);
    try testing.expectEqual(@as(u32, 44100), info.rate);
    try testing.expectEqual(@as(u32, 2), info.channels);
    try testing.expectEqualStrings("Lossy", textOf(&info.title));
    try testing.expectEqual(@as(u32, 0), linkOf(acb, stream));

    // The first link to its last frame, which a call of fewer hands out:
    // still the first link then.
    try testing.expectEqual(@as(u32, 4500), try decodeLink(acb, stream, 2, 999, &.{}));
    try testing.expectEqual(@as(u32, 0), linkOf(acb, stream));
    acb.GetAudioStreamInfo(stream, &info);
    try testing.expectEqual(@as(u32, 44100), info.rate);

    // The calls after it: the second link, as it decodes alone - its rate,
    // one channel, and none of the first's names.
    var later: [2250]i16 = undefined;
    try testing.expectEqual(@as(u32, 2250), try decodeAll(acb, stream, 1, 999, &later));
    try testing.expectEqualSlices(i16, &alone, &later);
    try testing.expectEqual(@as(u32, 1), linkOf(acb, stream));
    acb.GetAudioStreamInfo(stream, &info);
    try testing.expectEqual(@as(u32, 22050), info.rate);
    try testing.expectEqual(@as(u32, 1), info.channels);
    try testing.expectEqualStrings("", textOf(&info.title));
    var artist: [*:0]const u8 = "unread";
    _ = acb.GetAudioStreamAttrs(stream, &[_]utility.TagItem{
        .{ .tag = ac.ACA_Artist, .data = @intFromPtr(&artist) },
        .{},
    });
    try testing.expectEqualStrings("", std.mem.span(artist));
    var buffer: [16]i16 = undefined;
    try testing.expectEqual(@as(i32, 0), acb.DecodeAudio(stream, &buffer, 8));
}

test "a chained Ogg file: each link measured, a seek within the link being played" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit() catch {};
    const acb = rig.acb;
    var err: i32 = 0;

    try rig.write("WORK:chain.ogg", &.{ lossy_ogg, mono_ogg });
    const stream = openFile(acb, "WORK:chain.ogg", &err) orelse return error.NoStream;
    defer acb.CloseAudioStream(stream);
    var info: ac.AudioStreamInfo = .{};
    acb.GetAudioStreamInfo(stream, &info);
    // The first link's length, though the file's last page is the second's.
    try testing.expectEqual(@as(u32, 4500), info.frames);

    var first: [4500 * 2]i16 = undefined;
    try testing.expectEqual(@as(u32, 4500), try decodeLink(acb, stream, 2, 1999, &first));
    var some: [400 * 2]i16 = undefined;
    try testing.expectEqual(ac.ACERR_OK, acb.SeekAudio(stream, 3000));
    try testing.expectEqual(@as(i32, 400), acb.DecodeAudio(stream, &some, 400));
    try testing.expectEqualSlices(i16, first[3000 * 2 ..][0 .. 400 * 2], &some);
    try testing.expectEqual(@as(u32, 1100), try decodeLink(acb, stream, 2, 1999, &.{}));

    // The second link: measured as it begins, sought in from its own start.
    var second: [2250]i16 = undefined;
    try testing.expectEqual(@as(u32, 2250), try decodeLink(acb, stream, 1, 1999, &second));
    try testing.expectEqual(@as(u32, 1), linkOf(acb, stream));
    acb.GetAudioStreamInfo(stream, &info);
    try testing.expectEqual(@as(u32, 2250), info.frames);
    try testing.expectEqual(@as(u32, 22050), info.rate);
    for ([_]u32{ 1000, 0 }) |frame| {
        try testing.expectEqual(ac.ACERR_OK, acb.SeekAudio(stream, frame));
        try testing.expectEqual(@as(i32, 400), acb.DecodeAudio(stream, &some, 400));
        try testing.expectEqualSlices(i16, second[frame..][0..400], some[0..400]);
    }
    try testing.expectEqual(@as(u32, 1), linkOf(acb, stream));
}

test "a link cut short - no page ends it - ends where the next link begins" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit() catch {};
    const acb = rig.acb;
    var err: i32 = 0;

    // The first link's last page without its flag that ends the stream.
    var cut = chain_ogg;
    const last_page = 4029;
    cut[last_page + 5] &= ~@as(u8, 0x04);
    const length = 27 + 13 + 1391;
    std.mem.writeInt(u32, cut[last_page + 22 ..][0..4], oggCrc(cut[last_page..][0..length]), .little);

    var memory: Memory = .{ .bytes = &cut, .piece = 700 };
    const stream = openMemory(acb, &memory, &err) orelse return error.NoStream;
    defer acb.CloseAudioStream(stream);
    // Not cut where the sound stops, as no page says the stream ends.
    try testing.expect(try decodeLink(acb, stream, 2, 1999, &.{}) >= 4500);
    try testing.expectEqual(@as(u32, 0), linkOf(acb, stream));
    try testing.expectEqual(@as(u32, 2250), try decodeAll(acb, stream, 1, 1999, &.{}));
    try testing.expectEqual(@as(u32, 1), linkOf(acb, stream));
}

// --- AAC --------------------------------------------------------------------------

const lossy_m4a = @embedFile("lossy.m4a");
const lossy_m4a_ref = @embedFile("lossy_ref.raw");
const low_aac = @embedFile("low.aac");
const low_aac_ref = @embedFile("low_ref.raw");
const mono_aac = @embedFile("mono.aac");
const mono_aac_ref = @embedFile("mono_ref.raw");
const tail_m4a = @embedFile("../../media/tests/tail.m4a");
const lossless_mka = @embedFile("lossless.mka");
const vorbis_mka = @embedFile("vorbis.mka");
const tone_mka = @embedFile("tone.mka");
const aac_mka = @embedFile("aac.mka");
const layer2_mka = @embedFile("layer2.mka");
const opus_mka = @embedFile("opus.mka");
const film_mkv = @embedFile("../../media/tests/film.mkv");
/// film.mkv with its sound 100 ms late: its first block at 100 ms.
const late_mkv = @embedFile("late.mkv");
/// film.mkv with a hole in its sound: the blocks from 400 ms on 50 ms
/// later.
const hole_mkv = @embedFile("hole.mkv");

/// Frames `count` long from frame `from` of `ours`, within a step of
/// ffmpeg's frames from frame `at` of `reference`.
fn expectNear(ours: []const i16, from: usize, reference: []const u8, at: usize, count: usize, channels: usize) !void {
    const theirs: []align(1) const i16 = std.mem.bytesAsSlice(i16, reference);
    for (0..count * channels) |i| {
        const a: i32 = ours[from * channels + i];
        const b: i32 = theirs[at * channels + i];
        if (@abs(a - b) > 1) {
            std.debug.print("sample {d}: {d}, ffmpeg {d}\n", .{ i, a, b });
            return error.TestExpectedNear;
        }
    }
}

test "what AAC is, by its first bytes: an MP4, ADTS frames, ADTS behind an ID3v2 tag" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit() catch {};
    const acb = rig.acb;
    try testing.expectEqual(ac.ACODEC_AAC, acb.IdentifyAudio(lossy_m4a, ac.AUDIO_IDENTIFY_BYTES));
    try testing.expectEqual(ac.ACODEC_AAC, acb.IdentifyAudio(low_aac, ac.AUDIO_IDENTIFY_BYTES));
    const t = &id3_tag;
    t.* = .{ .version = 3 };
    t.frame("TIT2", 0, "\x00Mono");
    try testing.expectEqual(ac.ACODEC_AAC, acb.IdentifyAudio(t.finish(0, mono_aac[0..4096]).ptr, ac.AUDIO_IDENTIFY_BYTES));
    // An MP3 is none.
    try testing.expectEqual(ac.ACODEC_MP3, acb.IdentifyAudio(tone_mp3, ac.AUDIO_IDENTIFY_BYTES));
}

test "AAC in an MP4 by name: ffmpeg's samples to the exact length, the tags and the cover, exact seeks" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit() catch {};
    const acb = rig.acb;
    var err: i32 = 0;

    try rig.write("WORK:lossy.m4a", &.{lossy_m4a});
    const stream = acb.OpenAudioStream(&[_]utility.TagItem{
        .{ .tag = ac.ACA_Name, .data = @intFromPtr("WORK:lossy.m4a") },
        .{ .tag = ac.ACA_KeepPicture, .data = 1 },
        .{},
    }, &err) orelse return error.NoStream;
    defer acb.CloseAudioStream(stream);
    var info: ac.AudioStreamInfo = .{};
    acb.GetAudioStreamInfo(stream, &info);
    try testing.expectEqual(ac.ACODEC_AAC, info.codec);
    try testing.expectEqual(@as(u32, 44100), info.rate);
    try testing.expectEqual(@as(u32, 2), info.channels);
    try testing.expectEqual(@as(u32, 16), info.bits);
    // The edit leaves out the encoder's 1024 frames of priming.
    try testing.expectEqual(@as(u32, 44100), info.frames);
    try testing.expectEqual(@as(u32, 1), info.seekable);
    try testing.expect(info.bitrate > 100_000 and info.bitrate < 160_000);
    try testing.expectEqualStrings("Lossy", textOf(&info.title));
    try testing.expectEqualStrings("The Testers", textOf(&info.artist));
    try testing.expectEqualStrings("Small Songs", textOf(&info.album));

    var album_artist: [*:0]const u8 = "";
    var composer: [*:0]const u8 = "";
    var genre: [*:0]const u8 = "";
    var comment: [*:0]const u8 = "";
    var year: u32 = 0;
    var track: u32 = 0;
    var tracks: u32 = 0;
    var cover: ?*const ac.AudioPicture = null;
    try testing.expectEqual(@as(u32, 8), acb.GetAudioStreamAttrs(stream, &[_]utility.TagItem{
        .{ .tag = ac.ACA_AlbumArtist, .data = @intFromPtr(&album_artist) },
        .{ .tag = ac.ACA_Composer, .data = @intFromPtr(&composer) },
        .{ .tag = ac.ACA_Genre, .data = @intFromPtr(&genre) },
        .{ .tag = ac.ACA_Comment, .data = @intFromPtr(&comment) },
        .{ .tag = ac.ACA_Year, .data = @intFromPtr(&year) },
        .{ .tag = ac.ACA_Track, .data = @intFromPtr(&track) },
        .{ .tag = ac.ACA_Tracks, .data = @intFromPtr(&tracks) },
        .{ .tag = ac.ACA_Picture, .data = @intFromPtr(&cover) },
        .{},
    }));
    try testing.expectEqualStrings("Testers All", std.mem.span(album_artist));
    try testing.expectEqualStrings("A. Writer", std.mem.span(composer));
    try testing.expectEqualStrings("Test", std.mem.span(genre));
    try testing.expectEqualStrings("made with ffmpeg", std.mem.span(comment));
    try testing.expectEqual(@as(u32, 2026), year);
    try testing.expectEqual(@as(u32, 4), track);
    try testing.expectEqual(@as(u32, 9), tracks);
    try testing.expectEqual(@as(u32, 160), cover.?.size);
    try testing.expectEqualStrings("image/png", std.mem.sliceTo(&cover.?.mime, 0));
    try testing.expect(std.mem.eql(u8, cover.?.data[0..4], "\x89PNG"));

    // Straight through in small pieces: the start, and the click in the
    // middle in short windows.
    var straight: [44100 * 2]i16 = undefined;
    try testing.expectEqual(@as(u32, 44100), try decodeAll(acb, stream, 2, 333, &straight));
    try expectNear(&straight, 0, lossy_m4a_ref, 0, 2048, 2);
    try expectNear(&straight, 21504, lossy_m4a_ref, 2048, 2048, 2);

    // Back to the start: the start again, its noise too.
    var some: [600 * 2]i16 = undefined;
    try testing.expectEqual(ac.ACERR_OK, acb.SeekAudio(stream, 0));
    try testing.expectEqual(@as(i32, 600), acb.DecodeAudio(stream, &some, 600));
    try testing.expectEqualSlices(i16, straight[0..1200], &some);
    // Elsewhere the noise the encoder sent in bands (PNS) is drawn anew:
    // the samples differ in those bands, but a seek lands on the very
    // frame - nowhere near as far from it as from a frame to either side.
    for ([_]u32{ 500, 1024, 10000, 22000, 33333 }) |frame| {
        try testing.expectEqual(ac.ACERR_OK, acb.SeekAudio(stream, frame));
        try testing.expectEqual(@as(i32, 600), acb.DecodeAudio(stream, &some, 600));
        const here = squaredDistance(&some, straight[frame * 2 ..][0..1200]);
        for ([_]u32{ frame - 2, frame - 1, frame + 1, frame + 2 }) |other| {
            try testing.expect(here * 4 < squaredDistance(&some, straight[other * 2 ..][0..1200]));
        }
    }
    try testing.expectEqual(ac.ACERR_OK, acb.SeekAudio(stream, 44000));
    try testing.expectEqual(@as(i32, 100), acb.DecodeAudio(stream, &some, 600));
    try testing.expectEqual(@as(i32, 0), acb.DecodeAudio(stream, &some, 600));
}

fn squaredDistance(a: []const i16, b: []const i16) u64 {
    var sum: u64 = 0;
    for (a, b) |x, y| {
        const d: i64 = @as(i64, x) - y;
        sum += @intCast(d * d);
    }
    return sum;
}

test "AAC in an MP4 through a read function; a track of a file media.library has open" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit() catch {};
    const acb = rig.acb;
    var err: i32 = 0;
    var info: ac.AudioStreamInfo = .{};
    var head: [2048 * 2]i16 = undefined;

    // Its index at the front: read straight through, never moved.
    var memory: Memory = .{ .bytes = lossy_m4a, .piece = 777 };
    const stream = openMemory(acb, &memory, &err) orelse return error.NoStream;
    acb.GetAudioStreamInfo(stream, &info);
    try testing.expectEqual(@as(u32, 0), info.seekable);
    try testing.expectEqual(@as(u32, 44100), info.frames);
    try testing.expectEqual(@as(u32, 44100), try decodeAll(acb, stream, 2, 1999, &head));
    try expectNear(&head, 0, lossy_m4a_ref, 0, 2048, 2);
    try testing.expectEqual(ac.ACERR_NOSEEK, acb.SeekAudio(stream, 0));
    acb.CloseAudioStream(stream);

    // Its index behind the sound: only from a file.
    memory = .{ .bytes = tail_m4a };
    try testing.expect(openMemory(acb, &memory, &err) == null);
    try testing.expectEqual(ac.ACERR_UNSUPPORTED, err);
    try rig.write("WORK:tail.m4a", &.{tail_m4a});
    const tail = openFile(acb, "WORK:tail.m4a", &err) orelse return error.NoStream;
    acb.GetAudioStreamInfo(tail, &info);
    try testing.expectEqual(@as(u32, 22050), info.rate);
    try testing.expectEqual(@as(u32, 1), info.channels);
    try testing.expectEqual(@as(u32, 4410), info.frames);
    try testing.expectEqual(@as(u32, 4410), try decodeAll(acb, tail, 1, 1000, &.{}));
    acb.CloseAudioStream(tail);

    // A file the program has open with media.library: its sound decoded,
    // the file still the program's after.
    try rig.write("WORK:lossy.m4a", &.{lossy_m4a});
    const mb: *sdk.interface.media.MediaBase = @ptrCast(rig.sysLib().OpenLibrary(media.MEDIANAME, 1) orelse return error.NoMedia);
    defer rig.sysLib().CloseLibrary(mb.lib());
    const film = mb.OpenMedia(&[_]utility.TagItem{
        .{ .tag = media.MDA_Name, .data = @intFromPtr("WORK:lossy.m4a") },
        .{},
    }, &err) orelse return error.NoFile;
    defer mb.CloseMedia(film);
    const sound = acb.OpenAudioStream(&[_]utility.TagItem{
        .{ .tag = ac.ACA_Media, .data = @intFromPtr(film) },
        .{},
    }, &err) orelse return error.NoStream;
    acb.GetAudioStreamInfo(sound, &info);
    try testing.expectEqual(ac.ACODEC_AAC, info.codec);
    try testing.expectEqual(@as(u32, 1), info.seekable);
    try testing.expectEqualStrings("Lossy", textOf(&info.title));
    try testing.expectEqual(ac.ACERR_OK, acb.SeekAudio(sound, 0));
    try testing.expectEqual(@as(u32, 44100), try decodeAll(acb, sound, 2, 1000, &head));
    try expectNear(&head, 0, lossy_m4a_ref, 0, 2048, 2);
    acb.CloseAudioStream(sound);
    var media_info: media.MediaInfo = .{};
    mb.GetMediaInfo(film, &media_info);
    try testing.expectEqual(@as(u32, 1), media_info.tracks);
    try testing.expectEqual(media.MERR_OK, mb.SeekMedia(film, 0, 0));
    var packet: media.MediaPacket = .{};
    try testing.expectEqual(media.MERR_OK, mb.ReadMediaPacket(film, 0, &packet));

    // A track that is none.
    try testing.expect(acb.OpenAudioStream(&[_]utility.TagItem{
        .{ .tag = ac.ACA_Media, .data = @intFromPtr(film) },
        .{ .tag = ac.ACA_MediaTrack, .data = 5 },
        .{},
    }, &err) == null);
    try testing.expectEqual(ac.ACERR_UNKNOWN, err);
}

test "ADTS: ffmpeg's samples, noise and intensity stereo at 48 kHz; mono behind a tag; a seek near the frame" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit() catch {};
    const acb = rig.acb;
    var err: i32 = 0;
    var info: ac.AudioStreamInfo = .{};

    try rig.write("WORK:low.aac", &.{low_aac});
    const stream = openFile(acb, "WORK:low.aac", &err) orelse return error.NoStream;
    defer acb.CloseAudioStream(stream);
    acb.GetAudioStreamInfo(stream, &info);
    try testing.expectEqual(ac.ACODEC_AAC, info.codec);
    try testing.expectEqual(@as(u32, 48000), info.rate);
    try testing.expectEqual(@as(u32, 2), info.channels);
    try testing.expectEqual(@as(u32, 1), info.seekable);
    // ADTS has no index: the length is the frames' bytes over the file's.
    try testing.expect(info.frames > 28000 and info.frames < 33000);
    // Every frame is handed out, the encoder's priming too, as ffmpeg
    // does for ADTS.
    var straight: [30720 * 2]i16 = undefined;
    try testing.expectEqual(@as(u32, 30720), try decodeAll(acb, stream, 2, 1500, &straight));
    try expectNear(&straight, 0, low_aac_ref, 0, 2048, 2);
    try expectNear(&straight, 20480, low_aac_ref, 2048, 2048, 2);
    // Back to the start: the start again. Elsewhere: near it, and on to
    // the end.
    var some: [1024 * 2]i16 = undefined;
    try testing.expectEqual(ac.ACERR_OK, acb.SeekAudio(stream, 0));
    try testing.expectEqual(@as(i32, 1024), acb.DecodeAudio(stream, &some, 1024));
    try testing.expectEqualSlices(i16, straight[0..2048], &some);
    try testing.expectEqual(ac.ACERR_OK, acb.SeekAudio(stream, 15000));
    const rest = try decodeAll(acb, stream, 2, 1500, &.{});
    try testing.expect(rest > 30720 - 15000 - 3 * 1024 and rest < 30720 - 15000 + 3 * 1024);

    // Mono at 22.05 kHz behind an ID3v2 tag, through a read function.
    const t = &id3_tag;
    t.* = .{ .version = 3 };
    t.frame("TIT2", 0, "\x00Mono");
    var memory: Memory = .{ .bytes = t.finish(0, mono_aac), .piece = 1000 };
    const mono = openMemory(acb, &memory, &err) orelse return error.NoStream;
    defer acb.CloseAudioStream(mono);
    acb.GetAudioStreamInfo(mono, &info);
    try testing.expectEqual(@as(u32, 22050), info.rate);
    try testing.expectEqual(@as(u32, 1), info.channels);
    try testing.expectEqual(@as(u32, 0), info.seekable);
    try testing.expectEqualStrings("Mono", textOf(&info.title));
    var head: [2048]i16 = undefined;
    try testing.expectEqual(@as(u32, 23 * 1024), try decodeAll(acb, mono, 1, 700, &head));
    try expectNear(&head, 0, mono_aac_ref, 0, 2048, 1);
}

/// The chapters a stream's tags mark.
fn chaptersOf(acb: *AudioCodecBase, stream: *ac.AudioStream) []const ac.AudioChapter {
    var count: u32 = 0;
    var list: ?[*]const ac.AudioChapter = null;
    _ = acb.GetAudioStreamAttrs(stream, &[_]utility.TagItem{
        .{ .tag = ac.ACA_Chapters, .data = @intFromPtr(&count) },
        .{ .tag = ac.ACA_ChapterList, .data = @intFromPtr(&list) },
        .{},
    });
    return if (list) |chapters| chapters[0..count] else &.{};
}

/// After seeks to `frames` of a stereo stream, where the 400 frames
/// decoded lie in what decoding straight through gave - as near as they
/// come, and no further off than `most`: `exact` when they are those very
/// samples there. A seek to the end gives none.
fn expectLandings(acb: *AudioCodecBase, stream: *ac.AudioStream, straight: []const i16, total: u32, frames: []const u32, most: i64, exact: bool) !void {
    var some: [400 * 2]i16 = undefined;
    for (frames) |frame| {
        try testing.expectEqual(ac.ACERR_OK, acb.SeekAudio(stream, frame));
        if (frame == total) {
            try testing.expectEqual(@as(i32, 0), acb.DecodeAudio(stream, &some, 400));
            continue;
        }
        try testing.expectEqual(@as(i32, 400), acb.DecodeAudio(stream, &some, 400));
        var best: i64 = 0;
        var nearest: u64 = std.math.maxInt(u64);
        var offset: i64 = -most;
        while (offset <= most) : (offset += 1) {
            const at = @as(i64, frame) + offset;
            if (at < 0 or at + 400 > total) continue;
            const here = squaredDistance(&some, straight[@as(usize, @intCast(at)) * 2 ..][0..800]);
            if (here < nearest) {
                nearest = here;
                best = offset;
            }
        }
        if (exact and nearest != 0) {
            std.debug.print("frame {d}: nearest {d} off, {d} apart\n", .{ frame, best, nearest });
            return error.TestNotLanded;
        }
        // Nowhere near as far from it as from a frame to either side.
        const at: usize = @intCast(@as(i64, frame) + best);
        if (!exact and at >= 2) {
            for ([_]usize{ at - 2, at - 1, at + 1, at + 2 }) |other| {
                if (other + 400 > total) continue;
                try testing.expect(nearest * 4 < squaredDistance(&some, straight[other * 2 ..][0..800]));
            }
        }
    }
}

test "Matroska sound by name: FLAC as coded to STREAMINFO's length, its chapters in order, seeks within a millisecond" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit() catch {};
    const acb = rig.acb;
    var err: i32 = 0;
    var info: ac.AudioStreamInfo = .{};

    try rig.write("WORK:lossless.mka", &.{lossless_mka});
    const stream = openFile(acb, "WORK:lossless.mka", &err) orelse return error.NoStream;
    defer acb.CloseAudioStream(stream);
    acb.GetAudioStreamInfo(stream, &info);
    try testing.expectEqual(ac.ACODEC_FLAC, info.codec);
    try testing.expectEqual(@as(u32, 44100), info.rate);
    try testing.expectEqual(@as(u32, 2), info.channels);
    try testing.expectEqual(@as(u32, 16), info.bits);
    try testing.expectEqual(@as(u32, 4500), info.frames);
    try testing.expectEqual(@as(u32, 1), info.seekable);
    // ffmpeg kept the order the FLAC gave them in, second first.
    const chapters = chaptersOf(acb, stream);
    try testing.expectEqual(@as(usize, 2), chapters.len);
    try testing.expectEqual(@as(u32, 0), chapters[0].start);
    try testing.expectEqual(@as(u32, 50), chapters[0].end);
    try testing.expectEqual(@as(u32, 50), chapters[1].start);
    try testing.expectEqual(@as(u32, 102), chapters[1].end);

    var all: [4500 * 2]i16 = undefined;
    try testing.expectEqual(@as(u32, 4500), try decodeAll(acb, stream, 2, 999, &all));
    var expected: [4500 * 2]i16 = undefined;
    signal(4500, 2, 16, &expected);
    try testing.expectEqualSlices(i16, &expected, &all);
    // Its blocks' times are milliseconds: a seek lands within half of one.
    try expectLandings(acb, stream, &all, 4500, &.{ 3000, 77, 0, 4000, 4500 }, 22, true);
    try testing.expectEqual(ac.ACERR_OK, acb.SeekAudio(stream, 0));
    try testing.expectEqual(@as(u32, 4500), try decodeAll(acb, stream, 2, 999, &all));
    try testing.expectEqualSlices(i16, &expected, &all);
}

test "Matroska sound through a read function: Vorbis, MP3 with its encoder's delay, AAC as ffmpeg decodes it" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit() catch {};
    const acb = rig.acb;
    var err: i32 = 0;
    var info: ac.AudioStreamInfo = .{};

    // Matroska says how long to the millisecond: 102 ms are 4498 frames.
    var memory: Memory = .{ .bytes = vorbis_mka, .piece = 501 };
    const vorbis = openMemory(acb, &memory, &err) orelse return error.NoStream;
    acb.GetAudioStreamInfo(vorbis, &info);
    try testing.expectEqual(ac.ACODEC_VORBIS, info.codec);
    try testing.expectEqual(@as(u32, 44100), info.rate);
    try testing.expectEqual(@as(u32, 2), info.channels);
    try testing.expectEqual(@as(u32, 4498), info.frames);
    try testing.expectEqual(@as(u32, 0), info.seekable);
    var head: [1024 * 2]i16 = undefined;
    try testing.expectEqual(@as(u32, 4498), try decodeAll(acb, vorbis, 2, 999, &head));
    const vorbis_ref: []align(1) const i16 = std.mem.bytesAsSlice(i16, lossy_head);
    for (head, vorbis_ref) |ours, theirs| {
        try testing.expect(@abs(@as(i32, ours) - theirs) <= 1);
    }
    try testing.expectEqual(ac.ACERR_NOSEEK, acb.SeekAudio(vorbis, 0));
    acb.CloseAudioStream(vorbis);

    // No CodecDelay: the encoder's 1105 frames are sound, as for ffmpeg;
    // its padding is cut where the segment ends, 339 ms in.
    memory = .{ .bytes = tone_mka, .piece = 333 };
    const tone = openMemory(acb, &memory, &err) orelse return error.NoStream;
    acb.GetAudioStreamInfo(tone, &info);
    try testing.expectEqual(ac.ACODEC_MP3, info.codec);
    try testing.expectEqual(@as(u32, 44100), info.rate);
    try testing.expectEqual(@as(u32, 2), info.channels);
    try testing.expectEqual(@as(u32, 14949), info.frames);
    var tone_all: [14949 * 2]i16 = undefined;
    try testing.expectEqual(@as(u32, 14949), try decodeAll(acb, tone, 2, 1000, &tone_all));
    const tone_ref: []align(1) const i16 = std.mem.bytesAsSlice(i16, tone_head);
    for (tone_all[1105 * 2 ..][0..2048], tone_ref) |ours, theirs| {
        try testing.expect(@abs(@as(i32, ours) - theirs) <= 1);
    }
    acb.CloseAudioStream(tone);

    // CodecDelay is the priming, 1024 frames; the segment ends 0.22 ms
    // short of the sound.
    memory = .{ .bytes = aac_mka, .piece = 777 };
    const lossy = openMemory(acb, &memory, &err) orelse return error.NoStream;
    acb.GetAudioStreamInfo(lossy, &info);
    try testing.expectEqual(ac.ACODEC_AAC, info.codec);
    try testing.expectEqual(@as(u32, 44090), info.frames);
    var straight: [44090 * 2]i16 = undefined;
    try testing.expectEqual(@as(u32, 44090), try decodeAll(acb, lossy, 2, 1999, &straight));
    try expectNear(&straight, 0, lossy_m4a_ref, 0, 2048, 2);
    try expectNear(&straight, 21504, lossy_m4a_ref, 2048, 2048, 2);
    acb.CloseAudioStream(lossy);
}

test "Matroska sound on a file: seeks within a millisecond - and FFmpeg's Vorbis times; codecs it does not decode" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit() catch {};
    const acb = rig.acb;
    var err: i32 = 0;

    try rig.write("WORK:vorbis.mka", &.{vorbis_mka});
    const vorbis = openFile(acb, "WORK:vorbis.mka", &err) orelse return error.NoStream;
    var vorbis_all: [4498 * 2]i16 = undefined;
    try testing.expectEqual(@as(u32, 4498), try decodeAll(acb, vorbis, 2, 999, &vorbis_all));
    // FFmpeg's times for Vorbis run half a short block late: 128 frames.
    try expectLandings(acb, vorbis, &vorbis_all, 4498, &.{ 3000, 77, 2048, 4000, 4498 }, 22 + 128, true);
    acb.CloseAudioStream(vorbis);

    try rig.write("WORK:tone.mka", &.{tone_mka});
    const tone = openFile(acb, "WORK:tone.mka", &err) orelse return error.NoStream;
    var tone_all: [14949 * 2]i16 = undefined;
    try testing.expectEqual(@as(u32, 14949), try decodeAll(acb, tone, 2, 1000, &tone_all));
    try expectLandings(acb, tone, &tone_all, 14949, &.{ 0, 1105, 7000, 12345, 14949 }, 22, true);
    acb.CloseAudioStream(tone);

    // PNS noise is drawn anew after a seek, but the start is the start,
    // and a seek lands as near the frame as the others.
    try rig.write("WORK:aac.mka", &.{aac_mka});
    const lossy = openFile(acb, "WORK:aac.mka", &err) orelse return error.NoStream;
    var straight: [44090 * 2]i16 = undefined;
    try testing.expectEqual(@as(u32, 44090), try decodeAll(acb, lossy, 2, 1999, &straight));
    var some: [600 * 2]i16 = undefined;
    try testing.expectEqual(ac.ACERR_OK, acb.SeekAudio(lossy, 0));
    try testing.expectEqual(@as(i32, 600), acb.DecodeAudio(lossy, &some, 600));
    try testing.expectEqualSlices(i16, straight[0..1200], &some);
    try expectLandings(acb, lossy, &straight, 44090, &.{ 500, 1024, 10000, 33333 }, 22, false);
    acb.CloseAudioStream(lossy);

    // Layer II is MPEG audio too, but not decoded.
    var memory: Memory = .{ .bytes = layer2_mka };
    try testing.expect(openMemory(acb, &memory, &err) == null);
    try testing.expectEqual(ac.ACERR_UNSUPPORTED, err);
    // The first bytes say nothing of what Matroska holds.
    try testing.expectEqual(ac.ACODEC_UNKNOWN, acb.IdentifyAudio(lossless_mka, ac.AUDIO_IDENTIFY_BYTES));
}

test "a film's sound in Matroska: by name, the sound track the file marks; through media.library's own file" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit() catch {};
    const acb = rig.acb;
    var err: i32 = 0;
    var info: ac.AudioStreamInfo = .{};

    try rig.write("WORK:film.mkv", &.{film_mkv});
    const stream = openFile(acb, "WORK:film.mkv", &err) orelse return error.NoStream;
    acb.GetAudioStreamInfo(stream, &info);
    try testing.expectEqual(ac.ACODEC_AAC, info.codec);
    try testing.expectEqual(@as(u32, 44100), info.rate);
    try testing.expectEqual(@as(u32, 1), info.channels);
    try testing.expectEqual(@as(u32, 35270), info.frames);
    try testing.expectEqual(@as(u32, 35270), try decodeAll(acb, stream, 1, 1000, &.{}));
    acb.CloseAudioStream(stream);

    const mb: *sdk.interface.media.MediaBase = @ptrCast(rig.sysLib().OpenLibrary(media.MEDIANAME, 1) orelse return error.NoMedia);
    defer rig.sysLib().CloseLibrary(mb.lib());
    const film = mb.OpenMedia(&[_]utility.TagItem{
        .{ .tag = media.MDA_Name, .data = @intFromPtr("WORK:film.mkv") },
        .{},
    }, &err) orelse return error.NoFile;
    defer mb.CloseMedia(film);
    // The film's pictures are no sound.
    try testing.expect(acb.OpenAudioStream(&[_]utility.TagItem{
        .{ .tag = ac.ACA_Media, .data = @intFromPtr(film) },
        .{ .tag = ac.ACA_MediaTrack, .data = 0 },
        .{},
    }, &err) == null);
    try testing.expectEqual(ac.ACERR_UNKNOWN, err);
    const sound = acb.OpenAudioStream(&[_]utility.TagItem{
        .{ .tag = ac.ACA_Media, .data = @intFromPtr(film) },
        .{},
    }, &err) orelse return error.NoStream;
    defer acb.CloseAudioStream(sound);
    acb.GetAudioStreamInfo(sound, &info);
    try testing.expectEqual(@as(u32, 1), info.seekable);
    try testing.expectEqual(ac.ACERR_OK, acb.SeekAudio(sound, 20000));
    try testing.expectEqual(@as(u32, 15270), try decodeAll(acb, sound, 1, 1000, &.{}));
}

test "a film's sound that begins late: silence up to its first block, its priming left out; seeks keep the film's time" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit() catch {};
    const acb = rig.acb;
    var err: i32 = 0;
    var info: ac.AudioStreamInfo = .{};
    const late_by = 4410;

    try rig.write("WORK:film.mkv", &.{film_mkv});
    try rig.write("WORK:late.mkv", &.{late_mkv});
    var on_time: [36000]i16 = undefined;
    const film = openFile(acb, "WORK:film.mkv", &err) orelse return error.NoStream;
    const count = try decodeAll(acb, film, 1, 1000, &on_time);
    try testing.expectEqual(ac.ACERR_OK, acb.SeekAudio(film, 20000));
    var moved: [16000]i16 = undefined;
    const moved_count = try decodeAll(acb, film, 1, 1000, &moved);
    acb.CloseAudioStream(film);

    const stream = openFile(acb, "WORK:late.mkv", &err) orelse return error.NoStream;
    defer acb.CloseAudioStream(stream);
    acb.GetAudioStreamInfo(stream, &info);
    try testing.expectEqual(@as(u32, late_by + count), info.frames);
    var late: [41000]i16 = undefined;
    try testing.expectEqual(info.frames, try decodeAll(acb, stream, 1, 1000, &late));
    for (late[0..late_by]) |sample| try testing.expectEqual(@as(i16, 0), sample);
    try testing.expectEqualSlices(i16, on_time[0..count], late[late_by..][0..count]);

    // Into the silence: the rest of it, then the sound.
    try testing.expectEqual(ac.ACERR_OK, acb.SeekAudio(stream, 1000));
    @memset(&late, 1);
    try testing.expectEqual(info.frames - 1000, try decodeAll(acb, stream, 1, 1000, &late));
    for (late[0 .. late_by - 1000]) |sample| try testing.expectEqual(@as(i16, 0), sample);
    try testing.expectEqualSlices(i16, on_time[0..count], late[late_by - 1000 ..][0..count]);
    // Past it: what the film on time gives from as far into its sound.
    try testing.expectEqual(ac.ACERR_OK, acb.SeekAudio(stream, late_by + 20000));
    try testing.expectEqual(moved_count, try decodeAll(acb, stream, 1, 1000, &late));
    try testing.expectEqualSlices(i16, moved[0..moved_count], late[0..moved_count]);
}

test "a hole in a film's sound: silence for it, the sound after it as before, the frames the film's time" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit() catch {};
    const acb = rig.acb;
    var err: i32 = 0;
    var info: ac.AudioStreamInfo = .{};

    try rig.write("WORK:film.mkv", &.{film_mkv});
    try rig.write("WORK:hole.mkv", &.{hole_mkv});
    var whole: [36000]i16 = undefined;
    const film = openFile(acb, "WORK:film.mkv", &err) orelse return error.NoStream;
    const count = try decodeAll(acb, film, 1, 1000, &whole);
    acb.CloseAudioStream(film);

    const stream = openFile(acb, "WORK:hole.mkv", &err) orelse return error.NoStream;
    defer acb.CloseAudioStream(stream);
    acb.GetAudioStreamInfo(stream, &info);
    var holed: [40000]i16 = undefined;
    // Pieces that do not meet the packets: the codec stops at the hole
    // within a call.
    const frames = try decodeAll(acb, stream, 1, 700, &holed);
    try testing.expectEqual(info.frames, frames);
    // The packet that was at 418 ms: 18 of 1024 frames after the priming.
    const hole_at = 18 * 1024;
    try testing.expectEqualSlices(i16, whole[0..hole_at], holed[0..hole_at]);
    var quiet: usize = 0;
    while (holed[hole_at + quiet] == 0) quiet += 1;
    // 50 ms, its ends each to the millisecond.
    try testing.expect(quiet >= 2205 - 44 and quiet <= 2205 + 44);
    const after = @min(count - hole_at, frames - hole_at - quiet);
    try testing.expect(after > count - hole_at - 50);
    try testing.expectEqualSlices(i16, whole[hole_at..][0..after], holed[hole_at + quiet ..][0..after]);

    // A seek past the hole counts it: a frame of the film's time.
    try testing.expectEqual(ac.ACERR_OK, acb.SeekAudio(stream, @intCast(hole_at + quiet + 4000)));
    var moved: [20000]i16 = undefined;
    try testing.expectEqual(frames - (hole_at + quiet + 4000), try decodeAll(acb, stream, 1, 1000, &moved));
}

// --- AC-3 and E-AC-3 ------------------------------------------------------------

/// Half a second of 5.1 at 192 kbit/s, ffmpeg's: 16 frames of 768 bytes.
const six_ac3 = @embedFile("six.ac3");
/// ffmpeg's samples of it mixed to stereo: frames 0 to 2048, then 16384
/// to 18432.
const six_ref = @embedFile("six_ref.raw");
/// Stereo E-AC-3 at 44.1 kHz in Matroska, its CodecDelay the encoder's
/// 256 frames; the same frames bare; ffmpeg's first 2048 of the track.
const eac3_mka = @embedFile("eac3.mka");
const stereo_eac3 = @embedFile("stereo.eac3");
const eac3_ref = @embedFile("eac3_ref.raw");
/// Mono AC-3 at 64 kbit/s in an MP4, its edit list leaving the priming
/// out; ffmpeg's first 2048 frames of it.
const mono_ac3_m4a = @embedFile("mono_ac3.m4a");
const mono_ac3_ref = @embedFile("mono_ac3_ref.raw");

/// After a seek to `frame`, 400 frames near those decoding straight
/// through gave there - the bits coded with none are dithered, and after
/// a seek the noise is another - and far nearer than to the frames a step
/// to either side.
fn expectSeekNear(acb: *AudioCodecBase, stream: *ac.AudioStream, straight: []const i16, channels: usize, frame: u32) !void {
    var some: [400 * 2]i16 = undefined;
    try testing.expectEqual(ac.ACERR_OK, acb.SeekAudio(stream, frame));
    try testing.expectEqual(@as(i32, 400), acb.DecodeAudio(stream, &some, 400));
    const count = 400 * channels;
    const total = straight.len / channels;
    const here = squaredDistance(some[0..count], straight[frame * channels ..][0..count]);
    for ([_]usize{ frame -| 1, frame + 1 }) |other| {
        if (other == frame or other + 400 > total) continue;
        try testing.expect(here * 4 < squaredDistance(some[0..count], straight[other * channels ..][0..count]));
    }
}

test "what AC-3 and E-AC-3 are, by their first bytes" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit() catch {};
    const acb = rig.acb;
    try testing.expectEqual(ac.ACODEC_AC3, acb.IdentifyAudio(six_ac3, ac.AUDIO_IDENTIFY_BYTES));
    try testing.expectEqual(ac.ACODEC_EAC3, acb.IdentifyAudio(stereo_eac3, ac.AUDIO_IDENTIFY_BYTES));
    // A header the next frame's does not follow is none.
    var lone = six_ac3[0..2000].*;
    lone[768] = 0;
    try testing.expectEqual(ac.ACODEC_UNKNOWN, acb.IdentifyAudio(&lone, lone.len));
}

test "AC-3 5.1 by name: mixed to stereo as ffmpeg does, its length, a damaged frame silent, seeks near" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit() catch {};
    const acb = rig.acb;
    var err: i32 = 0;
    var info: ac.AudioStreamInfo = .{};

    try rig.write("WORK:six.ac3", &.{six_ac3});
    const stream = openFile(acb, "WORK:six.ac3", &err) orelse return error.NoStream;
    defer acb.CloseAudioStream(stream);
    acb.GetAudioStreamInfo(stream, &info);
    try testing.expectEqual(ac.ACODEC_AC3, info.codec);
    try testing.expectEqual(@as(u32, 48000), info.rate);
    try testing.expectEqual(@as(u32, 2), info.channels);
    try testing.expectEqual(@as(u32, 192000), info.bitrate);
    try testing.expectEqual(@as(u32, 1), info.seekable);
    try testing.expectEqual(@as(u32, 16 * 1536), info.frames);
    var straight: [16 * 1536 * 2]i16 = undefined;
    try testing.expectEqual(@as(u32, 16 * 1536), try decodeAll(acb, stream, 2, 1500, &straight));
    try expectNear(&straight, 0, six_ref, 0, 2048, 2);
    try expectNear(&straight, 16384, six_ref, 2048, 2048, 2);

    // Back to the start: the start again; elsewhere, near.
    var some: [1000 * 2]i16 = undefined;
    try testing.expectEqual(ac.ACERR_OK, acb.SeekAudio(stream, 0));
    try testing.expectEqual(@as(i32, 1000), acb.DecodeAudio(stream, &some, 1000));
    try testing.expectEqualSlices(i16, straight[0..2000], &some);
    for ([_]u32{ 100, 1535, 1536, 1537, 5000, 12345, 16 * 1536 - 400 }) |frame| {
        try expectSeekNear(acb, stream, &straight, 2, frame);
    }
    try testing.expectEqual(ac.ACERR_OK, acb.SeekAudio(stream, 16 * 1536));
    try testing.expectEqual(@as(i32, 0), acb.DecodeAudio(stream, &some, 1000));

    // A byte of the sixth frame changed, through a read function: its
    // CRC says so, and its 1536 frames are silence.
    var damaged = six_ac3.*;
    damaged[5 * 768 + 300] ^= 0x10;
    var memory: Memory = .{ .bytes = &damaged, .piece = 900 };
    const broken = openMemory(acb, &memory, &err) orelse return error.NoStream;
    defer acb.CloseAudioStream(broken);
    acb.GetAudioStreamInfo(broken, &info);
    try testing.expectEqual(@as(u32, 0), info.seekable);
    var heard: [16 * 1536 * 2]i16 = undefined;
    try testing.expectEqual(@as(u32, 16 * 1536), try decodeAll(acb, broken, 2, 1000, &heard));
    try testing.expectEqualSlices(i16, straight[0 .. 5 * 1536 * 2], heard[0 .. 5 * 1536 * 2]);
    for (heard[5 * 1536 * 2 .. 6 * 1536 * 2]) |sample| try testing.expectEqual(@as(i16, 0), sample);
    try testing.expect(squaredDistance(straight[7 * 1536 * 2 ..], heard[7 * 1536 * 2 ..]) < squaredDistance(straight[7 * 1536 * 2 ..], &([_]i16{0} ** (9 * 1536 * 2))) / 1000);
}

test "E-AC-3 in Matroska: ffmpeg's samples, the encoder's delay left out; the same frames bare" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit() catch {};
    const acb = rig.acb;
    var err: i32 = 0;
    var info: ac.AudioStreamInfo = .{};

    var memory: Memory = .{ .bytes = eac3_mka, .piece = 613 };
    const track = openMemory(acb, &memory, &err) orelse return error.NoStream;
    defer acb.CloseAudioStream(track);
    acb.GetAudioStreamInfo(track, &info);
    try testing.expectEqual(ac.ACODEC_EAC3, info.codec);
    try testing.expectEqual(@as(u32, 44100), info.rate);
    try testing.expectEqual(@as(u32, 2), info.channels);
    // The segment's 506 ms, less the delay: past ffmpeg's 22050, which
    // the last block's DiscardPadding cuts.
    try testing.expectEqual(@as(u32, 22058), info.frames);
    var film: [22058 * 2]i16 = undefined;
    const length = try decodeAll(acb, track, 2, 999, &film);
    try testing.expectEqual(@as(u32, 22058), length);
    try expectNear(&film, 0, eac3_ref, 0, 2048, 2);

    // Bare, the delay is sound: 256 frames more in front, every one after
    // the same.
    try rig.write("WORK:stereo.eac3", &.{stereo_eac3});
    const bare = openFile(acb, "WORK:stereo.eac3", &err) orelse return error.NoStream;
    defer acb.CloseAudioStream(bare);
    acb.GetAudioStreamInfo(bare, &info);
    try testing.expectEqual(ac.ACODEC_EAC3, info.codec);
    // At 44.1 kHz the frames are not all one size: the rate is theirs.
    try testing.expect(info.bitrate > 95500 and info.bitrate < 96500);
    try testing.expectEqual(@as(u32, 15 * 1536), info.frames);
    var raw: [15 * 1536 * 2]i16 = undefined;
    try testing.expectEqual(@as(u32, 15 * 1536), try decodeAll(acb, bare, 2, 1234, &raw));
    try testing.expectEqualSlices(i16, raw[256 * 2 ..][0 .. length * 2], film[0 .. length * 2]);
}

test "AC-3 mono in an MP4: one channel, ffmpeg's samples to the edit list's length, seeks near" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit() catch {};
    const acb = rig.acb;
    var err: i32 = 0;
    var info: ac.AudioStreamInfo = .{};

    try rig.write("WORK:mono.m4a", &.{mono_ac3_m4a});
    const stream = openFile(acb, "WORK:mono.m4a", &err) orelse return error.NoStream;
    defer acb.CloseAudioStream(stream);
    acb.GetAudioStreamInfo(stream, &info);
    try testing.expectEqual(ac.ACODEC_AC3, info.codec);
    try testing.expectEqual(@as(u32, 48000), info.rate);
    try testing.expectEqual(@as(u32, 1), info.channels);
    try testing.expectEqual(@as(u32, 24000), info.frames);
    var straight: [24000]i16 = undefined;
    try testing.expectEqual(@as(u32, 24000), try decodeAll(acb, stream, 1, 777, &straight));
    try expectNear(&straight, 0, mono_ac3_ref, 0, 2048, 1);
    for ([_]u32{ 0, 1, 255, 256, 1537, 10000, 24000 - 400 }) |frame| {
        try expectSeekNear(acb, stream, &straight, 1, frame);
    }
}

// --- DTS ----------------------------------------------------------------------------

/// A fifth of a second of 5.1 at 768 kbit/s, from ffmpeg's encoder: frames of
/// 1024 bytes, 512 samples each; ffmpeg's samples of it mixed to stereo as we
/// mix.
const six_dts = @embedFile("six.dts");
const six_dts_ref = @embedFile("six_dts_ref.raw");
const six_frames = six_dts.len / 1024;
/// Ten frames of 5.1 of 2048 samples, of random numbers made to use every
/// branch of the syntax: several subframes and subsubframes, transients,
/// every code book and quantizer, ADPCM, high frequency vectors, joint
/// subbands, sums and differences, both filters, lossless steps, CRC words,
/// DSYNC in either place; ffmpeg's samples, mixed the same.
const syntax_dts = @embedFile("syntax.dts");
const syntax_ref = @embedFile("syntax_ref.raw");
/// Mono at 48 kHz and ffmpeg's samples.
const mono_dts = @embedFile("mono.dts");
const mono_dts_ref = @embedFile("mono_dts_ref.raw");
/// The same stereo frames, a tone in noise at 48 kHz, in Matroska and in an
/// MP4; ffmpeg's samples. A seek starts the predictors with no history,
/// which a pure tone's are slow to forget: the sound goes on the same, a
/// few percent out, for longer than a seek starts early.
const dts_mka = @embedFile("dts.mka");
const dts_m4a = @embedFile("dts.m4a");
const dts_ref = @embedFile("dts_ref.raw");

test "DTS, bare: what it is by its first bytes, ffmpeg's samples, a seek near the frame" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit() catch {};
    const acb = rig.acb;
    try testing.expectEqual(ac.ACODEC_DTS, acb.IdentifyAudio(six_dts, ac.AUDIO_IDENTIFY_BYTES));
    // A sync word with no frame after it is nothing.
    try testing.expectEqual(ac.ACODEC_UNKNOWN, acb.IdentifyAudio(six_dts[1..], ac.AUDIO_IDENTIFY_BYTES));

    var err: i32 = 0;
    var info: ac.AudioStreamInfo = .{};
    try rig.write("WORK:six.dts", &.{six_dts});
    const stream = openFile(acb, "WORK:six.dts", &err) orelse return error.NoStream;
    defer acb.CloseAudioStream(stream);
    acb.GetAudioStreamInfo(stream, &info);
    try testing.expectEqual(ac.ACODEC_DTS, info.codec);
    try testing.expectEqual(@as(u32, 48000), info.rate);
    try testing.expectEqual(@as(u32, 2), info.channels);
    try testing.expectEqual(@as(u32, 768000), info.bitrate);
    try testing.expectEqual(@as(u32, six_frames * 512), info.frames);
    var straight: [six_frames * 512 * 2]i16 = undefined;
    try testing.expectEqual(@as(u32, six_frames * 512), try decodeAll(acb, stream, 2, 777, &straight));
    try expectNear(&straight, 0, six_dts_ref, 0, 18 * 512, 2);

    var some: [400 * 2]i16 = undefined;
    try testing.expectEqual(ac.ACERR_OK, acb.SeekAudio(stream, 0));
    try testing.expectEqual(@as(i32, 400), acb.DecodeAudio(stream, &some, 400));
    try testing.expectEqualSlices(i16, straight[0..800], &some);
    for ([_]u32{ 100, 511, 512, 513, 2000, 5555, six_frames * 512 - 400 }) |frame| {
        try expectSeekNear(acb, stream, &straight, 2, frame);
    }
    try testing.expectEqual(ac.ACERR_OK, acb.SeekAudio(stream, six_frames * 512));
    try testing.expectEqual(@as(i32, 0), acb.DecodeAudio(stream, &some, 400));
}

test "DTS: every branch of the syntax as ffmpeg decodes it; mono" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit() catch {};
    const acb = rig.acb;
    var err: i32 = 0;
    var info: ac.AudioStreamInfo = .{};

    var memory: Memory = .{ .bytes = syntax_dts, .piece = 900 };
    const stream = openMemory(acb, &memory, &err) orelse return error.NoStream;
    defer acb.CloseAudioStream(stream);
    var heard: [10 * 2048 * 2]i16 = undefined;
    try testing.expectEqual(@as(u32, 10 * 2048), try decodeAll(acb, stream, 2, 1000, &heard));
    try expectNear(&heard, 0, syntax_ref, 0, 10 * 2048, 2);

    var mono_memory: Memory = .{ .bytes = mono_dts };
    const mono = openMemory(acb, &mono_memory, &err) orelse return error.NoStream;
    defer acb.CloseAudioStream(mono);
    acb.GetAudioStreamInfo(mono, &info);
    try testing.expectEqual(@as(u32, 1), info.channels);
    const count = mono_dts_ref.len / 2;
    const samples = try testing.allocator.alloc(i16, count);
    defer testing.allocator.free(samples);
    try testing.expectEqual(@as(u32, @intCast(count)), try decodeAll(acb, mono, 1, 500, samples));
    try expectNear(samples, 0, mono_dts_ref, 0, count, 1);
}

test "DTS: little end first, fourteen bits to a word, an extension between frames, a frame damaged" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit() catch {};
    const acb = rig.acb;
    var err: i32 = 0;
    var straight: [six_frames * 512 * 2]i16 = undefined;
    var memory: Memory = .{ .bytes = six_dts };
    const plain = openMemory(acb, &memory, &err) orelse return error.NoStream;
    defer acb.CloseAudioStream(plain);
    try testing.expectEqual(@as(u32, six_frames * 512), try decodeAll(acb, plain, 2, 777, &straight));
    var heard: [six_frames * 512 * 2]i16 = undefined;

    // The same bytes in pairs swapped.
    var swapped = six_dts.*;
    var i: usize = 0;
    while (i < swapped.len) : (i += 2) {
        swapped[i] = six_dts[i + 1];
        swapped[i + 1] = six_dts[i];
    }
    try testing.expectEqual(ac.ACODEC_DTS, acb.IdentifyAudio(&swapped, ac.AUDIO_IDENTIFY_BYTES));
    memory = .{ .bytes = &swapped };
    const little = openMemory(acb, &memory, &err) orelse return error.NoStream;
    defer acb.CloseAudioStream(little);
    try testing.expectEqual(@as(u32, six_frames * 512), try decodeAll(acb, little, 2, 777, &heard));
    try testing.expectEqualSlices(i16, &straight, &heard);

    // The same bits fourteen to a word, each frame on its own.
    const frame_bytes = 1024;
    const packed_frame = (frame_bytes * 8 + 13) / 14 * 2;
    var fourteen: [six_frames * packed_frame]u8 = undefined;
    for (0..six_frames) |f| {
        var bits: Bits = .{ .bytes = six_dts[f * frame_bytes ..][0..frame_bytes] };
        for (0..packed_frame / 2) |w| {
            var word = bits.read(14);
            if (word & 0x2000 != 0) word |= 0xC000; // its sign, as such a stream has
            fourteen[f * packed_frame + w * 2] = @truncate(word >> 8);
            fourteen[f * packed_frame + w * 2 + 1] = @truncate(word);
        }
    }
    try testing.expectEqual(ac.ACODEC_DTS, acb.IdentifyAudio(&fourteen, ac.AUDIO_IDENTIFY_BYTES));
    memory = .{ .bytes = &fourteen };
    const narrow = openMemory(acb, &memory, &err) orelse return error.NoStream;
    defer acb.CloseAudioStream(narrow);
    try testing.expectEqual(@as(u32, six_frames * 512), try decodeAll(acb, narrow, 2, 777, &heard));
    try testing.expectEqualSlices(i16, &straight, &heard);

    // An extension substream's bytes after each frame are passed over.
    const extra = 200;
    var extended: [six_frames * (frame_bytes + extra)]u8 = @splat(0x5A);
    for (0..six_frames) |f| {
        const at = f * (frame_bytes + extra);
        @memcpy(extended[at..][0..frame_bytes], six_dts[f * frame_bytes ..][0..frame_bytes]);
        @memcpy(extended[at + frame_bytes ..][0..4], &[_]u8{ 0x64, 0x58, 0x20, 0x25 });
    }
    try testing.expectEqual(ac.ACODEC_DTS, acb.IdentifyAudio(&extended, ac.AUDIO_IDENTIFY_BYTES));
    memory = .{ .bytes = &extended };
    const with_extension = openMemory(acb, &memory, &err) orelse return error.NoStream;
    defer acb.CloseAudioStream(with_extension);
    try testing.expectEqual(@as(u32, six_frames * 512), try decodeAll(acb, with_extension, 2, 777, &heard));
    try testing.expectEqualSlices(i16, &straight, &heard);

    // A frame's audio data zeroed: its DSYNC is not there, its 512 frames
    // are silence; the frames before it as they were.
    var damaged = six_dts.*;
    @memset(damaged[5 * frame_bytes + 40 .. 6 * frame_bytes], 0);
    memory = .{ .bytes = &damaged };
    const broken = openMemory(acb, &memory, &err) orelse return error.NoStream;
    defer acb.CloseAudioStream(broken);
    try testing.expectEqual(@as(u32, six_frames * 512), try decodeAll(acb, broken, 2, 777, &heard));
    try testing.expectEqualSlices(i16, straight[0 .. 5 * 512 * 2], heard[0 .. 5 * 512 * 2]);
    for (heard[5 * 512 * 2 .. 6 * 512 * 2]) |sample| try testing.expectEqual(@as(i16, 0), sample);
    try testing.expect(squaredDistance(straight[8 * 512 * 2 ..], heard[8 * 512 * 2 ..]) < squaredDistance(straight[8 * 512 * 2 ..], &([_]i16{0} ** ((six_frames - 8) * 512 * 2))) / 1000);
}

test "DTS in Matroska and in an MP4: ffmpeg's samples, a seek near the frame" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit() catch {};
    const acb = rig.acb;
    var err: i32 = 0;
    var info: ac.AudioStreamInfo = .{};
    const count = dts_ref.len / 4;
    const straight = try testing.allocator.alloc(i16, count * 2 + 2048);
    defer testing.allocator.free(straight);
    try rig.write("WORK:dts.mka", &.{dts_mka});
    try rig.write("WORK:dts.m4a", &.{dts_m4a});
    for ([_][*:0]const u8{ "WORK:dts.mka", "WORK:dts.m4a" }) |name| {
        const stream = openFile(acb, name, &err) orelse return error.NoStream;
        defer acb.CloseAudioStream(stream);
        acb.GetAudioStreamInfo(stream, &info);
        try testing.expectEqual(ac.ACODEC_DTS, info.codec);
        try testing.expectEqual(@as(u32, 48000), info.rate);
        try testing.expectEqual(@as(u32, 2), info.channels);
        const total = try decodeAll(acb, stream, 2, 777, straight);
        // As long as the container says, which ffmpeg rounded.
        try testing.expect(total + 64 >= count);
        try expectNear(straight, 0, dts_ref, 0, @min(total, count), 2);
        // Matroska's times are in milliseconds: only an MP4's seek is exact.
        if (name[10] == 'k') continue;
        for ([_]u32{ 0, 100, 512, 1000, 5000 }) |frame| {
            try expectSeekNear(acb, stream, straight[0 .. total * 2], 2, frame);
        }
    }
}

// --- Opus ---------------------------------------------------------------------------

const stereo_opus = @embedFile("stereo.opus");
const stereo_opus_ref = @embedFile("stereo_ref.raw");
const voice_opus = @embedFile("voice.opus");
const voice_opus_ref = @embedFile("voice_ref.raw");
const six_opus = @embedFile("six.opus");
const six_opus_ref = @embedFile("six_opus_ref.raw");
const voice_mp4 = @embedFile("voice.mp4");
const opus_mka_ref = @embedFile("opus_mka_ref.raw");
const opus_chain = stereo_opus.* ++ voice_opus.*;

test "Ogg Opus through a read function: libopus's samples, the pre-skip left out, its tags" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit() catch {};
    const acb = rig.acb;
    var err: i32 = 0;
    var info: ac.AudioStreamInfo = .{};

    try testing.expectEqual(ac.ACODEC_OPUS, acb.IdentifyAudio(stereo_opus, ac.AUDIO_IDENTIFY_BYTES));
    var memory: Memory = .{ .bytes = stereo_opus, .piece = 333 };
    const stream = openMemory(acb, &memory, &err) orelse return error.NoStream;
    defer acb.CloseAudioStream(stream);
    acb.GetAudioStreamInfo(stream, &info);
    try testing.expectEqual(ac.ACODEC_OPUS, info.codec);
    try testing.expectEqual(@as(u32, 48000), info.rate);
    try testing.expectEqual(@as(u32, 2), info.channels);
    try testing.expectEqual(@as(u32, 16), info.bits);
    try testing.expectEqualStrings("Opus Tone", textOf(&info.title));
    try testing.expectEqualStrings("PowerOS", textOf(&info.artist));
    var straight: [48000 * 2]i16 = undefined;
    try testing.expectEqual(@as(u32, 48000), try decodeAll(acb, stream, 2, 1111, &straight));
    try expectNear(&straight, 0, stereo_opus_ref, 0, 2048, 2);
    try expectNear(&straight, 30000, stereo_opus_ref, 2048, 2048, 2);
}

test "Ogg Opus by name: its length from the last page, seeks exact from the start and near 160 ms on" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit() catch {};
    const acb = rig.acb;
    var err: i32 = 0;
    var info: ac.AudioStreamInfo = .{};

    try rig.write("WORK:stereo.opus", &.{stereo_opus});
    const stream = openFile(acb, "WORK:stereo.opus", &err) orelse return error.NoStream;
    defer acb.CloseAudioStream(stream);
    acb.GetAudioStreamInfo(stream, &info);
    try testing.expectEqual(@as(u32, 48000), info.frames);
    try testing.expect(info.bitrate > 90000 and info.bitrate < 130000);
    var straight: [48000 * 2]i16 = undefined;
    try testing.expectEqual(@as(u32, 48000), try decodeAll(acb, stream, 2, 2000, &straight));
    try expectNear(&straight, 30000, stereo_opus_ref, 2048, 2048, 2);

    // Within 160 ms of the start the decoding goes from the first packet,
    // as it went straight through; past it from a page 160 ms early - of
    // 100 ms pages - the decoder settled by the frame.
    try expectOpusFromStart(acb, stream, &straight, 2);
    for ([_]u32{ 7680, 10000, 24001, 33333, 48000 - 400 }) |frame| {
        try expectSeekNear(acb, stream, &straight, 2, frame);
    }
    var some: [400 * 2]i16 = undefined;
    try testing.expectEqual(ac.ACERR_OK, acb.SeekAudio(stream, 48000));
    try testing.expectEqual(@as(i32, 0), acb.DecodeAudio(stream, &some, 400));
}

test "Ogg Opus in mono, coded for speech (SILK): libopus's samples" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit() catch {};
    const acb = rig.acb;
    var err: i32 = 0;
    var info: ac.AudioStreamInfo = .{};

    try rig.write("WORK:voice.opus", &.{voice_opus});
    const stream = openFile(acb, "WORK:voice.opus", &err) orelse return error.NoStream;
    defer acb.CloseAudioStream(stream);
    acb.GetAudioStreamInfo(stream, &info);
    try testing.expectEqual(@as(u32, 1), info.channels);
    try testing.expectEqual(@as(u32, 24000), info.frames);
    var straight: [24000]i16 = undefined;
    try testing.expectEqual(@as(u32, 24000), try decodeAll(acb, stream, 1, 1500, &straight));
    try expectNear(&straight, 0, voice_opus_ref, 0, 2048, 1);
    try expectNear(&straight, 12000, voice_opus_ref, 2048, 2048, 1);
    // Within 160 ms of the start, exact; a hum this steady takes SILK's
    // long-term prediction longer than that to settle after a seek.
    try expectOpusFromStart(acb, stream, &straight, 1);
}

test "Ogg Opus in 5.1: its six channels mixed into stereo" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit() catch {};
    const acb = rig.acb;
    var err: i32 = 0;
    var info: ac.AudioStreamInfo = .{};

    var memory: Memory = .{ .bytes = six_opus };
    const stream = openMemory(acb, &memory, &err) orelse return error.NoStream;
    defer acb.CloseAudioStream(stream);
    acb.GetAudioStreamInfo(stream, &info);
    try testing.expectEqual(ac.ACODEC_OPUS, info.codec);
    try testing.expectEqual(@as(u32, 2), info.channels);
    var straight: [14400 * 2]i16 = undefined;
    try testing.expectEqual(@as(u32, 14400), try decodeAll(acb, stream, 2, 1000, &straight));
    try expectNear(&straight, 0, six_opus_ref, 0, 2048, 2);
    try expectNear(&straight, 8000, six_opus_ref, 2048, 2048, 2);
}

test "a chain of Ogg Opus links: stereo, then mono with no names" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit() catch {};
    const acb = rig.acb;
    var err: i32 = 0;
    var info: ac.AudioStreamInfo = .{};

    var memory: Memory = .{ .bytes = &opus_chain, .piece = 501 };
    const stream = openMemory(acb, &memory, &err) orelse return error.NoStream;
    defer acb.CloseAudioStream(stream);
    try testing.expectEqual(@as(u32, 0), linkOf(acb, stream));
    var first: [48000 * 2]i16 = undefined;
    try testing.expectEqual(@as(u32, 48000), try decodeLink(acb, stream, 2, 999, &first));
    try expectNear(&first, 30000, stereo_opus_ref, 2048, 2048, 2);
    var later: [24000]i16 = undefined;
    try testing.expectEqual(@as(u32, 24000), try decodeAll(acb, stream, 1, 999, &later));
    try testing.expectEqual(@as(u32, 1), linkOf(acb, stream));
    acb.GetAudioStreamInfo(stream, &info);
    try testing.expectEqual(@as(u32, 1), info.channels);
    try testing.expectEqualStrings("", textOf(&info.title));
    try expectNear(&later, 12000, voice_opus_ref, 2048, 2048, 1);
}

test "Opus in Matroska and in an MP4: the pre-skip the track's delay, libopus's samples" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit() catch {};
    const acb = rig.acb;
    var err: i32 = 0;
    var info: ac.AudioStreamInfo = .{};

    var memory: Memory = .{ .bytes = opus_mka };
    const mka = openMemory(acb, &memory, &err) orelse return error.NoStream;
    acb.GetAudioStreamInfo(mka, &info);
    try testing.expectEqual(ac.ACODEC_OPUS, info.codec);
    try testing.expectEqual(@as(u32, 2), info.channels);
    // Its length from the segment's, to the millisecond and a half: its
    // first block lies before 0 by the priming, and the padding its last
    // block says to drop is not read - libopus through ffmpeg gives 2400.
    var short: [2472 * 2]i16 = undefined;
    try testing.expectEqual(@as(u32, 2472), try decodeAll(acb, mka, 2, 700, &short));
    try expectNear(&short, 0, opus_mka_ref, 0, 2400, 2);
    acb.CloseAudioStream(mka);

    try rig.write("WORK:voice.mp4", &.{voice_mp4});
    const mp4 = openFile(acb, "WORK:voice.mp4", &err) orelse return error.NoStream;
    defer acb.CloseAudioStream(mp4);
    acb.GetAudioStreamInfo(mp4, &info);
    try testing.expectEqual(ac.ACODEC_OPUS, info.codec);
    try testing.expectEqual(@as(u32, 1), info.channels);
    try testing.expectEqual(@as(u32, 24000), info.frames);
    var straight: [24000]i16 = undefined;
    try testing.expectEqual(@as(u32, 24000), try decodeAll(acb, mp4, 1, 1234, &straight));
    try expectNear(&straight, 0, voice_opus_ref, 0, 2048, 1);
    try expectNear(&straight, 12000, voice_opus_ref, 2048, 2048, 1);
    try expectOpusFromStart(acb, mp4, &straight, 1);
}

/// Seeks within 160 ms of the start decode from the first packet: the
/// samples those decoding straight through gave.
fn expectOpusFromStart(acb: *AudioCodecBase, stream: *ac.AudioStream, straight: []const i16, channels: usize) !void {
    var some: [400 * 2]i16 = undefined;
    const count = 400 * channels;
    for ([_]u32{ 0, 1, 959, 5000, 7679 }) |frame| {
        try testing.expectEqual(ac.ACERR_OK, acb.SeekAudio(stream, frame));
        try testing.expectEqual(@as(i32, 400), acb.DecodeAudio(stream, &some, 400));
        try testing.expectEqualSlices(i16, straight[frame * channels ..][0..count], some[0..count]);
    }
}

test "a kind with no module on the disk: found out what it is, refused, and played once it is there" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit() catch {};
    const acb = rig.acb;
    const module = rig.modules[sound_modules.mp3];
    const name = module.node.name;

    module.node.name = "gone";
    try testing.expectEqual(ac.ACODEC_MP3, acb.IdentifyAudio(tone_mp3.ptr, @intCast(tone_mp3.len)));
    var memory: Memory = .{ .bytes = tone_mp3 };
    var err: i32 = -99;
    try testing.expect(openMemory(acb, &memory, &err) == null);
    try testing.expectEqual(ac.ACERR_UNSUPPORTED, err);
    module.node.name = name;

    memory = .{ .bytes = tone_mp3 };
    const stream = openMemory(acb, &memory, &err) orelse return error.NoStream;
    try testing.expectEqual(@as(@TypeOf(module.open_cnt), 1), module.open_cnt);
    acb.CloseAudioStream(stream);
    try testing.expectEqual(@as(@TypeOf(module.open_cnt), 0), module.open_cnt);
}

test "a sound module refuses a stream of another layout" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit() catch {};
    const module: *sdk.interface.acodec.ACodecBase = @ptrCast(rig.sysLib().OpenLibrary("codecs/wav.acodec", 1) orelse return error.NoModule);
    defer rig.sysLib().CloseLibrary(module.lib());

    const Other = struct {
        var stream: sdk.acodec.ACodecStream = undefined;
    };
    @memset(std.mem.asBytes(&Other.stream), 0);
    Other.stream.layout = sdk.acodec.ACODEC_LAYOUT + 1;
    try testing.expectEqual(ac.ACERR_UNSUPPORTED, module.OpenACodec(&Other.stream));
    var track: media.MediaTrack = .{};
    try testing.expectEqual(ac.ACERR_UNSUPPORTED, module.OpenACodecTrack(&Other.stream, &track));
    // Nothing made, nothing to give back.
    module.CloseACodec(&Other.stream);
}
