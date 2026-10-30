// SPDX-License-Identifier: MIT
//! EnqueueCxObj: an object into another's list by its priority.

const sdk = @import("sdk");
const cx = sdk.commodities;
const _base = @import("../commodities_base.zig");
const _attach = @import("_attach.zig");
const CxBase = _base.CxBase;

/// Puts an object into another object's list by its priority.
///
/// SYNOPSIS:
/// ```zig
/// fn EnqueueCxObj(base: *CxBase, head_obj: ?*cx.CxObj, co: ?*cx.CxObj) void
/// ```
///
/// SINCE: 1.0. LVO -60.
///
/// INPUTS:
/// - `head_obj` - the object whose list it joins; null deletes `co` and
///   everything attached to it.
/// - `co` - the object; null is recorded in `head_obj` as
///   COERR_NULLATTACH.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// The list is kept highest priority first; `co` goes before the first
/// object of a lower priority, so objects of one priority stay in the
/// order they came. The priority is SetCxObjPri's, 0 for an object never
/// given one. Otherwise as AttachCxObj.
///
/// CONTEXT:
/// - Waits: for the network's lock.
/// - Interrupts: no.
/// - Locks: takes the network's lock.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// `co` stays the caller's; DeleteCxObjAll of anything above it deletes
/// it too.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `SetCxObjPri`, `AttachCxObj`, `InsertCxObj`
///
/// EXAMPLES:
/// ```zig
/// _ = cb.SetCxObjPri(first_look, 10);
/// cb.EnqueueCxObj(broker, first_look);
/// ```
pub fn EnqueueCxObj(base: *CxBase, head_obj: ?*cx.CxObj, co: ?*cx.CxObj) void {
    _attach.attach(base, head_obj, co, .priority);
}
