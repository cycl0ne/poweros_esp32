// SPDX-License-Identifier: MIT
//! ActivateCxObj: an object turned on or off.

const sdk = @import("sdk");
const cx = sdk.commodities;
const _base = @import("../commodities_base.zig");
const CxBase = _base.CxBase;

/// Turns an object on or off.
///
/// SYNOPSIS:
/// ```zig
/// fn ActivateCxObj(base: *CxBase, co: ?*cx.CxObj, active: bool) bool
/// ```
///
/// SINCE: 1.0. LVO -28.
///
/// INPUTS:
/// - `co` - the object; null does nothing.
/// - `active` - true to turn it on, false off.
///
/// RESULT:
/// Whether it was on; false for null.
///
/// BEHAVIOR:
/// An object that is off does nothing with what reaches it: the message
/// goes on to the object after it. Every object starts on, a broker off -
/// a program builds its tree under the broker and then turns the broker
/// on, so no event meets half a tree. A broker turned on or off is told
/// to the controller (CXCMD_LIST_CHG).
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
/// It is what a program does for CXCMD_DISABLE and CXCMD_ENABLE.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CxBroker`, `BrokerCommand`
///
/// EXAMPLES:
/// ```zig
/// cx.CXCMD_DISABLE => _ = cb.ActivateCxObj(broker, false),
/// cx.CXCMD_ENABLE => _ = cb.ActivateCxObj(broker, true),
/// ```
pub fn ActivateCxObj(base: *CxBase, co: ?*cx.CxObj, active: bool) bool {
    const object = _base.objectOf(co orelse return false);
    const sys = base.sys_base;
    sys.ObtainSemaphore(&base.lock);
    const was = object.flags & _base.COF_ENABLE != 0;
    if (active) object.flags |= _base.COF_ENABLE else object.flags &= ~_base.COF_ENABLE;
    sys.ReleaseSemaphore(&base.lock);
    if (object.kind == cx.CX_BROKER) _ = base.iface().BrokerCommand(null, cx.CXCMD_LIST_CHG);
    return was;
}
