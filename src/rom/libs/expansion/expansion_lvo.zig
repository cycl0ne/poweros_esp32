// SPDX-License-Identifier: MPL-2.0
//! expansion.library's jump table: every `lvo<Name>` wrapper, the table of
//! them in slot order, and the checks that hold the table to the SDK's
//! contract - the signatures and the documented LVOs at compile time, the
//! slots and the forwarding in the tests at the end.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const utility = sdk.utility;
const BoardPart = sdk.expansion.BoardPart;
const vec = exec.vec;
const expansion_base = @import("expansion_base.zig");
const ExpansionBase = expansion_base.ExpansionBase;
const FindBoardPart = @import("part/findboardpart.zig").FindBoardPart;
const SystemTags = @import("part/systemtags.zig").SystemTags;

/// expansion.library's interface, as the SDK generates it from
/// sdk/fd/expansion_lib.fd.
const interface = sdk.interface.expansion;
const LVO = interface.LVO;

comptime {
    for (@typeInfo(LVO).@"struct".decls) |d| {
        const f = @field(@This(), "lvo" ++ d.name);
        if (!exec.libraries.sameSignature(@TypeOf(&f), @field(interface.Fn, d.name))) {
            @compileError("expansion.library: lvo" ++ d.name ++ " does not match the SDK's type");
        }
    }
}

// Every slot's documented LVO is the one the .fd gives it.
comptime {
    @setEvalBranchQuota(10_000_000);
    for (contract_files) |source| {
        exec.libraries.checkDocumentedLvosAt(source, LVO, "expansion.library", "pub fn ");
    }
}

/// The files whose call carries its contract, above `pub fn <Name>`.
const contract_files = [_][]const u8{
    @embedFile("part/findboardpart.zig"),
    @embedFile("part/systemtags.zig"),
};

fn lvoFindBoardPart(eb: *ExpansionBase, old: ?*const BoardPart, kind: u32, chip: u32) callconv(.c) ?*const BoardPart {
    return FindBoardPart(eb, old, kind, chip);
}
fn lvoSystemTags(eb: *ExpansionBase) callconv(.c) [*]const utility.TagItem {
    return SystemTags(eb);
}

/// The jump table, in slot order: the standard vectors, then one
/// `lvo<Name>` per `.fd` line.
pub const vectors = [_]*const anyopaque{
    vec(exec.libOpen),
    vec(exec.libClose),
    vec(expansion_base.expunge),
    vec(exec.libExtFunc),
    vec(lvoFindBoardPart),
    vec(lvoSystemTags),
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
    try exec.libraries.checkForwarding(@embedFile("expansion_lvo.zig"), LVO, &.{});
}
