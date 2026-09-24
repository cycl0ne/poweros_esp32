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
/// **The port may go away as soon as Forbid is let go**, and this call
/// takes and releases Forbid itself. So the pointer is only trustworthy
/// while the caller holds Forbid *across* both this and the `PutMsg` that
/// follows - which is the usual shape and the reason the two are almost
/// always written together.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no. It takes Forbid.
/// - Forbid: taken here for the search, and needed by the caller around
///   the call and the send.
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
/// sys.Forbid();
/// defer sys.Permit();
/// const port = sys.FindPort("my.port") orelse return;
/// sys.PutMsg(port, &msg);
/// ```
pub fn FindPort(base: *ExecBase, name: [*:0]const u8) ?*MsgPort {
    const sys = base.iface();
    sys.Forbid();
    defer sys.Permit();
    const node = sys.FindName(&base.port_list, name) orelse return null;
    return @fieldParentPtr("node", node);
}
