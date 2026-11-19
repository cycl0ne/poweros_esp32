// SPDX-License-Identifier: MIT
//! paintio.library's jump table: every `lvo<Name>` wrapper, the table of
//! them in slot order, and the checks that hold the table to the SDK's
//! contract - the signatures and the documented LVOs at compile time, the
//! slots and the forwarding in the tests at the end.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const paintio = sdk.paintio;
const vec = exec.vec;
const PaintIOBase = @import("paintio_base.zig").PaintIOBase;
const paintio_init = @import("paintio_init.zig");

const LoadProject = @import("project/loadproject.zig").LoadProject;
const SaveProject = @import("project/saveproject.zig").SaveProject;
const SavePicture = @import("picture/savepicture.zig").SavePicture;
const FreeProject = @import("project/freeproject.zig").FreeProject;

/// paintio.library's interface, as the SDK generates it from
/// sdk/fd/paintio_lib.fd.
const interface = sdk.interface.paintio;
const LVO = interface.LVO;

comptime {
    for (@typeInfo(LVO).@"struct".decls) |d| {
        const f = @field(@This(), "lvo" ++ d.name);
        if (!exec.libraries.sameSignature(@TypeOf(&f), @field(interface.Fn, d.name))) {
            @compileError("paintio.library: lvo" ++ d.name ++ " does not match the SDK's type");
        }
    }
}

// Every call's contract is in the list, once, and documents the LVO the
// .fd gives it.
comptime {
    @setEvalBranchQuota(10_000_000);
    exec.libraries.checkContractFiles(&contract_files, LVO, "paintio.library", "pub fn ");
}

/// The files whose call carries its contract, above `pub fn <Name>`.
const contract_files = [_][]const u8{
    @embedFile("project/loadproject.zig"),
    @embedFile("project/saveproject.zig"),
    @embedFile("picture/savepicture.zig"),
    @embedFile("project/freeproject.zig"),
};

fn lvoLoadProject(base: *PaintIOBase, name: [*:0]const u8, project: *paintio.Project) callconv(.c) i32 {
    return LoadProject(base, name, project);
}
fn lvoSaveProject(base: *PaintIOBase, name: [*:0]const u8, project: *const paintio.Project) callconv(.c) i32 {
    return SaveProject(base, name, project);
}
fn lvoSavePicture(base: *PaintIOBase, name: [*:0]const u8, pixels: [*]const u32, width: u32, height: u32, format: u32) callconv(.c) i32 {
    return SavePicture(base, name, pixels, width, height, format);
}
fn lvoFreeProject(base: *PaintIOBase, project: *paintio.Project) callconv(.c) void {
    return FreeProject(base, project);
}

/// The jump table, in slot order: the standard vectors, then one
/// `lvo<Name>` per `.fd` line.
pub const vectors = [_]*const anyopaque{
    vec(exec.libOpen),
    vec(exec.libClose),
    vec(paintio_init.expungeVector),
    vec(exec.libExtFunc),
    vec(lvoLoadProject),
    vec(lvoSaveProject),
    vec(lvoSavePicture),
    vec(lvoFreeProject),
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
    try exec.libraries.checkForwarding(@embedFile("paintio_lvo.zig"), LVO, &.{});
}
