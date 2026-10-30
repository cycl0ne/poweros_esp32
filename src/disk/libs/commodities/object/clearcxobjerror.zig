// SPDX-License-Identifier: MIT
//! ClearCxObjError: an object's recorded errors forgotten.

const sdk = @import("sdk");
const cx = sdk.commodities;
const _base = @import("../commodities_base.zig");
const CxBase = _base.CxBase;

/// Forgets the errors an object has recorded.
///
/// SYNOPSIS:
/// ```zig
/// fn ClearCxObjError(base: *CxBase, co: ?*cx.CxObj) void
/// ```
///
/// SINCE: 1.0. LVO -48.
///
/// INPUTS:
/// - `co` - the object; null does nothing.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// CxObjError answers 0 afterwards. Nothing about the object changes
/// otherwise: a filter whose condition made no sense still matches
/// nothing.
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
/// A filter is put right with a new condition (SetFilter), which clears
/// COERR_BADFILTER itself.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CxObjError`
///
/// EXAMPLES:
/// ```zig
/// cb.ClearCxObjError(broker);
/// ```
pub fn ClearCxObjError(base: *CxBase, co: ?*cx.CxObj) void {
    const object = _base.objectOf(co orelse return);
    const sys = base.sys_base;
    sys.ObtainSemaphore(&base.lock);
    object.err = 0;
    sys.ReleaseSemaphore(&base.lock);
}
