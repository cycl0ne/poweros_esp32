// SPDX-License-Identifier: MPL-2.0
//! acpi.resource's jump table: every `lvo<Name>` wrapper, the table of
//! them in slot order, and the checks that hold the table to the SDK's
//! contract - the signatures and the documented LVOs at compile time, the
//! slots and the forwarding in the tests at the end.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const vec = exec.vec;
const acpi = sdk.resources.acpi;
const AcpiBase = @import("acpi_base.zig").AcpiBase;
const FindAcpiNode = @import("namespace/findacpinode.zig").FindAcpiNode;
const NextAcpiDevice = @import("namespace/nextacpidevice.zig").NextAcpiDevice;

/// acpi.resource's interface, as the SDK generates it from
/// sdk/fd/acpi_lib.fd.
const interface = sdk.interface.acpi;
const LVO = interface.LVO;

comptime {
    for (@typeInfo(LVO).@"struct".decls) |d| {
        const f = @field(@This(), "lvo" ++ d.name);
        if (!exec.libraries.sameSignature(@TypeOf(&f), @field(interface.Fn, d.name))) {
            @compileError("acpi.resource: lvo" ++ d.name ++ " does not match the SDK's type");
        }
    }
}

// Every call's contract is in the list, once, and documents the LVO the
// .fd gives it.
comptime {
    @setEvalBranchQuota(10_000_000);
    exec.libraries.checkContractFiles(&contract_files, LVO, "acpi.resource", "pub fn ");
}

/// The files whose call carries its contract, above `pub fn <Name>`.
const contract_files = [_][]const u8{
    @embedFile("namespace/findacpinode.zig"),
    @embedFile("namespace/nextacpidevice.zig"),
};

fn lvoFindAcpiNode(ab: *AcpiBase, scope: ?*acpi.AcpiNode, path: [*:0]const u8) callconv(.c) ?*acpi.AcpiNode {
    return FindAcpiNode(ab, scope, path);
}
fn lvoNextAcpiDevice(ab: *AcpiBase, old: ?*acpi.AcpiNode, id: ?[*:0]const u8) callconv(.c) ?*acpi.AcpiNode {
    return NextAcpiDevice(ab, old, id);
}

/// The jump table, in slot order: a resource has no standard vectors, so
/// its first function is in the first slot.
pub const vectors = [_]*const anyopaque{
    vec(lvoFindAcpiNode),
    vec(lvoNextAcpiDevice),
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
    try exec.libraries.checkForwarding(@embedFile("acpi_lvo.zig"), LVO, &.{});
}
