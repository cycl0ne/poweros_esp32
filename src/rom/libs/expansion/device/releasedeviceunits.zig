// SPDX-License-Identifier: MPL-2.0
//! ReleaseDeviceUnits: a list ObtainDeviceUnits answered, given back.

const sdk = @import("sdk");
const exec = sdk.exec;
const ExpansionBase = @import("../expansion_base.zig").ExpansionBase;

/// The list ObtainDeviceUnits answered, and every node on it, freed.
///
/// SYNOPSIS:
/// ```zig
/// fn ReleaseDeviceUnits(eb: *ExpansionBase, list: ?*exec.List) void
/// ```
///
/// SINCE: 1.2. LVO -44.
///
/// INPUTS:
/// - `list` - what ObtainDeviceUnits answered; null does nothing.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// Each node is freed, then the list. The names and labels the nodes
/// pointed at go with them.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none taken.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The list and its nodes are gone; nothing read from them may be used
/// after.
///
/// NOTES:
/// A node taken off the list by the caller is the caller's to FreeVec.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ObtainDeviceUnits`
///
/// EXAMPLES:
/// ```zig
/// const list = eb.ObtainDeviceUnits(devices.DEVIF_BLOCK, null) orelse return;
/// defer eb.ReleaseDeviceUnits(list);
/// ```
pub fn ReleaseDeviceUnits(eb: *ExpansionBase, list: ?*exec.List) void {
    const sys = eb.sys_base;
    const kept = list orelse return;
    while (sys.RemHead(kept)) |node| sys.FreeVec(node);
    sys.FreeVec(kept);
}
