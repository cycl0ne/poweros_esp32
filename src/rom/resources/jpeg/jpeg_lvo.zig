// SPDX-License-Identifier: MPL-2.0
//! jpeg.resource's jump table: every `lvo<Name>` wrapper, the table of
//! them in slot order, and the checks that hold the table to the SDK's
//! contract - the signatures and the documented LVOs at compile time, the
//! slots and the forwarding in the tests at the end.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const types = sdk.resources.jpeg;
const vec = exec.vec;
const JpegBase = @import("jpeg_base.zig").JpegBase;
const ExamineJPEG = @import("picture/examinejpeg.zig").ExamineJPEG;
const DecodeJPEG = @import("picture/decodejpeg.zig").DecodeJPEG;
const FreeJPEGPicture = @import("picture/freejpegpicture.zig").FreeJPEGPicture;

/// jpeg.resource's interface, as the SDK generates it from
/// sdk/fd/jpeg_lib.fd.
const interface = sdk.interface.jpeg;
const LVO = interface.LVO;

comptime {
    for (@typeInfo(LVO).@"struct".decls) |d| {
        const f = @field(@This(), "lvo" ++ d.name);
        if (!exec.libraries.sameSignature(@TypeOf(&f), @field(interface.Fn, d.name))) {
            @compileError("jpeg.resource: lvo" ++ d.name ++ " does not match the SDK's type");
        }
    }
}

// Every slot's documented LVO is the one the .fd gives it.
comptime {
    @setEvalBranchQuota(10_000_000);
    for (contract_files) |source| {
        exec.libraries.checkDocumentedLvosAt(source, LVO, "jpeg.resource", "pub fn ");
    }
}

/// The files whose call carries its contract, above `pub fn <Name>`.
const contract_files = [_][]const u8{
    @embedFile("picture/examinejpeg.zig"),
    @embedFile("picture/decodejpeg.zig"),
    @embedFile("picture/freejpegpicture.zig"),
};

fn lvoExamineJPEG(jb: *JpegBase, file: [*]const u8, length: u32, info: *types.JPEGInfo) callconv(.c) u32 {
    return ExamineJPEG(jb, file, length, info);
}
fn lvoDecodeJPEG(jb: *JpegBase, file: [*]const u8, length: u32, picture: *types.JPEGPicture) callconv(.c) u32 {
    return DecodeJPEG(jb, file, length, picture);
}
fn lvoFreeJPEGPicture(jb: *JpegBase, picture: *types.JPEGPicture) callconv(.c) void {
    FreeJPEGPicture(jb, picture);
}

/// The jump table, in slot order: a resource has no standard vectors, so
/// its first function is in the first slot.
pub const vectors = [_]*const anyopaque{
    vec(lvoExamineJPEG),
    vec(lvoDecodeJPEG),
    vec(lvoFreeJPEGPicture),
};

// --- tests (host: ./zig build test) -----------------------------------------

const testing = std.testing;

test "the jump table: this resource's own, from the first slot" {
    try testing.expectEqual(@as(usize, @typeInfo(LVO).@"struct".decls.len), vectors.len);
    inline for (@typeInfo(LVO).@"struct".decls) |d| {
        const index: usize = @intCast(@divExact(-@field(LVO, d.name), exec.slot_size) - 1);
        try testing.expectEqual(vec(@field(@This(), "lvo" ++ d.name)), vectors[index]);
    }
}

test "every wrapper hands its parameters on, in order, to the call it is named after" {
    try exec.libraries.checkForwarding(@embedFile("jpeg_lvo.zig"), LVO, &.{});
}
