// SPDX-License-Identifier: MPL-2.0
//! AddBoardMode: A mode of a board, from its driver.

const sdk = @import("sdk");
const rtg = sdk.rtg;
const RtgBase = @import("../rtg.zig").RtgBase;
const boards = @import("../board/_board.zig");
const _mode = @import("_mode.zig");

/// Adds a mode to a board's list.
///
/// SYNOPSIS:
/// ```zig
/// fn AddBoardMode(rb: *RtgBase, board: *rtg.RtgBoard, timings: *const rtg.RtgTimings, format: u32, flags: u32) u32
/// ```
///
/// SINCE: 1.19. LVO -384.
///
/// INPUTS:
/// - `board` - the board, one of the caller's own.
/// - `timings` - the mode's timings: its picture's size, and where the
///   display has a clock, the clock and the blanking. Copied.
/// - `format` - the pixel format the board shows the mode in, as a number.
/// - `flags` - `RTGMF_DEFAULT` for the mode the board comes up in,
///   `RTGMF_TURNED` for a picture that lies on the panel a quarter turn
///   round.
///
/// RESULT:
/// The mode's number, from 1; 0 for timings whose picture is empty, for a
/// format this build does not know, and without memory.
///
/// BEHAVIOR:
/// The library makes the mode: its name is its size ("1024x600") - with
/// the refresh behind it where the board has that size at more than one -
/// its refresh is what the timings come to, 0 where they have no clock,
/// and its number is the next the board has not used. The list is kept
/// with the larger picture first. The first mode added is the board's
/// default until one is added with `RTGMF_DEFAULT`. A mode added again -
/// the same size, format, refresh and turn - is the one that is there: it
/// takes the timings handed over and keeps its number.
///
/// On a board with a connector (`detect`) the modes are what the monitor
/// names, made by the library; the ones added with this call are the
/// board's own, which stand while no monitor is there or the one there
/// names none the board can make.
///
/// A row of a buffer of the mode is as long as `AllocBitMap` makes one:
/// the width in the format, rounded up to what the board's display memory
/// is aligned to. It is set once the board has joined the list, so a
/// driver that needs the figure in its `attach` works it out from its own
/// region.
///
/// CONTEXT:
/// - Waits: while another task holds the board's lock.
/// - Interrupts: no.
/// - Locks: takes the board's lock. No spinlock may be held.
/// - Process: a Task will do. A driver calls it in its `attach`.
///
/// OWNERSHIP:
/// The mode is the library's and goes with the board. Nothing is kept of
/// `timings`.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ReadTimingTags`, `GetBoardModes`, `CreateBoard`
///
/// EXAMPLES:
/// ```zig
/// var timings: rtg.RtgTimings = .{};
/// if (!rb.ReadTimingTags(tag_list, &timings)) return rtg.errors.RTGERR_BAD_TAGS;
/// _ = rb.AddBoardMode(board, &timings, @intFromEnum(rtg.PixelFormat.rgb565), rtg.modes.RTGMF_DEFAULT);
/// ```
pub fn AddBoardMode(rb: *RtgBase, board: *rtg.RtgBoard, timings: *const rtg.RtgTimings, format: u32, flags: u32) u32 {
    if (timings.h_active == 0 or timings.v_active == 0) return 0;
    if (rb.iface().RtgFormatBits(format) == 0) return 0;
    boards.obtain(rb, board);
    defer boards.release(rb, board);
    const record = _mode.add(rb, board, timings, format, flags, .driver) orelse return 0;
    // On a board whose monitor names modes, the driver's own stand by:
    // they are offered while it names none.
    if (boards.privateOf(board).monitor) |state| {
        if (state.names_modes) _mode.withdraw(rb, board, .driver);
    }
    return record.mode.id;
}
