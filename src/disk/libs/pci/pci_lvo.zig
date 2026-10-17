// SPDX-License-Identifier: MIT
//! pci.library's jump table: every `lvo<Name>` wrapper, the table of them
//! in slot order, and the checks that hold the table to the SDK's
//! contract - the signatures and the documented LVOs at compile time, the
//! slots and the forwarding in the tests at the end.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const pci = sdk.pci;
const vec = exec.vec;
const PCIBase = @import("pci_base.zig").PCIBase;
const pci_init = @import("pci_init.zig");

const FindPCIDevice = @import("find/findpcidevice.zig").FindPCIDevice;
const FindPCIClass = @import("find/findpciclass.zig").FindPCIClass;
const ReadPCIConfig = @import("config/readpciconfig.zig").ReadPCIConfig;
const WritePCIConfig = @import("config/writepciconfig.zig").WritePCIConfig;
const ClaimPCIDevice = @import("claim/claimpcidevice.zig").ClaimPCIDevice;
const ReleasePCIDevice = @import("claim/releasepcidevice.zig").ReleasePCIDevice;
const AddPCIIntServer = @import("interrupt/addpciintserver.zig").AddPCIIntServer;
const RemPCIIntServer = @import("interrupt/rempciintserver.zig").RemPCIIntServer;

/// pci.library's interface, as the SDK generates it from
/// sdk/fd/pci_lib.fd.
const interface = sdk.interface.pci;
const LVO = interface.LVO;

comptime {
    for (@typeInfo(LVO).@"struct".decls) |d| {
        const f = @field(@This(), "lvo" ++ d.name);
        if (!exec.libraries.sameSignature(@TypeOf(&f), @field(interface.Fn, d.name))) {
            @compileError("pci.library: lvo" ++ d.name ++ " does not match the SDK's type");
        }
    }
}

// Every slot's documented LVO is the one the .fd gives it.
comptime {
    @setEvalBranchQuota(10_000_000);
    for (contract_files) |source| {
        exec.libraries.checkDocumentedLvosAt(source, LVO, "pci.library", "pub fn ");
    }
}

/// The files whose call carries its contract, above `pub fn <Name>`.
const contract_files = [_][]const u8{
    @embedFile("find/findpcidevice.zig"),
    @embedFile("find/findpciclass.zig"),
    @embedFile("config/readpciconfig.zig"),
    @embedFile("config/writepciconfig.zig"),
    @embedFile("claim/claimpcidevice.zig"),
    @embedFile("claim/releasepcidevice.zig"),
    @embedFile("interrupt/addpciintserver.zig"),
    @embedFile("interrupt/rempciintserver.zig"),
};

fn lvoFindPCIDevice(base: *PCIBase, previous: ?*pci.PCIDevice, vendor: u32, device: u32) callconv(.c) ?*pci.PCIDevice {
    return FindPCIDevice(base, previous, vendor, device);
}
fn lvoFindPCIClass(base: *PCIBase, previous: ?*pci.PCIDevice, class_code: u32, mask: u32) callconv(.c) ?*pci.PCIDevice {
    return FindPCIClass(base, previous, class_code, mask);
}
fn lvoReadPCIConfig(base: *PCIBase, device: *pci.PCIDevice, offset: u32, size: u32) callconv(.c) u32 {
    return ReadPCIConfig(base, device, offset, size);
}
fn lvoWritePCIConfig(base: *PCIBase, device: *pci.PCIDevice, offset: u32, size: u32, value: u32) callconv(.c) void {
    return WritePCIConfig(base, device, offset, size, value);
}
fn lvoClaimPCIDevice(base: *PCIBase, device: *pci.PCIDevice, owner: [*:0]const u8) callconv(.c) ?[*:0]const u8 {
    return ClaimPCIDevice(base, device, owner);
}
fn lvoReleasePCIDevice(base: *PCIBase, device: *pci.PCIDevice) callconv(.c) void {
    return ReleasePCIDevice(base, device);
}
fn lvoAddPCIIntServer(base: *PCIBase, device: *pci.PCIDevice, server: *exec.Interrupt) callconv(.c) bool {
    return AddPCIIntServer(base, device, server);
}
fn lvoRemPCIIntServer(base: *PCIBase, device: *pci.PCIDevice, server: *exec.Interrupt) callconv(.c) void {
    return RemPCIIntServer(base, device, server);
}

/// The jump table, in slot order: the standard vectors, then one
/// `lvo<Name>` per `.fd` line.
pub const vectors = [_]*const anyopaque{
    vec(exec.libOpen),
    vec(exec.libClose),
    vec(pci_init.expungeVector),
    vec(exec.libExtFunc),
    vec(lvoFindPCIDevice),
    vec(lvoFindPCIClass),
    vec(lvoReadPCIConfig),
    vec(lvoWritePCIConfig),
    vec(lvoClaimPCIDevice),
    vec(lvoReleasePCIDevice),
    vec(lvoAddPCIIntServer),
    vec(lvoRemPCIIntServer),
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
    try exec.libraries.checkForwarding(@embedFile("pci_lvo.zig"), LVO, &.{});
}
