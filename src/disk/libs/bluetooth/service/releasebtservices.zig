// SPDX-License-Identifier: MIT
//! ReleaseBTServices: a list of services given back.

const sdk = @import("sdk");
const exec = sdk.exec;
const BluetoothBase = @import("../bluetooth_base.zig").BluetoothBase;

/// Gives back a list from ObtainBTServices.
///
/// SYNOPSIS:
/// ```zig
/// fn ReleaseBTServices(base: *BluetoothBase, list: ?*exec.List) void
/// ```
///
/// SINCE: 1.7. LVO -128.
///
/// INPUTS:
/// - `list` - from ObtainBTServices; null does nothing.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// The list, its nodes, their names and records are freed.
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
/// `ObtainBTServices`
///
/// EXAMPLES:
/// ```zig
/// bt.ReleaseBTServices(services);
/// ```
pub fn ReleaseBTServices(base: *BluetoothBase, list: ?*exec.List) void {
    base.sys_base.FreeVec(list orelse return);
}
