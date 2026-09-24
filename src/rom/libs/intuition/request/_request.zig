// SPDX-License-Identifier: MPL-2.0
//! The easy requester: what its calls share.
//!
//! A requester is a window with a message sunk in a frame and a row of
//! framed buttons under it, on a dithered ground. BuildEasyRequestArgs
//! formats the message and the buttons' words with RawDoFmt, lays them out
//! in the screen's font, opens the window and draws the message into it
//! once: the window is smart refresh, so what it drew is kept when another
//! window covers it, and only the buttons are gadgets.
//!
//! Everything made for one requester is in one `Request`, allocated as one
//! block with the words and the IntuiText after it, and hung on the window
//! for FreeSysRequest.

const sdk = @import("sdk");
const intuition = sdk.intuition;
const Object = intuition.Object;
const IntuiText = intuition.IntuiText;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;

/// One requester's own things.
pub const Request = struct {
    /// Bytes in the block this struct begins.
    size: usize,
    /// The message, one run a line, linked in order.
    lines: [*]IntuiText,
    line_count: u32,
    /// The buttons from the left; the rightmost answers 0.
    buttons: [*]?*Object,
    button_count: u32,
    /// The words the lines and the buttons point into.
    text: [*]u8,
};

/// Give back a Request and the buttons it made. The window goes first: a
/// button in a window is the window's until it is taken out.
pub fn free(ib: *IntuitionBase, request: *Request) void {
    const it = ib.iface();
    for (request.buttons[0..request.button_count]) |button| it.DisposeObject(button);
    ib.sys_base.FreeVec(request);
}
