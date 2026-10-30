// SPDX-License-Identifier: MIT
//! RemoveCxObj: an object off its list.

const sdk = @import("sdk");
const cx = sdk.commodities;
const _base = @import("../commodities_base.zig");
const _input = @import("../input/_input.zig");
const CxBase = _base.CxBase;

/// Takes an object off whatever list it is on.
///
/// SYNOPSIS:
/// ```zig
/// fn RemoveCxObj(base: *CxBase, co: ?*cx.CxObj) void
/// ```
///
/// SINCE: 1.0. LVO -68.
///
/// INPUTS:
/// - `co` - the object; null, or one on no list, does nothing.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// The object leaves its list with everything attached to it, which stays
/// attached: the tree is out of the network as a whole. A broker leaves
/// the network's list; the controller is told (CXCMD_LIST_CHG), and when
/// it was the last, the library's handler comes off input.device's chain
/// and events pass the library by.
///
/// CONTEXT:
/// - Waits: for the network's lock, and for input.device when it was the
///   last broker.
/// - Interrupts: no.
/// - Locks: takes the network's lock.
/// - Process: a Task will do; never a custom object's function.
///
/// OWNERSHIP:
/// The object stays the caller's.
///
/// NOTES:
/// A message on its way through the tree when it goes is not lost: the
/// network's lock keeps the handler out until the tree is off.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AttachCxObj`, `DeleteCxObj`
///
/// EXAMPLES:
/// ```zig
/// cb.RemoveCxObj(filter);
/// cb.SetFilter(filter, new_description);
/// cb.AttachCxObj(broker, filter);
/// ```
pub fn RemoveCxObj(base: *CxBase, co: ?*cx.CxObj) void {
    const object = _base.objectOf(co orelse return);
    const sys = base.sys_base;
    sys.ObtainSemaphore(&base.lock);
    if (object.flags & _base.COF_INLIST == 0) {
        sys.ReleaseSemaphore(&base.lock);
        return;
    }
    sys.Remove(&object.node);
    object.flags &= ~_base.COF_INLIST;
    const none_left = base.brokers.isEmpty();
    sys.ReleaseSemaphore(&base.lock);
    if (object.kind != cx.CX_BROKER) return;
    if (none_left) _input.updateHandler(base) else _ = base.iface().BrokerCommand(null, cx.CXCMD_LIST_CHG);
}
