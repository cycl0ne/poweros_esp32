// SPDX-License-Identifier: MIT
//! MatchIX: whether an event meets an input expression.

const sdk = @import("sdk");
const cx = sdk.commodities;
const ie = sdk.devices.inputevent;
const _base = @import("../commodities_base.zig");
const CxBase = _base.CxBase;

/// `qualifier` with the whole of `mask` when any of it is there.
fn widened(qualifier: u32, mask: u32) u32 {
    return if (qualifier & mask != 0) qualifier | mask else qualifier;
}

/// Says whether an event meets an input expression.
///
/// SYNOPSIS:
/// ```zig
/// fn MatchIX(base: *CxBase, event: *const ie.InputEvent, ix: *const cx.InputXpression) bool
/// ```
///
/// SINCE: 1.0. LVO -132.
///
/// INPUTS:
/// - `event` - the event.
/// - `ix` - the expression.
///
/// RESULT:
/// Whether it matches.
///
/// BEHAVIOR:
/// An expression of class IECLASS_NULL matches every event. Otherwise
/// the event's class is the expression's, its code has the expression's
/// bits wherever `code_mask` has a bit, and its qualifiers have the
/// expression's wherever `qual_mask` has one - the event's qualifiers
/// widened first by `qual_same`: with IXSYM_SHIFT either shift held is
/// both, with IXSYM_CAPS either shift or Caps Lock is all three, with
/// IXSYM_ALT either alt is both. It is the test every filter makes.
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
/// A custom object's function uses it to test an event against several
/// expressions without a filter for each.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ParseIX`, `SetFilterIX`
///
/// EXAMPLES:
/// ```zig
/// if (cb.MatchIX(event, &hotkey)) cb.DisposeCxMsg(cxm);
/// ```
pub fn MatchIX(_: *CxBase, event: *const ie.InputEvent, ix: *const cx.InputXpression) bool {
    if (ix.class == ie.IECLASS_NULL) return true;
    if (event.class != ix.class) return false;
    if ((event.code ^ ix.code) & ix.code_mask != 0) return false;
    var qualifier = event.qualifier;
    if (ix.qual_same & cx.IXSYM_SHIFT != 0) qualifier = widened(qualifier, cx.IXSYM_SHIFTMASK);
    if (ix.qual_same & cx.IXSYM_CAPS != 0) qualifier = widened(qualifier, cx.IXSYM_CAPSMASK);
    if (ix.qual_same & cx.IXSYM_ALT != 0) qualifier = widened(qualifier, cx.IXSYM_ALTMASK);
    return (qualifier ^ ix.qualifier) & ix.qual_mask == 0;
}
