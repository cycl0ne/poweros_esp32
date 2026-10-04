// SPDX-License-Identifier: MPL-2.0
//! AddPort: makes a port public - on exec's port list by priority, where
//! `FindPort` finds it by name.

const sdk = @import("sdk");

const ExecBase = @import("../exec.zig").ExecBase;
const MsgPort = sdk.exec.MsgPort;

/// Makes a port public, so that anything can find it by name.
///
/// SYNOPSIS:
/// ```zig
/// fn AddPort(base: *ExecBase, port: *MsgPort) void
/// ```
///
/// SINCE: 1.0. LVO -220.
///
/// INPUTS:
/// - `port` - the port, with its name and priority set and its action and
///   signal already arranged.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// The message list is initialised here, so a port need not have been
/// through `CreateMsgPort` - a port in a structure the caller allocated is
/// added the same way.
///
/// It is enqueued by priority, so a higher-priority port of the same name
/// is the one `FindPort` answers.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no. It takes exec's port lock, around the list.
/// - Forbid: may be held. It is taken here as well, around the change:
///   a program walks the port list under Forbid, which must keep it
///   still on both cores.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated. The port stays the caller's, and must not be freed
/// until it has been removed - anything may be sending to it.
///
/// NOTES:
/// The port's message list is made empty here, so a port declared rather
/// than created needs nothing else before it is added.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `RemPort`, `FindPort`, `CreateMsgPort`
///
/// EXAMPLES:
/// ```zig
/// port.node.name = "my.port";
/// sys.AddPort(port);
/// ```
pub fn AddPort(base: *ExecBase, port: *MsgPort) void {
    port.node.type = .msgport;
    port.msg_list.init(.message);
    const sys = base.iface();
    sys.Forbid();
    defer sys.Permit();
    sys.AcquireLock(&base.lock_ports);
    defer sys.ReleaseLock(&base.lock_ports);
    sys.Enqueue(&base.port_list, &port.node);
}
