// SPDX-License-Identifier: MIT
//! DisposeCxMsg: a commodity message taken out of the network.

const sdk = @import("sdk");
const cx = sdk.commodities;
const _base = @import("../commodities_base.zig");
const _message = @import("_message.zig");
const CxBase = _base.CxBase;

/// Takes a commodity message out of the network.
///
/// SYNOPSIS:
/// ```zig
/// fn DisposeCxMsg(base: *CxBase, cxm: *cx.CxMsg) void
/// ```
///
/// SINCE: 1.0. LVO -108.
///
/// INPUTS:
/// - `cxm` - the message a custom object's function was given.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// The message is freed: its event goes to no further object and never
/// reaches the windows. It is how a custom object swallows an event.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: the network's, already held by the handler that called the
///   custom object's function.
/// - Process: a custom object's function, on input.device's task.
///
/// OWNERSHIP:
/// The message is gone; neither it nor its event may be touched after.
///
/// NOTES:
/// A message from a sender is not disposed of: it is replied to
/// (ReplyMsg), and the library frees it.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CxCustom`, `CxTranslate`
///
/// EXAMPLES:
/// ```zig
/// fn eatF10(cb: *cx.CxBase, cxm: *cx.CxMsg, _: *cx.CxObj) callconv(.c) void {
///     const event = cb.CxMsgData(cxm) orelse return;
///     if (event.class == ie.IECLASS_RAWKEY and event.code == kbd.RAWKEY_F10) cb.DisposeCxMsg(cxm);
/// }
/// ```
pub fn DisposeCxMsg(base: *CxBase, cxm: *cx.CxMsg) void {
    const sys = base.sys_base;
    const message = _base.messageOf(cxm);
    sys.ObtainSemaphore(&base.lock);
    sys.Remove(&message.msg.node);
    sys.ReleaseSemaphore(&base.lock);
    _message.free(base, message);
}
