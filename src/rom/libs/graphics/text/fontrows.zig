// SPDX-License-Identifier: MPL-2.0
//! FontRows: how many rows a TextAttr asks for.

const sdk = @import("sdk");
const graphics = sdk.graphics;
const GraphicsBase = @import("../graphics.zig").GraphicsBase;
const _text = @import("_text.zig");

/// How many rows a TextAttr asks for.
///
/// SYNOPSIS:
/// ```zig
/// fn FontRows(gb: *GraphicsBase, text_attr: *const graphics.TextAttr) u32
/// ```
///
/// SINCE: 0.19. LVO -304.
///
/// INPUTS:
/// - `text_attr` - a request; its `y_size` and `FPF_POINTS` are read.
///
/// RESULT:
/// `y_size` as it is, or with `FPF_POINTS` that many points in rows:
/// `points * dpi / 72`, to the nearest row, at least 1 for a size above 0.
///
/// BEHAVIOR:
/// The DPI is the screen's, from the board's system tags
/// (`SYSTAG_ScreenDPI`), read once when the library starts; without one
/// it is 72 and a point is a row. So 10 points is 24 rows on a screen of
/// 170 DPI and 23 on one of 165: the same size on the glass on either.
/// `OpenFont` and `WeighTAMatch` go through this, and diskfont.library
/// does too, so a size in points means one thing everywhere.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: safe. It reads its argument and the DPI.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `OpenFont`, `WeighTAMatch`
///
/// EXAMPLES:
/// ```zig
/// const rows = gb.FontRows(&.{ .name = "spleen.font", .y_size = 10, .flags = sdk.graphics.FPF_POINTS });
/// ```
pub fn FontRows(gb: *GraphicsBase, text_attr: *const graphics.TextAttr) u32 {
    const size: u32 = text_attr.y_size;
    if (text_attr.flags & graphics.FPF_POINTS == 0) return size;
    if (size == 0) return 0;
    const rows = (size * gb.screen_dpi + _text.points_per_inch / 2) / _text.points_per_inch;
    return @max(rows, 1);
}
