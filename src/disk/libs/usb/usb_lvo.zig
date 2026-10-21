// SPDX-License-Identifier: MIT
//! usb.library's jump table: every `lvo<Name>` wrapper, the table of them
//! in slot order, and the checks that hold the table to the SDK's
//! contract - the signatures and the documented LVOs at compile time, the
//! slots and the forwarding in the tests at the end.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const usb = sdk.usb;
const vec = exec.vec;
const UsbBase = @import("usb_base.zig").UsbBase;
const usb_init = @import("usb_init.zig");

const StartUSB = @import("bus/startusb.zig").StartUSB;
const StopUSB = @import("bus/stopusb.zig").StopUSB;
const ObtainUSBDeviceList = @import("list/obtainusbdevicelist.zig").ObtainUSBDeviceList;
const ReleaseUSBDeviceList = @import("list/releaseusbdevicelist.zig").ReleaseUSBDeviceList;
const NextUSBDescriptor = @import("descriptor/nextusbdescriptor.zig").NextUSBDescriptor;
const FindUSBInterface = @import("descriptor/findusbinterface.zig").FindUSBInterface;
const FindUSBEndpoint = @import("descriptor/findusbendpoint.zig").FindUSBEndpoint;
const GetUSBString = @import("descriptor/getusbstring.zig").GetUSBString;
const OpenUSBPipe = @import("pipe/openusbpipe.zig").OpenUSBPipe;
const CloseUSBPipe = @import("pipe/closeusbpipe.zig").CloseUSBPipe;
const DoUSBControl = @import("pipe/dousbcontrol.zig").DoUSBControl;
const ClearUSBStall = @import("pipe/clearusbstall.zig").ClearUSBStall;
const ClaimUSBInterface = @import("claim/claimusbinterface.zig").ClaimUSBInterface;
const ReleaseUSBInterface = @import("claim/releaseusbinterface.zig").ReleaseUSBInterface;
const AddUSBNotify = @import("notify/addusbnotify.zig").AddUSBNotify;
const RemUSBNotify = @import("notify/remusbnotify.zig").RemUSBNotify;
const OpenUSBStreamPipe = @import("pipe/openusbstreampipe.zig").OpenUSBStreamPipe;

/// usb.library's interface, as the SDK generates it from
/// sdk/fd/usb_lib.fd.
const interface = sdk.interface.usb;
const LVO = interface.LVO;

comptime {
    for (@typeInfo(LVO).@"struct".decls) |d| {
        const f = @field(@This(), "lvo" ++ d.name);
        if (!exec.libraries.sameSignature(@TypeOf(&f), @field(interface.Fn, d.name))) {
            @compileError("usb.library: lvo" ++ d.name ++ " does not match the SDK's type");
        }
    }
}

// Every slot's documented LVO is the one the .fd gives it.
comptime {
    @setEvalBranchQuota(10_000_000);
    for (contract_files) |source| {
        exec.libraries.checkDocumentedLvosAt(source, LVO, "usb.library", "pub fn ");
    }
}

/// The files whose call carries its contract, above `pub fn <Name>`.
const contract_files = [_][]const u8{
    @embedFile("bus/startusb.zig"),
    @embedFile("bus/stopusb.zig"),
    @embedFile("list/obtainusbdevicelist.zig"),
    @embedFile("list/releaseusbdevicelist.zig"),
    @embedFile("descriptor/nextusbdescriptor.zig"),
    @embedFile("descriptor/findusbinterface.zig"),
    @embedFile("descriptor/findusbendpoint.zig"),
    @embedFile("descriptor/getusbstring.zig"),
    @embedFile("pipe/openusbpipe.zig"),
    @embedFile("pipe/closeusbpipe.zig"),
    @embedFile("pipe/dousbcontrol.zig"),
    @embedFile("pipe/clearusbstall.zig"),
    @embedFile("claim/claimusbinterface.zig"),
    @embedFile("claim/releaseusbinterface.zig"),
    @embedFile("notify/addusbnotify.zig"),
    @embedFile("notify/remusbnotify.zig"),
    @embedFile("pipe/openusbstreampipe.zig"),
};

fn lvoStartUSB(base: *UsbBase, bus: u32) callconv(.c) i32 {
    return StartUSB(base, bus);
}
fn lvoStopUSB(base: *UsbBase, bus: u32) callconv(.c) void {
    return StopUSB(base, bus);
}
fn lvoObtainUSBDeviceList(base: *UsbBase) callconv(.c) *exec.List {
    return ObtainUSBDeviceList(base);
}
fn lvoReleaseUSBDeviceList(base: *UsbBase) callconv(.c) void {
    return ReleaseUSBDeviceList(base);
}
fn lvoNextUSBDescriptor(base: *UsbBase, device: *usb.USBDevice, previous: ?*const usb.DescriptorHeader, descriptor_type: u32) callconv(.c) ?*const usb.DescriptorHeader {
    return NextUSBDescriptor(base, device, previous, descriptor_type);
}
fn lvoFindUSBInterface(base: *UsbBase, device: *usb.USBDevice, previous: ?*const usb.InterfaceDescriptor, class: i32, subclass: i32, protocol: i32) callconv(.c) ?*const usb.InterfaceDescriptor {
    return FindUSBInterface(base, device, previous, class, subclass, protocol);
}
fn lvoFindUSBEndpoint(base: *UsbBase, device: *usb.USBDevice, interface_desc: *const usb.InterfaceDescriptor, direction: u32, transfer_type: u32) callconv(.c) ?*const usb.EndpointDescriptor {
    return FindUSBEndpoint(base, device, interface_desc, direction, transfer_type);
}
fn lvoGetUSBString(base: *UsbBase, device: *usb.USBDevice, index: u32, buffer: [*]u8, size: u32) callconv(.c) i32 {
    return GetUSBString(base, device, index, buffer, size);
}
fn lvoOpenUSBPipe(base: *UsbBase, device: *usb.USBDevice, endpoint_address: u32, reply_port: *exec.MsgPort) callconv(.c) ?*usb.USBPipe {
    return OpenUSBPipe(base, device, endpoint_address, reply_port);
}
fn lvoCloseUSBPipe(base: *UsbBase, pipe: ?*usb.USBPipe) callconv(.c) void {
    return CloseUSBPipe(base, pipe);
}
fn lvoDoUSBControl(base: *UsbBase, device: *usb.USBDevice, setup: *const usb.SetupPacket, data: ?*anyopaque, actual: ?*u32) callconv(.c) i32 {
    return DoUSBControl(base, device, setup, data, actual);
}
fn lvoClearUSBStall(base: *UsbBase, pipe: *usb.USBPipe) callconv(.c) i32 {
    return ClearUSBStall(base, pipe);
}
fn lvoClaimUSBInterface(base: *UsbBase, device: *usb.USBDevice, interface_number: u32, name: [*:0]const u8) callconv(.c) bool {
    return ClaimUSBInterface(base, device, interface_number, name);
}
fn lvoReleaseUSBInterface(base: *UsbBase, device: *usb.USBDevice, interface_number: u32) callconv(.c) void {
    return ReleaseUSBInterface(base, device, interface_number);
}
fn lvoAddUSBNotify(base: *UsbBase, task: *exec.Task, signals: u32) callconv(.c) ?*usb.USBNotify {
    return AddUSBNotify(base, task, signals);
}
fn lvoRemUSBNotify(base: *UsbBase, notify: ?*usb.USBNotify) callconv(.c) void {
    return RemUSBNotify(base, notify);
}
fn lvoOpenUSBStreamPipe(base: *UsbBase, device: *usb.USBDevice, endpoint_address: u32, stream: u32, reply_port: *exec.MsgPort) callconv(.c) ?*usb.USBPipe {
    return OpenUSBStreamPipe(base, device, endpoint_address, stream, reply_port);
}

/// The jump table, in slot order: the standard vectors, then one
/// `lvo<Name>` per `.fd` line.
pub const vectors = [_]*const anyopaque{
    vec(exec.libOpen),
    vec(exec.libClose),
    vec(usb_init.expungeVector),
    vec(exec.libExtFunc),
    vec(lvoStartUSB),
    vec(lvoStopUSB),
    vec(lvoObtainUSBDeviceList),
    vec(lvoReleaseUSBDeviceList),
    vec(lvoNextUSBDescriptor),
    vec(lvoFindUSBInterface),
    vec(lvoFindUSBEndpoint),
    vec(lvoGetUSBString),
    vec(lvoOpenUSBPipe),
    vec(lvoCloseUSBPipe),
    vec(lvoDoUSBControl),
    vec(lvoClearUSBStall),
    vec(lvoClaimUSBInterface),
    vec(lvoReleaseUSBInterface),
    vec(lvoAddUSBNotify),
    vec(lvoRemUSBNotify),
    vec(lvoOpenUSBStreamPipe),
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
    try exec.libraries.checkForwarding(@embedFile("usb_lvo.zig"), LVO, &.{});
}
