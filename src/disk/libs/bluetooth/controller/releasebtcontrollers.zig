// SPDX-License-Identifier: MIT
//! ReleaseBTControllers: a list of controllers given back.

const sdk = @import("sdk");
const exec = sdk.exec;
const BluetoothBase = @import("../bluetooth_base.zig").BluetoothBase;

/// Gives back what ObtainBTControllers answered.
///
/// SYNOPSIS:
/// ```zig
/// fn ReleaseBTControllers(base: *BluetoothBase, list: ?*exec.List) void
/// ```
///
/// SINCE: 1.0. LVO -32.
///
/// INPUTS:
/// - `list` - from ObtainBTControllers; null does nothing.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// The list and every node on it are freed in one.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The list is gone, and so is every node and string it held.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ObtainBTControllers`
///
/// EXAMPLES:
/// ```zig
/// bt.ReleaseBTControllers(list);
/// ```
pub fn ReleaseBTControllers(base: *BluetoothBase, list: ?*exec.List) void {
    base.sys_base.FreeVec(list orelse return);
}
