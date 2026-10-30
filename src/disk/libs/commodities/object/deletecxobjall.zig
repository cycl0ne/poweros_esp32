// SPDX-License-Identifier: MIT
//! DeleteCxObjAll: an object and everything attached to it, freed.

const sdk = @import("sdk");
const cx = sdk.commodities;
const _base = @import("../commodities_base.zig");
const _object = @import("_object.zig");
const CxBase = _base.CxBase;

/// Takes an object off its list and frees it with everything attached to
/// it, and everything attached to those.
///
/// SYNOPSIS:
/// ```zig
/// fn DeleteCxObjAll(base: *CxBase, co: ?*cx.CxObj) void
/// ```
///
/// SINCE: 1.0. LVO -36.
///
/// INPUTS:
/// - `co` - the top of the tree; null does nothing.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// The object is taken off its list (RemoveCxObj), which takes its whole
/// tree out of the network at once; then every object in it is freed. A
/// broker's going is told to the controller, and the last broker's takes
/// the library's handler off input.device's chain.
///
/// CONTEXT:
/// - Waits: for the network's lock, and for input.device when it was the
///   last broker.
/// - Interrupts: no.
/// - Locks: takes the network's lock.
/// - Process: a Task will do; never a custom object's function.
///
/// OWNERSHIP:
/// Every object of the tree is gone. Translators' events and senders'
/// ports stay the caller's; messages a sender sent are still to be
/// replied to.
///
/// NOTES:
/// A program's broker deleted this way is all a program has to undo in
/// the library before it ends, besides replying to its messages.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `DeleteCxObj`, `CxBroker`
///
/// EXAMPLES:
/// ```zig
/// cb.DeleteCxObjAll(broker);
/// while (sys.GetMsg(port)) |msg| sys.ReplyMsg(msg);
/// ```
pub fn DeleteCxObjAll(base: *CxBase, co: ?*cx.CxObj) void {
    const handle = co orelse return;
    base.iface().RemoveCxObj(handle);
    const object = _base.objectOf(handle);
    _object.freeTree(base, &object.list);
    _object.free(base, object);
}
