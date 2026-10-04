// SPDX-License-Identifier: MIT
//! GoodType: whether four characters may name a kind of form.

const sdk = @import("sdk");
const _base = @import("../iffparse_base.zig");
const _parse = @import("../parse/_parse.zig");
const IFFParseBase = _base.IFFParseBase;

/// Says whether four characters may name a kind of form.
///
/// SYNOPSIS:
/// ```zig
/// fn GoodType(ib: *IFFParseBase, form_type: u32) bool
/// ```
///
/// SINCE: 1.0. LVO -172.
///
/// INPUTS:
/// - `form_type` - four characters as a number.
///
/// RESULT:
/// True when it is a good id and holds only upper case letters, digits
/// and spaces.
///
/// BEHAVIOR:
/// The type of a `FORM`, a `LIST` or a `CAT ` names a kind of thing -
/// `ILBM`, `FTXT`, `8SVX` - and the rule is tighter than for a chunk id
/// so that a type and a chunk name are told apart on sight.
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
/// Lower case is what marks a chunk that a program made up for itself,
/// which is why a type may not have any.
///
/// SEE ALSO:
/// `GoodID`, `PushChunk`
///
/// EXAMPLES:
/// ```zig
/// if (!ip.GoodType(kind)) return error.NotAFormKind;
/// ```
pub fn GoodType(ib: *IFFParseBase, form_type: u32) bool {
    _ = ib;
    return _parse.goodType(form_type);
}
