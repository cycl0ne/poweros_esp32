// SPDX-License-Identifier: MPL-2.0
//! ramlib.library's jump table. What it does it does by standing in front
//! of exec's OpenLibrary and OpenDevice; its one call of its own is exec's,
//! made when a module goes (SINCE 1.4).

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const vec = exec.vec;
const ramlib_base = @import("ramlib_base.zig");
const RamLibBase = ramlib_base.RamLibBase;
const UnLoadModule = @import("unloadmodule.zig").UnLoadModule;

/// ramlib.library's interface, as the SDK generates it from
/// sdk/fd/ramlib_lib.fd.
const interface = sdk.interface.ramlib;
const LVO = interface.LVO;

comptime {
    for (@typeInfo(LVO).@"struct".decls) |d| {
        const f = @field(@This(), "lvo" ++ d.name);
        if (!exec.libraries.sameSignature(@TypeOf(&f), @field(interface.Fn, d.name))) {
            @compileError("ramlib.library: lvo" ++ d.name ++ " does not match the SDK's type");
        }
    }
}

// Every slot's documented LVO is the one the .fd gives it.
comptime {
    @setEvalBranchQuota(1_000_000);
    exec.libraries.checkDocumentedLvosAt(@embedFile("unloadmodule.zig"), LVO, "ramlib.library", "pub fn ");
}

fn lvoUnLoadModule(rlb: *RamLibBase, seg_list: ?*anyopaque) callconv(.c) void {
    UnLoadModule(rlb, seg_list);
}

/// ramlib.library's jump table: the standard Open, Close and ExtFunc, and
/// its own Expunge, which refuses - it has patched OpenLibrary and
/// OpenDevice, and freeing it would leave those slots pointing at freed
/// code - then UnLoadModule.
pub const vectors = [_]*const anyopaque{
    vec(exec.libOpen),
    vec(exec.libClose),
    vec(ramlib_base.expunge),
    vec(exec.libExtFunc),
    vec(lvoUnLoadModule),
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
    try exec.libraries.checkForwarding(@embedFile("ramlib_lvo.zig"), LVO, &.{});
}
