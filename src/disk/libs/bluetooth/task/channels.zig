// SPDX-License-Identifier: MIT
//! The task's side of the channels (l2cap/channels.zig) and the service
//! queries (sdp/client.zig; att/client.zig over LE): the commands of
//! OpenBTChannel, StartBTChannel, CloseBTChannel, SendBTChannel,
//! AttemptSendBTChannel and ObtainBTServices handed to the layer, what the layer tells of the channels sent to
//! their ports as BTChannelMessages, and those messages - and GATT's
//! (gatt.zig) - freed as they come back.
//!
//! **A channel's block** is the BTChannel its holder has: OpenBTChannel's
//! and StartBTChannel's made in their caller's context, one a device
//! opened to a listener made here and given to the listener's task. A
//! started channel's opening is told to its block's port as a device's
//! is - BTCM_OPENED - and an end before it as BTCM_CLOSED. The layer's record of the
//! channel names the block as its `owner`; a command that names a block
//! acts on the record that names it, so a block whose record is gone - its
//! channel closed, its controller gone - touches nothing.
//!
//! **The messages** are the task's: made here, put on the channel's port
//! - or the GATT block's - and kept on the base's list until they come
//! back, freed then. Those about a channel CloseBTChannel closes, or a
//! block CloseBTGatt does, that are still on its port are taken back off
//! it (exec's RemoveMsg) and freed, so that nothing about it is there
//! once the call returns - one its receiver has taken already comes back
//! as ever. Of a channel's frames at most l2cap_channels.OUT_MOST are out
//! at once - those past them let go and counted in its block
//! (BTChannel.dropped), as a GATT block's values are - and the task does
//! not end while any message is out.
//!
//! Every function here runs in the task, the layers under the base's lock
//! - the upcalls (`event`, `listener`) called by the layer under it.

const sdk = @import("sdk");
const exec = sdk.exec;
const bluetooth = sdk.bluetooth;
const _base = @import("../bluetooth_base.zig");
const BluetoothBase = _base.BluetoothBase;
const _controller = @import("../controller/_controller.zig");
const Controller = _controller.Controller;
const _channel = @import("../channel/_channel.zig");
const _hci = @import("../hci/_hci.zig");
const connections = @import("../hci/connections.zig");
const l2cap_channels = @import("../l2cap/channels.zig");
const sdp_client = @import("../sdp/client.zig");
const att_client = @import("../att/client.zig");
const Command = @import("_task.zig").Command;

/// The port's upcall for the task's channels: one open, a frame, one
/// closed - each to the channel's port. False only for a channel a device
/// opened that is not taken: its listener gone, or no memory.
pub fn event(context: *anyopaque, happened: *const l2cap_channels.Event) bool {
    const controller: *Controller = @ptrCast(@alignCast(context));
    const record = happened.channel;
    switch (happened.kind) {
        .opened => {
            if (record.incoming) return taken(controller, record);
            // OpenBTChannel's and StartBTChannel's: the block told what the
            // channel is - a started one's port told that it is open.
            const owner = record.owner orelse return true;
            const block: *bluetooth.BTChannel = @ptrCast(@alignCast(owner));
            describe(block, controller, record);
            if (record.started) return started(controller, block);
        },
        .data => frame(controller, record, happened.data),
        .closed => closed(controller, record, happened.result),
    }
    return true;
}

/// The port's upcall for a device's Connection Request: the listener that
/// serves `psm` - its number, 0 for none - and whether it is secure.
pub fn listener(context: *anyopaque, psm: u16) _hci.Listening {
    const controller: *Controller = @ptrCast(@alignCast(context));
    const base = controller.base;
    const sys = base.sys_base;
    sys.ObtainSemaphoreShared(&base.listeners_lock);
    defer sys.ReleaseSemaphore(&base.listeners_lock);
    const serving = _channel.findPsm(base, psm) orelse return .{};
    return .{ .id = serving.id, .secure = serving.secure };
}

/// What a channel's block says of it, from its record.
fn describe(block: *bluetooth.BTChannel, controller: *const Controller, record: *const l2cap_channels.Channel) void {
    block.controller = controller.id;
    block.address = record.address;
    block.psm = record.psm;
    block.local_cid = record.local_cid;
    block.remote_cid = record.remote_cid;
    block.mtu_out = record.mtu_out;
    block.mtu_in = l2cap_channels.MTU_IN;
}

/// A channel a device opened to a listener: its block made, given to the
/// listener's task, and sent to its port as BTCM_OPENED - under the
/// listeners' lock, which RemBTListener takes, so nothing comes to the
/// port of one that has gone.
fn taken(controller: *Controller, record: *l2cap_channels.Channel) bool {
    const base = controller.base;
    const sys = base.sys_base;
    sys.ObtainSemaphoreShared(&base.listeners_lock);
    defer sys.ReleaseSemaphore(&base.listeners_lock);
    const serving = _channel.find(base, record.listener) orelse return false;
    const memory = sys.AllocVec(@sizeOf(bluetooth.BTChannel), exec.MEMF_CLEAR) orelse return false;
    const block: *bluetooth.BTChannel = @ptrCast(@alignCast(memory));
    const message = newMessage(controller, block, false, bluetooth.BTCM_OPENED, 0, 0) orelse {
        sys.FreeVec(memory);
        return false;
    };
    block.* = .{ .flags = bluetooth.BTCHF_INCOMING, .port = serving.port };
    describe(block, controller, record);
    record.owner = block;
    if (serving.port.sig_task) |task| _ = sys.SetMemOwner(block, @ptrCast(@alignCast(task)));
    put(base, serving.port, message);
    return true;
}

/// A channel StartBTChannel began, open: BTCM_OPENED to its block's port.
/// False without memory, and the layer closes it again.
fn started(controller: *Controller, block: *bluetooth.BTChannel) bool {
    const port = block.port orelse return false;
    const message = newMessage(controller, block, false, bluetooth.BTCM_OPENED, 0, 0) orelse return false;
    put(controller.base, port, message);
    return true;
}

/// A frame to the channel's port as BTCM_DATA - let go and counted while
/// OUT_MOST of its frames are out, or without memory.
fn frame(controller: *Controller, record: *l2cap_channels.Channel, data: []const u8) void {
    const block: *bluetooth.BTChannel = @ptrCast(@alignCast(record.owner orelse return));
    const port = block.port orelse return;
    if (record.out >= l2cap_channels.OUT_MOST) {
        block.dropped +%= 1;
        return;
    }
    const message = newMessage(controller, block, false, bluetooth.BTCM_DATA, 0, data.len) orelse {
        block.dropped +%= 1;
        return;
    };
    const room = extraOf(message);
    @memcpy(room[0..data.len], data);
    message.public.channel.data = room;
    message.public.channel.length = @intCast(data.len);
    record.out += 1;
    put(controller.base, port, message);
}

/// The channel closed, for `result`: its block says so, and BTCM_CLOSED
/// goes to its port.
fn closed(controller: *Controller, record: *l2cap_channels.Channel, result: i32) void {
    const block: *bluetooth.BTChannel = @ptrCast(@alignCast(record.owner orelse return));
    block.flags |= bluetooth.BTCHF_CLOSED;
    const port = block.port orelse return;
    const message = newMessage(controller, block, false, bluetooth.BTCM_CLOSED, result, 0) orelse return;
    put(controller.base, port, message);
}

/// A message about the block `owner` - a channel's, or with `gatt` a GATT
/// block's - with `extra` bytes after it for a frame or a value; null
/// without memory.
pub fn newMessage(controller: *const Controller, owner: *anyopaque, gatt: bool, kind: u32, result: i32, extra: usize) ?*_channel.Message {
    const base = controller.base;
    const replies = base.channel_replies orelse return null;
    const memory = base.sys_base.AllocVec(@sizeOf(_channel.Message) + extra, exec.MEMF_CLEAR) orelse return null;
    const message: *_channel.Message = @ptrCast(@alignCast(memory));
    message.* = .{ .gatt = gatt, .controller = controller.id, .owner = owner };
    if (gatt) {
        message.public = .{ .gatt = .{ .kind = kind, .result = result, .gatt = @ptrCast(@alignCast(owner)) } };
    } else {
        message.public = .{ .channel = .{ .kind = kind, .result = result, .channel = @ptrCast(@alignCast(owner)) } };
    }
    const header = _channel.messageOf(message);
    header.reply_port = replies;
    header.length = if (gatt) @sizeOf(bluetooth.BTGattMessage) else @sizeOf(bluetooth.BTChannelMessage);
    header.node.type = .message;
    return message;
}

/// The room after a message made with extra bytes.
pub fn extraOf(message: *_channel.Message) [*]u8 {
    return @ptrFromInt(@intFromPtr(message) + @sizeOf(_channel.Message));
}

/// The message put on `port`, and kept on the base's list of those out.
pub fn put(base: *BluetoothBase, port: *exec.MsgPort, message: *_channel.Message) void {
    const sys = base.sys_base;
    message.port = port;
    sys.AddTail(&base.channel_messages, &message.link);
    base.channel_out += 1;
    sys.PutMsg(port, _channel.messageOf(message));
}

/// A message back: taken off the list and freed, and - a frame's or a
/// value's - its channel's or block's count of those out given back,
/// where it is still there.
pub fn replied(base: *BluetoothBase, message: *exec.Message) void {
    const sys = base.sys_base;
    const sent = _channel.fromMessage(message);
    sys.ObtainSemaphore(&base.lock);
    sys.Remove(&sent.link);
    const counted = if (sent.gatt) sent.public.gatt.kind == bluetooth.BTGM_VALUE else sent.public.channel.kind == bluetooth.BTCM_DATA;
    if (counted) {
        if (byId(base, sent.controller)) |controller| {
            if (sent.gatt) {
                if (att_client.byOwner(&controller.layer, sent.owner.?)) |record| {
                    if (record.out > 0) record.out -= 1;
                }
            } else if (l2cap_channels.byOwner(&controller.layer, sent.owner.?)) |record| {
                if (record.out > 0) record.out -= 1;
            }
        }
    }
    base.channel_out -= 1;
    sys.ReleaseSemaphore(&base.lock);
    sys.FreeVec(sent);
}

/// CloseBTChannel's and CloseBTGatt's, once nothing more is put about
/// `block`: its messages still on its port taken back off it and freed.
/// One its receiver has taken already is left to come back.
pub fn takeBack(base: *BluetoothBase, block: *const anyopaque) void {
    const sys = base.sys_base;
    var it = base.channel_messages.iterator();
    while (it.next()) |node| {
        const sent = _channel.fromLink(node);
        if (@intFromPtr(sent.owner) != @intFromPtr(block)) continue;
        if (!sys.RemoveMsg(sent.port.?, _channel.messageOf(sent))) continue;
        sys.Remove(&sent.link);
        base.channel_out -= 1;
        sys.FreeVec(sent);
    }
}

/// The controller numbered `id`; null when it is gone.
pub fn byId(base: *BluetoothBase, id: u32) ?*Controller {
    var it = base.controllers.iterator();
    while (it.next()) |node| {
        const controller = _controller.fromNode(node);
        if (controller.id == id) return controller;
    }
    return null;
}

// --- the commands ---------------------------------------------------------------

/// OpenBTChannel: the channel begun - the call's wait, its record naming
/// the caller's block - or why not.
pub fn open(controller: *Controller, command: *Command) connections.Begun {
    const layer = &controller.layer;
    if (!l2cap_channels.validPsm(command.psm)) return .{ .done = bluetooth.BTERR_UNSUPPORTED };
    const begun = l2cap_channels.open(layer, command.address, @intCast(command.psm));
    switch (begun) {
        .waiting => |index| {
            const record = l2cap_channels.bySerial(layer, layer.waits[index].serial).?;
            record.owner = command.block;
            const block: *bluetooth.BTChannel = @ptrCast(@alignCast(command.block.?));
            block.controller = controller.id;
        },
        .done => {},
    }
    return begun;
}

/// StartBTChannel: the channel begun, its record naming the caller's
/// block - 0 - or why not. Its opening, or its end before it, is told to
/// the block's port.
pub fn start(controller: *Controller, command: *Command) i32 {
    if (!l2cap_channels.validPsm(command.psm)) return bluetooth.BTERR_UNSUPPORTED;
    switch (l2cap_channels.start(&controller.layer, command.address, @intCast(command.psm))) {
        .channel => |record| {
            record.owner = command.block;
            const block: *bluetooth.BTChannel = @ptrCast(@alignCast(command.block.?));
            block.controller = controller.id;
            return 0;
        },
        .failed => |result| return result,
    }
}

/// CloseBTChannel: the block's channel closed - the device asked, its
/// answer not waited for - where it is not closed already. Nothing more
/// is put about it either way: its record no longer names the block.
pub fn close(controller: *Controller, command: *const Command) void {
    const layer = &controller.layer;
    const record = l2cap_channels.byOwner(layer, command.block.?) orelse return;
    l2cap_channels.closeFor(layer, record);
}

/// SendBTChannel: the frame queued on the block's channel - 0, BTERR_BUSY
/// while the controller's queue is full, or why not.
pub fn send(controller: *Controller, command: *Command) i32 {
    const layer = &controller.layer;
    const record = l2cap_channels.byOwner(layer, command.block.?) orelse return bluetooth.BTERR_NOTCONNECTED;
    return l2cap_channels.send(layer, record, command.data.?[0..command.length]);
}

/// AttemptSendBTChannel: the frame queued on the block's channel - 0 - or
/// BTERR_BUSY where the controller's queue is full or `behind` says sends
/// wait for room before it; BTERR_NOTCONNECTED for a channel closed.
pub fn attempt(controller: *Controller, command: *Command, behind: bool) i32 {
    const layer = &controller.layer;
    const record = l2cap_channels.byOwner(layer, command.block.?) orelse return bluetooth.BTERR_NOTCONNECTED;
    if (behind) return bluetooth.BTERR_BUSY;
    return l2cap_channels.send(layer, record, command.data.?[0..command.length]);
}

/// ObtainBTServices: the device's records asked for - over LE its GATT
/// services - into the caller's room: the call's wait, or why not.
pub fn services(controller: *Controller, command: *Command) connections.Begun {
    // The call's list names the controller that asked.
    command.controller = controller.id;
    const room = command.room.?[0..command.length];
    if (command.address.kind != bluetooth.BTADDR_BREDR) return att_client.services(&controller.layer, command.address, room);
    return sdp_client.query(&controller.layer, command.address, room);
}

/// ObtainBTServices's wait done, the wait's `serial` read before it was
/// given back: how much of the room the records fill read, and the
/// query's record freed - an SDP query's controller free to query again.
pub fn servicesAnswered(controller: *Controller, command: *Command, serial: u32) void {
    const layer = &controller.layer;
    if (command.address.kind != bluetooth.BTADDR_BREDR) {
        if (att_client.procedureOf(layer, serial)) |procedure| command.have = @intCast(procedure.have);
        att_client.release(layer, serial);
        return;
    }
    command.have = @intCast(layer.sdp_query.have);
    sdp_client.release(layer);
}
