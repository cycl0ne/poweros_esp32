// SPDX-License-Identifier: MPL-2.0
//! RemoveMsg: takes one given message off a port, under the port's lock -
//! the request an AbortIO takes back.

const sdk = @import("sdk");

const ExecBase = @import("../exec.zig").ExecBase;
const Message = sdk.exec.Message;
const MsgPort = sdk.exec.MsgPort;

/// Takes `msg` off `port` if it is still on it.
///
/// SYNOPSIS:
/// ```zig
/// fn RemoveMsg(base: *ExecBase, port: *MsgPort, msg: *Message) bool
/// ```
///
/// SINCE: 1.6. LVO -540.
///
/// INPUTS:
/// - `port` - the port the message was put to.
/// - `msg` - the message.
///
/// RESULT:
/// True when it was on the port and is off it now; false when it was not
/// there - taken by `GetMsg` already, or never put.
///
/// BEHAVIOR:
/// The port's queue is walked and changed under exec's port lock, which is
/// what `PutMsg`, `GetMsg` and `ReplyMsg` change it under. So it holds
/// against a message put on the same port from the other core or from an
/// interrupt meanwhile, which a list walked under any other lock does not.
///
/// What a device's AbortIO needs: a request still queued on its unit's port
/// is taken back here, and one that is not is somewhere else - in the
/// device's own lists, or being worked on.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: safe. It takes exec's port lock, which masks the core's
///   interrupts.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// A message taken off is the caller's to reply or to put again.
///
/// NOTES:
/// The walk is as long as the queue.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `GetMsg`, `PutMsg`, `AbortIO`
///
/// EXAMPLES:
/// ```zig
/// if (sys.RemoveMsg(&unit.msg_port, &io.message)) {
///     io.err = IOERR_ABORTED;
///     sys.ReplyIO(io);
/// }
/// ```
pub fn RemoveMsg(base: *ExecBase, port: *MsgPort, msg: *Message) bool {
    const sys = base.iface();
    sys.AcquireLock(&base.lock_ports);
    defer sys.ReleaseLock(&base.lock_ports);
    var it = port.msg_list.iterator();
    while (it.next()) |node| {
        if (node != &msg.node) continue;
        sys.Remove(node);
        return true;
    }
    return false;
}
