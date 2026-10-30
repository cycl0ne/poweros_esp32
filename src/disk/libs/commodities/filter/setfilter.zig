// SPDX-License-Identifier: MIT
//! SetFilter: a filter's condition, as a description.

const sdk = @import("sdk");
const cx = sdk.commodities;
const _base = @import("../commodities_base.zig");
const CxBase = _base.CxBase;

/// Sets a filter's condition from a description.
///
/// SYNOPSIS:
/// ```zig
/// fn SetFilter(base: *CxBase, filter: ?*cx.CxObj, text: ?[*:0]const u8) void
/// ```
///
/// SINCE: 1.0. LVO -76.
///
/// INPUTS:
/// - `filter` - a filter; null does nothing.
/// - `text` - the description, as ParseIX reads it.
///
/// RESULT:
/// None. COERR_BADFILTER is set in the filter when the description makes
/// no sense or is null, and cleared when it does; COERR_BADTYPE is
/// recorded in an object that is not a filter.
///
/// BEHAVIOR:
/// From the next event on, the filter passes down its list the events
/// that meet the description. While COERR_BADFILTER is set it passes
/// none: every event goes on to the object after it.
///
/// CONTEXT:
/// - Waits: for the network's lock.
/// - Interrupts: no.
/// - Locks: takes the network's lock.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The description is read during the call and not kept.
///
/// NOTES:
/// It is how a program takes a new hotkey from its user while running.
/// To stop a filter for a while, turn it off (ActivateCxObj).
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ParseIX`, `SetFilterIX`, `CxObjError`
///
/// EXAMPLES:
/// ```zig
/// cb.SetFilter(filter, new_key);
/// if (cb.CxObjError(filter) & cx.COERR_BADFILTER != 0) cb.SetFilter(filter, old_key);
/// ```
pub fn SetFilter(base: *CxBase, filter: ?*cx.CxObj, text: ?[*:0]const u8) void {
    const object = _base.objectOf(filter orelse return);
    const sys = base.sys_base;
    sys.ObtainSemaphore(&base.lock);
    defer sys.ReleaseSemaphore(&base.lock);
    if (object.kind != cx.CX_FILTER) {
        object.err |= cx.COERR_BADTYPE;
        return;
    }
    if (text == null or base.iface().ParseIX(text, &object.data.filter) != 0) {
        object.err |= cx.COERR_BADFILTER;
    } else {
        object.err &= ~cx.COERR_BADFILTER;
    }
}
