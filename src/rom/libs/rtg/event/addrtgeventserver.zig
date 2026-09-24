// SPDX-License-Identifier: MPL-2.0
//! AddRtgEventServer: Hand an RTGEV_* event of that board to your
//! Interrupt, highest ln_Pri first.

const sdk = @import("sdk");
const exec = sdk.exec;
const rtg = sdk.rtg;
const utility = sdk.utility;
const TagItem = utility.TagItem;
const Tag = utility.Tag;
const RtgBase = @import("../rtg.zig").RtgBase;
const _event = @import("_event.zig");

/// Hangs an interrupt server on one of a board's events.
///
/// SYNOPSIS:
/// ```zig
/// fn AddRtgEventServer(rb: *RtgBase, board: *rtg.RtgBoard, event: u32, server: *exec.Interrupt) bool
/// ```
///
/// SINCE: 1.0. LVO -160.
///
/// INPUTS:
/// - `board` - the board.
/// - `event` - an `RTGEV_` event.
/// - `server` - the Interrupt: `is_Code` an `RtgEventFn`, `is_Data` its
///   own, `ln_Pri` its place in the chain.
///
/// RESULT:
/// True, or false for an event that does not exist.
///
/// BEHAVIOR:
/// The chain is kept by priority, highest first. The server runs in
/// interrupt context, when the driver signals the event: it may not wait
/// and should be brief. A server that answers non-zero stops the chain.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: safe. It takes Disable.
/// - Forbid: not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The server stays the caller's, and must stay put until
/// `RemRtgEventServer`.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `RemRtgEventServer`, `SignalRtgEvent`
///
/// EXAMPLES:
/// ```zig
/// if (!rb.AddRtgEventServer(board, rtg.events.RTGEV_VBLANK, &server)) return error.NoSuchEvent;
/// ```
pub fn AddRtgEventServer(rb: *RtgBase, board: *rtg.RtgBoard, event: u32, server: *exec.Interrupt) bool {
    if (event >= rtg.events.RTGEV_COUNT) return false;
    server.node.type = .interrupt;
    rb.sys_base.Disable();
    defer rb.sys_base.Enable();
    rb.sys_base.Enqueue(&board.event_lists[event], &server.node);
    return true;
}
