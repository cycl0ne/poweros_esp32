// SPDX-License-Identifier: MIT
//! Messages: made, copied and freed.
//!
//! Every message is one size - the event is inside it, an InputEvent here
//! carries nothing beside itself - and is the system's memory, since it
//! is made on whichever task needs it (the handler's, a program adding
//! events or sending a command) and freed on another. A message the
//! library sends a program comes back to the base's reply port, where
//! `freeReplied` finds it.

const sdk = @import("sdk");
const exec = sdk.exec;
const ie = sdk.devices.inputevent;
const InputEvent = ie.InputEvent;
const _base = @import("../commodities_base.zig");
const CxBase = _base.CxBase;
const Message = _base.Message;

/// A message of `kind`, with a copy of `event` (its `next` cleared) for
/// CXM_IEVENT; null without memory.
pub fn create(base: *CxBase, kind: u32, event: ?*const InputEvent) ?*Message {
    const sys = base.sys_base;
    const block = sys.AllocMem(@sizeOf(Message), exec.MEMF_ANY | exec.MEMF_CLEAR | exec.MEMF_SYSTEM) orelse return null;
    const message: *Message = @ptrCast(@alignCast(block));
    message.* = .{ .kind = kind };
    message.msg.node.type = .message;
    message.msg.reply_port = &base.reply_port;
    message.msg.length = @sizeOf(Message);
    if (event) |e| {
        message.event = e.*;
        message.event.next = null;
    }
    return message;
}

/// A message given back.
pub fn free(base: *CxBase, message: *Message) void {
    base.sys_base.FreeMem(message, @sizeOf(Message));
}

/// Every message on `list` freed.
pub fn freeList(base: *CxBase, list: *exec.List) void {
    const sys = base.sys_base;
    while (sys.RemHead(list)) |node| free(base, @ptrCast(@alignCast(node)));
}

/// The messages programs have replied to, freed.
pub fn freeReplied(base: *CxBase) void {
    const sys = base.sys_base;
    while (sys.GetMsg(&base.reply_port)) |msg| free(base, @ptrCast(@alignCast(msg)));
}

/// The node `message` goes to first: the first broker, or the end of the
/// brokers' list when there are none.
pub fn routeToFirstBroker(base: *CxBase, message: *Message) void {
    message.destination = base.brokers.head;
}
