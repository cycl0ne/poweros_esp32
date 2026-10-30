// SPDX-License-Identifier: MIT
//! AddIEvents: events of the caller's into the network.

const sdk = @import("sdk");
const exec = sdk.exec;
const cx = sdk.commodities;
const ie = sdk.devices.inputevent;
const _base = @import("../commodities_base.zig");
const _message = @import("../message/_message.zig");
const _input = @import("_input.zig");
const CxBase = _base.CxBase;

/// Puts copies of events into the network, as though a device had made
/// them.
///
/// SYNOPSIS:
/// ```zig
/// fn AddIEvents(base: *CxBase, events: ?*const ie.InputEvent) void
/// ```
///
/// SINCE: 1.0. LVO -116.
///
/// INPUTS:
/// - `events` - a list linked by `next`; null does nothing.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// Each event is copied into a message, in the list's order. The
/// messages go to the first broker in the handler's next round - the
/// next event from a device, or the tick, a tenth of a second at most -
/// ahead of that round's own events, and through the whole network as
/// those do. Called from a custom object's function they join the round
/// that is under way, behind the messages already in it. Memory running
/// out ends the copying where it is.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: takes the library's queue spinlock for a moment.
/// - Process: a Task will do; a custom object's function may call it.
///
/// OWNERSHIP:
/// The events stay the caller's, and may go as soon as the call is back.
///
/// NOTES:
/// With no broker the library has no handler on input.device's chain,
/// and the events wait for the first one: IND_WRITEEVENT to input.device
/// is the way in then.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `InvertString`, `InvertKeyMap`
///
/// EXAMPLES:
/// ```zig
/// const typed = cx.InvertString(sys, cb, "hello\n", null) orelse return;
/// defer cx.FreeIEvents(sys, typed);
/// cb.AddIEvents(typed);
/// ```
pub fn AddIEvents(base: *CxBase, events: ?*const ie.InputEvent) void {
    const sys = base.sys_base;
    var made: exec.List = .{};
    made.init(.message);
    var event = events;
    while (event) |e| : (event = e.next) {
        const message = _message.create(base, cx.CXM_IEVENT, e) orelse break;
        sys.AddTail(&made, &message.msg.node);
    }
    if (_input.inWalk(base)) {
        while (sys.RemHead(&made)) |node| {
            _message.routeToFirstBroker(base, @ptrCast(@alignCast(node)));
            sys.AddTail(&base.routing, node);
        }
        return;
    }
    sys.AcquireLock(&base.queue_lock);
    while (sys.RemHead(&made)) |node| sys.AddTail(&base.queue, node);
    sys.ReleaseLock(&base.queue_lock);
}
