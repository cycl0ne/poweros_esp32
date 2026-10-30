// SPDX-License-Identifier: MIT
//! RouteCxMsg: where a commodity message goes next.

const sdk = @import("sdk");
const cx = sdk.commodities;
const _base = @import("../commodities_base.zig");
const CxBase = _base.CxBase;

/// Sets the object a commodity message goes to next.
///
/// SYNOPSIS:
/// ```zig
/// fn RouteCxMsg(base: *CxBase, cxm: *cx.CxMsg, co: *cx.CxObj) void
/// ```
///
/// SINCE: 1.0. LVO -104.
///
/// INPUTS:
/// - `cxm` - the message a custom object's function was given.
/// - `co` - the object it goes to; it must be in the network.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// A jump: the message goes on from `co`, through the objects after it,
/// and its stack of objects to come back to stays as it was.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none taken; the network's lock is held by the handler that
///   called the custom object's function.
/// - Process: a custom object's function, on input.device's task.
///
/// OWNERSHIP:
/// Nothing changes hands.
///
/// NOTES:
/// A message routed round in a circle leaves the network after it has
/// been through 1024 objects.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `DivertCxMsg`, `CxCustom`
///
/// EXAMPLES:
/// ```zig
/// cb.RouteCxMsg(cxm, other_filter);
/// ```
pub fn RouteCxMsg(_: *CxBase, cxm: *cx.CxMsg, co: *cx.CxObj) void {
    _base.messageOf(cxm).destination = &_base.objectOf(co).node;
}
