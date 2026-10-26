// SPDX-License-Identifier: MIT
//! Host tests of ScreenDump's PNG writer, on the ROM's exec with
//! compression.library made from its ROM tag: a picture like a screen
//! written, then read back by the PNG decoder - its stream unpacked by the
//! library a chunk at a time - and by Zig's std.compress, and unfiltered
//! row by row into the picture it was.

const std = @import("std");
const sdk = @import("sdk");
const compression = sdk.compression;
const decode = sdk.datatypes.png.decode;
const ExecBase = sdk.interface.exec.ExecBase;
const CompressionBase = sdk.interface.compression.CompressionBase;
const kexec = @import("host_rom").exec;
const compression_init = @import("../../../libs/compression/compression_init.zig");
const png = @import("../png.zig");

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

/// A picture like a screen: flat areas, edges, text-like noise, a ramp,
/// and below it a photograph's worth of noise, which packs to more than
/// one chunk.
fn screenLike(rows: []u8, width: u32, height: u32) void {
    const stride = png.rowBytes(width);
    var seed: u32 = 7;
    for (0..height) |y| {
        for (0..width) |x| {
            const at = y * stride + 1 + x * 3;
            var pixel = [3]u8{ 170, 170, 175 };
            if (y < 16) pixel = .{ 255, 255, 255 };
            if (x > 40 and x < 200 and y > 40 and y < 120) pixel = .{ 90, 130, 200 };
            if (y > 150) pixel = .{ @truncate(x), @truncate(y), @truncate(x + y) };
            seed = seed *% 1103515245 +% 12345;
            if (y > 60 and y < 70 and (seed >> 16) & 3 == 0) pixel = .{ 0, 0, 0 };
            if (y > 400) pixel = .{ @truncate(seed >> 24), @truncate(seed >> 16), @truncate(seed >> 8) };
            @memcpy(rows[at..][0..3], &pixel);
        }
    }
}

test "a screen-like picture written and read back is the same picture, and smaller" {
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
    const stride = comptime png.rowBytes(width);
    const rows = try testing.allocator.alloc(u8, stride * height);
    defer testing.allocator.free(rows);
    screenLike(rows, width, height);
    const original = try testing.allocator.dupe(u8, rows);
    defer testing.allocator.free(original);

    const work = try testing.allocator.create(png.Work);
    defer testing.allocator.destroy(work);
    var collect: Collect = .{};
    defer collect.bytes.deinit(testing.allocator);
    try testing.expectEqual(png.Result.written, png.write(work, cb, .{ .context = &collect, .put = Collect.put }, width, height, rows));
    const file = collect.bytes.items;

    const info = try decode.readInfo(file);
    try testing.expectEqual(@as(u32, width), info.width);
    try testing.expectEqual(@as(u32, height), info.height);
    try testing.expectEqual(original.len, decode.rawSize(info));

    // The library, through the decoder, a chunk at a time.
    const raw = try testing.allocator.alloc(u8, original.len);
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
    try testing.expect(joined.items.len < original.len / 3);
    var reader: std.Io.Reader = .fixed(joined.items);
    var by_std: std.Io.Writer.Allocating = .init(testing.allocator);
    defer by_std.deinit();
    var unpacker: std.compress.flate.Decompress = .init(&reader, .zlib, &.{});
    _ = try unpacker.reader.streamRemaining(&by_std.writer);
    try testing.expectEqualSlices(u8, raw, by_std.written());

    const zero: [stride]u8 = @splat(0);
    for (0..height) |y| {
        const row = raw[y * stride ..][0..stride];
        const above: []const u8 = if (y > 0) raw[(y - 1) * stride ..][0..stride] else &zero;
        try decode.unfilter(row[0], row[1..], above[1..], 3);
        try testing.expectEqualSlices(u8, original[y * stride + 1 ..][0 .. stride - 1], row[1..]);
    }

    sys.CloseLibrary(cb.lib());
    _ = sys.RemLibrary(library);
    try kexec.expectNoLeaks();
    try testing.expectEqual(@intFromPtr(region.upper) - @intFromPtr(region.lower), region.free);
    sys.Remove(&region.node);
    kexec.deinit();
}
