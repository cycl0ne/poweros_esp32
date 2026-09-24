// SPDX-License-Identifier: MPL-2.0
//! SysReqHandler: reads what arrived at a requester and says whether it
//! answered it.

const sdk = @import("sdk");
const intuition = sdk.intuition;
const wn = intuition.windows;
const gc = intuition.gadgetclass;
const ie = sdk.devices.inputevent;
const Object = intuition.Object;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const Window = @import("../window/_window.zig").Window;

/// The key that answers the leftmost button, with the left Amiga key held.
const true_key = 'V';
/// The key that answers the rightmost, the same way.
const false_key = 'B';

/// Reads what arrived at a requester.
///
/// SYNOPSIS:
/// ```zig
/// fn SysReqHandler(ib: *IntuitionBase, window: ?*Window, idcmp_ptr: ?*u32,
///     wait_input: bool) i32
/// ```
///
/// SINCE: 0.11. LVO -256.
///
/// INPUTS:
/// - `window` - what `BuildEasyRequestArgs` answered. Null, which is what it
///   answers when it failed, is answered 0 at once.
/// - `idcmp_ptr` - where to write which of the caller's own IDCMP classes
///   arrived, or null.
/// - `wait_input` - wait for a message when none is waiting.
///
/// RESULT:
/// - 1, 2, ... for the buttons from the left and 0 for the rightmost.
/// - -1 (`SYSREQ_IDCMP`): one of the classes the caller gave
///   `BuildEasyRequestArgs` arrived; it is written to `*idcmp_ptr`.
/// - -2 (`SYSREQ_PENDING`): nothing that arrived answered the requester -
///   a key it does not know, or no message at all without `wait_input`.
///
/// BEHAVIOR:
/// Every message waiting is read and replied to until one answers. A
/// button let go over itself answers with its number; the left Amiga key
/// with V answers as the leftmost button would, and with B as the
/// rightmost. Any other key is passed over.
///
/// CONTEXT:
/// - Waits: with `wait_input`, until the window has a message.
/// - Interrupts: no.
/// - Forbid: must not be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing changes hands. The requester stays open until
/// `FreeSysRequest`, whatever the answer.
///
/// NOTES:
/// - When more than one class of the caller's is asked for, `*idcmp_ptr`
///   holds the one that arrived; set it again before the next time it is
///   given to `EasyRequestArgs`.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `BuildEasyRequestArgs`, `FreeSysRequest`, `EasyRequestArgs`
///
/// EXAMPLES:
/// ```zig
/// var answer = ib.SysReqHandler(req, null, true);
/// while (answer == requesters.SYSREQ_PENDING) : (answer = ib.SysReqHandler(req, null, true)) {}
/// ```
pub fn SysReqHandler(ib: *IntuitionBase, window: ?*Window, idcmp_ptr: ?*u32, wait_input: bool) i32 {
    const sys = ib.sys_base;
    const w = window orelse return 0;
    const port = w.user_port orelse return intuition.requesters.SYSREQ_PENDING;
    if (wait_input) _ = sys.WaitPort(port);

    var answer: i32 = intuition.requesters.SYSREQ_PENDING;
    while (answer == intuition.requesters.SYSREQ_PENDING) {
        const m = sys.GetMsg(port) orelse break;
        const im: *intuition.IntuiMessage = @ptrCast(@alignCast(m));
        switch (im.class) {
            wn.IDCMP_GADGETUP => {
                var id: usize = 0;
                const gadget: ?*Object = @ptrCast(im.iaddress);
                _ = ib.iface().GetAttr(gc.GA_ID, gadget, &id);
                answer = @intCast(id);
            },
            wn.IDCMP_VANILLAKEY => if (im.qualifier & ie.IEQUALIFIER_LCOMMAND != 0) {
                const key = ib.utility_base.ToUpper(im.code);
                if (key == false_key) answer = 0;
                if (key == true_key) answer = 1;
            },
            else => {
                answer = intuition.requesters.SYSREQ_IDCMP;
                if (idcmp_ptr) |out| out.* = im.class;
            },
        }
        sys.ReplyMsg(m);
    }
    return answer;
}
