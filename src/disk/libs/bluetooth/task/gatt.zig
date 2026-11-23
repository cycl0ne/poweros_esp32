// SPDX-License-Identifier: MIT
//! The task's side of GATT's client (att/client.zig): the commands of
//! OpenBTGatt, CloseBTGatt, ObtainBTCharacteristics, ReadBTAttribute,
//! WriteBTAttribute, SubscribeBTAttribute and UnsubscribeBTAttribute
//! handed to the layer, and what the layer tells of a block sent to the
//! block's port as BTGattMessages - made, counted, taken back and freed
//! as a channel's are (channels.zig).
//!
//! **A block** is the BTGatt OpenBTGatt made in its caller's context; the
//! layer's record of it names the block as its `owner`, and a command
//! that names a block acts on the record that names it - so a block
//! whose record is gone, its controller with it, touches nothing.
//!
//! Every function here runs in the task, the layers under the base's lock
//! - the upcall (`event`) called by the layer under it.

const sdk = @import("sdk");
const bluetooth = sdk.bluetooth;
const att = bluetooth.att;
const _controller = @import("../controller/_controller.zig");
const Controller = _controller.Controller;
const connections = @import("../hci/connections.zig");
const att_client = @import("../att/client.zig");
const taskchannels = @import("channels.zig");
const Command = @import("_task.zig").Command;

/// The port's upcall for the task's GATT blocks: a value, a block that
/// waits open or waiting again, a block closed - each to the block's
/// port.
pub fn event(context: *anyopaque, happened: *const att_client.Event) void {
    const controller: *Controller = @ptrCast(@alignCast(context));
    const record = happened.client;
    const block: *bluetooth.BTGatt = @ptrCast(@alignCast(record.owner orelse return));
    switch (happened.kind) {
        .value => valueCame(controller, record, block, happened.handle, happened.data),
        .opened => opened(controller, record, block),
        .waiting => waiting(controller, block, happened.result),
        .closed => closed(controller, block, happened.result),
    }
}

/// A value to the block's port as BTGM_VALUE - let go and counted while
/// OUT_MOST of its values are out, or without memory.
fn valueCame(controller: *Controller, record: *att_client.Client, block: *bluetooth.BTGatt, handle: u16, data: []const u8) void {
    const port = block.port orelse return;
    if (record.out >= att_client.OUT_MOST) {
        block.dropped +%= 1;
        return;
    }
    const message = taskchannels.newMessage(controller, block, true, bluetooth.BTGM_VALUE, 0, data.len) orelse {
        block.dropped +%= 1;
        return;
    };
    const room = taskchannels.extraOf(message);
    @memcpy(room[0..data.len], data);
    message.public.gatt.handle = handle;
    message.public.gatt.data = room;
    message.public.gatt.length = @intCast(data.len);
    record.out += 1;
    taskchannels.put(controller.base, port, message);
}

/// A block that waits open: its link's MTU in it, BTGF_WAITING cleared,
/// and BTGM_OPENED to its port.
fn opened(controller: *Controller, record: *const att_client.Client, block: *bluetooth.BTGatt) void {
    block.mtu = if (connections.find(&controller.layer, record.address)) |connection| connection.att.mtu else att.ATT_MTU_DEFAULT;
    block.flags &= ~bluetooth.BTGF_WAITING;
    tellState(controller, block, bluetooth.BTGM_OPENED, 0);
}

/// A block that waits waiting again, its link ended for `result`:
/// BTGF_WAITING set, and BTGM_WAITING to its port.
fn waiting(controller: *Controller, block: *bluetooth.BTGatt, result: i32) void {
    block.flags |= bluetooth.BTGF_WAITING;
    tellState(controller, block, bluetooth.BTGM_WAITING, result);
}

fn tellState(controller: *Controller, block: *bluetooth.BTGatt, kind: u32, result: i32) void {
    const port = block.port orelse return;
    const message = taskchannels.newMessage(controller, block, true, kind, result, 0) orelse return;
    taskchannels.put(controller.base, port, message);
}

/// The block closed, for `result`: it says so, and BTGM_CLOSED goes to
/// its port.
fn closed(controller: *Controller, block: *bluetooth.BTGatt, result: i32) void {
    block.flags |= bluetooth.BTGF_CLOSED;
    tellState(controller, block, bluetooth.BTGM_CLOSED, result);
}

// --- the commands ---------------------------------------------------------------

/// OpenBTGatt: the block begun - the call's wait, the layer's record
/// naming the caller's block - or why not; one that waits answered at
/// once. The block names its controller first: one that waits may open
/// before the call returns.
pub fn open(controller: *Controller, command: *Command) connections.Begun {
    const block: *bluetooth.BTGatt = @ptrCast(@alignCast(command.block.?));
    block.controller = controller.id;
    return att_client.open(&controller.layer, command.address, block, command.flags & bluetooth.BTGO_WAIT != 0);
}

/// CloseBTGatt: the block's record given back, the device told of the
/// values only it wanted. Nothing more is put about the block.
pub fn close(controller: *Controller, command: *Command) void {
    const layer = &controller.layer;
    const record = att_client.byOwner(layer, command.block.?) orelse return;
    att_client.close(layer, record);
}

/// The open record of the command's block; null - the command's result
/// set - where it is closed or gone.
fn recordOf(controller: *Controller, command: *Command) ?*att_client.Client {
    const record = att_client.byOwner(&controller.layer, command.block.?);
    if (record == null or record.?.state != .open) {
        command.result = bluetooth.BTERR_NOTCONNECTED;
        return null;
    }
    return record;
}

/// ObtainBTCharacteristics: the service's characteristics asked for, into
/// the caller's room.
pub fn characteristics(controller: *Controller, command: *Command) connections.Begun {
    const record = recordOf(controller, command) orelse return .{ .done = command.result };
    return att_client.characteristics(&controller.layer, record, @intCast(command.handle), @intCast(command.end_handle), command.room.?[0..command.length]);
}

/// ReadBTAttribute: the value read into the caller's buffer.
pub fn read(controller: *Controller, command: *Command) connections.Begun {
    const record = recordOf(controller, command) orelse return .{ .done = command.result };
    const buffer: []u8 = if (command.length == 0) &.{} else command.room.?[0..command.length];
    return att_client.read(&controller.layer, record, @intCast(command.handle), buffer);
}

/// WriteBTAttribute: the caller's value written.
pub fn write(controller: *Controller, command: *Command) connections.Begun {
    const record = recordOf(controller, command) orelse return .{ .done = command.result };
    const value: []const u8 = if (command.length == 0) &.{} else command.data.?[0..command.length];
    return att_client.write(&controller.layer, record, @intCast(command.handle), value, command.flags & bluetooth.BTGW_NORESPONSE != 0);
}

/// SubscribeBTAttribute: the value subscribed to, its configuration
/// written.
pub fn subscribe(controller: *Controller, command: *Command) connections.Begun {
    const record = recordOf(controller, command) orelse return .{ .done = command.result };
    return att_client.subscribe(&controller.layer, record, @intCast(command.handle), @intCast(command.configuration), command.flags & bluetooth.BTGS_INDICATE != 0);
}

/// UnsubscribeBTAttribute: the subscription ended, its configuration
/// written.
pub fn unsubscribe(controller: *Controller, command: *Command) connections.Begun {
    const record = recordOf(controller, command) orelse return .{ .done = command.result };
    return att_client.unsubscribe(&controller.layer, record, @intCast(command.handle));
}

/// A command's wait done, the wait's `serial` read before it was given
/// back: how much of the caller's room its procedure filled, the
/// procedure's record freed, and an opened block told its MTU.
pub fn answered(controller: *Controller, command: *Command, serial: u32) void {
    const layer = &controller.layer;
    if (att_client.procedureOf(layer, serial)) |procedure| command.have = @intCast(procedure.have);
    att_client.release(layer, serial);
    if (command.kind != .open_gatt or command.result != 0) return;
    const block: *bluetooth.BTGatt = @ptrCast(@alignCast(command.block.?));
    block.address = command.address;
    block.mtu = if (connections.find(layer, command.address)) |connection| connection.att.mtu else att.ATT_MTU_DEFAULT;
}
