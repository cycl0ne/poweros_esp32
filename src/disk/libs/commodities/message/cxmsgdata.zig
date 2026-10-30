// SPDX-License-Identifier: MIT
//! CxMsgData: the input event a commodity message carries.

const sdk = @import("sdk");
const cx = sdk.commodities;
const ie = sdk.devices.inputevent;
const _base = @import("../commodities_base.zig");
const CxBase = _base.CxBase;

/// Answers the input event a commodity message carries.
///
/// SYNOPSIS:
/// ```zig
/// fn CxMsgData(base: *CxBase, cxm: ?*cx.CxMsg) ?*ie.InputEvent
/// ```
///
/// SINCE: 1.0. LVO -92.
///
/// INPUTS:
/// - `cxm` - a message, or null.
///
/// RESULT:
/// The message's event; null for a command and for a null message.
///
/// BEHAVIOR:
/// The event is inside the message. A custom object's function may change
/// it, and what it changes is what the rest of the network and the
/// windows see; a sender's copy is the program's to read, and changing it
/// changes nothing else. Its `next` is null: each message carries one
/// event.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do; a custom object's function may call it.
///
/// OWNERSHIP:
/// The event goes with the message: a sender's is not to be read once the
/// message is replied to, a custom object's not after its function
/// returns.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CxMsgType`, `DisposeCxMsg`
///
/// EXAMPLES:
/// ```zig
/// fn noCaps(cb: *cx.CxBase, cxm: *cx.CxMsg, _: *cx.CxObj) callconv(.c) void {
///     const event = cb.CxMsgData(cxm) orelse return;
///     event.qualifier &= ~ie.IEQUALIFIER_CAPSLOCK;
/// }
/// ```
pub fn CxMsgData(_: *CxBase, cxm: ?*cx.CxMsg) ?*ie.InputEvent {
    const message = _base.messageOf(cxm orelse return null);
    if (message.kind != cx.CXM_IEVENT) return null;
    return &message.event;
}
