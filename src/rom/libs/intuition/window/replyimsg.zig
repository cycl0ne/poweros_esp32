// SPDX-License-Identifier: MPL-2.0
//! ReplyIMsg: hands a window's message back.

const sdk = @import("sdk");
const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const IntuiMessage = sdk.intuition.IntuiMessage;

/// Hands a message from `GetIMsg` back.
///
/// SYNOPSIS:
/// ```zig
/// fn ReplyIMsg(ib: *IntuitionBase, msg: *IntuiMessage) void
/// ```
///
/// SINCE: 0.14. LVO -336.
///
/// INPUTS:
/// - `msg` - a message `GetIMsg` answered, not yet handed back.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// `ReplyMsg` on the message. Intuition takes it back: a verify message
/// lets the screen go on, and a held-back move or key repeat can be sent
/// again.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Forbid: not held and not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The message is Intuition's again; it must not be read after this.
///
/// NOTES:
/// Copy what is needed out of the message before replying.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `GetIMsg`, `WaitIMsg`
///
/// EXAMPLES:
/// ```zig
/// const code = im.code;
/// ib.ReplyIMsg(im);
/// ```
pub fn ReplyIMsg(ib: *IntuitionBase, msg: *IntuiMessage) void {
    ib.sys_base.ReplyMsg(&msg.msg);
}
