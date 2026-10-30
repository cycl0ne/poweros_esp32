// SPDX-License-Identifier: MIT
//! InsertCxObj: an object into another's list after a given one.

const sdk = @import("sdk");
const cx = sdk.commodities;
const _base = @import("../commodities_base.zig");
const _attach = @import("_attach.zig");
const CxBase = _base.CxBase;

/// Puts an object into another object's list after a given one.
///
/// SYNOPSIS:
/// ```zig
/// fn InsertCxObj(base: *CxBase, head_obj: ?*cx.CxObj, co: ?*cx.CxObj, pred: ?*cx.CxObj) void
/// ```
///
/// SINCE: 1.0. LVO -64.
///
/// INPUTS:
/// - `head_obj` - the object whose list it joins; null deletes `co` and
///   everything attached to it.
/// - `co` - the object; null is recorded in `head_obj` as
///   COERR_NULLATTACH.
/// - `pred` - the object on that list it goes after; null puts it first.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// As AttachCxObj, at the place given.
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
/// `pred` must be on `head_obj`'s list.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AttachCxObj`, `EnqueueCxObj`
///
/// EXAMPLES:
/// ```zig
/// cb.InsertCxObj(broker, debug, null); // sees every event first
/// ```
pub fn InsertCxObj(base: *CxBase, head_obj: ?*cx.CxObj, co: ?*cx.CxObj, pred: ?*cx.CxObj) void {
    const after: ?*sdk.exec.Node = if (pred) |p| &_base.objectOf(p).node else null;
    _attach.attach(base, head_obj, co, .{ .after = after });
}
