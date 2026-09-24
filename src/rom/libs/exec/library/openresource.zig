// SPDX-License-Identifier: MPL-2.0
//! OpenResource: a resource by name. Nothing is counted and nothing is
//! owed back - there is no CloseResource.

const ExecBase = @import("../exec.zig").ExecBase;

/// Finds a resource by name.
///
/// SYNOPSIS:
/// ```zig
/// fn OpenResource(base: *ExecBase, res_name: [*:0]const u8) ?*anyopaque
/// ```
///
/// SINCE: 1.0. LVO -396.
///
/// INPUTS:
/// - `res_name` - the resource's name, matched exactly.
///
/// RESULT:
/// The resource, or null if there is none of that name - which for a
/// resource that only exists on some boards is the ordinary answer and not
/// an error.
///
/// BEHAVIOR:
/// It is called "open" for the shape of the thing, but **nothing is
/// counted and there is no close**. The pointer is good for as long as the
/// machine is running.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no. It takes Forbid.
/// - Forbid: taken here, around the search.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated and nothing is owed.
///
/// NOTES:
/// A resource is how a program reaches a fact of the machine it cannot
/// import: platform.resource holds the chip's, expander.resource a pin
/// that is not the chip's own. What is soldered on the board comes from
/// expansion.library.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AddResource`, `OpenLibrary`
///
/// EXAMPLES:
/// ```zig
/// const pb = sys.OpenResource("platform.resource") orelse return;
/// ```
pub fn OpenResource(base: *ExecBase, res_name: [*:0]const u8) ?*anyopaque {
    const sys = base.iface();
    sys.Forbid();
    defer sys.Permit();
    return sys.FindName(&base.resource_list, res_name);
}
