// SPDX-License-Identifier: MIT
//! hid.library's jump table: every `lvo<Name>` wrapper, the table of them
//! in slot order, and the checks that hold the table to the SDK's
//! contract - the signatures and the documented LVOs at compile time, the
//! slots and the forwarding in the tests at the end.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const hid = sdk.hid;
const utility = sdk.utility;
const vec = exec.vec;
const HIDBase = @import("hid_base.zig").HIDBase;
const hid_init = @import("hid_init.zig");

const OpenHID = @import("function/openhid.zig").OpenHID;
const CloseHID = @import("function/closehid.zig").CloseHID;
const HIDInput = @import("function/hidinput.zig").HIDInput;

/// hid.library's interface, as the SDK generates it from
/// sdk/fd/hid_lib.fd.
const interface = sdk.interface.hid;
const LVO = interface.LVO;

comptime {
    for (@typeInfo(LVO).@"struct".decls) |d| {
        const f = @field(@This(), "lvo" ++ d.name);
        if (!exec.libraries.sameSignature(@TypeOf(&f), @field(interface.Fn, d.name))) {
            @compileError("hid.library: lvo" ++ d.name ++ " does not match the SDK's type");
        }
    }
}

// Every call's contract is in the list, once, and documents the LVO the
// .fd gives it.
comptime {
    @setEvalBranchQuota(1_000_000);
    exec.libraries.checkContractFiles(&contract_files, LVO, "hid.library", "pub fn ");
}

/// The files whose call carries its contract, above `pub fn <Name>`.
const contract_files = [_][]const u8{
    @embedFile("function/openhid.zig"),
    @embedFile("function/closehid.zig"),
    @embedFile("function/hidinput.zig"),
};

fn lvoOpenHID(base: *HIDBase, descriptor: ?[*]const u8, length: u32, tags: ?[*]const utility.TagItem) callconv(.c) ?*hid.HIDFunction {
    return OpenHID(base, descriptor, length, tags);
}
fn lvoCloseHID(base: *HIDBase, function: ?*hid.HIDFunction) callconv(.c) void {
    return CloseHID(base, function);
}
fn lvoHIDInput(base: *HIDBase, function: *hid.HIDFunction, report: [*]const u8, length: u32) callconv(.c) void {
    return HIDInput(base, function, report, length);
}

/// The jump table, in slot order: the standard vectors, then one
/// `lvo<Name>` per `.fd` line.
pub const vectors = [_]*const anyopaque{
    vec(exec.libOpen),
    vec(exec.libClose),
    vec(hid_init.expungeVector),
    vec(exec.libExtFunc),
    vec(lvoOpenHID),
    vec(lvoCloseHID),
    vec(lvoHIDInput),
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
    try exec.libraries.checkForwarding(@embedFile("hid_lvo.zig"), LVO, &.{});
}
