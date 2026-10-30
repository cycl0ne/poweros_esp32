// SPDX-License-Identifier: MIT
//! CxObjError: the errors an object has recorded.

const sdk = @import("sdk");
const cx = sdk.commodities;
const _base = @import("../commodities_base.zig");
const CxBase = _base.CxBase;

/// Answers the errors an object has recorded.
///
/// SYNOPSIS:
/// ```zig
/// fn CxObjError(base: *CxBase, co: ?*cx.CxObj) u32
/// ```
///
/// SINCE: 1.0. LVO -44.
///
/// INPUTS:
/// - `co` - the object, or null.
///
/// RESULT:
/// COERR_ bits, 0 for none; COERR_ISNULL for null - the object was never
/// made.
///
/// BEHAVIOR:
/// A call that fails on an object records why in it rather than
/// answering: COERR_NULLATTACH when a null object was attached to it,
/// COERR_BADFILTER while its condition makes no sense, COERR_BADTYPE when
/// a call for another kind was made on it. The bits stay until
/// ClearCxObjError, except COERR_BADFILTER, which the next condition that
/// makes sense clears. So a tree is built without a check after every
/// call, and checked once at the end.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing changes hands.
///
/// NOTES:
/// A bad description in a filter attached to a broker is the filter's
/// error, not the broker's: look at the filter.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ClearCxObjError`, `AttachCxObj`, `SetFilter`
///
/// EXAMPLES:
/// ```zig
/// const filter = cx.HotKey(cb, description, port, 1) orelse return;
/// if (cb.CxObjError(filter) & cx.COERR_BADFILTER != 0) return badHotkey(description);
/// ```
pub fn CxObjError(_: *CxBase, co: ?*cx.CxObj) u32 {
    return _base.objectOf(co orelse return cx.COERR_ISNULL).err;
}
