// SPDX-License-Identifier: MPL-2.0
//! ReplyMsg: sends a message back to its sender's reply port, marked as a
//! reply. A message with no reply port is marked free instead, so its
//! sender can see it is done.

const sdk = @import("sdk");
const _ports = @import("_ports.zig");

const ExecBase = @import("../exec.zig").ExecBase;
const Message = sdk.exec.Message;

/// Sends a message back to whoever sent it.
///
/// SYNOPSIS:
/// ```zig
/// fn ReplyMsg(base: *ExecBase, msg: *Message) void
/// ```
///
/// SINCE: 1.0. LVO -212.
///
/// INPUTS:
/// - `msg` - a message the caller took with `GetMsg`.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// It goes on the sender's reply port and that port's action is done, so
/// replying wakes the sender exactly as sending woke the receiver.
///
/// **A message with no reply port** is marked as free and nothing else
/// happens. That is how a sender says "this one is one-way, do not answer
/// it" - and how the receiver tells one from the other without being told.
///
/// The message's type says which way round it is, so a sender can check
/// that what came back is a reply.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: safe. It takes Disable.
/// - Forbid: not needed. The reply port belongs to the sender, which is
///   waiting for this and so cannot have gone away.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The message goes back to the sender and must not be touched again. For a
/// one-way message with no reply port, it is the receiver's to free.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `GetMsg`, `PutMsg`, `ReplyIO`
///
/// EXAMPLES:
/// ```zig
/// sys.ReplyMsg(msg);
/// ```
pub fn ReplyMsg(base: *ExecBase, msg: *Message) void {
    const port = msg.reply_port orelse {
        msg.node.type = .freemsg;
        return;
    };
    _ports.put(base, port, msg, .replymsg);
}
