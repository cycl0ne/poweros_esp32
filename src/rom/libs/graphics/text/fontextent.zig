// SPDX-License-Identifier: MPL-2.0
//! FontExtent: what a font is.

const sdk = @import("sdk");
const exec = sdk.exec;
const graphics = sdk.graphics;
const rtg = sdk.rtg;
const TagItem = sdk.utility.TagItem;
const GraphicsBase = @import("../graphics.zig").GraphicsBase;
const _text = @import("_text.zig");
const TextFont = _text.TextFont;

/// What a font is.
///
/// SYNOPSIS:
/// ```zig
/// fn FontExtent(_: *GraphicsBase, font: *const TextFont, out: *graphics.FontExtent) void
/// ```
///
/// SINCE: 0.15. LVO -184.
///
/// INPUTS:
/// - `font` - the font.
/// - `out` - where the answer goes: the nominal width and the height, the
///   baseline, the styles it was **drawn** with, and where any
///   character's ink can land relative to the point.
///
/// RESULT:
/// Nothing; the answer is in `out`.
///
/// BEHAVIOR:
/// The style is the part worth reading. On a font drawn extended,
/// asking for `FSF_EXTENDED` does nothing - `AskSoftStyle` says as much, and widening it twice is the sort of thing nobody notices until a
/// column of text fails to line up.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: safe. It reads the font and nothing else.
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
/// `AskSoftStyle`, `TextExtent`
///
/// EXAMPLES:
/// ```zig
/// var about: graphics.FontExtent = .{};
/// gb.FontExtent(font, &about);
/// ```
pub fn FontExtent(_: *GraphicsBase, font: *const TextFont, out: *graphics.FontExtent) void {
    const image = font.image;
    const height: i32 = image.height;
    const base: i32 = image.baseline;
    // The widest reach of any glyph, from a kern back to the far edge of
    // the widest box; never narrower than a cell.
    var min_x: i32 = 0;
    var max_x: i32 = image.x_size;
    for (graphics.fontimage.glyphsOf(image)) |*glyph| {
        if (glyph.width == 0) continue;
        min_x = @min(min_x, glyph.left);
        max_x = @max(max_x, @as(i32, glyph.left) + glyph.width);
    }
    out.* = .{
        .width = image.x_size,
        .height = height,
        .baseline = base,
        .style = image.style,
        .extent = .{ .min_x = min_x, .min_y = -base, .max_x = max_x, .max_y = height - base },
    };
}
