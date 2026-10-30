// SPDX-License-Identifier: MIT
//! AttachCxObj: an object at the end of another's list.

const sdk = @import("sdk");
const cx = sdk.commodities;
const _base = @import("../commodities_base.zig");
const _attach = @import("_attach.zig");
const CxBase = _base.CxBase;

/// Puts an object at the end of another object's list.
///
/// SYNOPSIS:
/// ```zig
/// fn AttachCxObj(base: *CxBase, head_obj: ?*cx.CxObj, co: ?*cx.CxObj) void
/// ```
///
/// SINCE: 1.0. LVO -56.
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
/// `co` goes last on `head_obj`'s list: a message diverted into
/// `head_obj` reaches it after everything attached before. Taking either
/// side as null lets a tree be built from calls that make objects
/// without checking each: an object that could not be made shows as an
/// error in the one it was to join, and one with nowhere to go is not
/// left behind.
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
/// An object is on one list at a time: take it off one (RemoveCxObj)
/// before attaching it to another.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `EnqueueCxObj`, `InsertCxObj`, `RemoveCxObj`, `CxObjError`
///
/// EXAMPLES:
/// ```zig
/// cb.AttachCxObj(broker, filter);
/// cb.AttachCxObj(filter, cx.CxSender(cb, port, 1));
/// cb.AttachCxObj(filter, cx.CxTranslate(cb, null));
/// if (cb.CxObjError(filter) != 0) return error.NoMemory;
/// ```
pub fn AttachCxObj(base: *CxBase, head_obj: ?*cx.CxObj, co: ?*cx.CxObj) void {
    _attach.attach(base, head_obj, co, .tail);
}
