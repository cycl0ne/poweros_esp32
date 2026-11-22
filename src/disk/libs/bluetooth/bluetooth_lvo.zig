// SPDX-License-Identifier: MIT
//! bluetooth.library's jump table: every `lvo<Name>` wrapper, the table of
//! them in slot order, and the checks that hold the table to the SDK's
//! contract - the signatures and the documented LVOs at compile time, the
//! slots and the forwarding in the tests at the end.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const bluetooth = sdk.bluetooth;
const utility = sdk.utility;
const vec = exec.vec;
const BluetoothBase = @import("bluetooth_base.zig").BluetoothBase;
const bluetooth_init = @import("bluetooth_init.zig");

const AddBTController = @import("controller/addbtcontroller.zig").AddBTController;
const RemBTController = @import("controller/rembtcontroller.zig").RemBTController;
const ObtainBTControllers = @import("controller/obtainbtcontrollers.zig").ObtainBTControllers;
const ReleaseBTControllers = @import("controller/releasebtcontrollers.zig").ReleaseBTControllers;
const AddBTNotify = @import("notify/addbtnotify.zig").AddBTNotify;
const RemBTNotify = @import("notify/rembtnotify.zig").RemBTNotify;
const SetBTControllerAttrs = @import("controller/setbtcontrollerattrs.zig").SetBTControllerAttrs;
const StartBTDiscovery = @import("discovery/startbtdiscovery.zig").StartBTDiscovery;
const StopBTDiscovery = @import("discovery/stopbtdiscovery.zig").StopBTDiscovery;
const ObtainBTDevices = @import("discovery/obtainbtdevices.zig").ObtainBTDevices;
const ReleaseBTDevices = @import("discovery/releasebtdevices.zig").ReleaseBTDevices;

/// bluetooth.library's interface, as the SDK generates it from
/// sdk/fd/bluetooth_lib.fd.
const interface = sdk.interface.bluetooth;
const LVO = interface.LVO;

comptime {
    for (@typeInfo(LVO).@"struct".decls) |d| {
        const f = @field(@This(), "lvo" ++ d.name);
        if (!exec.libraries.sameSignature(@TypeOf(&f), @field(interface.Fn, d.name))) {
            @compileError("bluetooth.library: lvo" ++ d.name ++ " does not match the SDK's type");
        }
    }
}

// Every call's contract is in the list, once, and documents the LVO the
// .fd gives it.
comptime {
    @setEvalBranchQuota(10_000_000);
    exec.libraries.checkContractFiles(&contract_files, LVO, "bluetooth.library", "pub fn ");
}

/// The files whose call carries its contract, above `pub fn <Name>`.
const contract_files = [_][]const u8{
    @embedFile("controller/addbtcontroller.zig"),
    @embedFile("controller/rembtcontroller.zig"),
    @embedFile("controller/obtainbtcontrollers.zig"),
    @embedFile("controller/releasebtcontrollers.zig"),
    @embedFile("notify/addbtnotify.zig"),
    @embedFile("notify/rembtnotify.zig"),
    @embedFile("controller/setbtcontrollerattrs.zig"),
    @embedFile("discovery/startbtdiscovery.zig"),
    @embedFile("discovery/stopbtdiscovery.zig"),
    @embedFile("discovery/obtainbtdevices.zig"),
    @embedFile("discovery/releasebtdevices.zig"),
};

// --- controllers ----------------------------------------------------------------

fn lvoAddBTController(base: *BluetoothBase, device_name: [*:0]const u8, unit: u32) callconv(.c) i32 {
    return AddBTController(base, device_name, unit);
}
fn lvoRemBTController(base: *BluetoothBase, device_name: [*:0]const u8, unit: u32) callconv(.c) void {
    return RemBTController(base, device_name, unit);
}
fn lvoObtainBTControllers(base: *BluetoothBase) callconv(.c) ?*exec.List {
    return ObtainBTControllers(base);
}
fn lvoReleaseBTControllers(base: *BluetoothBase, list: ?*exec.List) callconv(.c) void {
    return ReleaseBTControllers(base, list);
}

// --- notification ---------------------------------------------------------------

fn lvoAddBTNotify(base: *BluetoothBase, task: *exec.Task, signals: u32) callconv(.c) ?*bluetooth.BTNotify {
    return AddBTNotify(base, task, signals);
}
fn lvoRemBTNotify(base: *BluetoothBase, notify: ?*bluetooth.BTNotify) callconv(.c) void {
    return RemBTNotify(base, notify);
}

// --- settings -------------------------------------------------------------------

fn lvoSetBTControllerAttrs(base: *BluetoothBase, controller: u32, tags: ?[*]const utility.TagItem) callconv(.c) i32 {
    return SetBTControllerAttrs(base, controller, tags);
}

// --- discovery ------------------------------------------------------------------

fn lvoStartBTDiscovery(base: *BluetoothBase, controller: u32, seconds: u32) callconv(.c) i32 {
    return StartBTDiscovery(base, controller, seconds);
}
fn lvoStopBTDiscovery(base: *BluetoothBase, controller: u32) callconv(.c) void {
    return StopBTDiscovery(base, controller);
}
fn lvoObtainBTDevices(base: *BluetoothBase, controller: u32) callconv(.c) ?*exec.List {
    return ObtainBTDevices(base, controller);
}
fn lvoReleaseBTDevices(base: *BluetoothBase, list: ?*exec.List) callconv(.c) void {
    return ReleaseBTDevices(base, list);
}

/// The jump table, in slot order: the standard vectors, then one
/// `lvo<Name>` per `.fd` line.
pub const vectors = [_]*const anyopaque{
    vec(bluetooth_init.openVector),
    vec(exec.libClose),
    vec(bluetooth_init.expungeVector),
    vec(exec.libExtFunc),
    vec(lvoAddBTController),
    vec(lvoRemBTController),
    vec(lvoObtainBTControllers),
    vec(lvoReleaseBTControllers),
    vec(lvoAddBTNotify),
    vec(lvoRemBTNotify),
    vec(lvoSetBTControllerAttrs),
    vec(lvoStartBTDiscovery),
    vec(lvoStopBTDiscovery),
    vec(lvoObtainBTDevices),
    vec(lvoReleaseBTDevices),
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
    try exec.libraries.checkForwarding(@embedFile("bluetooth_lvo.zig"), LVO, &.{});
}
