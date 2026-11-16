// SPDX-License-Identifier: MPL-2.0
//! ReadBoardEDID: Copy out the EDID of the monitor on a board.

const sdk = @import("sdk");
const rtg = sdk.rtg;
const RtgBase = @import("../rtg.zig").RtgBase;
const boards = @import("../board/_board.zig");

/// Copies out the EDID the monitor on a board's connector was read to
/// have.
///
/// SYNOPSIS:
/// ```zig
/// fn ReadBoardEDID(rb: *RtgBase, board: *rtg.RtgBoard, buffer: ?[*]u8, size: u32) u32
/// ```
///
/// SINCE: 1.20. LVO -316.
///
/// INPUTS:
/// - `board` - the board.
/// - `buffer` - where the bytes go, or null to ask how many there are.
/// - `size` - how many bytes `buffer` has room for.
///
/// RESULT:
/// The EDID's length in bytes, which may be more than were copied: whole
/// blocks of 128, at most `RTG_EDID_MAX`. 0 for a panel, a board with no
/// monitor on it, and a monitor whose EDID did not read.
///
/// BEHAVIOR:
/// Up to `size` bytes are copied, the first block first, as the library
/// holds them from its last look at the connector: nothing is read from
/// the monitor at this call. Only an EDID whose first block begins as one
/// and sums to zero is held.
///
/// CONTEXT:
/// - Waits: while another task holds the board's lock.
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
/// `GetBoardMonitor`
///
/// EXAMPLES:
/// ```zig
/// var bytes: [rtg.modes.RTG_EDID_MAX]u8 = undefined;
/// const length = rb.ReadBoardEDID(board, &bytes, bytes.len);
/// ```
pub fn ReadBoardEDID(rb: *RtgBase, board: *rtg.RtgBoard, buffer: ?[*]u8, size: u32) u32 {
    boards.obtain(rb, board);
    defer boards.release(rb, board);
    const state = boards.privateOf(board).monitor orelse return 0;
    const held = state.edid;
    const length = state.info.edid_size;
    if (buffer) |into| {
        const copied = @min(size, length);
        @memcpy(into[0..copied], held[0..copied]);
    }
    return length;
}
