// SPDX-License-Identifier: MIT
//! ReleaseBTConnections: a list of links given back.

const sdk = @import("sdk");
const exec = sdk.exec;
const BluetoothBase = @import("../bluetooth_base.zig").BluetoothBase;

/// Gives back what ObtainBTConnections answered.
///
/// SYNOPSIS:
/// ```zig
/// fn ReleaseBTConnections(base: *BluetoothBase, list: ?*exec.List) void
/// ```
///
/// SINCE: 1.3. LVO -76.
///
/// INPUTS:
/// - `list` - from ObtainBTConnections; null does nothing.
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
/// `ObtainBTConnections`
///
/// EXAMPLES:
/// ```zig
/// bt.ReleaseBTConnections(list);
/// ```
pub fn ReleaseBTConnections(base: *BluetoothBase, list: ?*exec.List) void {
    base.sys_base.FreeVec(list orelse return);
}
