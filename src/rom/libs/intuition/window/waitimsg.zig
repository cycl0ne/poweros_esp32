// SPDX-License-Identifier: MPL-2.0
//! WaitIMsg: waits for a window's message or for other signals.

const sdk = @import("sdk");
const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const Window = @import("_window.zig").Window;

/// Waits until a window has a message, or one of some other signals comes.
///
/// SYNOPSIS:
/// ```zig
/// fn WaitIMsg(ib: *IntuitionBase, window: *Window, others: u32) u32
/// ```
///
/// SINCE: 0.14. LVO -340.
///
/// INPUTS:
/// - `window` - the window whose messages are waited for.
/// - `others` - more signals to wake up for, such as
///   `SIGBREAKF_CTRL_C`; 0 for none.
///
/// RESULT:
/// The signals received: the window port's signal when a message came, and
/// those of `others` that arrived. 0 when there is nothing to wait for:
/// no port and `others` 0.
///
/// BEHAVIOR:
/// With a message already waiting it answers at once, the port's signal
/// and any of `others` already set, without clearing them. Otherwise it
/// is `Wait` on the port's signal and `others`, which clears the signals
/// it answers. A window without a port waits for `others` alone.
///
/// CONTEXT:
/// - Waits: yes, unless a message is already there.
/// - Interrupts: no.
/// - Forbid: must not be held.
/// - Process: a Task will do; it must be the task the window's port
///   signals, the one that opened the window or last gave it a port.
///
/// OWNERSHIP:
/// Nothing is allocated and no message is taken: `GetIMsg` does that.
///
/// NOTES:
/// One wake-up can mean several messages: take them with `GetIMsg` until
/// it answers null before waiting again.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `GetIMsg`, `ReplyIMsg`, `ModifyIDCMP`
///
/// EXAMPLES:
/// ```zig
/// while (true) {
///     const got = ib.WaitIMsg(window, SIGBREAKF_CTRL_C);
///     if (got & SIGBREAKF_CTRL_C != 0) break;
///     while (ib.GetIMsg(window)) |im| {
///         const class = im.class;
///         ib.ReplyIMsg(im);
///         if (class == IDCMP_CLOSEWINDOW) return;
///     }
/// }
/// ```
pub fn WaitIMsg(ib: *IntuitionBase, window: *Window, others: u32) u32 {
    const sys = ib.sys_base;
    const port = window.user_port orelse {
        if (others == 0) return 0;
        return sys.Wait(others);
    };
    const mask = port.sigMask();
    if (!port.msg_list.isEmpty()) return mask | (sys.SetSignal(0, 0) & others);
    return sys.Wait(mask | others);
}
