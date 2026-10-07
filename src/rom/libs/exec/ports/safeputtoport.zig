// SPDX-License-Identifier: MPL-2.0
//! SafePutToPort: a message to a public port found by its name, the find
//! and the send under one hold of exec's port lock.

const sdk = @import("sdk");

const ExecBase = @import("../exec.zig").ExecBase;
const Message = sdk.exec.Message;
const MsgPort = sdk.exec.MsgPort;
const _ports = @import("_ports.zig");

/// Puts a message to the public port of a name, if there is one.
///
/// SYNOPSIS:
/// ```zig
/// fn SafePutToPort(base: *ExecBase, message: *Message, name: [*:0]const u8) bool
/// ```
///
/// SINCE: 1.7. LVO -544.
///
/// INPUTS:
/// - `message` - what is sent, its `reply_port` set if an answer is wanted.
/// - `name` - the port's name, matched exactly.
///
/// RESULT:
/// True when the port was there and has the message; false when no port
/// of that name is on the list, and the message is still the caller's.
///
/// BEHAVIOR:
/// The port is looked for and the message put on it as `PutMsg` puts one
/// - the port's action done - without exec's port lock being let go in
/// between. `RemPort` takes the same lock, so a port found here is still
/// on the list when the message reaches it: its owner, who takes it off
/// and then answers what is on it before it deletes the port, answers
/// this message too. `FindPort` followed by `PutMsg` leaves a moment in
/// which the owner may take the port off and delete it, and the message
/// would go to memory that is no longer a port.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: safe. It takes exec's port lock, which masks the core's
///   interrupts.
/// - Locks: takes exec's port lock for the search and the put.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// On true the message is the port's owner's until it is replied; on false
/// it is still the caller's.
///
/// NOTES:
/// The search is as long as the list of public ports.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `FindPort`, `PutMsg`, `AddPort`, `RemPort`
///
/// EXAMPLES:
/// ```zig
/// if (!sys.SafePutToPort(&request.msg, "counter.port")) return dos.RETURN_WARN;
/// _ = sys.WaitPort(reply_port);
/// _ = sys.GetMsg(reply_port);
/// ```
pub fn SafePutToPort(base: *ExecBase, message: *Message, name: [*:0]const u8) bool {
    const sys = base.iface();
    sys.AcquireLock(&base.lock_ports);
    defer sys.ReleaseLock(&base.lock_ports);
    const node = sys.FindName(&base.port_list, name) orelse return false;
    const port: *MsgPort = @fieldParentPtr("node", node);
    _ports.putHeld(base, port, message, .message);
    return true;
}
