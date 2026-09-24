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
/// - `out` - where the answer goes: the width and height, the baseline, the
///   styles it was **drawn** with, and where one character's ink lands
///   relative to the point.
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
/// - Forbid: not needed.
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
    const height: i32 = font.height;
    const base: i32 = font.baseline;
    out.* = .{
        .width = font.width,
        .height = height,
        .baseline = base,
        .style = font.style,
        .extent = .{ .min_x = 0, .min_y = -base, .max_x = font.width, .max_y = height - base },
    };
}
