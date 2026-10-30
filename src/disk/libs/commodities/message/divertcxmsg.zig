// SPDX-License-Identifier: MIT
//! DivertCxMsg: a commodity message down an object's list.

const sdk = @import("sdk");
const cx = sdk.commodities;
const _base = @import("../commodities_base.zig");
const CxBase = _base.CxBase;

/// Sends a commodity message down an object's list, and on from another
/// object once the list is done.
///
/// SYNOPSIS:
/// ```zig
/// fn DivertCxMsg(base: *CxBase, cxm: *cx.CxMsg, head_obj: *cx.CxObj, return_obj: *cx.CxObj) void
/// ```
///
/// SINCE: 1.0. LVO -100.
///
/// INPUTS:
/// - `cxm` - the message a custom object's function was given.
/// - `head_obj` - the object whose list it goes down.
/// - `return_obj` - the object it goes on after when that list is done.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// The message's next object is the first on `head_obj`'s list, and
/// `return_obj` goes on the message's stack: at the end of the list the
/// message goes to the object after `return_obj`. It is what a filter
/// does with an event that matches - `DivertCxMsg(cxm, filter, filter)` -
/// and a broker with every event.
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
/// The stack holds 32 objects; a message diverted deeper than that goes
/// on, at the end of the deepest lists, to where the 32nd would have
/// sent it.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `RouteCxMsg`, `CxCustom`
///
/// EXAMPLES:
/// ```zig
/// // A custom filter: only events with the pointer on the left half.
/// if (event.x < half) cb.DivertCxMsg(cxm, co, co);
/// ```
pub fn DivertCxMsg(_: *CxBase, cxm: *cx.CxMsg, head_obj: *cx.CxObj, return_obj: *cx.CxObj) void {
    const message = _base.messageOf(cxm);
    message.destination = _base.objectOf(head_obj).list.head;
    if (message.stack_index < _base.STACK_SLOTS) {
        message.stack[message.stack_index] = _base.objectOf(return_obj);
        message.stack_index += 1;
    }
}
