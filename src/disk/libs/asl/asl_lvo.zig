// SPDX-License-Identifier: MIT
//! asl.library's jump table: every `lvo<Name>` wrapper, the table of them
//! in slot order, and the checks that hold the table to the SDK's
//! contract - the signatures and the documented LVOs at compile time, the
//! slots and the forwarding in the tests at the end.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const utility = sdk.utility;
const vec = exec.vec;
const AslBase = @import("asl_base.zig").AslBase;
const asl_init = @import("asl_init.zig");

const AllocAslRequest = @import("request/allocaslrequest.zig").AllocAslRequest;
const FreeAslRequest = @import("request/freeaslrequest.zig").FreeAslRequest;
const AslRequest = @import("request/aslrequest.zig").AslRequest;

/// asl.library's interface, as the SDK generates it from
/// sdk/fd/asl_lib.fd.
const interface = sdk.interface.asl;
const LVO = interface.LVO;

comptime {
    for (@typeInfo(LVO).@"struct".decls) |d| {
        const f = @field(@This(), "lvo" ++ d.name);
        if (!exec.libraries.sameSignature(@TypeOf(&f), @field(interface.Fn, d.name))) {
            @compileError("asl.library: lvo" ++ d.name ++ " does not match the SDK's type");
        }
    }
}

// Every slot's documented LVO is the one the .fd gives it.
comptime {
    @setEvalBranchQuota(10_000_000);
    for (contract_files) |source| {
        exec.libraries.checkDocumentedLvosAt(source, LVO, "asl.library", "pub fn ");
    }
}

/// The files whose call carries its contract, above `pub fn <Name>`.
const contract_files = [_][]const u8{
    @embedFile("request/allocaslrequest.zig"),
    @embedFile("request/freeaslrequest.zig"),
    @embedFile("request/aslrequest.zig"),
};

fn lvoAllocAslRequest(ab: *AslBase, kind: u32, tags: ?[*]const utility.TagItem) callconv(.c) ?*anyopaque {
    return AllocAslRequest(ab, kind, tags);
}
fn lvoFreeAslRequest(ab: *AslBase, requester: ?*anyopaque) callconv(.c) void {
    return FreeAslRequest(ab, requester);
}
fn lvoAslRequest(ab: *AslBase, requester: *anyopaque, tags: ?[*]const utility.TagItem) callconv(.c) bool {
    return AslRequest(ab, requester, tags);
}

pub const vectors = [_]*const anyopaque{
    vec(asl_init.openVector),
    vec(asl_init.closeVector),
    vec(asl_init.expungeVector),
    vec(exec.libExtFunc),
    vec(lvoAllocAslRequest),
    vec(lvoFreeAslRequest),
    vec(lvoAslRequest),
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
    try exec.libraries.checkForwarding(@embedFile("asl_lvo.zig"), LVO, &.{});
}
