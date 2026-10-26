// SPDX-License-Identifier: MIT
//! What Git's host tests run on: exec with memory lent to it,
//! crypto.library and compression.library made and opened as a program
//! opens them, and a sink that collects bytes in a buffer.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const compression = sdk.compression;
const ExecBase = sdk.interface.exec.ExecBase;
const CryptoBase = sdk.interface.crypto.CryptoBase;
const CompressionBase = sdk.interface.compression.CompressionBase;
const crypto_init = @import("../../../../libs/crypto/crypto_init.zig");
const compression_init = @import("../../../../libs/compression/compression_init.zig");
const kexec = @import("host_rom").exec;
const _git = @import("../_git.zig");

const testing = std.testing;

var lent: [512 * 1024]u8 align(16) = undefined;

pub const Rig = struct {
    sys: *ExecBase,
    region: *exec.MemHeader,
    crypto_lib: *exec.Library,
    compression_lib: *exec.Library,
    cb: *CryptoBase,
    zb: *CompressionBase,

    pub fn init() !Rig {
        try kexec.setUp();
        const sys = kexec.SysBase.iface();
        const region = sys.AddMemList(lent.len, exec.MEMF_ANY, 0, &lent, "lent").?;
        const crypto_made = kexec.InitResident(kexec.SysBase, &crypto_init.crypto_library_tag, null) orelse return error.NoCrypto;
        const compression_made = kexec.InitResident(kexec.SysBase, &compression_init.compression_library_tag, null) orelse return error.NoCompression;
        const cb = sys.OpenLibrary(sdk.crypto.CRYPTONAME, 1) orelse return error.NoBase;
        const zb = sys.OpenLibrary(compression.COMPRESSIONNAME, 1) orelse return error.NoBase;
        return .{
            .sys = sys,
            .region = region,
            .crypto_lib = @ptrCast(@alignCast(crypto_made)),
            .compression_lib = @ptrCast(@alignCast(compression_made)),
            .cb = @ptrCast(cb),
            .zb = @ptrCast(zb),
        };
    }

    /// The libraries closed and expunged, and nothing left behind.
    pub fn deinit(rig: *Rig) !void {
        rig.sys.CloseLibrary(rig.cb.lib());
        rig.sys.CloseLibrary(rig.zb.lib());
        _ = rig.sys.RemLibrary(rig.crypto_lib);
        _ = rig.sys.RemLibrary(rig.compression_lib);
        try kexec.expectNoLeaks();
        try testing.expectEqual(@intFromPtr(rig.region.upper) - @intFromPtr(rig.region.lower), rig.region.free);
        rig.sys.Remove(&rig.region.node);
        kexec.deinit();
    }

    /// The zlib stream at the start of `bytes` into `into`, which holds
    /// exactly what it unpacks to: how many bytes of `bytes` it took.
    pub fn inflate(rig: *Rig, bytes: []const u8, into: []u8) !usize {
        var stream: compression.Stream = .{};
        try testing.expectEqual(compression.COMPRESS_OK, rig.zb.InitInflate(&stream, compression.FORMAT_ZLIB));
        defer rig.zb.EndInflate(&stream);
        stream.next_in = bytes.ptr;
        stream.avail_in = @intCast(bytes.len);
        stream.next_out = into.ptr;
        stream.avail_out = @intCast(into.len);
        try testing.expectEqual(compression.COMPRESS_END, rig.zb.Inflate(&stream, compression.FLUSH_FINISH));
        try testing.expectEqual(@as(u64, into.len), stream.total_out);
        return @intCast(stream.total_in);
    }
};

/// Bytes collected in a buffer: a sink that fails when it is full.
pub const BufferSink = struct {
    out: _git.Out,

    fn write(context: *anyopaque, data: []const u8) bool {
        const buffer: *BufferSink = @ptrCast(@alignCast(context));
        buffer.out.put(data);
        return !buffer.out.overflow;
    }

    pub fn sink(buffer: *BufferSink) _git.Sink {
        return .{ .context = buffer, .write = write };
    }
};
