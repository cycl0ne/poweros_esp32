// SPDX-License-Identifier: MIT
//! paintfx.library's jump table: every `lvo<Name>` wrapper, the table of
//! them in slot order, and the checks that hold the table to the SDK's
//! contract - the signatures and the documented LVOs at compile time, the
//! slots and the forwarding in the tests at the end.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const paintfx = sdk.paintfx;
const vec = exec.vec;
const PaintFXBase = @import("paintfx_base.zig").PaintFXBase;
const paintfx_init = @import("paintfx_init.zig");

const AdjustColours = @import("colour/adjustcolours.zig").AdjustColours;
const BlurPixels = @import("filter/blurpixels.zig").BlurPixels;
const SharpenPixels = @import("filter/sharpenpixels.zig").SharpenPixels;
const ScalePixels = @import("geometry/scalepixels.zig").ScalePixels;
const TransformPixels = @import("geometry/transformpixels.zig").TransformPixels;

/// paintfx.library's interface, as the SDK generates it from
/// sdk/fd/paintfx_lib.fd.
const interface = sdk.interface.paintfx;
const LVO = interface.LVO;

comptime {
    for (@typeInfo(LVO).@"struct".decls) |d| {
        const f = @field(@This(), "lvo" ++ d.name);
        if (!exec.libraries.sameSignature(@TypeOf(&f), @field(interface.Fn, d.name))) {
            @compileError("paintfx.library: lvo" ++ d.name ++ " does not match the SDK's type");
        }
    }
}

// Every call's contract is in the list, once, and documents the LVO the
// .fd gives it.
comptime {
    @setEvalBranchQuota(10_000_000);
    exec.libraries.checkContractFiles(&contract_files, LVO, "paintfx.library", "pub fn ");
}

/// The files whose call carries its contract, above `pub fn <Name>`.
const contract_files = [_][]const u8{
    @embedFile("colour/adjustcolours.zig"),
    @embedFile("filter/blurpixels.zig"),
    @embedFile("filter/sharpenpixels.zig"),
    @embedFile("geometry/scalepixels.zig"),
    @embedFile("geometry/transformpixels.zig"),
};

fn lvoAdjustColours(base: *PaintFXBase, pixels: *const paintfx.Pixels, adjust: *const paintfx.Adjust) callconv(.c) void {
    return AdjustColours(base, pixels, adjust);
}
fn lvoBlurPixels(base: *PaintFXBase, from: *const paintfx.Pixels, into: *const paintfx.Pixels, radius: u32) callconv(.c) i32 {
    return BlurPixels(base, from, into, radius);
}
fn lvoSharpenPixels(base: *PaintFXBase, from: *const paintfx.Pixels, into: *const paintfx.Pixels, amount: u32, radius: u32) callconv(.c) i32 {
    return SharpenPixels(base, from, into, amount, radius);
}
fn lvoScalePixels(base: *PaintFXBase, from: *const paintfx.Pixels, into: *const paintfx.Pixels, how: u32) callconv(.c) i32 {
    return ScalePixels(base, from, into, how);
}
fn lvoTransformPixels(base: *PaintFXBase, from: *const paintfx.Pixels, into: *const paintfx.Pixels, matrix: *const paintfx.Matrix, how: u32) callconv(.c) void {
    return TransformPixels(base, from, into, matrix, how);
}

/// The jump table, in slot order: the standard vectors, then one
/// `lvo<Name>` per `.fd` line.
pub const vectors = [_]*const anyopaque{
    vec(exec.libOpen),
    vec(exec.libClose),
    vec(paintfx_init.expungeVector),
    vec(exec.libExtFunc),
    vec(lvoAdjustColours),
    vec(lvoBlurPixels),
    vec(lvoSharpenPixels),
    vec(lvoScalePixels),
    vec(lvoTransformPixels),
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
    try exec.libraries.checkForwarding(@embedFile("paintfx_lvo.zig"), LVO, &.{});
}
