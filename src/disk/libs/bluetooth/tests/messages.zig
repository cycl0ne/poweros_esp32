// SPDX-License-Identifier: MIT
//! Host tests of the task's messages to channels' ports, on the ROM's
//! exec: each kept on the base's list while it is out; those about a
//! channel CloseBTChannel closes that are still on its port taken back
//! and freed, while one its receiver has taken already and another
//! channel's are left to come back; each coming back freed, a frame's
//! count of frames out given back to its channel.

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
