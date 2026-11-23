// SPDX-License-Identifier: MIT
//! CloseHID: a function given back.

const sdk = @import("sdk");
const hid = sdk.hid;
const HIDBase = @import("../hid_base.zig").HIDBase;
const _function = @import("_function.zig");

/// Gives a function back: its sources let go of whatever keys and
/// buttons the device still held, and are closed.
///
/// SYNOPSIS:
/// ```zig
/// fn CloseHID(base: *HIDBase, function: ?*hid.HIDFunction) void
/// ```
///
/// SINCE: 1.0. LVO -24.
///
/// INPUTS:
/// - `function` - OpenHID's, or null.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// keyboard.device and mouse.device are closed for the function, each
/// letting go of what its source held down, so no key stays pressed and
/// no button held for a device that has gone. A port the function made
/// for itself is deleted. Null does nothing.
///
/// CONTEXT:
/// - Waits: yes, while the sources close.
/// - Interrupts: no.
/// - Locks: none may be held.
/// - Process: a Task will do: the one the function's reply port belongs
///   to.
///
/// OWNERSHIP:
/// The function is gone once the call returns.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `OpenHID`, `HIDInput`
///
/// EXAMPLES:
/// ```zig
/// hb.CloseHID(function);
/// ```
pub fn CloseHID(base: *HIDBase, function: ?*hid.HIDFunction) void {
    const public = function orelse return;
    _function.release(base, _function.functionOf(public));
}
