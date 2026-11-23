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
const ConnectBTDevice = @import("connection/connectbtdevice.zig").ConnectBTDevice;
const DisconnectBTDevice = @import("connection/disconnectbtdevice.zig").DisconnectBTDevice;
const ObtainBTConnections = @import("connection/obtainbtconnections.zig").ObtainBTConnections;
const ReleaseBTConnections = @import("connection/releasebtconnections.zig").ReleaseBTConnections;
const PairBTDevice = @import("pairing/pairbtdevice.zig").PairBTDevice;
const UnpairBTDevice = @import("pairing/unpairbtdevice.zig").UnpairBTDevice;
const AddBTAgent = @import("pairing/addbtagent.zig").AddBTAgent;
const RemBTAgent = @import("pairing/rembtagent.zig").RemBTAgent;
const ObtainBTBonds = @import("pairing/obtainbtbonds.zig").ObtainBTBonds;
const ReleaseBTBonds = @import("pairing/releasebtbonds.zig").ReleaseBTBonds;
const OpenBTChannel = @import("channel/openbtchannel.zig").OpenBTChannel;
const CloseBTChannel = @import("channel/closebtchannel.zig").CloseBTChannel;
const SendBTChannel = @import("channel/sendbtchannel.zig").SendBTChannel;
const AddBTListener = @import("channel/addbtlistener.zig").AddBTListener;
const RemBTListener = @import("channel/rembtlistener.zig").RemBTListener;
const ObtainBTServices = @import("service/obtainbtservices.zig").ObtainBTServices;
const ReleaseBTServices = @import("service/releasebtservices.zig").ReleaseBTServices;
const OpenBTGatt = @import("gatt/openbtgatt.zig").OpenBTGatt;
const CloseBTGatt = @import("gatt/closebtgatt.zig").CloseBTGatt;
const ObtainBTCharacteristics = @import("gatt/obtainbtcharacteristics.zig").ObtainBTCharacteristics;
const ReleaseBTCharacteristics = @import("gatt/releasebtcharacteristics.zig").ReleaseBTCharacteristics;
const ReadBTAttribute = @import("gatt/readbtattribute.zig").ReadBTAttribute;
const WriteBTAttribute = @import("gatt/writebtattribute.zig").WriteBTAttribute;
const SubscribeBTAttribute = @import("gatt/subscribebtattribute.zig").SubscribeBTAttribute;
const UnsubscribeBTAttribute = @import("gatt/unsubscribebtattribute.zig").UnsubscribeBTAttribute;
const NextBTDataElement = @import("service/nextbtdataelement.zig").NextBTDataElement;
const FindBTServiceAttribute = @import("service/findbtserviceattribute.zig").FindBTServiceAttribute;
const AddBTService = @import("service/addbtservice.zig").AddBTService;
const RemBTService = @import("service/rembtservice.zig").RemBTService;

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
    @embedFile("connection/connectbtdevice.zig"),
    @embedFile("connection/disconnectbtdevice.zig"),
    @embedFile("connection/obtainbtconnections.zig"),
    @embedFile("connection/releasebtconnections.zig"),
    @embedFile("pairing/pairbtdevice.zig"),
    @embedFile("pairing/unpairbtdevice.zig"),
    @embedFile("pairing/addbtagent.zig"),
    @embedFile("pairing/rembtagent.zig"),
    @embedFile("pairing/obtainbtbonds.zig"),
    @embedFile("pairing/releasebtbonds.zig"),
    @embedFile("channel/openbtchannel.zig"),
    @embedFile("channel/closebtchannel.zig"),
    @embedFile("channel/sendbtchannel.zig"),
    @embedFile("channel/addbtlistener.zig"),
    @embedFile("channel/rembtlistener.zig"),
    @embedFile("service/obtainbtservices.zig"),
    @embedFile("service/releasebtservices.zig"),
    @embedFile("gatt/openbtgatt.zig"),
    @embedFile("gatt/closebtgatt.zig"),
    @embedFile("gatt/obtainbtcharacteristics.zig"),
    @embedFile("gatt/releasebtcharacteristics.zig"),
    @embedFile("gatt/readbtattribute.zig"),
    @embedFile("gatt/writebtattribute.zig"),
    @embedFile("gatt/subscribebtattribute.zig"),
    @embedFile("gatt/unsubscribebtattribute.zig"),
    @embedFile("service/nextbtdataelement.zig"),
    @embedFile("service/findbtserviceattribute.zig"),
    @embedFile("service/addbtservice.zig"),
    @embedFile("service/rembtservice.zig"),
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

// --- connections ----------------------------------------------------------------

fn lvoConnectBTDevice(base: *BluetoothBase, controller: u32, address: *const bluetooth.BTAddress) callconv(.c) i32 {
    return ConnectBTDevice(base, controller, address);
}

fn lvoDisconnectBTDevice(base: *BluetoothBase, controller: u32, address: *const bluetooth.BTAddress) callconv(.c) i32 {
    return DisconnectBTDevice(base, controller, address);
}

fn lvoObtainBTConnections(base: *BluetoothBase, controller: u32) callconv(.c) ?*exec.List {
    return ObtainBTConnections(base, controller);
}

fn lvoReleaseBTConnections(base: *BluetoothBase, list: ?*exec.List) callconv(.c) void {
    return ReleaseBTConnections(base, list);
}

// --- pairing --------------------------------------------------------------------

fn lvoPairBTDevice(base: *BluetoothBase, controller: u32, address: *const bluetooth.BTAddress, agent: ?*bluetooth.BTAgent) callconv(.c) i32 {
    return PairBTDevice(base, controller, address, agent);
}

fn lvoUnpairBTDevice(base: *BluetoothBase, controller: u32, address: *const bluetooth.BTAddress) callconv(.c) i32 {
    return UnpairBTDevice(base, controller, address);
}

fn lvoAddBTAgent(base: *BluetoothBase, port: *exec.MsgPort, capability: u32) callconv(.c) ?*bluetooth.BTAgent {
    return AddBTAgent(base, port, capability);
}

fn lvoRemBTAgent(base: *BluetoothBase, agent: ?*bluetooth.BTAgent) callconv(.c) void {
    return RemBTAgent(base, agent);
}

fn lvoObtainBTBonds(base: *BluetoothBase, controller: u32) callconv(.c) ?*exec.List {
    return ObtainBTBonds(base, controller);
}

fn lvoReleaseBTBonds(base: *BluetoothBase, list: ?*exec.List) callconv(.c) void {
    return ReleaseBTBonds(base, list);
}

// --- channels -------------------------------------------------------------------

fn lvoOpenBTChannel(base: *BluetoothBase, controller: u32, address: *const bluetooth.BTAddress, psm: u32, port: *exec.MsgPort, channel: *?*bluetooth.BTChannel) callconv(.c) i32 {
    return OpenBTChannel(base, controller, address, psm, port, channel);
}

fn lvoCloseBTChannel(base: *BluetoothBase, channel: ?*bluetooth.BTChannel) callconv(.c) void {
    return CloseBTChannel(base, channel);
}

fn lvoSendBTChannel(base: *BluetoothBase, channel: *bluetooth.BTChannel, data: [*]const u8, length: u32) callconv(.c) i32 {
    return SendBTChannel(base, channel, data, length);
}

fn lvoAddBTListener(base: *BluetoothBase, psm: u32, port: *exec.MsgPort, flags: u32) callconv(.c) ?*bluetooth.BTListener {
    return AddBTListener(base, psm, port, flags);
}

fn lvoRemBTListener(base: *BluetoothBase, listener: ?*bluetooth.BTListener) callconv(.c) void {
    return RemBTListener(base, listener);
}

// --- services -------------------------------------------------------------------

fn lvoObtainBTServices(base: *BluetoothBase, controller: u32, address: *const bluetooth.BTAddress, list: *?*exec.List) callconv(.c) i32 {
    return ObtainBTServices(base, controller, address, list);
}

fn lvoReleaseBTServices(base: *BluetoothBase, list: ?*exec.List) callconv(.c) void {
    return ReleaseBTServices(base, list);
}

// --- GATT -----------------------------------------------------------------------

fn lvoOpenBTGatt(base: *BluetoothBase, controller: u32, address: *const bluetooth.BTAddress, port: *exec.MsgPort, gatt: *?*bluetooth.BTGatt, flags: u32) callconv(.c) i32 {
    return OpenBTGatt(base, controller, address, port, gatt, flags);
}

fn lvoCloseBTGatt(base: *BluetoothBase, gatt: ?*bluetooth.BTGatt) callconv(.c) void {
    return CloseBTGatt(base, gatt);
}

fn lvoObtainBTCharacteristics(base: *BluetoothBase, gatt: *bluetooth.BTGatt, service: *const bluetooth.BTService, list: *?*exec.List) callconv(.c) i32 {
    return ObtainBTCharacteristics(base, gatt, service, list);
}

fn lvoReleaseBTCharacteristics(base: *BluetoothBase, list: ?*exec.List) callconv(.c) void {
    return ReleaseBTCharacteristics(base, list);
}

fn lvoReadBTAttribute(base: *BluetoothBase, gatt: *bluetooth.BTGatt, handle: u32, buffer: [*]u8, length: u32, actual: *u32) callconv(.c) i32 {
    return ReadBTAttribute(base, gatt, handle, buffer, length, actual);
}

fn lvoWriteBTAttribute(base: *BluetoothBase, gatt: *bluetooth.BTGatt, handle: u32, data: [*]const u8, length: u32, flags: u32) callconv(.c) i32 {
    return WriteBTAttribute(base, gatt, handle, data, length, flags);
}

fn lvoSubscribeBTAttribute(base: *BluetoothBase, gatt: *bluetooth.BTGatt, which: *const bluetooth.BTCharacteristic, flags: u32) callconv(.c) i32 {
    return SubscribeBTAttribute(base, gatt, which, flags);
}

fn lvoUnsubscribeBTAttribute(base: *BluetoothBase, gatt: *bluetooth.BTGatt, which: *const bluetooth.BTCharacteristic) callconv(.c) i32 {
    return UnsubscribeBTAttribute(base, gatt, which);
}

// --- records ----------------------------------------------------------------------

fn lvoNextBTDataElement(base: *BluetoothBase, data: [*]const u8, length: u32, element: *bluetooth.BTDataElement) callconv(.c) bool {
    return NextBTDataElement(base, data, length, element);
}

fn lvoFindBTServiceAttribute(base: *BluetoothBase, record: [*]const u8, length: u32, id: u32, element: *bluetooth.BTDataElement) callconv(.c) bool {
    return FindBTServiceAttribute(base, record, length, id, element);
}

fn lvoAddBTService(base: *BluetoothBase, record: [*]const u8, length: u32) callconv(.c) ?*bluetooth.BTRecord {
    return AddBTService(base, record, length);
}

fn lvoRemBTService(base: *BluetoothBase, record: ?*bluetooth.BTRecord) callconv(.c) void {
    return RemBTService(base, record);
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
    vec(lvoConnectBTDevice),
    vec(lvoDisconnectBTDevice),
    vec(lvoObtainBTConnections),
    vec(lvoReleaseBTConnections),
    vec(lvoPairBTDevice),
    vec(lvoUnpairBTDevice),
    vec(lvoAddBTAgent),
    vec(lvoRemBTAgent),
    vec(lvoObtainBTBonds),
    vec(lvoReleaseBTBonds),
    vec(lvoOpenBTChannel),
    vec(lvoCloseBTChannel),
    vec(lvoSendBTChannel),
    vec(lvoAddBTListener),
    vec(lvoRemBTListener),
    vec(lvoObtainBTServices),
    vec(lvoReleaseBTServices),
    vec(lvoOpenBTGatt),
    vec(lvoCloseBTGatt),
    vec(lvoObtainBTCharacteristics),
    vec(lvoReleaseBTCharacteristics),
    vec(lvoReadBTAttribute),
    vec(lvoWriteBTAttribute),
    vec(lvoSubscribeBTAttribute),
    vec(lvoUnsubscribeBTAttribute),
    vec(lvoNextBTDataElement),
    vec(lvoFindBTServiceAttribute),
    vec(lvoAddBTService),
    vec(lvoRemBTService),
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
