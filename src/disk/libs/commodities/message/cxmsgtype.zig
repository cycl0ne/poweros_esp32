// SPDX-License-Identifier: MIT
//! CxMsgType: what kind of message a commodity message is.

const sdk = @import("sdk");
const cx = sdk.commodities;
const _base = @import("../commodities_base.zig");
const CxBase = _base.CxBase;

/// Says what kind of message a commodity message is.
///
/// SYNOPSIS:
/// ```zig
/// fn CxMsgType(base: *CxBase, cxm: *const cx.CxMsg) u32
/// ```
///
/// SINCE: 1.0. LVO -88.
///
/// INPUTS:
/// - `cxm` - a message from a sender, or the one a custom object's
///   function was given; not null.
///
/// RESULT:
/// CXM_IEVENT for an input event, CXM_COMMAND for an order from the
/// controller.
///
/// BEHAVIOR:
/// A sender's messages and a custom object's are events; a broker's port
/// gets both kinds when the program gives its senders the same port, so
/// the kind is the first thing a program looks at.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do; a custom object's function may call it.
///
/// OWNERSHIP:
/// Nothing changes hands.
///
/// NOTES:
/// Read it before replying: a replied message is the library's again.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CxMsgID`, `CxMsgData`
///
/// EXAMPLES:
/// ```zig
/// while (sys.GetMsg(port)) |msg| {
///     const cxm = cx.CxMsg.from(msg);
///     const kind = cb.CxMsgType(cxm);
///     const id = cb.CxMsgID(cxm);
///     sys.ReplyMsg(msg);
///     if (kind == cx.CXM_COMMAND and id == cx.CXCMD_KILL) done = true;
/// }
/// ```
pub fn CxMsgType(_: *CxBase, cxm: *const cx.CxMsg) u32 {
    return _base.constMessageOf(cxm).kind;
}
