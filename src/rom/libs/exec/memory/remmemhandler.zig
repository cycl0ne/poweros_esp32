// SPDX-License-Identifier: MPL-2.0
//! RemMemHandler: takes a low-memory handler off exec's handler list.

const sdk = @import("sdk");

const ExecBase = @import("../exec.zig").ExecBase;
const Interrupt = sdk.exec.Interrupt;

/// Takes a low-memory handler off the list.
///
/// SYNOPSIS:
/// ```zig
/// fn RemMemHandler(base: *ExecBase, handler: *Interrupt) void
/// ```
///
/// SINCE: 1.0. LVO -124.
///
/// INPUTS:
/// - `handler` - one that was added with `AddMemHandler`.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// It comes off the list and is not asked again.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no. It takes Forbid.
/// - Forbid: taken here, around the list.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated. The `Interrupt` is the caller's again and may be
/// freed.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AddMemHandler`
///
/// EXAMPLES:
/// ```zig
/// sys.RemMemHandler(&handler);
/// ```
pub fn RemMemHandler(base: *ExecBase, handler: *Interrupt) void {
    const sys = base.iface();
    sys.Forbid();
    defer sys.Permit();
    sys.Remove(&handler.node);
}
