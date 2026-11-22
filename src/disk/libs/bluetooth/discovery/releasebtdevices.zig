// SPDX-License-Identifier: MIT
//! ReleaseBTDevices: a list of found devices given back.

const sdk = @import("sdk");
const exec = sdk.exec;
const BluetoothBase = @import("../bluetooth_base.zig").BluetoothBase;

/// Gives back what ObtainBTDevices answered.
///
/// SYNOPSIS:
/// ```zig
/// fn ReleaseBTDevices(base: *BluetoothBase, list: ?*exec.List) void
/// ```
///
/// SINCE: 1.2. LVO -60.
///
/// INPUTS:
/// - `list` - from ObtainBTDevices; null does nothing.
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
/// The list is gone, and so is every node and name it held.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ObtainBTDevices`
///
/// EXAMPLES:
/// ```zig
/// bt.ReleaseBTDevices(list);
/// ```
pub fn ReleaseBTDevices(base: *BluetoothBase, list: ?*exec.List) void {
    base.sys_base.FreeVec(list orelse return);
}
