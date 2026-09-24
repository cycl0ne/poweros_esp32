// SPDX-License-Identifier: MPL-2.0
//! PutMsg: sends a message to a port. It is queued there and the port's
//! action is done - a signal to its task, a software interrupt, or
//! nothing.

const sdk = @import("sdk");
const _ports = @import("_ports.zig");

const ExecBase = @import("../exec.zig").ExecBase;
const Message = sdk.exec.Message;
const MsgPort = sdk.exec.MsgPort;

/// Sends a message to a port, and does whatever that port asks for on
/// arrival.
///
/// SYNOPSIS:
/// ```zig
/// fn PutMsg(base: *ExecBase, port: *MsgPort, msg: *Message) void
/// ```
///
/// SINCE: 1.0. LVO -204.
///
/// INPUTS:
/// - `port` - where it goes. It must still exist; for a public port that
///   means holding Forbid from the `FindPort` to here.
/// - `msg` - the message. Its `reply_port` should be set if a reply is
///   wanted, and its length if the receiver reads one.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// The message goes on the end of the port's queue, so messages are taken
/// in the order they were sent. Then the port's action: signal its task,
/// `Cause` its software interrupt, or nothing at all.
///
/// **The message now belongs to the receiver.** The sender must not read or
/// write it, and must not free it, until it comes back.
///
/// CONTEXT:
/// - Waits: no. Sending is never blocking - a port's queue has no limit,
///   and flow control is something the two ends arrange between them.
/// - Interrupts: safe. It takes Disable, and it is how an interrupt hands
///   work to a task.
/// - Forbid: not needed for the send itself; needed by the caller around
///   `FindPort` and this, so that a public port cannot go away in between.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The message passes to the receiver and comes back on `ReplyMsg`. It must
/// stay allocated for all of that time, which is why a message on a
/// sender's stack is only safe if the sender waits for the reply.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `GetMsg`, `ReplyMsg`, `WaitPort`, `FindPort`
///
/// EXAMPLES:
/// ```zig
/// sys.Forbid();
/// if (sys.FindPort("some.port")) |port| sys.PutMsg(port, &msg);
/// sys.Permit();
/// ```
pub fn PutMsg(base: *ExecBase, port: *MsgPort, msg: *Message) void {
    _ports.put(base, port, msg, .message);
}
