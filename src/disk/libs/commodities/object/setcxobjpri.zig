// SPDX-License-Identifier: MIT
//! SetCxObjPri: an object's priority.

const sdk = @import("sdk");
const cx = sdk.commodities;
const _base = @import("../commodities_base.zig");
const CxBase = _base.CxBase;

/// Sets an object's priority, which EnqueueCxObj places it by.
///
/// SYNOPSIS:
/// ```zig
/// fn SetCxObjPri(base: *CxBase, co: ?*cx.CxObj, pri: i32) i32
/// ```
///
/// SINCE: 1.0. LVO -52.
///
/// INPUTS:
/// - `co` - the object; null does nothing.
/// - `pri` - -128 to 127, higher first; 0 is the usual. Outside that it
///   is the nearest end.
///
/// RESULT:
/// The priority it had; 0 for null.
///
/// BEHAVIOR:
/// Only the number changes: an object already on a list stays where it
/// is. To move it, take it off (RemoveCxObj), set the priority, and put
/// it back with EnqueueCxObj.
///
/// CONTEXT:
/// - Waits: for the network's lock.
/// - Interrupts: no.
/// - Locks: takes the network's lock.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing changes hands.
///
/// NOTES:
/// A broker's priority comes from its NewBroker; the user is best given
/// a way to set it (a PRI argument).
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `EnqueueCxObj`, `RemoveCxObj`
///
/// EXAMPLES:
/// ```zig
/// cb.RemoveCxObj(filter);
/// _ = cb.SetCxObjPri(filter, 10);
/// cb.EnqueueCxObj(broker, filter);
/// ```
pub fn SetCxObjPri(base: *CxBase, co: ?*cx.CxObj, pri: i32) i32 {
    const object = _base.objectOf(co orelse return 0);
    const sys = base.sys_base;
    sys.ObtainSemaphore(&base.lock);
    const old: i32 = object.node.pri;
    object.node.pri = @intCast(@max(-128, @min(127, pri)));
    sys.ReleaseSemaphore(&base.lock);
    return old;
}
