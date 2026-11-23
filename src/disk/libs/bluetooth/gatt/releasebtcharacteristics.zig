// SPDX-License-Identifier: MIT
//! ReleaseBTCharacteristics: a list from ObtainBTCharacteristics given
//! back.

const sdk = @import("sdk");
const exec = sdk.exec;
const BluetoothBase = @import("../bluetooth_base.zig").BluetoothBase;

/// Gives back a list from ObtainBTCharacteristics.
///
/// SYNOPSIS:
/// ```zig
/// fn ReleaseBTCharacteristics(base: *BluetoothBase, list: ?*exec.List) void
/// ```
///
/// SINCE: 1.8. LVO -144.
///
/// INPUTS:
/// - `list` - from ObtainBTCharacteristics; null does nothing.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// The list, its nodes and their descriptors are freed.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The list is gone. A subscription to one of its characteristics is
/// not: it lasts until UnsubscribeBTAttribute or CloseBTGatt.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ObtainBTCharacteristics`
///
/// EXAMPLES:
/// ```zig
/// bt.ReleaseBTCharacteristics(characteristics);
/// ```
pub fn ReleaseBTCharacteristics(base: *BluetoothBase, list: ?*exec.List) void {
    base.sys_base.FreeVec(list orelse return);
}
