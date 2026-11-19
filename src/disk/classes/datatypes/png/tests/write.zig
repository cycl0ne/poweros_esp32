// SPDX-License-Identifier: MIT
//! Host tests of png.datatype's PNG encoder, on the ROM's exec with
//! compression.library made from its ROM tag: a picture like a screen
//! written with and without its coverage, then read back by the PNG
//! decoder - its stream unpacked by the library a chunk at a time - and by
//! Zig's std.compress, and unfiltered row by row into the picture it was.

const std = @import("std");
const sdk = @import("sdk");
const compression = sdk.compression;
const decode = sdk.datatypes.png.decode;
const ExecBase = sdk.interface.exec.ExecBase;
const CompressionBase = sdk.interface.compression.CompressionBase;
const kexec = @import("host_rom").exec;
const compression_init = @import("../../../../libs/compression/compression_init.zig");
const write = @import("../write.zig");

const testing = std.testing;

/// Memory lent to exec, for Deflate's state.
var lent: [1024 * 1024]u8 align(16) = undefined;

const Collect = struct {
    bytes: std.ArrayList(u8) = .empty,

    fn put(context: *anyopaque, bytes: []const u8) bool {
        const collect: *Collect = @ptrCast(@alignCast(context));
        collect.bytes.appendSlice(testing.allocator, bytes) catch return false;
        return true;
    }
};

/// A picture like a screen, as pens: flat areas, edges, text-like noise,
/// a ramp, coverage that changes along it, and below it a photograph's
/// worth of noise, which packs to more than one chunk.
fn screenLike(pens: []u32, width: u32, height: u32) void {
    var seed: u32 = 7;
    for (0..height) |y| {
        for (0..width) |x| {
            var pixel: u32 = 0xFFAAAAAF;
            if (y < 16) pixel = 0xFFFFFFFF;
            if (x > 40 and x < 200 and y > 40 and y < 120) pixel = 0x805A82C8;
            if (y > 150) pixel = @as(u32, @as(u8, @truncate(x ^ y))) << 24 | @as(u32, @as(u8, @truncate(x))) << 16 | @as(u32, @as(u8, @truncate(y))) << 8 | @as(u8, @truncate(x + y));
            seed = seed *% 1103515245 +% 12345;
            if (y > 60 and y < 70 and (seed >> 16) & 3 == 0) pixel = 0xFF000000;
            if (y > 400) pixel = seed;
            pens[y * width + x] = pixel;
        }
    }
}

/// The bytes the file holds for a pen.
fn expected(pen: u32, alpha: bool, into: []u8) void {
    into[0] = @truncate(pen >> 16);
    into[1] = @truncate(pen >> 8);
    into[2] = @truncate(pen);
    if (alpha) into[3] = @truncate(pen >> 24);
}

test "a screen-like picture written and read back is the same picture, and smaller" {
    try roundTrip(false);
    try roundTrip(true);
}

fn roundTrip(alpha: bool) !void {
    try kexec.setUp();
    const sys: *ExecBase = kexec.SysBase.iface();
    const region = sys.AddMemList(lent.len, sdk.exec.MEMF_ANY, 0, &lent, "lent").?;
    const made = kexec.InitResident(kexec.SysBase, &compression_init.compression_library_tag, null) orelse return error.NoLibrary;
    const library: *sdk.exec.Library = @ptrCast(@alignCast(made));
    const cb: *CompressionBase = @ptrCast(sys.OpenLibrary(compression.COMPRESSIONNAME, 1) orelse return error.NoBase);

    // A width whose rows are not a multiple of anything, and more rows
    // than one IDAT chunk holds packed.
    const width = 237;
    const height = 481;
    const pixel: usize = if (alpha) 4 else 3;
    const stride = 1 + width * pixel;
    const pens = try testing.allocator.alloc(u32, width * height);
    defer testing.allocator.free(pens);
    screenLike(pens, width, height);
    // The pens a row apart that is more than the row, as a picture's are
    // when they are kept to a boundary.
    const pitch = width * 4 + 12;
    const kept = try testing.allocator.alloc(u8, pitch * height);
    defer testing.allocator.free(kept);
    for (0..height) |y| @memcpy(kept[y * pitch ..][0 .. width * 4], std.mem.sliceAsBytes(pens[y * width ..][0..width]));

    const work = try testing.allocator.create(write.Work);
    defer testing.allocator.destroy(work);
    const rows = try testing.allocator.alloc(u8, write.rowRoom(width, alpha));
    defer testing.allocator.free(rows);
    var collect: Collect = .{};
    defer collect.bytes.deinit(testing.allocator);
    try testing.expectEqual(write.Result.written, write.encode(work, cb, .{ .context = &collect, .put = Collect.put }, kept.ptr, pitch, width, height, alpha, rows));
    const file = collect.bytes.items;

    const info = try decode.readInfo(file);
    try testing.expectEqual(@as(u32, width), info.width);
    try testing.expectEqual(@as(u32, height), info.height);
    try testing.expectEqual(@as(u32, if (alpha) 4 else 3), info.channels());
    try testing.expectEqual(stride * height, decode.rawSize(info));

    // The library, through the decoder, a chunk at a time.
    const raw = try testing.allocator.alloc(u8, stride * height);
    defer testing.allocator.free(raw);
    try decode.unpackRows(cb, file, raw);

    // std.compress, from the chunks joined; and the chunks are several.
    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(testing.allocator);
    var chunks: u32 = 0;
    var walk = try decode.Walk.start(file);
    while (try walk.next()) |chunk| {
        if (chunk.id != decode.ID_IDAT) continue;
        try joined.appendSlice(testing.allocator, chunk.data);
        chunks += 1;
    }
    try testing.expect(chunks > 1);
    try testing.expect(joined.items.len < raw.len / 3);
    var reader: std.Io.Reader = .fixed(joined.items);
    var by_std: std.Io.Writer.Allocating = .init(testing.allocator);
    defer by_std.deinit();
    var unpacker: std.compress.flate.Decompress = .init(&reader, .zlib, &.{});
    _ = try unpacker.reader.streamRemaining(&by_std.writer);
    try testing.expectEqualSlices(u8, raw, by_std.written());

    const zero: [1 + width * 4]u8 = @splat(0);
    var want: [width * 4]u8 = undefined;
    for (0..height) |y| {
        const row = raw[y * stride ..][0..stride];
        const above: []const u8 = if (y > 0) raw[(y - 1) * stride ..][0..stride] else zero[0..stride];
        try decode.unfilter(row[0], row[1..], above[1..], @intCast(pixel));
        for (0..width) |x| expected(pens[y * width + x], alpha, want[x * pixel ..]);
        try testing.expectEqualSlices(u8, want[0 .. width * pixel], row[1..]);
    }

    sys.CloseLibrary(cb.lib());
    _ = sys.RemLibrary(library);
    try kexec.expectNoLeaks();
    try testing.expectEqual(@intFromPtr(region.upper) - @intFromPtr(region.lower), region.free);
    sys.Remove(&region.node);
    kexec.deinit();
}
