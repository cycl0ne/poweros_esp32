// SPDX-License-Identifier: MPL-2.0
//! battmem.resource's jump table: every `lvo<Name>` wrapper, the table of
//! them in slot order, and the checks that hold the table to the SDK's
//! contract - the signatures and the documented LVOs at compile time, the
//! slots and the forwarding in the tests at the end.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const vec = exec.vec;
const BattMemBase = @import("battmem_base.zig").BattMemBase;
const ObtainBattSemaphore = @import("bits/obtainbattsemaphore.zig").ObtainBattSemaphore;
const ReleaseBattSemaphore = @import("bits/releasebattsemaphore.zig").ReleaseBattSemaphore;
const ReadBattMem = @import("bits/readbattmem.zig").ReadBattMem;
const WriteBattMem = @import("bits/writebattmem.zig").WriteBattMem;

/// battmem.resource's interface, as the SDK generates it from
/// sdk/fd/battmem_lib.fd.
const interface = sdk.interface.battmem;
const LVO = interface.LVO;

comptime {
    for (@typeInfo(LVO).@"struct".decls) |d| {
        const f = @field(@This(), "lvo" ++ d.name);
        if (!exec.libraries.sameSignature(@TypeOf(&f), @field(interface.Fn, d.name))) {
            @compileError("battmem.resource: lvo" ++ d.name ++ " does not match the SDK's type");
        }
    }
}

// Every slot's documented LVO is the one the .fd gives it.
comptime {
    @setEvalBranchQuota(10_000_000);
    for (contract_files) |source| {
        exec.libraries.checkDocumentedLvosAt(source, LVO, "battmem.resource", "pub fn ");
    }
}

/// The files whose call carries its contract, above `pub fn <Name>`.
const contract_files = [_][]const u8{
    @embedFile("bits/obtainbattsemaphore.zig"),
    @embedFile("bits/releasebattsemaphore.zig"),
    @embedFile("bits/readbattmem.zig"),
    @embedFile("bits/writebattmem.zig"),
};

fn lvoObtainBattSemaphore(mb: *BattMemBase) callconv(.c) void {
    ObtainBattSemaphore(mb);
}
fn lvoReleaseBattSemaphore(mb: *BattMemBase) callconv(.c) void {
    ReleaseBattSemaphore(mb);
}
fn lvoReadBattMem(mb: *BattMemBase, buffer: [*]u8, offset: u32, length: u32) callconv(.c) u32 {
    return ReadBattMem(mb, buffer, offset, length);
}
fn lvoWriteBattMem(mb: *BattMemBase, buffer: [*]const u8, offset: u32, length: u32) callconv(.c) u32 {
    return WriteBattMem(mb, buffer, offset, length);
}

/// The jump table, in slot order: a resource has no standard vectors, so
/// its first function is in the first slot.
pub const vectors = [_]*const anyopaque{
    vec(lvoObtainBattSemaphore),
    vec(lvoReleaseBattSemaphore),
    vec(lvoReadBattMem),
    vec(lvoWriteBattMem),
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
    try exec.libraries.checkForwarding(@embedFile("battmem_lvo.zig"), LVO, &.{});
}
