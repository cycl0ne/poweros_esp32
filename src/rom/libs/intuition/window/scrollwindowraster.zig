// SPDX-License-Identifier: MPL-2.0
//! ScrollWindowRaster: moves part of what a window shows, and clears what
//! it leaves.

const graphics = @import("sdk").graphics;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _window = @import("_window.zig");
const Window = _window.Window;
const innerLayer = _window.innerLayer;
const innerRastPort = _window.innerRastPort;

/// Moves part of what a window shows, and clears what it leaves.
///
/// SYNOPSIS:
/// ```zig
/// fn ScrollWindowRaster(ib: *IntuitionBase, window: *Window, dx: i32, dy: i32, area: *const Rect) bool
/// ```
///
/// SINCE: 0.14. LVO -348.
///
/// INPUTS:
/// - `window` - the window.
/// - `dx`, `dy` - how far the contents move left and up; negative moves
///   them right and down.
/// - `area` - what moves, half-open, in the coordinates the program draws
///   in: `WA_RastPort`'s, which for a GimmeZeroZero window start inside
///   the border.
///
/// RESULT:
/// True when the contents moved: only the strip they left is cleared, and
/// only that needs drawing. False when they could not be moved - part of
/// what was to be read is covered and kept nowhere, or the area is in too
/// many pieces - and then the whole area is cleared and wants drawing.
///
/// BEHAVIOR:
/// `ScrollRaster` on the window's RastPort, then what is to be drawn again
/// is cleared the way the window paints its ground, its backfill hook or
/// the background pen.
///
/// CONTEXT:
/// - Waits: for the window's layer.
/// - Interrupts: no.
/// - Forbid: not held and not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated.
///
/// NOTES:
/// A scroll by the area's whole width or height or more moves nothing and
/// clears all of it, and answers true.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ScrollRaster`, `EraseRect`
///
/// EXAMPLES:
/// ```zig
/// // One line of text up; the line it leaves at the bottom is drawn.
/// if (ib.ScrollWindowRaster(window, 0, line_height, &text_area)) drawLastLine() else drawAll();
/// ```
pub fn ScrollWindowRaster(ib: *IntuitionBase, window: *Window, dx: i32, dy: i32, area: *const graphics.Rect) bool {
    const gb = ib.graphics_base;
    const layer = innerLayer(window);
    const rp = innerRastPort(window);
    ib.layers_base.LockLayer(layer);
    defer ib.layers_base.UnlockLayer(layer);

    const width = area.max_x - area.min_x;
    const height = area.max_y - area.min_y;
    if (width <= 0 or height <= 0) return true;
    if (dx >= width or -dx >= width or dy >= height or -dy >= height) {
        gb.EraseRect(rp, area);
        return true;
    }
    if (!gb.ScrollRaster(rp, dx, dy, area)) {
        gb.EraseRect(rp, area);
        return false;
    }
    // The columns, then the rows, the contents moved away from.
    if (dx > 0) gb.EraseRect(rp, &.{ .min_x = area.max_x - dx, .min_y = area.min_y, .max_x = area.max_x, .max_y = area.max_y });
    if (dx < 0) gb.EraseRect(rp, &.{ .min_x = area.min_x, .min_y = area.min_y, .max_x = area.min_x - dx, .max_y = area.max_y });
    if (dy > 0) gb.EraseRect(rp, &.{ .min_x = area.min_x, .min_y = area.max_y - dy, .max_x = area.max_x, .max_y = area.max_y });
    if (dy < 0) gb.EraseRect(rp, &.{ .min_x = area.min_x, .min_y = area.min_y, .max_x = area.max_x, .max_y = area.min_y - dy });
    return true;
}
