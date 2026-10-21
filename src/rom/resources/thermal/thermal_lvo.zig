// SPDX-License-Identifier: MPL-2.0
//! thermal.resource's jump table: every `lvo<Name>` wrapper, the table of
//! them in slot order, and the checks that hold the table to the SDK's
//! contract - the signatures and the documented LVOs at compile time, the
//! slots and the forwarding in the tests at the end.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const vec = exec.vec;
const thermal = sdk.resources.thermal;
const ThermalBase = @import("thermal_base.zig").ThermalBase;
const ReadTemperature = @import("state/readtemperature.zig").ReadTemperature;
const AddThermalNotify = @import("notify/addthermalnotify.zig").AddThermalNotify;
const RemThermalNotify = @import("notify/remthermalnotify.zig").RemThermalNotify;

/// thermal.resource's interface, as the SDK generates it from
/// sdk/fd/thermal_lib.fd.
const interface = sdk.interface.thermal;
const LVO = interface.LVO;

comptime {
    for (@typeInfo(LVO).@"struct".decls) |d| {
        const f = @field(@This(), "lvo" ++ d.name);
        if (!exec.libraries.sameSignature(@TypeOf(&f), @field(interface.Fn, d.name))) {
            @compileError("thermal.resource: lvo" ++ d.name ++ " does not match the SDK's type");
        }
    }
}

// Every slot's documented LVO is the one the .fd gives it.
comptime {
    @setEvalBranchQuota(10_000_000);
    for (contract_files) |source| {
        exec.libraries.checkDocumentedLvosAt(source, LVO, "thermal.resource", "pub fn ");
    }
}

/// The files whose call carries its contract, above `pub fn <Name>`.
const contract_files = [_][]const u8{
    @embedFile("state/readtemperature.zig"),
    @embedFile("notify/addthermalnotify.zig"),
    @embedFile("notify/remthermalnotify.zig"),
};

fn lvoReadTemperature(tb: *ThermalBase, unit: u32, state: *thermal.ThermalState) callconv(.c) bool {
    return ReadTemperature(tb, unit, state);
}
fn lvoAddThermalNotify(tb: *ThermalBase, task: *exec.Task, signals: u32) callconv(.c) ?*thermal.ThermalNotify {
    return AddThermalNotify(tb, task, signals);
}
fn lvoRemThermalNotify(tb: *ThermalBase, notify: ?*thermal.ThermalNotify) callconv(.c) void {
    RemThermalNotify(tb, notify);
}

/// The jump table, in slot order: a resource has no standard vectors, so
/// its first function is in the first slot.
pub const vectors = [_]*const anyopaque{
    vec(lvoReadTemperature),
    vec(lvoAddThermalNotify),
    vec(lvoRemThermalNotify),
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
    try exec.libraries.checkForwarding(@embedFile("thermal_lvo.zig"), LVO, &.{});
}
