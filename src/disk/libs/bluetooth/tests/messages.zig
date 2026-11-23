// SPDX-License-Identifier: MIT
//! Host tests of the task's messages to channels' and GATT blocks' ports,
//! on the ROM's exec: each kept on the base's list while it is out; those
//! about a channel CloseBTChannel closes that are still on its port taken
//! back and freed, while one its receiver has taken already and another
//! channel's are left to come back; a started channel's opening told to
//! its port with its block filled in, and an end before it with why, an
//! OpenBTChannel's opening to nobody; each coming back freed, a frame's
//! count of frames out given back to its channel; a block's values with
//! their attribute, 32 of them out at most and those past them counted,
//! its close told, and what is on its port taken back as CloseBTGatt
//! does.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const bluetooth = sdk.bluetooth;
const kexec = @import("host_rom").exec;
const utility_library = @import("host_rom").utility;
const bluetooth_init = @import("../bluetooth_init.zig");
const _base = @import("../bluetooth_base.zig");
const _controller = @import("../controller/_controller.zig");
const taskchannels = @import("../task/channels.zig");
const taskgatt = @import("../task/gatt.zig");
const att_client = @import("../att/client.zig");

const testing = std.testing;

fn sendNothing(context: *anyopaque, packet_type: u8, bytes: []const u8) bool {
    _ = context;
    _ = packet_type;
    _ = bytes;
    return true;
}

test "a closed channel's messages still on its port taken back; one taken, and another channel's, left to come back" {
    const kub = try utility_library.setUp();
    const made = kexec.InitResident(kexec.SysBase, &bluetooth_init.bluetooth_library_tag, null) orelse return error.NoLibrary;
    const lib: *exec.Library = @ptrCast(@alignCast(made));
    const base = _base.bluetoothBase(lib);
    const sys = base.sys_base;
    const replies = sys.CreateMsgPort() orelse return error.NoPort;
    base.channel_replies = replies;
    const port = sys.CreateMsgPort() orelse return error.NoPort;
    var controller = _controller.Controller{ .base = base, .id = 3, .layer = .{ .port = .{ .context = undefined, .send = sendNothing } } };
    sys.AddTail(&base.controllers, &controller.node);
    var one: bluetooth.BTChannel = .{ .port = port };
    var other: bluetooth.BTChannel = .{ .port = port };
    const first = &controller.layer.channels[0];
    const second = &controller.layer.channels[1];
    first.* = .{ .state = .open, .told = true, .local_cid = 0x40, .owner = &one };
    second.* = .{ .state = .open, .told = true, .local_cid = 0x41, .owner = &other };

    // Three frames: two of `one`'s, one of `other`'s.
    sys.ObtainSemaphore(&base.lock);
    _ = taskchannels.event(&controller, &.{ .kind = .data, .channel = first, .data = "one" });
    _ = taskchannels.event(&controller, &.{ .kind = .data, .channel = first, .data = "two" });
    _ = taskchannels.event(&controller, &.{ .kind = .data, .channel = second, .data = "three" });
    sys.ReleaseSemaphore(&base.lock);
    try testing.expectEqual(@as(u32, 3), base.channel_out);
    try testing.expectEqual(@as(u8, 2), first.out);

    // The receiver takes the first; then `one` is closed - its record no
    // longer names its block - and what is still on the port about it is
    // taken back.
    const taken = sys.GetMsg(port) orelse return error.NoMessage;
    const taken_message: *bluetooth.BTChannelMessage = @fieldParentPtr("message", taken);
    try testing.expectEqualStrings("one", taken_message.data.?[0..taken_message.length]);
    first.* = .{};
    sys.ObtainSemaphore(&base.lock);
    taskchannels.takeBack(base, &one);
    sys.ReleaseSemaphore(&base.lock);
    try testing.expectEqual(@as(u32, 2), base.channel_out);
    const left = sys.GetMsg(port) orelse return error.NoMessage;
    const left_message: *bluetooth.BTChannelMessage = @fieldParentPtr("message", left);
    try testing.expectEqual(@as(?*bluetooth.BTChannel, &other), left_message.channel);
    try testing.expect(sys.GetMsg(port) == null);
    // Taking back again finds nothing.
    sys.ObtainSemaphore(&base.lock);
    taskchannels.takeBack(base, &one);
    sys.ReleaseSemaphore(&base.lock);
    try testing.expectEqual(@as(u32, 2), base.channel_out);

    // Both come back: freed, `other`'s count of frames out given back.
    sys.ReplyMsg(taken);
    sys.ReplyMsg(left);
    while (sys.GetMsg(replies)) |message| taskchannels.replied(base, message);
    try testing.expectEqual(@as(u32, 0), base.channel_out);
    try testing.expectEqual(@as(u8, 0), second.out);
    try testing.expect(base.channel_messages.isEmpty());

    sys.Remove(&controller.node);
    sys.DeleteMsgPort(port);
    sys.DeleteMsgPort(replies);
    base.channel_replies = null;
    _ = sys.RemLibrary(lib);
    try utility_library.tearDown(kub);
    kexec.deinit();
}

test "a started channel's opening told to its port, its block filled in; an end before it told with why; a waited one's told to no port" {
    const kub = try utility_library.setUp();
    const made = kexec.InitResident(kexec.SysBase, &bluetooth_init.bluetooth_library_tag, null) orelse return error.NoLibrary;
    const lib: *exec.Library = @ptrCast(@alignCast(made));
    const base = _base.bluetoothBase(lib);
    const sys = base.sys_base;
    const replies = sys.CreateMsgPort() orelse return error.NoPort;
    base.channel_replies = replies;
    const port = sys.CreateMsgPort() orelse return error.NoPort;
    var controller = _controller.Controller{ .base = base, .id = 3, .layer = .{ .port = .{ .context = undefined, .send = sendNothing } } };
    sys.AddTail(&base.controllers, &controller.node);
    var started: bluetooth.BTChannel = .{ .port = port };
    var failed: bluetooth.BTChannel = .{ .port = port };
    var waited: bluetooth.BTChannel = .{ .port = port };
    const open = &controller.layer.channels[0];
    const ending = &controller.layer.channels[1];
    const opened_waited = &controller.layer.channels[2];
    open.* = .{ .state = .open, .started = true, .psm = 0x0019, .local_cid = 0x40, .remote_cid = 0x51, .mtu_out = 895, .owner = &started };
    ending.* = .{ .state = .connecting, .started = true, .psm = 0x0017, .local_cid = 0x41, .owner = &failed };
    opened_waited.* = .{ .state = .open, .psm = 0x1001, .local_cid = 0x42, .remote_cid = 0x52, .owner = &waited };

    sys.ObtainSemaphore(&base.lock);
    try testing.expect(taskchannels.event(&controller, &.{ .kind = .opened, .channel = open }));
    _ = taskchannels.event(&controller, &.{ .kind = .closed, .channel = ending, .result = bluetooth.BTERR_TIMEOUT });
    try testing.expect(taskchannels.event(&controller, &.{ .kind = .opened, .channel = opened_waited }));
    sys.ReleaseSemaphore(&base.lock);
    try testing.expectEqual(@as(u32, 2), base.channel_out);

    // Open: the block says what the channel is.
    const first = sys.GetMsg(port) orelse return error.NoMessage;
    const first_message: *bluetooth.BTChannelMessage = @fieldParentPtr("message", first);
    try testing.expectEqual(bluetooth.BTCM_OPENED, first_message.kind);
    try testing.expectEqual(@as(?*bluetooth.BTChannel, &started), first_message.channel);
    try testing.expectEqual(@as(u32, 3), started.controller);
    try testing.expectEqual(@as(u16, 0x0019), started.psm);
    try testing.expectEqual(@as(u16, 0x51), started.remote_cid);
    try testing.expectEqual(@as(u16, 895), started.mtu_out);
    try testing.expectEqual(@as(u32, 0), started.flags);
    // Ended before it was open: why, and closed in its flags.
    const second = sys.GetMsg(port) orelse return error.NoMessage;
    const second_message: *bluetooth.BTChannelMessage = @fieldParentPtr("message", second);
    try testing.expectEqual(bluetooth.BTCM_CLOSED, second_message.kind);
    try testing.expectEqual(@as(?*bluetooth.BTChannel, &failed), second_message.channel);
    try testing.expectEqual(bluetooth.BTERR_TIMEOUT, second_message.result);
    try testing.expect(failed.flags & bluetooth.BTCHF_CLOSED != 0);
    // OpenBTChannel's: described for its call, nothing on the port.
    try testing.expect(sys.GetMsg(port) == null);
    try testing.expectEqual(@as(u16, 0x52), waited.remote_cid);

    sys.ReplyMsg(first);
    sys.ReplyMsg(second);
    while (sys.GetMsg(replies)) |message| taskchannels.replied(base, message);
    try testing.expectEqual(@as(u32, 0), base.channel_out);
    try testing.expect(base.channel_messages.isEmpty());

    sys.Remove(&controller.node);
    sys.DeleteMsgPort(port);
    sys.DeleteMsgPort(replies);
    base.channel_replies = null;
    _ = sys.RemLibrary(lib);
    try utility_library.tearDown(kub);
    kexec.deinit();
}

test "a GATT block's values to its port with their attribute, 32 out at most, its close told, what is on its port taken back" {
    const kub = try utility_library.setUp();
    const made = kexec.InitResident(kexec.SysBase, &bluetooth_init.bluetooth_library_tag, null) orelse return error.NoLibrary;
    const lib: *exec.Library = @ptrCast(@alignCast(made));
    const base = _base.bluetoothBase(lib);
    const sys = base.sys_base;
    const replies = sys.CreateMsgPort() orelse return error.NoPort;
    base.channel_replies = replies;
    const port = sys.CreateMsgPort() orelse return error.NoPort;
    var controller = _controller.Controller{ .base = base, .id = 3, .layer = .{ .port = .{ .context = undefined, .send = sendNothing } } };
    sys.AddTail(&base.controllers, &controller.node);
    var block: bluetooth.BTGatt = .{ .controller = 3, .port = port };
    const record = &controller.layer.att_clients[0];
    record.* = .{ .state = .open, .serial = 1, .owner = &block };

    // A value: on the port with its attribute, counted until it is replied.
    sys.ObtainSemaphore(&base.lock);
    taskgatt.event(&controller, &.{ .kind = .value, .client = record, .handle = 0x002A, .data = "level" });
    sys.ReleaseSemaphore(&base.lock);
    try testing.expectEqual(@as(u8, 1), record.out);
    const taken = sys.GetMsg(port) orelse return error.NoMessage;
    const told: *bluetooth.BTGattMessage = @fieldParentPtr("message", taken);
    try testing.expectEqual(bluetooth.BTGM_VALUE, told.kind);
    try testing.expectEqual(@as(?*bluetooth.BTGatt, &block), told.gatt);
    try testing.expectEqual(@as(u32, 0x002A), told.handle);
    try testing.expectEqualStrings("level", told.data.?[0..told.length]);
    sys.ReplyMsg(taken);
    while (sys.GetMsg(replies)) |message| taskchannels.replied(base, message);
    try testing.expectEqual(@as(u8, 0), record.out);
    try testing.expectEqual(@as(u32, 0), base.channel_out);

    // 33 values: the last let go, and counted.
    sys.ObtainSemaphore(&base.lock);
    for (0..att_client.OUT_MOST + 1) |_| taskgatt.event(&controller, &.{ .kind = .value, .client = record, .handle = 0x002A, .data = "x" });
    sys.ReleaseSemaphore(&base.lock);
    try testing.expectEqual(@as(u8, att_client.OUT_MOST), record.out);
    try testing.expectEqual(@as(u32, 1), block.dropped);
    try testing.expectEqual(@as(u32, att_client.OUT_MOST), base.channel_out);

    // Closed: said in its flags, and on the port after the values.
    sys.ObtainSemaphore(&base.lock);
    taskgatt.event(&controller, &.{ .kind = .closed, .client = record, .result = bluetooth.BTERR_TIMEOUT });
    sys.ReleaseSemaphore(&base.lock);
    try testing.expect(block.flags & bluetooth.BTGF_CLOSED != 0);
    try testing.expectEqual(@as(u32, att_client.OUT_MOST + 1), base.channel_out);
    const first = sys.GetMsg(port) orelse return error.NoMessage;
    const first_told: *bluetooth.BTGattMessage = @fieldParentPtr("message", first);
    try testing.expectEqual(bluetooth.BTGM_VALUE, first_told.kind);

    // CloseBTGatt: the record given back, what is still on the port taken
    // back and freed; the one taken comes back as before.
    record.* = .{};
    sys.ObtainSemaphore(&base.lock);
    taskchannels.takeBack(base, &block);
    sys.ReleaseSemaphore(&base.lock);
    try testing.expect(sys.GetMsg(port) == null);
    try testing.expectEqual(@as(u32, 1), base.channel_out);
    sys.ReplyMsg(first);
    while (sys.GetMsg(replies)) |message| taskchannels.replied(base, message);
    try testing.expectEqual(@as(u32, 0), base.channel_out);
    try testing.expect(base.channel_messages.isEmpty());

    sys.Remove(&controller.node);
    sys.DeleteMsgPort(port);
    sys.DeleteMsgPort(replies);
    base.channel_replies = null;
    _ = sys.RemLibrary(lib);
    try utility_library.tearDown(kub);
    kexec.deinit();
}
