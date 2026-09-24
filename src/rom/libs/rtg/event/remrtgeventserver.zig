// SPDX-License-Identifier: MPL-2.0
//! RemRtgEventServer: Take it off again.

const sdk = @import("sdk");
const exec = sdk.exec;
const rtg = sdk.rtg;
const utility = sdk.utility;
const TagItem = utility.TagItem;
const Tag = utility.Tag;
const RtgBase = @import("../rtg.zig").RtgBase;
const _event = @import("_event.zig");

/// Takes an interrupt server off one of a board's events.
///
/// SYNOPSIS:
/// ```zig
/// fn RemRtgEventServer(rb: *RtgBase, board: *rtg.RtgBoard, event: u32, server: *exec.Interrupt) void
/// ```
///
/// SINCE: 1.0. LVO -164.
///
/// INPUTS:
/// - `board` - the board.
/// - `event` - the event it was hung on.
/// - `server` - the Interrupt.
///
/// RESULT:
/// Nothing. A server not on the chain is left alone.
///
/// BEHAVIOR:
/// The chain is changed with interrupts off, so a signal cannot run into
/// it half changed; once this returns the server is not called again.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: safe. It takes Disable.
/// - Forbid: not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The server is the caller's again.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AddRtgEventServer`
///
/// EXAMPLES:
/// ```zig
/// rb.RemRtgEventServer(board, rtg.events.RTGEV_VBLANK, &server);
/// ```
pub fn RemRtgEventServer(rb: *RtgBase, board: *rtg.RtgBoard, event: u32, server: *exec.Interrupt) void {
    if (event >= rtg.events.RTGEV_COUNT) return;
    rb.sys_base.Disable();
    defer rb.sys_base.Enable();
    var node = board.event_lists[event].first();
    while (node) |n| : (node = n.next()) {
        if (n == &server.node) {
            rb.sys_base.Remove(n);
            return;
        }
    }
}
