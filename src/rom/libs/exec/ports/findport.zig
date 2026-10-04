// SPDX-License-Identifier: MPL-2.0
//! FindPort: a public port by name.

const sdk = @import("sdk");

const ExecBase = @import("../exec.zig").ExecBase;
const MsgPort = sdk.exec.MsgPort;

/// Finds a public port by name.
///
/// SYNOPSIS:
/// ```zig
/// fn FindPort(base: *ExecBase, name: [*:0]const u8) ?*MsgPort
/// ```
///
/// SINCE: 1.0. LVO -228.
///
/// INPUTS:
/// - `name` - the port's name, matched exactly, case included.
///
/// RESULT:
/// The port, or null if there is none of that name.
///
/// BEHAVIOR:
/// **The port may go away as soon as the search is over**: this call
/// looks under exec's port lock and lets it go. So the pointer is only as
/// good as the protocol of the program that made the port: one that takes
/// it off the list first and answers what is on it before it goes is one
/// a caller may find and then send to.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no. It takes exec's port lock for the search.
/// - Locks: takes exec's port lock for the search. The port may be removed the
///   moment it is let go: the protocol of the program that made it is what
///   keeps it there.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AddPort`, `PutMsg`, `FindName`
///
/// EXAMPLES:
/// ```zig
/// // The server that made "my.port" keeps it there while it runs.
/// const port = sys.FindPort("my.port") orelse return;
/// sys.PutMsg(port, &msg);
/// ```
pub fn FindPort(base: *ExecBase, name: [*:0]const u8) ?*MsgPort {
    const sys = base.iface();
    sys.AcquireLock(&base.lock_ports);
    defer sys.ReleaseLock(&base.lock_ports);
    const node = sys.FindName(&base.port_list, name) orelse return null;
    return @fieldParentPtr("node", node);
}
