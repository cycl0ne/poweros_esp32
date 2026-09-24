// SPDX-License-Identifier: MPL-2.0
//! RemResource: takes a resource off exec's resource list, so
//! `OpenResource` no longer finds it. There is no open count to consult:
//! a resource is not opened and closed, only found.

const ExecBase = @import("../exec.zig").ExecBase;

/// Takes a resource off the resource list.
///
/// SYNOPSIS:
/// ```zig
/// fn RemResource(base: *ExecBase, resource: *anyopaque) void
/// ```
///
/// SINCE: 1.0. LVO -392.
///
/// INPUTS:
/// - `resource` - one that was added.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// Nothing new can find it. **Whoever already has the pointer still has
/// it**, and since a resource is never closed there is no count to say who
/// that is - so removing one is only safe when the caller knows by other
/// means that nobody is using it.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no. It takes Forbid.
/// - Forbid: taken here, around the list.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AddResource`, `OpenResource`
///
/// EXAMPLES:
/// ```zig
/// sys.RemResource(base);
/// ```
pub fn RemResource(base: *ExecBase, resource: *anyopaque) void {
    const sys = base.iface();
    sys.Forbid();
    defer sys.Permit();
    sys.Remove(@ptrCast(@alignCast(resource)));
}
