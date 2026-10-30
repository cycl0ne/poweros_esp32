// SPDX-License-Identifier: MIT
//! SetFilterIX: a filter's condition, as an input expression.

const sdk = @import("sdk");
const cx = sdk.commodities;
const _base = @import("../commodities_base.zig");
const CxBase = _base.CxBase;

/// Sets a filter's condition from an input expression.
///
/// SYNOPSIS:
/// ```zig
/// fn SetFilterIX(base: *CxBase, filter: ?*cx.CxObj, ix: *const cx.InputXpression) void
/// ```
///
/// SINCE: 1.0. LVO -80.
///
/// INPUTS:
/// - `filter` - a filter; null does nothing.
/// - `ix` - the expression; its `version` must be IX_VERSION.
///
/// RESULT:
/// None. COERR_BADFILTER is set in the filter for an expression of
/// another version, and cleared otherwise; COERR_BADTYPE is recorded in
/// an object that is not a filter.
///
/// BEHAVIOR:
/// The expression is copied into the filter, which from the next event
/// on passes down its list the events that meet it (MatchIX). An
/// expression of another version is not copied, and the filter passes
/// nothing until it gets one it can use.
///
/// CONTEXT:
/// - Waits: for the network's lock.
/// - Interrupts: no.
/// - Locks: takes the network's lock.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The expression stays the caller's; the filter has its own copy.
///
/// NOTES:
/// For conditions no description can say: a code mask over several
/// keys, an event class with a code.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `SetFilter`, `ParseIX`, `MatchIX`
///
/// EXAMPLES:
/// ```zig
/// // F1 to F8 going down, nothing held: the codes 0x50 to 0x57.
/// cb.SetFilterIX(filter, &.{ .code = kbd.RAWKEY_F1, .code_mask = 0xF8 });
/// ```
pub fn SetFilterIX(base: *CxBase, filter: ?*cx.CxObj, ix: *const cx.InputXpression) void {
    const object = _base.objectOf(filter orelse return);
    const sys = base.sys_base;
    sys.ObtainSemaphore(&base.lock);
    defer sys.ReleaseSemaphore(&base.lock);
    if (object.kind != cx.CX_FILTER) {
        object.err |= cx.COERR_BADTYPE;
    } else if (ix.version != cx.IX_VERSION) {
        object.err |= cx.COERR_BADFILTER;
    } else {
        object.data.filter = ix.*;
        object.err &= ~cx.COERR_BADFILTER;
    }
}
