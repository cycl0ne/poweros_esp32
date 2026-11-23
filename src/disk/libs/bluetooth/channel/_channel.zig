// SPDX-License-Identifier: MIT
//! The channel calls' shared parts: AddBTListener's record, kept on the
//! base's list under its lock, and the message the library's task sends
//! to a channel's port, or a GATT block's - the BTChannelMessage or
//! BTGattMessage its receiver reads, with what the task knows it by when
//! it comes back, and its place on the base's list of the messages out,
//! by which CloseBTChannel and CloseBTGatt find those still on the
//! port.

const sdk = @import("sdk");
const exec = sdk.exec;
const bluetooth = sdk.bluetooth;
const BluetoothBase = @import("../bluetooth_base.zig").BluetoothBase;

/// One AddBTListener: the BTListener its caller holds.
pub const Listener = struct {
    node: exec.Node = .{},
    /// Its number: never 0, never one another listener had.
    id: u32,
    psm: u16,
    port: *exec.MsgPort,
};

/// A message to a channel's port, or a GATT block's: what its receiver
/// reads, the block's controller and the block, by which the task finds
/// the channel or the GATT block again when it comes back - and, for
/// BTCM_DATA and BTGM_VALUE, the frame or the value after it.
pub const Message = extern struct {
    public: Public = .{ .channel = .{} },
    /// Which of the two `public` is.
    gatt: bool = false,
    controller: u32 = 0,
    owner: ?*anyopaque = null,
    /// The port it was put to.
    port: ?*exec.MsgPort = null,
    /// On the base's `channel_messages` while it is out.
    link: exec.Node = .{},
};

/// What the receiver reads: each begins with its exec.Message.
pub const Public = extern union {
    channel: bluetooth.BTChannelMessage,
    gatt: bluetooth.BTGattMessage,
};

/// The message whose `link` is `node`.
pub fn fromLink(node: *exec.Node) *Message {
    return @alignCast(@fieldParentPtr("link", node));
}

/// The exec.Message the receiver gets, first in either.
pub fn messageOf(sent: *Message) *exec.Message {
    return &sent.public.channel.message;
}

/// The message `message` begins.
pub fn fromMessage(message: *exec.Message) *Message {
    return @ptrCast(@alignCast(message));
}

/// The listener that serves `psm`; null for none. Under the listeners'
/// lock, held while the record is used.
pub fn findPsm(base: *BluetoothBase, psm: u32) ?*Listener {
    var it = base.listeners.iterator();
    while (it.next()) |node| {
        const listener: *Listener = @alignCast(@fieldParentPtr("node", node));
        if (listener.psm == psm) return listener;
    }
    return null;
}

/// The listener with number `id`; null when it is gone. Under the
/// listeners' lock, held while the record is used.
pub fn find(base: *BluetoothBase, id: u32) ?*Listener {
    var it = base.listeners.iterator();
    while (it.next()) |node| {
        const listener: *Listener = @alignCast(@fieldParentPtr("node", node));
        if (listener.id == id) return listener;
    }
    return null;
}
