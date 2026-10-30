// SPDX-License-Identifier: MIT
//! DeleteCxObj: one object off its list and freed.

const sdk = @import("sdk");
const cx = sdk.commodities;
const _base = @import("../commodities_base.zig");
const _object = @import("_object.zig");
const CxBase = _base.CxBase;

/// Takes an object off its list and frees it.
///
/// SYNOPSIS:
/// ```zig
/// fn DeleteCxObj(base: *CxBase, co: ?*cx.CxObj) void
/// ```
///
/// SINCE: 1.0. LVO -32.
///
/// INPUTS:
/// - `co` - the object; null does nothing.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// The object is taken off whatever list it is on (RemoveCxObj) and
/// freed. What is attached to it is not: those objects are on no list in
/// the network any more, and are the caller's to delete. A broker's going
/// is told to the controller, and the last broker's takes the library's
/// handler off input.device's chain.
///
/// CONTEXT:
/// - Waits: for the network's lock, and for input.device when it was the
///   last broker.
/// - Interrupts: no.
/// - Locks: takes the network's lock.
/// - Process: a Task will do; never a custom object's function.
///
/// OWNERSHIP:
/// The object is gone.
///
/// NOTES:
/// A whole tree goes with DeleteCxObjAll.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `DeleteCxObjAll`, `RemoveCxObj`
///
/// EXAMPLES:
/// ```zig
/// cb.DeleteCxObj(old_filter);
/// ```
pub fn DeleteCxObj(base: *CxBase, co: ?*cx.CxObj) void {
    const handle = co orelse return;
    base.iface().RemoveCxObj(handle);
    _object.free(base, _base.objectOf(handle));
}
