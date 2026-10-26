// SPDX-License-Identifier: MIT
//! compression.library's jump table: every `lvo<Name>` wrapper, the table
//! of them in slot order, and the checks that hold the table to the SDK's
//! contract - the signatures and the documented LVOs at compile time, the
//! slots and the forwarding in the tests at the end.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const compression = sdk.compression;
const vec = exec.vec;
const CompressionBase = @import("compression_base.zig").CompressionBase;
const compression_init = @import("compression_init.zig");

const InitInflate = @import("inflate/initinflate.zig").InitInflate;
const Inflate = @import("inflate/inflate.zig").Inflate;
const EndInflate = @import("inflate/endinflate.zig").EndInflate;
const InitDeflate = @import("deflate/initdeflate.zig").InitDeflate;
const Deflate = @import("deflate/deflate.zig").Deflate;
const EndDeflate = @import("deflate/enddeflate.zig").EndDeflate;
const Uncompress = @import("inflate/uncompress.zig").Uncompress;
const Compress = @import("deflate/compress.zig").Compress;
const CompressBound = @import("deflate/compressbound.zig").CompressBound;
const Crc32 = @import("checksum/crc32.zig").Crc32;
const Adler32 = @import("checksum/adler32.zig").Adler32;

/// compression.library's interface, as the SDK generates it from
/// sdk/fd/compression_lib.fd.
const interface = sdk.interface.compression;
const LVO = interface.LVO;

comptime {
    for (@typeInfo(LVO).@"struct".decls) |d| {
        const f = @field(@This(), "lvo" ++ d.name);
        if (!exec.libraries.sameSignature(@TypeOf(&f), @field(interface.Fn, d.name))) {
            @compileError("compression.library: lvo" ++ d.name ++ " does not match the SDK's type");
        }
    }
}

// Every slot's documented LVO is the one the .fd gives it.
comptime {
    @setEvalBranchQuota(10_000_000);
    for (contract_files) |source| {
        exec.libraries.checkDocumentedLvosAt(source, LVO, "compression.library", "pub fn ");
    }
}

/// The files whose call carries its contract, above `pub fn <Name>`.
const contract_files = [_][]const u8{
    @embedFile("inflate/initinflate.zig"),
    @embedFile("inflate/inflate.zig"),
    @embedFile("inflate/endinflate.zig"),
    @embedFile("deflate/initdeflate.zig"),
    @embedFile("deflate/deflate.zig"),
    @embedFile("deflate/enddeflate.zig"),
    @embedFile("inflate/uncompress.zig"),
    @embedFile("deflate/compress.zig"),
    @embedFile("deflate/compressbound.zig"),
    @embedFile("checksum/crc32.zig"),
    @embedFile("checksum/adler32.zig"),
};

fn lvoInitInflate(cb: *CompressionBase, stream: *compression.Stream, format: u32) callconv(.c) i32 {
    return InitInflate(cb, stream, format);
}
fn lvoInflate(cb: *CompressionBase, stream: *compression.Stream, flush: u32) callconv(.c) i32 {
    return Inflate(cb, stream, flush);
}
fn lvoEndInflate(cb: *CompressionBase, stream: *compression.Stream) callconv(.c) void {
    return EndInflate(cb, stream);
}
fn lvoInitDeflate(cb: *CompressionBase, stream: *compression.Stream, format: u32, level: u32) callconv(.c) i32 {
    return InitDeflate(cb, stream, format, level);
}
fn lvoDeflate(cb: *CompressionBase, stream: *compression.Stream, flush: u32) callconv(.c) i32 {
    return Deflate(cb, stream, flush);
}
fn lvoEndDeflate(cb: *CompressionBase, stream: *compression.Stream) callconv(.c) void {
    return EndDeflate(cb, stream);
}
fn lvoUncompress(cb: *CompressionBase, stream: *compression.Stream, format: u32) callconv(.c) i32 {
    return Uncompress(cb, stream, format);
}
fn lvoCompress(cb: *CompressionBase, stream: *compression.Stream, format: u32, level: u32) callconv(.c) i32 {
    return Compress(cb, stream, format, level);
}
fn lvoCompressBound(cb: *CompressionBase, format: u32, length: u32) callconv(.c) u32 {
    return CompressBound(cb, format, length);
}
fn lvoCrc32(cb: *CompressionBase, crc: u32, data: ?*const anyopaque, length: u32) callconv(.c) u32 {
    return Crc32(cb, crc, data, length);
}
fn lvoAdler32(cb: *CompressionBase, adler: u32, data: ?*const anyopaque, length: u32) callconv(.c) u32 {
    return Adler32(cb, adler, data, length);
}

/// The jump table, in slot order: the standard vectors, then one
/// `lvo<Name>` per `.fd` line.
pub const vectors = [_]*const anyopaque{
    vec(exec.libOpen),
    vec(exec.libClose),
    vec(compression_init.expungeVector),
    vec(exec.libExtFunc),
    vec(lvoInitInflate),
    vec(lvoInflate),
    vec(lvoEndInflate),
    vec(lvoInitDeflate),
    vec(lvoDeflate),
    vec(lvoEndDeflate),
    vec(lvoUncompress),
    vec(lvoCompress),
    vec(lvoCompressBound),
    vec(lvoCrc32),
    vec(lvoAdler32),
};

// --- tests (host: ./zig build test) -----------------------------------------

const testing = std.testing;

test "the jump table: the standard four, then this library's own" {
    try testing.expectEqual(@as(usize, 4 + @typeInfo(LVO).@"struct".decls.len), vectors.len);
    inline for (@typeInfo(LVO).@"struct".decls) |d| {
        const index: usize = @intCast(@divExact(-@field(LVO, d.name), exec.slot_size) - 1);
        try testing.expectEqual(vec(@field(@This(), "lvo" ++ d.name)), vectors[index]);
    }
}

test "every wrapper hands its parameters on, in order, to the call it is named after" {
    try exec.libraries.checkForwarding(@embedFile("compression_lvo.zig"), LVO, &.{});
}
