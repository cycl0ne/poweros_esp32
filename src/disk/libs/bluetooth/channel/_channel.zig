// SPDX-License-Identifier: MIT
//! The channel calls' shared parts: AddBTListener's record, kept on the
//! base's list under its lock, and the message the library's task sends
//! to a channel's port - the BTChannelMessage its receiver reads, with
//! what the task knows it by when it comes back, and its place on the
//! base's list of the messages out, by which CloseBTChannel finds those
//! still on the port.

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

/// A message to a channel's port: what its receiver reads, the channel's
/// controller and block, by which the task finds the channel again when
/// it comes back - and, for BTCM_DATA, the frame after it.
pub const Message = extern struct {
    public: bluetooth.BTChannelMessage = .{},
    controller: u32 = 0,
    owner: ?*anyopaque = null,
    /// The port it was put to.
    port: ?*exec.MsgPort = null,
    /// On the base's `channel_messages` while it is out.
    link: exec.Node = .{},
};

/// The message whose `link` is `node`.
pub fn fromLink(node: *exec.Node) *Message {
    return @alignCast(@fieldParentPtr("link", node));
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
