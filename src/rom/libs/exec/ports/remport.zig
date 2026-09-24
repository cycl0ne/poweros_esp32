// SPDX-License-Identifier: MPL-2.0
//! RemPort: takes a public port off exec's port list, so `FindPort` no
//! longer finds it.

const sdk = @import("sdk");

const ExecBase = @import("../exec.zig").ExecBase;
const MsgPort = sdk.exec.MsgPort;

/// Takes a port off the public list.
///
/// SYNOPSIS:
/// ```zig
/// fn RemPort(base: *ExecBase, port: *MsgPort) void
/// ```
///
/// SINCE: 1.0. LVO -224.
///
/// INPUTS:
/// - `port` - a port that was added with `AddPort`.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// Nothing new can find it. Messages already on its queue are still there
/// and are still the caller's to deal with - removing a port does not empty
/// it, and anything already replied to will still arrive.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no. It takes Forbid.
/// - Forbid: taken here, around the list.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated. Draining the queue before freeing the port is the
/// caller's.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AddPort`, `DeleteMsgPort`
///
/// EXAMPLES:
/// ```zig
/// sys.RemPort(port);
/// while (sys.GetMsg(port)) |msg| sys.ReplyMsg(msg);
/// ```
pub fn RemPort(base: *ExecBase, port: *MsgPort) void {
    const sys = base.iface();
    sys.Forbid();
    defer sys.Permit();
    sys.Remove(&port.node);
}
