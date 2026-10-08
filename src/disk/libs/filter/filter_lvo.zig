// SPDX-License-Identifier: MIT
//! filter.library's jump table: every `lvo<Name>` wrapper, the table of
//! them in slot order, and the checks that hold the table to the SDK's
//! contract - the signatures and the documented LVOs at compile time, the
//! slots and the forwarding in the tests at the end.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const filter = sdk.filter;
const vec = exec.vec;
const FilterBase = @import("filter_base.zig").FilterBase;
const filter_init = @import("filter_init.zig");

const LoadFilterRules = @import("rules/loadfilterrules.zig").LoadFilterRules;
const ClearFilterRules = @import("rules/clearfilterrules.zig").ClearFilterRules;
const GetFilterRules = @import("rules/getfilterrules.zig").GetFilterRules;
const GetFilterFlows = @import("flows/getfilterflows.zig").GetFilterFlows;

/// filter.library's interface, as the SDK generates it from
/// sdk/fd/filter_lib.fd.
const interface = sdk.interface.filter;
const LVO = interface.LVO;

comptime {
    for (@typeInfo(LVO).@"struct".decls) |d| {
        const f = @field(@This(), "lvo" ++ d.name);
        if (!exec.libraries.sameSignature(@TypeOf(&f), @field(interface.Fn, d.name))) {
            @compileError("filter.library: lvo" ++ d.name ++ " does not match the SDK's type");
        }
    }
}

// Every slot's documented LVO is the one the .fd gives it.
comptime {
    @setEvalBranchQuota(10_000_000);
    for (contract_files) |source| {
        exec.libraries.checkDocumentedLvosAt(source, LVO, "filter.library", "pub fn ");
    }
}

/// The files whose call carries its contract, above `pub fn <Name>`.
const contract_files = [_][]const u8{
    @embedFile("rules/loadfilterrules.zig"),
    @embedFile("rules/clearfilterrules.zig"),
    @embedFile("rules/getfilterrules.zig"),
    @embedFile("flows/getfilterflows.zig"),
};

fn lvoLoadFilterRules(base: *FilterBase, text: [*]const u8, length: u32, err: ?*filter.FilterError) callconv(.c) u32 {
    return LoadFilterRules(base, text, length, err);
}
fn lvoClearFilterRules(base: *FilterBase) callconv(.c) void {
    return ClearFilterRules(base);
}
fn lvoGetFilterRules(base: *FilterBase, into: ?[*]filter.FilterRuleInfo, count: u32) callconv(.c) u32 {
    return GetFilterRules(base, into, count);
}
fn lvoGetFilterFlows(base: *FilterBase, into: ?[*]filter.FilterFlowInfo, count: u32) callconv(.c) u32 {
    return GetFilterFlows(base, into, count);
}

/// The standard four, then the library's own in .fd order.
pub const vectors = [_]*const anyopaque{
    vec(exec.libOpen),
    vec(exec.libClose),
    vec(filter_init.expungeVector),
    vec(exec.libExtFunc),
    vec(lvoLoadFilterRules),
    vec(lvoClearFilterRules),
    vec(lvoGetFilterRules),
    vec(lvoGetFilterFlows),
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
    try exec.libraries.checkForwarding(@embedFile("filter_lvo.zig"), LVO, &.{});
}
