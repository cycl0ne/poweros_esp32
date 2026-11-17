// SPDX-License-Identifier: MPL-2.0
//! ComposeLines: The pixels of a rectangle of a board's display as they
//! are to be seen.

const sdk = @import("sdk");
const rtg = sdk.rtg;
const RtgBase = @import("../rtg.zig").RtgBase;
const _compose = @import("_compose.zig");

/// Fetches the pixels of a rectangle of a board's picture, as the library
/// composes it.
///
/// SYNOPSIS:
/// ```zig
/// fn ComposeLines(rb: *RtgBase, board: *rtg.RtgBoard, area: *const rtg.RtgRect, into: [*]u8, pitch: u32) i32
/// ```
///
/// SINCE: 1.24. LVO -316.
///
/// INPUTS:
/// - `board` - the board: one of the caller's own, whose display has a
///   picture of its own (`update`).
/// - `area` - the rectangle, in the display's coordinates - the
///   picture's own, mirrored where the library mirrors the picture -
///   wholly inside the display in the mode the board is shown in: the
///   rectangle `update` was handed, as it is.
/// - `into` - where the pixels go, the rectangle's top left first:
///   `area.height` rows of `area.width` pixels in the mode's format.
/// - `pitch` - bytes from one row of `into` to the next; at least a row
///   of the rectangle.
///
/// RESULT:
/// `RTGERR_OK`; `RTGERR_BAD_ARG` for a rectangle that is empty or not
/// wholly inside the display; `RTGERR_BAD_FORMAT` in a mode whose pixels
/// are not whole bytes, and on a board that was never shown.
///
/// BEHAVIOR:
/// Each line of the rectangle comes from the band that covers it - the
/// buffer's row that far below the band's origin, its first row for a
/// repeating band - and is black where no band does, as on a board that
/// shows nothing. A band whose buffer is not the display's width comes
/// scaled, by the ratio of the two widths both ways, its neighbouring
/// pixels mixed where that is no whole number; a line whose row the
/// buffer has not got is black. Over that the overlay is laid, and over
/// both the pointer where it is shown: each a masked copy of the part of
/// its image inside the rectangle. An image the board lays itself
/// (`RtgPointerOps`, `RtgOverlayOps`) is not laid here.
///
/// A picture the library mirrors (`MirrorBoard`, an axis the board's
/// own hardware does not turn) comes mirrored: its rows the other way
/// round, each row turned round. On a board that is blank or asleep
/// (`SetBoardPower`) every pixel is black.
///
/// It is what a driver calls from its `update`, for the rectangle it was
/// handed, and from its `show` for the whole display when the board is
/// shown without `RTGSHOW_DIRECT`: the bands of that show are in place
/// then. The pixels may go straight into the display's own memory or
/// into a block the driver sends.
///
/// CONTEXT:
/// - Waits: for the board's compose lock, where the caller does not hold
///   it; inside `update` and `show` it does.
/// - Interrupts: no.
/// - Locks: takes the board's compose lock, which nests for the task
///   that holds it.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated. `into` is the caller's.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CreateBoard`, `RefreshRect`, `SetBoardPointer`, `ShowBoard`
///
/// EXAMPLES:
/// ```zig
/// // update: the rectangle straight into the display's own frame.
/// fn update(board: *rtg.RtgBoard, area: *const rtg.RtgRect) callconv(.c) i32 {
///     const screen = screenOf(board);
///     const at = screen.frame + @as(usize, @intCast(area.y)) * screen.pitch + @as(usize, @intCast(area.x)) * 4;
///     return screen.rtg_base.ComposeLines(board, area, at, screen.pitch);
/// }
/// ```
pub fn ComposeLines(rb: *RtgBase, board: *rtg.RtgBoard, area: *const rtg.RtgRect, into: [*]u8, pitch: u32) i32 {
    _compose.obtain(rb, board);
    defer _compose.release(rb, board);
    return _compose.lines(rb, board, area, into, pitch);
}
