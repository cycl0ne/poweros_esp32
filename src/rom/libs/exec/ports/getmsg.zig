// SPDX-License-Identifier: MPL-2.0
//! GetMsg: takes the first message off a port, without waiting.

const sdk = @import("sdk");

const ExecBase = @import("../exec.zig").ExecBase;
const Message = sdk.exec.Message;
const MsgPort = sdk.exec.MsgPort;

/// Takes the oldest message off a port, without waiting.
///
/// SYNOPSIS:
/// ```zig
/// fn GetMsg(base: *ExecBase, port: *MsgPort) ?*Message
/// ```
///
/// SINCE: 1.0. LVO -208.
///
/// INPUTS:
/// - `port` - the caller's own port.
///
/// RESULT:
/// The message, or null if the queue is empty.
///
/// BEHAVIOR:
/// It never waits, which is what makes the drain loop right: a signal may
/// stand for any number of messages, so what follows a wakeup is `while
/// (GetMsg())` and not one `GetMsg` per signal.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: safe. It takes Disable, which is how a port with
///   `PA_SOFTINT` is drained.
/// - Forbid: not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The message is the receiver's until it replies. If it has a reply port
/// it must be replied, or the sender waits for ever.
///
/// NOTES:
/// The list is taken from under Disable, because an interrupt may be
/// putting a message on it.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `PutMsg`, `ReplyMsg`, `WaitPort`
///
/// EXAMPLES:
/// ```zig
/// _ = sys.Wait(mask);
/// while (sys.GetMsg(port)) |msg| {
///     // ... deal with it ...
///     sys.ReplyMsg(msg);
/// }
/// ```
pub fn GetMsg(base: *ExecBase, port: *MsgPort) ?*Message {
    const sys = base.iface();
    sys.Disable();
    defer sys.Enable();
    const node = sys.RemHead(&port.msg_list) orelse return null;
    return @fieldParentPtr("node", node);
}
