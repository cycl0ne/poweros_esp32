// SPDX-License-Identifier: MIT
//! CxObjType: what kind of object an object is.

const sdk = @import("sdk");
const cx = sdk.commodities;
const _base = @import("../commodities_base.zig");
const CxBase = _base.CxBase;

/// Says what kind of object an object is.
///
/// SYNOPSIS:
/// ```zig
/// fn CxObjType(base: *CxBase, co: ?*cx.CxObj) u32
/// ```
///
/// SINCE: 1.0. LVO -40.
///
/// INPUTS:
/// - `co` - the object, or null.
///
/// RESULT:
/// CX_FILTER ... CX_CUSTOM; CX_INVALID for null.
///
/// BEHAVIOR:
/// The kind it was made as; it never changes.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do; a custom object's function may call it.
///
/// OWNERSHIP:
/// Nothing changes hands.
///
/// NOTES:
/// A program knows what it made; this is for code handed an object.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CreateCxObj`
///
/// EXAMPLES:
/// ```zig
/// if (cb.CxObjType(co) == cx.CX_FILTER) cb.SetFilter(co, "ctrl alt x");
/// ```
pub fn CxObjType(_: *CxBase, co: ?*cx.CxObj) u32 {
    return _base.objectOf(co orelse return cx.CX_INVALID).kind;
}
