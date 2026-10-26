// SPDX-License-Identifier: MIT
//! Host tests of compression.library as a whole: the library made from
//! its ROM tag on the ROM's exec, opened as a program opens it, and spoken
//! to through its jump table. Streams made by zlib itself (stored, fixed
//! and dynamic blocks, a gzip header with every field) and by Zig's
//! std.compress are unpacked whole, a byte at a time each way, and in
//! pieces that make repeats reach into the window; broken ones are
//! refused for the reason they are broken. What Deflate packs, at every
//! level and in every wrapping, whole and a byte at a time, is read back
//! by std.compress and by Inflate.

const std = @import("std");
const sdk = @import("sdk");
const compression = sdk.compression;
const ExecBase = sdk.interface.exec.ExecBase;
const CompressionBase = sdk.interface.compression.CompressionBase;
const compression_init = @import("../compression_init.zig");
const kexec = @import("host_rom").exec;
const flate = std.compress.flate;

const testing = std.testing;

test {
    _ = @import("../compression_lvo.zig");
}

/// Memory lent to exec: a packing stream's state is larger than the test
/// RAM exec starts with.
var lent: [1024 * 1024]u8 align(16) = undefined;

/// exec with memory lent, and the library; the base the tests open is
/// theirs.
const Rig = struct {
    sys: *ExecBase,
    region: *sdk.exec.MemHeader,
    library: *sdk.exec.Library,
    cb: *CompressionBase,

    fn init() !Rig {
        try kexec.setUp();
        const sys = kexec.SysBase.iface();
        const region = sys.AddMemList(lent.len, sdk.exec.MEMF_ANY, 0, &lent, "lent").?;
        const made = kexec.InitResident(kexec.SysBase, &compression_init.compression_library_tag, null) orelse return error.NoLibrary;
        const library: *sdk.exec.Library = @ptrCast(@alignCast(made));
        const opened = sys.OpenLibrary(compression.COMPRESSIONNAME, 1) orelse return error.NoBase;
        return .{ .sys = sys, .region = region, .library = library, .cb = @ptrCast(opened) };
    }

    /// The library closed and expunged, and nothing left behind.
    fn deinit(rig: *Rig) !void {
        rig.sys.CloseLibrary(rig.cb.lib());
        _ = rig.sys.RemLibrary(rig.library);
        try kexec.expectNoLeaks();
        try testing.expectEqual(@intFromPtr(rig.region.upper) - @intFromPtr(rig.region.lower), rig.region.free);
        rig.sys.Remove(&rig.region.node);
        kexec.deinit();
    }
};

fn hex(comptime text: []const u8) [text.len / 2]u8 {
    @setEvalBranchQuota(100_000);
    var out: [text.len / 2]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, text) catch unreachable;
    return out;
}

/// The words the fixtures were made of, in the order Python's generator
/// put them.
fn wordsText(into: []u8) []u8 {
    const words = [_][]const u8{ "git", "pack", "object", "tree", "blob", "commit", "delta", "window", "huffman", "code", "stream", "PowerOS", "Amiga", "library", "device" };
    var seed: u32 = 1;
    var length: usize = 0;
    var count: usize = 0;
    while (length < 3000) {
        seed = (seed *% 1103515245 +% 12345) & 0x7FFF_FFFF;
        const word = words[(seed >> 16) % words.len];
        @memcpy(into[length..][0..word.len], word);
        length += word.len;
        count += 1;
        into[length] = if (count % 12 == 0) '\n' else ' ';
        length += 1;
    }
    return into[0..length];
}

const short_text = "PowerOS packs and unpacks with DEFLATE. " ** 3 ++ "The quick brown fox jumps over the lazy dog.\n";

const zlib_fixed = hex("78010bc82f4f2df20f5628484cce2e5648cc4b5128cd83b0cb334b32145c5cdd7c1c435cf51402a8ac2e242355a1b03433395b21a928bf3c4f212dbf4221ab34b7a05821bf2cb548a12423552127b1aa5221253f5d8f0b006d7538aa");
const zlib_stored = hex("780101a5005aff506f7765724f53207061636b7320616e6420756e7061636b732077697468204445464c4154452e20506f7765724f53207061636b7320616e6420756e7061636b732077697468204445464c4154452e20506f7765724f53207061636b7320616e6420756e7061636b732077697468204445464c4154452e2054686520717569636b2062726f776e20666f78206a756d7073206f76657220746865206c617a7920646f672e0a6d7538aa");
const raw_fixed = hex("0bc82f4f2df20f5628484cce2e5648cc4b5128cd83b0cb334b32145c5cdd7c1c435cf51402a8ac2e242355a1b03433395b21a928bf3c4f212dbf4221ab34b7a05821bf2cb548a12423552127b1aa5221253f5d8f0b00");
/// FEXTRA, FNAME (hello.txt), FCOMMENT and FHCRC.
const gzip_fields = hex("1f8b081e00000000000304006162000068656c6c6f2e747874006120636f6d6d656e740023580bc82f4f2df20f5628484cce2e5648cc4b5128cd83b0cb334b32145c5cdd7c1c435cf51402a8ac2e242355a1b03433395b21a928bf3c4f212dbf4221ab34b7a05821bf2cb548a12423552127b1aa5221253f5d8f0b000de402afa5000000");
/// zlib level 9 of wordsText: one dynamic block.
const zlib_dynamic = hex("78da6d565b929b400cfc9f53cc5572826c554e80cdec2c8959525e27aedc3e466a8dd4821f6360d47ab55a7cfc797f5fa7cf7a5b2ef7e9feaf3eeeadd5afd7efb4d6dfd3f557dd2e3fdbf551fbf2a8d76d6ef5dbbaf4a9ceedf698eae5b65d70a0c84b3db5aeafcb0780e5b9a046cbb7edd9eedf7f0cb7309297450f8aa19ec6dbe7f2396fcf613bb7bfcbb5b9a9dca533084e02355f8aa9bf16a55df70424d884d33da3828a786288409c1890e6602ef50e98b0d7227368527101460bdc09ac90a61c941fc098dfd018751a0e05f8f330b5fc382c18ee87fb8694c7656e143600cb6851702968910b8156d67941355f5677bbf7c0a430862b8f237d2d2bdc868a16a6c7f0a4ee231790ba64a1d1321af835b02570ca0297d84fe0e5b8e4dccb69f104d525a2b47c22fff05fd21633c0ecd685096f698185084263157b22a1fc585d042d8facd828748a4c6c99ec7622f794592d9061d488ed897a7236b45bab7632e82e17414a9c3e9d9ba3307d74310e3852d217722ef1884aeb48494b2cbcc1afa8b31ae548ee50f558621a08b443ea052604fd7c257632b29e66a4273d392a3acfa1dd204758d9d3d4331afd300325d16264cb9d74f90ac20120d405f398b8cea9c3a22faca6acd5bebe769b42ab2f0c0e693ebc0d1604b910fbfd7089f51fc2125717afb54122da1a56d842e2c719c823c6c45d0f1a05e136a526913e2cba33cef390a56d146a8c7c60e5c31ab76de8ad909f4945b972ad7b420e439d2b85c763f649165829a3fc79014a5a1a9d2995a99ba42c44a6b1730bb94afe757458d9723a8c019ab8dfa3262e9039144518dd759ed1ae2ab1524cad244651d00427a900f05ceb7cace3ec9e44420bd53f6a0a0f0eafefc85ada9fe9b382564f52c7ac474492419d93b6f80ac910c7ad6a55a0b532708db787ef378de53fb0154333");

/// `packed` unpacked in one go: the bytes, in `into`.
fn uncompress(cb: *CompressionBase, format: u32, packed_bytes: []const u8, into: []u8) ![]u8 {
    var stream: compression.Stream = .{
        .next_in = packed_bytes.ptr,
        .avail_in = @intCast(packed_bytes.len),
        .next_out = into.ptr,
        .avail_out = @intCast(into.len),
    };
    const result = cb.Uncompress(&stream, format);
    if (result != compression.COMPRESS_OK) return error.Refused;
    try testing.expectEqual(@as(u64, packed_bytes.len), stream.total_in);
    return into[0..@intCast(stream.total_out)];
}

/// `packed` unpacked with `in_step` bytes of input and `out_step` of room
/// at a time.
fn inflatePieces(cb: *CompressionBase, format: u32, packed_bytes: []const u8, into: []u8, in_step: usize, out_step: usize) ![]u8 {
    var stream: compression.Stream = .{};
    try testing.expectEqual(compression.COMPRESS_OK, cb.InitInflate(&stream, format));
    defer cb.EndInflate(&stream);
    var given: usize = 0;
    var made: usize = 0;
    while (true) {
        if (stream.avail_in == 0 and given < packed_bytes.len) {
            const count = @min(in_step, packed_bytes.len - given);
            stream.next_in = packed_bytes[given..].ptr;
            stream.avail_in = @intCast(count);
            given += count;
        }
        const room = @min(out_step, into.len - made);
        stream.next_out = into[made..].ptr;
        stream.avail_out = @intCast(room);
        const result = cb.Inflate(&stream, if (given == packed_bytes.len) compression.FLUSH_FINISH else compression.FLUSH_NONE);
        made += room - stream.avail_out;
        if (result == compression.COMPRESS_END) break;
        if (result != compression.COMPRESS_OK) return error.Refused;
    }
    try testing.expectEqual(@as(u64, packed_bytes.len), stream.total_in);
    try testing.expectEqual(@as(u64, made), stream.total_out);
    return into[0..made];
}

test "CRC-32 and Adler-32: the check values, and carried on in pieces" {
    var rig = try Rig.init();
    const cb = rig.cb;
    try testing.expectEqual(@as(u32, 0xCBF4_3926), cb.Crc32(0, "123456789", 9));
    try testing.expectEqual(@as(u32, 0xCBF4_3926), cb.Crc32(cb.Crc32(0, "1234", 4), "56789", 5));
    try testing.expectEqual(@as(u32, 0x11E6_0398), cb.Adler32(1, "Wikipedia", 9));
    try testing.expectEqual(@as(u32, 0x11E6_0398), cb.Adler32(cb.Adler32(1, "Wiki", 4), "pedia", 5));
    try testing.expectEqual(@as(u32, 7), cb.Crc32(7, null, 0));
    try rig.deinit();
}

test "zlib's own streams: stored, fixed, dynamic, raw, gzip with every header field" {
    var rig = try Rig.init();
    const cb = rig.cb;
    var out: [4096]u8 = undefined;
    try testing.expectEqualStrings(short_text, try uncompress(cb, compression.FORMAT_ZLIB, &zlib_stored, &out));
    try testing.expectEqualStrings(short_text, try uncompress(cb, compression.FORMAT_ZLIB, &zlib_fixed, &out));
    try testing.expectEqualStrings(short_text, try uncompress(cb, compression.FORMAT_RAW, &raw_fixed, &out));
    try testing.expectEqualStrings(short_text, try uncompress(cb, compression.FORMAT_GZIP, &gzip_fields, &out));
    try testing.expectEqualStrings(short_text, try uncompress(cb, compression.FORMAT_AUTO, &gzip_fields, &out));
    try testing.expectEqualStrings(short_text, try uncompress(cb, compression.FORMAT_AUTO, &zlib_fixed, &out));
    var words: [3100]u8 = undefined;
    try testing.expectEqualStrings(wordsText(&words), try uncompress(cb, compression.FORMAT_ZLIB, &zlib_dynamic, &out));
    try rig.deinit();
}

test "a byte at a time, in and out, and FORMAT_AUTO said back" {
    var rig = try Rig.init();
    const cb = rig.cb;
    var out: [4096]u8 = undefined;
    var words: [3100]u8 = undefined;
    try testing.expectEqualStrings(wordsText(&words), try inflatePieces(cb, compression.FORMAT_ZLIB, &zlib_dynamic, &out, 1, 1));
    try testing.expectEqualStrings(short_text, try inflatePieces(cb, compression.FORMAT_AUTO, &gzip_fields, &out, 1, 1));
    try testing.expectEqualStrings(short_text, try inflatePieces(cb, compression.FORMAT_ZLIB, &zlib_stored, &out, 3, 7));

    var stream: compression.Stream = .{ .next_in = &gzip_fields, .avail_in = 2 };
    try testing.expectEqual(compression.COMPRESS_OK, cb.InitInflate(&stream, compression.FORMAT_AUTO));
    try testing.expectEqual(compression.COMPRESS_OK, cb.Inflate(&stream, compression.FLUSH_NONE));
    try testing.expectEqual(compression.FORMAT_GZIP, stream.format);
    cb.EndInflate(&stream);
    try testing.expect(stream.state == null);
    try rig.deinit();
}

test "the stream's end found: what follows is not read" {
    var rig = try Rig.init();
    const cb = rig.cb;
    var joined: [zlib_fixed.len + 5]u8 = undefined;
    @memcpy(joined[0..zlib_fixed.len], &zlib_fixed);
    @memcpy(joined[zlib_fixed.len..], "after");
    var out: [512]u8 = undefined;
    var stream: compression.Stream = .{ .next_in = &joined, .avail_in = joined.len, .next_out = &out, .avail_out = out.len };
    try testing.expectEqual(compression.COMPRESS_OK, cb.Uncompress(&stream, compression.FORMAT_ZLIB));
    try testing.expectEqual(@as(u64, zlib_fixed.len), stream.total_in);
    try testing.expectEqual(@as(u32, 5), stream.avail_in);
    try testing.expectEqualStrings("after", stream.next_in.?[0..5]);

    // A raw stream ends on its last code, part of a byte in: the rest of
    // that byte is padding, and the next byte is left.
    var raw_joined: [raw_fixed.len + 1]u8 = undefined;
    @memcpy(raw_joined[0..raw_fixed.len], &raw_fixed);
    raw_joined[raw_fixed.len] = 0xAA;
    var raw_stream: compression.Stream = .{ .next_in = &raw_joined, .avail_in = raw_joined.len, .next_out = &out, .avail_out = out.len };
    try testing.expectEqual(compression.COMPRESS_OK, cb.Uncompress(&raw_stream, compression.FORMAT_RAW));
    try testing.expectEqual(@as(u64, raw_fixed.len), raw_stream.total_in);
    try rig.deinit();
}

test "room for exactly the bytes: the end of the block and the trailer still read" {
    var rig = try Rig.init();
    const cb = rig.cb;
    var words: [3100]u8 = undefined;
    const text = wordsText(&words);
    var out: [3100]u8 = undefined;
    for ([_][]const u8{ &zlib_dynamic, &gzip_fields }, [_][]const u8{ text, short_text }) |packed_bytes, expected| {
        var stream: compression.Stream = .{ .next_in = packed_bytes.ptr, .avail_in = @intCast(packed_bytes.len), .next_out = &out, .avail_out = @intCast(expected.len) };
        try testing.expectEqual(compression.COMPRESS_OK, cb.Uncompress(&stream, compression.FORMAT_AUTO));
        try testing.expectEqual(@as(u64, packed_bytes.len), stream.total_in);
        try testing.expectEqualStrings(expected, out[0..expected.len]);
        // A byte less is too little.
        stream = .{ .next_in = packed_bytes.ptr, .avail_in = @intCast(packed_bytes.len), .next_out = &out, .avail_out = @intCast(expected.len - 1) };
        try testing.expectEqual(compression.COMPRESSERR_BUFFER, cb.Uncompress(&stream, compression.FORMAT_AUTO));
    }
    try rig.deinit();
}

test "refused: too little room, cut short, a byte changed, a header that is none" {
    var rig = try Rig.init();
    const cb = rig.cb;
    var out: [4096]u8 = undefined;

    var small: compression.Stream = .{ .next_in = &zlib_fixed, .avail_in = zlib_fixed.len, .next_out = &out, .avail_out = 100 };
    try testing.expectEqual(compression.COMPRESSERR_BUFFER, cb.Uncompress(&small, compression.FORMAT_ZLIB));

    var cut: compression.Stream = .{ .next_in = &zlib_fixed, .avail_in = zlib_fixed.len - 3, .next_out = &out, .avail_out = out.len };
    try testing.expectEqual(compression.COMPRESSERR_TRUNCATED, cb.Uncompress(&cut, compression.FORMAT_ZLIB));

    var changed = zlib_stored;
    changed[40] ^= 1;
    var flipped: compression.Stream = .{ .next_in = &changed, .avail_in = changed.len, .next_out = &out, .avail_out = out.len };
    try testing.expectEqual(compression.COMPRESSERR_DATA, cb.Uncompress(&flipped, compression.FORMAT_ZLIB));

    var gzip_size = gzip_fields;
    gzip_size[gzip_size.len - 4] ^= 1;
    var sized: compression.Stream = .{ .next_in = &gzip_size, .avail_in = gzip_size.len, .next_out = &out, .avail_out = out.len };
    try testing.expectEqual(compression.COMPRESSERR_DATA, cb.Uncompress(&sized, compression.FORMAT_GZIP));

    var wrong: compression.Stream = .{ .next_in = &zlib_fixed, .avail_in = zlib_fixed.len, .next_out = &out, .avail_out = out.len };
    try testing.expectEqual(compression.COMPRESSERR_DATA, cb.Uncompress(&wrong, compression.FORMAT_GZIP));

    var not_set_up: compression.Stream = .{};
    try testing.expectEqual(compression.COMPRESSERR_STREAM, cb.Inflate(&not_set_up, compression.FLUSH_NONE));
    try testing.expectEqual(compression.COMPRESSERR_STREAM, cb.InitInflate(&not_set_up, 7));
    var too_small: compression.Stream = .{ .size = 8 };
    try testing.expectEqual(compression.COMPRESSERR_STREAM, cb.InitInflate(&too_small, compression.FORMAT_ZLIB));
    try rig.deinit();
}

/// Bytes that compress the way files do: runs, repeats near and far
/// (some past 30 KiB back), and stretches of noise.
fn sample(into: []u8) void {
    var seed: u32 = 0x1234_5678;
    var at: usize = 0;
    while (at < into.len) {
        seed = seed *% 1664525 +% 1013904223;
        const kind = seed >> 29;
        const count = @min(into.len - at, 16 + ((seed >> 8) & 0x3FF));
        switch (kind) {
            0, 1 => for (into[at..][0..count], 0..) |*byte, index| {
                byte.* = @truncate((seed >> 3) +% index *% 7);
            },
            2, 3, 4 => {
                const back: usize = 1 + (seed & 0x7FFF);
                if (back <= at) {
                    for (0..count) |index| into[at + index] = into[at + index - back];
                } else @memset(into[at..][0..count], 'a');
            },
            else => for (into[at..][0..count]) |*byte| {
                seed = seed *% 1664525 +% 1013904223;
                byte.* = @truncate(seed >> 24);
            },
        }
        at += count;
    }
}

fn stdCompress(data: []const u8, container: flate.Container, options: flate.Compress.Options) ![]u8 {
    var packed_writer: std.Io.Writer.Allocating = try .initCapacity(testing.allocator, 1024);
    errdefer packed_writer.deinit();
    const window = try testing.allocator.alloc(u8, flate.max_window_len);
    defer testing.allocator.free(window);
    var packer = try flate.Compress.init(&packed_writer.writer, window, container, options);
    try packer.writer.writeAll(data);
    try packer.finish();
    return packed_writer.toOwnedSlice();
}

test "Zig's std.compress: every wrapping and level, whole and in pieces, repeats into the window" {
    var rig = try Rig.init();
    const cb = rig.cb;
    const data = try testing.allocator.alloc(u8, 300 * 1024);
    defer testing.allocator.free(data);
    sample(data);
    const out = try testing.allocator.alloc(u8, data.len + 16);
    defer testing.allocator.free(out);

    const cases = [_]struct { container: flate.Container, format: u32, options: flate.Compress.Options }{
        .{ .container = .zlib, .format = compression.FORMAT_ZLIB, .options = .default },
        .{ .container = .gzip, .format = compression.FORMAT_AUTO, .options = .fastest },
        .{ .container = .raw, .format = compression.FORMAT_RAW, .options = .best },
    };
    for (cases) |case| {
        const packed_bytes = try stdCompress(data, case.container, case.options);
        defer testing.allocator.free(packed_bytes);
        try testing.expectEqualSlices(u8, data, try uncompress(cb, case.format, packed_bytes, out));
        try testing.expectEqualSlices(u8, data, try inflatePieces(cb, case.format, packed_bytes, out, 4093, 1000));
        try testing.expectEqualSlices(u8, data, try inflatePieces(cb, case.format, packed_bytes, out, 17, 40000));
    }
    try rig.deinit();
}

// --- packing ------------------------------------------------------------------------

/// `packed` unpacked by Zig's std.compress, an independent decoder.
fn stdUncompress(packed_bytes: []const u8, container: flate.Container) ![]u8 {
    var reader: std.Io.Reader = .fixed(packed_bytes);
    var unpacked: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer unpacked.deinit();
    var unpacker: flate.Decompress = .init(&reader, container, &.{});
    _ = try unpacker.reader.streamRemaining(&unpacked.writer);
    return unpacked.toOwnedSlice();
}

fn containerOf(format: u32) flate.Container {
    return switch (format) {
        compression.FORMAT_ZLIB => .zlib,
        compression.FORMAT_GZIP => .gzip,
        else => .raw,
    };
}

/// `data` packed with Compress into `into`, which CompressBound sized.
fn compress(cb: *CompressionBase, format: u32, level: u32, data: []const u8, into: []u8) ![]u8 {
    const bound = cb.CompressBound(format, @intCast(data.len));
    try testing.expect(bound <= into.len);
    var stream: compression.Stream = .{
        .next_in = data.ptr,
        .avail_in = @intCast(data.len),
        .next_out = into.ptr,
        .avail_out = bound,
    };
    try testing.expectEqual(compression.COMPRESS_OK, cb.Compress(&stream, format, level));
    try testing.expectEqual(@as(u64, data.len), stream.total_in);
    try testing.expect(stream.total_out <= bound);
    return into[0..@intCast(stream.total_out)];
}

test "packed at every level and in every wrapping, read back by std.compress and by Inflate" {
    var rig = try Rig.init();
    const cb = rig.cb;
    const sampled = try testing.allocator.alloc(u8, 200 * 1024);
    defer testing.allocator.free(sampled);
    sample(sampled);
    const noise = try testing.allocator.alloc(u8, 70 * 1024);
    defer testing.allocator.free(noise);
    var seed: u32 = 99;
    for (noise) |*byte| {
        seed = seed *% 1664525 +% 1013904223;
        byte.* = @truncate(seed >> 24);
    }
    const zeros = try testing.allocator.alloc(u8, 150 * 1024);
    defer testing.allocator.free(zeros);
    @memset(zeros, 0);
    var words: [3100]u8 = undefined;
    const inputs = [_][]const u8{ sampled, noise, zeros, wordsText(&words), short_text, "", "x" };

    const packed_room = try testing.allocator.alloc(u8, 300 * 1024);
    defer testing.allocator.free(packed_room);
    const back = try testing.allocator.alloc(u8, 300 * 1024);
    defer testing.allocator.free(back);
    for ([_]u32{ compression.FORMAT_RAW, compression.FORMAT_ZLIB, compression.FORMAT_GZIP }) |format| {
        for (0..10) |level| {
            for (inputs) |data| {
                const packed_bytes = try compress(cb, format, @intCast(level), data, packed_room);
                const by_std = try stdUncompress(packed_bytes, containerOf(format));
                defer testing.allocator.free(by_std);
                try testing.expectEqualSlices(u8, data, by_std);
                try testing.expectEqualSlices(u8, data, try uncompress(cb, format, packed_bytes, back));
            }
        }
    }
    try rig.deinit();
}

test "blocks of both kinds after one another: text, noise, text, packed with the output in pieces" {
    var rig = try Rig.init();
    const cb = rig.cb;
    // Coded blocks, then stored ones, then coded again: the byte a block
    // ends on goes to one of them, never both or neither.
    const data = try testing.allocator.alloc(u8, 260 * 1024);
    defer testing.allocator.free(data);
    sample(data[0 .. 100 * 1024]);
    var seed: u32 = 3;
    for (data[100 * 1024 .. 180 * 1024]) |*byte| {
        seed = seed *% 1664525 +% 1013904223;
        byte.* = @truncate(seed >> 24);
    }
    sample(data[180 * 1024 ..]);
    const packed_bytes = try testing.allocator.alloc(u8, 300 * 1024);
    defer testing.allocator.free(packed_bytes);
    const back = try testing.allocator.alloc(u8, data.len);
    defer testing.allocator.free(back);
    for (1..10) |level| {
        // All the input at once, the output 32 KiB at a time, FLUSH_FINISH
        // on every call.
        var stream: compression.Stream = .{ .next_in = data.ptr, .avail_in = @intCast(data.len) };
        try testing.expectEqual(compression.COMPRESS_OK, cb.InitDeflate(&stream, compression.FORMAT_ZLIB, @intCast(level)));
        var made: usize = 0;
        while (true) {
            stream.next_out = packed_bytes[made..].ptr;
            stream.avail_out = 32 * 1024;
            const result = cb.Deflate(&stream, compression.FLUSH_FINISH);
            made += 32 * 1024 - stream.avail_out;
            if (result == compression.COMPRESS_END) break;
            try testing.expectEqual(compression.COMPRESS_OK, result);
        }
        cb.EndDeflate(&stream);
        try testing.expectEqualSlices(u8, data, try uncompress(cb, compression.FORMAT_ZLIB, packed_bytes[0..made], back));
        const by_std = try stdUncompress(packed_bytes[0..made], .zlib);
        defer testing.allocator.free(by_std);
        try testing.expectEqualSlices(u8, data, by_std);
    }
    try rig.deinit();
}

test "packed small: about what zlib makes of the same words, runs to almost nothing, noise stored" {
    var rig = try Rig.init();
    const cb = rig.cb;
    var room: [160 * 1024]u8 = undefined;
    var words: [3100]u8 = undefined;
    // zlib -9 makes 673 bytes of these words.
    const packed_words = try compress(cb, compression.FORMAT_ZLIB, 9, wordsText(&words), &room);
    try testing.expect(packed_words.len < 740);
    const zeros: [100 * 1024]u8 = @splat(0);
    try testing.expect((try compress(cb, compression.FORMAT_ZLIB, 6, &zeros, &room)).len < 200);
    var noise: [40 * 1024]u8 = undefined;
    var seed: u32 = 7;
    for (&noise) |*byte| {
        seed = seed *% 1664525 +% 1013904223;
        byte.* = @truncate(seed >> 24);
    }
    const packed_noise = try compress(cb, compression.FORMAT_RAW, 9, &noise, &room);
    try testing.expect(packed_noise.len <= noise.len + 16);
    try rig.deinit();
}

test "packed a byte at a time each way, with a FLUSH_SYNC that lets the far end read all so far" {
    var rig = try Rig.init();
    const cb = rig.cb;
    const data = try testing.allocator.alloc(u8, 90 * 1024);
    defer testing.allocator.free(data);
    sample(data);
    const packed_bytes = try testing.allocator.alloc(u8, 100 * 1024);
    defer testing.allocator.free(packed_bytes);

    var stream: compression.Stream = .{};
    try testing.expectEqual(compression.COMPRESS_OK, cb.InitDeflate(&stream, compression.FORMAT_ZLIB, 6));
    var given: usize = 0;
    var made: usize = 0;
    const half = data.len / 2;
    var synced_at: usize = 0;
    // The first half in pieces of 7 bytes, the output a byte at a time;
    // then a FLUSH_SYNC; then the rest, and the end.
    while (true) {
        const target = if (synced_at == 0) half else data.len;
        if (stream.avail_in == 0 and given < target) {
            const count = @min(7, target - given);
            stream.next_in = data[given..].ptr;
            stream.avail_in = @intCast(count);
            given += count;
        }
        stream.next_out = packed_bytes[made..].ptr;
        stream.avail_out = 1;
        const flush: u32 = if (given == data.len and stream.avail_in == 0) compression.FLUSH_FINISH else if (given == half and stream.avail_in == 0 and synced_at == 0) compression.FLUSH_SYNC else compression.FLUSH_NONE;
        const result = cb.Deflate(&stream, flush);
        made += 1 - stream.avail_out;
        if (flush == compression.FLUSH_SYNC and result == compression.COMPRESS_OK and stream.avail_out == 1) synced_at = made;
        if (result == compression.COMPRESS_END) break;
        try testing.expectEqual(compression.COMPRESS_OK, result);
    }
    cb.EndDeflate(&stream);
    try testing.expect(synced_at != 0);

    // Up to the sync the output is a stream cut short that unpacks to the
    // first half exactly.
    const back = try testing.allocator.alloc(u8, data.len);
    defer testing.allocator.free(back);
    var partial: compression.Stream = .{ .next_in = packed_bytes.ptr, .avail_in = @intCast(synced_at), .next_out = back.ptr, .avail_out = @intCast(back.len) };
    try testing.expectEqual(compression.COMPRESS_OK, cb.InitInflate(&partial, compression.FORMAT_ZLIB));
    try testing.expectEqual(compression.COMPRESS_OK, cb.Inflate(&partial, compression.FLUSH_NONE));
    try testing.expectEqual(@as(u64, half), partial.total_out);
    try testing.expectEqualSlices(u8, data[0..half], back[0..half]);
    cb.EndInflate(&partial);

    try testing.expectEqualSlices(u8, data, try uncompress(cb, compression.FORMAT_ZLIB, packed_bytes[0..made], back));
    const by_std = try stdUncompress(packed_bytes[0..made], .zlib);
    defer testing.allocator.free(by_std);
    try testing.expectEqualSlices(u8, data, by_std);
    try rig.deinit();
}

test "refused: no room, FORMAT_AUTO or a level past 9 to pack with" {
    var rig = try Rig.init();
    const cb = rig.cb;
    var out: [16]u8 = undefined;
    var small: compression.Stream = .{ .next_in = short_text, .avail_in = short_text.len, .next_out = &out, .avail_out = out.len };
    try testing.expectEqual(compression.COMPRESSERR_BUFFER, cb.Compress(&small, compression.FORMAT_ZLIB, 6));
    var stream: compression.Stream = .{};
    try testing.expectEqual(compression.COMPRESSERR_STREAM, cb.InitDeflate(&stream, compression.FORMAT_AUTO, 6));
    try testing.expectEqual(compression.COMPRESSERR_STREAM, cb.InitDeflate(&stream, compression.FORMAT_ZLIB, 10));
    try testing.expectEqual(compression.COMPRESSERR_STREAM, cb.Deflate(&stream, compression.FLUSH_NONE));
    try rig.deinit();
}
