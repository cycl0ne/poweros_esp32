// SPDX-License-Identifier: MIT
//! ReleaseBTBonds: a list of bonds given back.

const sdk = @import("sdk");
const exec = sdk.exec;
const BluetoothBase = @import("../bluetooth_base.zig").BluetoothBase;

/// Gives back a list from ObtainBTBonds.
///
/// SYNOPSIS:
/// ```zig
/// fn ReleaseBTBonds(base: *BluetoothBase, list: ?*exec.List) void
/// ```
///
/// SINCE: 1.4. LVO -100.
///
/// INPUTS:
/// - `list` - from ObtainBTBonds; null does nothing.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// The list and its nodes are freed.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The list is gone.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ObtainBTBonds`
///
/// EXAMPLES:
/// ```zig
/// bt.ReleaseBTBonds(list);
/// ```
pub fn ReleaseBTBonds(base: *BluetoothBase, list: ?*exec.List) void {
    base.sys_base.FreeVec(list orelse return);
}
