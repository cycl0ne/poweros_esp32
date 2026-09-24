// SPDX-License-Identifier: MPL-2.0
//! Message ports: where messages are sent.
//!
//! A port says what to do when a message arrives - signal its task, cause a
//! software interrupt, or nothing - and that one choice is what lets the
//! same PutMsg deliver to a waiting process and to an interrupt.
//!
//! A public port has a name and is on SysBase's port list, so anything can
//! find it; a private one is reached only by being handed the pointer,
//! which is what every reply port is. struct MsgPort and the PA_* actions
//! are the SDK's (sdk/libs/exec/ports.zig).
//!
//! Messages. One is queued on a port with PutMsg, which then does the
//! port's action; the receiver takes it with GetMsg and sends it back to
//! the sender's reply port with ReplyMsg.
//!
//! **A message is never copied.** Sender and receiver share the memory, and
//! the sender must not touch a message between sending it and getting it
//! back. That is what every packet, I/O request and semaphore bid in this
//! system is built on: a Message with something on the end of it.
//!
//! The port and message calls are a file each in this folder; this file
//! is the half `PutMsg` and `ReplyMsg` share.

const sdk = @import("sdk");

const ExecBase = @import("../exec.zig").ExecBase;
const Message = sdk.exec.Message;
const MsgPort = sdk.exec.MsgPort;

/// Queues a message on a port and does the port's action - the half
/// `PutMsg` and `ReplyMsg` share. It runs under Disable, because the port's
/// list and its action may be reached from an interrupt.
///
/// INPUTS:
/// - `base` - exec: the jump table the calls go through.
/// - `port` - where the message goes.
/// - `msg` - what is sent.
/// - `node_type` - which way it is travelling, `.message` or `.replymsg`,
///   so that a sender can tell a reply from a fresh message.
pub fn put(base: *ExecBase, port: *MsgPort, msg: *Message, node_type: sdk.exec.NodeType) void {
    const sys = base.iface();
    sys.Disable();
    defer sys.Enable();
    msg.node.type = node_type;
    sys.AddTail(&port.msg_list, &msg.node);
    switch (port.flags & sdk.exec.PF_ACTION) {
        sdk.exec.PA_SIGNAL => if (port.sig_task) |task| sys.Signal(@ptrCast(@alignCast(task)), port.sigMask()),
        sdk.exec.PA_SOFTINT => if (port.sig_task) |interrupt| sys.Cause(@ptrCast(@alignCast(interrupt))),
        else => {},
    }
}
