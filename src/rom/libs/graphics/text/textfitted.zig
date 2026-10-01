// SPDX-License-Identifier: MPL-2.0
//! TextFitted: a string drawn to fit a width, with dots where it was cut.

const sdk = @import("sdk");
const graphics = sdk.graphics;
const GraphicsBase = @import("../graphics.zig").GraphicsBase;
const RastPort = @import("../rastport/_rastport.zig").RastPort;

/// What stands for the rest of a string that did not fit. Three full
/// stops rather than one ellipsis character: a font here is indexed by
/// byte, and every one of them has a full stop.
const dots = "...";

/// Draws as much of a string as fits in a width, and dots where it had to
/// stop.
///
/// SYNOPSIS:
/// ```zig
/// fn TextFitted(gb: *GraphicsBase, rp: *RastPort, string: [*]const u8,
///     count: u32, width: i32) u32
/// ```
///
/// SINCE: 0.7. LVO -430.
///
/// INPUTS:
/// - `rp` - the RastPort. It draws from the current point, in its font,
///   its pens and its draw mode, and leaves the point after what it drew.
/// - `string` - the characters.
/// - `count` - how many of them.
/// - `width` - how much room there is, in pixels.
///
/// RESULT:
/// How many characters of `string` were drawn - not counting the dots.
/// `count` means all of it fitted and nothing was added.
///
/// BEHAVIOR:
/// All of it fits: all of it is drawn, and nothing is added. It does not:
/// as many characters as fit in what is left when the dots are taken off
/// the width, and then the dots. Room for the dots but for no characters:
/// only the dots. Not even room for those: nothing at all, and 0.
///
/// What fits is worked out by `TextFit`, so the answer is the one every
/// other measuring call would give for the same string, font and style.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Forbid: not held and not wanted.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated.
///
/// NOTES:
/// - A label, a list cell and a button all want this: a name too long for
///   its box should say that it was cut, not run into its neighbour or
///   stop mid-letter with no sign.
/// - `width` 0 or less draws nothing.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `TextFit`, `TextLength`, `Text`
///
/// EXAMPLES:
/// ```zig
/// // A file's name in a column 120 pixels wide.
/// gb.Move(rp, cell.min_x, baseline);
/// _ = gb.TextFitted(rp, name, len, 120);
/// ```
pub fn TextFitted(gb: *GraphicsBase, rp: *RastPort, string: [*]const u8, count: u32, width: i32) u32 {
    const graphics_lib = gb.iface();
    rp.last_error = graphics.GERR_OK;
    if (width <= 0) return 0;

    // All of it, if all of it fits. Asked of the same call that decides
    // what fits below, so the two cannot disagree at the boundary.
    if (count != 0 and graphics_lib.TextLength(@ptrCast(rp), string, count) <= width) {
        graphics_lib.Text(@ptrCast(rp), string, count);
        return count;
    }

    const dots_wide = graphics_lib.TextLength(@ptrCast(rp), dots, dots.len);
    if (dots_wide > width) return 0;

    var extent: graphics.TextExtent = .{};
    const fits = if (count == 0)
        0
    else
        graphics_lib.TextFit(@ptrCast(rp), string, count, &extent, null, 1, width - dots_wide, 0);

    if (fits != 0) graphics_lib.Text(@ptrCast(rp), string, fits);
    graphics_lib.Text(@ptrCast(rp), dots, dots.len);
    return fits;
}
