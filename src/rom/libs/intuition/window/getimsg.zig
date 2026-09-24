// SPDX-License-Identifier: MPL-2.0
//! GetIMsg: the next message on a window's port, as an IntuiMessage.

const sdk = @import("sdk");
const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const Window = @import("_window.zig").Window;
const IntuiMessage = sdk.intuition.IntuiMessage;

/// Takes the next message off a window's port.
///
/// SYNOPSIS:
/// ```zig
/// fn GetIMsg(ib: *IntuitionBase, window: *Window) ?*IntuiMessage
/// ```
///
/// SINCE: 0.14. LVO -332.
///
/// INPUTS:
/// - `window` - the window whose messages are wanted.
///
/// RESULT:
/// The oldest message waiting, taken off the port, or null when there is
/// none or the window has no port.
///
/// BEHAVIOR:
/// `GetMsg` on the window's port, handed back as the IntuiMessage it is.
/// A window gets a port when it is opened with an `IDCMP_` class, or given
/// one with `ModifyIDCMP`, and loses it with `ModifyIDCMP(window, 0)`.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Forbid: not held and not needed; only the window's own program
///   changes its port, through `ModifyIDCMP` and `CloseWindow`.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The message is the program's until it hands it back with `ReplyIMsg`,
/// which it must do before the window closes or its port is taken away.
///
/// NOTES:
/// Read what is needed and reply soon: moves and key repeats are held back
/// while earlier ones wait unreplied, and a verify message holds up the
/// screen until it is answered.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ReplyIMsg`, `WaitIMsg`, `ModifyIDCMP`
///
/// EXAMPLES:
/// ```zig
/// while (ib.GetIMsg(window)) |im| {
///     const class = im.class;
///     ib.ReplyIMsg(im);
///     if (class == IDCMP_CLOSEWINDOW) done = true;
/// }
/// ```
pub fn GetIMsg(ib: *IntuitionBase, window: *Window) ?*IntuiMessage {
    const port = window.user_port orelse return null;
    const msg = ib.sys_base.GetMsg(port) orelse return null;
    return @fieldParentPtr("msg", msg);
}
