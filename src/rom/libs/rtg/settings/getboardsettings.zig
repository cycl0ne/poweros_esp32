// SPDX-License-Identifier: MPL-2.0
//! GetBoardSettings: The line in force for a board, as a structure.

const sdk = @import("sdk");
const rtg = sdk.rtg;
const RtgBase = @import("../rtg.zig").RtgBase;
const boards = @import("../board/_board.zig");
const settings = @import("_settings.zig");

/// Copies out the settings line in force for a board.
///
/// SYNOPSIS:
/// ```zig
/// fn GetBoardSettings(rb: *RtgBase, board: *rtg.RtgBoard, into: *rtg.RtgSettings, size: u32) u32
/// ```
///
/// SINCE: 1.34. LVO -164.
///
/// INPUTS:
/// - `board` - the board.
/// - `into` - takes the line.
/// - `size` - how many bytes of `into` are there: pass
///   `@sizeOf(RtgSettings)`.
///
/// RESULT:
/// The bytes written: `size`, or the structure's size where that is
/// less. Check it before trusting a field near the end.
///
/// BEHAVIOR:
/// The line in force is the one for the monitor on the board now -
/// `RTGSET_MONITOR` is set in its flags, and `maker`, `product` and
/// `serial` are that monitor's - else the one that names no monitor: a
/// panel's line, and the line for whatever is on a connector. A board
/// with neither answers flags of 0.
///
/// A flag that is clear says the line leaves that alone: without
/// `RTGSET_MODE` the board comes up in the mode its driver or its
/// monitor prefers, without `RTGSET_MIRROR` its picture stays as it is
/// turned, without `RTGSET_RANGE` the colours go out in the range the
/// monitor asks for.
///
/// What the line says is what was asked, not what the board does: a
/// mode the monitor has not got, a brightness on a board with no
/// backlight to set stay in the line and do nothing. `GetBoardInfo` and
/// `GetBoardModes` say what the board is at.
///
/// CONTEXT:
/// - Waits: only while another task holds the board's lock.
/// - Interrupts: no.
/// - Locks: takes the board's lock, and the settings' inside it.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated; `into` is the caller's.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `SetBoardSettings`, `LoadBoardSettings`, `GetBoardMonitor`
///
/// EXAMPLES:
/// ```zig
/// var line: rtg.RtgSettings = .{};
/// if (rb.GetBoardSettings(board, &line, @sizeOf(rtg.RtgSettings)) == @sizeOf(rtg.RtgSettings)) {
///     if (line.flags & rtg.RTGSET_MODE != 0) {
///         // It comes up in line.mode_width by line.mode_height.
///     }
/// }
/// ```
pub fn GetBoardSettings(rb: *RtgBase, board: *rtg.RtgBoard, into: *rtg.RtgSettings, size: u32) u32 {
    var line: rtg.RtgSettings = .{};
    boards.obtain(rb, board);
    _ = settings.lineOf(rb, board, &line);
    boards.release(rb, board);
    const count: u32 = @min(size, @sizeOf(rtg.RtgSettings));
    const from: [*]const u8 = @ptrCast(&line);
    const to: [*]u8 = @ptrCast(into);
    @memcpy(to[0..count], from[0..count]);
    return count;
}
