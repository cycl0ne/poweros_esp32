// SPDX-License-Identifier: MPL-2.0
//! GetBoardMonitor: What is on a board's connector.

const sdk = @import("sdk");
const rtg = sdk.rtg;
const RtgBase = @import("../rtg.zig").RtgBase;
const boards = @import("../board/_board.zig");
const _monitor = @import("_monitor.zig");

/// Reads what is on a board's connector.
///
/// SYNOPSIS:
/// ```zig
/// fn GetBoardMonitor(rb: *RtgBase, board: *rtg.RtgBoard, info: *rtg.RtgMonitorInfo, size: u32) u32
/// ```
///
/// SINCE: 1.20. LVO -228.
///
/// INPUTS:
/// - `board` - the board.
/// - `info` - where the answer goes.
/// - `size` - how many bytes `info` has: `@sizeOf(RtgMonitorInfo)`.
///
/// RESULT:
/// How many bytes were written. A caller built against an older SDK with a
/// smaller structure gets that much; check the count before trusting a
/// field near the end.
///
/// BEHAVIOR:
/// The answer is what the board's connector was last seen to have: the
/// library asks the driver when the board is made and whenever the driver
/// says the monitor changed, not at this call. `RTGMON_PRESENT` says a
/// monitor is there; with `RTGMON_EDID` its description was read, and the
/// maker's letters, the product and serial numbers, the name, the
/// picture's size in millimetres and when it was made are from it, as is
/// what it takes: HDMI's packets (`RTGMON_HDMI`), sound (`RTGMON_AUDIO`),
/// a choice of its RGB range, scrambling, and its fastest clock. A panel
/// is a monitor that is always there (`RTGMON_PANEL`), called what its
/// part is called. A board whose device has gone says what it last had.
///
/// CONTEXT:
/// - Waits: while another task holds the board's lock - through a show,
///   which may last a frame, or a look at the connector.
/// - Interrupts: no.
/// - Locks: takes the board's lock. No spinlock may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated: the copy is the caller's.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ReadBoardEDID`, `GetBoardModes`, `AddRtgNotify`
///
/// EXAMPLES:
/// ```zig
/// var monitor: rtg.RtgMonitorInfo = .{};
/// _ = rb.GetBoardMonitor(board, &monitor, @sizeOf(rtg.RtgMonitorInfo));
/// if (monitor.flags & rtg.modes.RTGMON_PRESENT == 0) return;
/// ```
pub fn GetBoardMonitor(rb: *RtgBase, board: *rtg.RtgBoard, info: *rtg.RtgMonitorInfo, size: u32) u32 {
    boards.obtain(rb, board);
    defer boards.release(rb, board);
    var said: rtg.RtgMonitorInfo = undefined;
    _monitor.infoOf(rb, board, &said);
    return boards.copyOut(rtg.RtgMonitorInfo, &said, info, size);
}
