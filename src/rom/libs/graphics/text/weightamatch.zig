// SPDX-License-Identifier: MPL-2.0
//! WeighTAMatch: how well a font matches what is asked for.

const sdk = @import("sdk");
const graphics = sdk.graphics;
const TagItem = sdk.utility.TagItem;
const GraphicsBase = @import("../graphics.zig").GraphicsBase;
const _text = @import("_text.zig");

/// How well a font matches what is asked for.
///
/// SYNOPSIS:
/// ```zig
/// fn WeighTAMatch(gb: *GraphicsBase, req: *const graphics.TextAttr, target: *const graphics.TextAttr, target_tags: ?[*]const TagItem) i32
/// ```
///
/// SINCE: 0.19. LVO -280.
///
/// INPUTS:
/// - `req` - what is asked for: height, style and flags.
/// - `target` - a font as it is: its height, the styles it was drawn
///   with, and its flags (`FPF_ROMFONT`, `FPF_DISKFONT`, `FPF_DESIGNED`).
/// - `target_tags` - more about the font, or null. None is weighed yet.
///
/// RESULT:
/// `MAXFONTMATCHWEIGHT` for a perfect match, less the further off, and 0
/// for a font that will not do. Weights of one request against several
/// fonts compare; the names are not looked at, since only fonts of the
/// name are weighed at all.
///
/// BEHAVIOR:
/// The weight starts at `MAXFONTMATCHWEIGHT` and loses:
///
/// - 32 for each row the font is shorter than asked, 128 for each row it
///   is taller: text short of its box reads better than text spilling
///   out of it;
/// - for a style asked for that the font was not drawn with - which the
///   soft styles can add - italic 16, bold 8, underlined 4, extended 0;
/// - for a style the font was drawn with and not asked for - which
///   nothing can take away - italic 1024, bold 512, underlined 2048,
///   extended 0;
/// - everything when `FPF_DESIGNED` is asked for and the font was scaled
///   from another size. A font in the ROM or loaded from a disk counts
///   as designed.
///
/// A height of 0 on either side will not do. What is left below 0 is 0.
/// A height in points (`FPF_POINTS`) on either side is weighed in the
/// rows it comes to.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: safe. It reads its arguments and nothing else.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated; the arguments are only read.
///
/// NOTES:
/// diskfont.library weighs the sizes a font's contents file lists with
/// it, before loading any of them, the same way `OpenFont` weighs the
/// fonts on the list.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `OpenFont`, `AskFont`
///
/// EXAMPLES:
/// ```zig
/// const want = sdk.graphics.TextAttr{ .name = "topaz.font", .y_size = 11 };
/// const have = sdk.graphics.TextAttr{ .name = "topaz.font", .y_size = 8, .flags = sdk.graphics.FPF_DISKFONT };
/// const weight = gb.WeighTAMatch(&want, &have, null); // 32767 - 3 * 32
/// ```
pub fn WeighTAMatch(gb: *GraphicsBase, req_given: *const graphics.TextAttr, target_given: *const graphics.TextAttr, target_tags: ?[*]const TagItem) i32 {
    _ = target_tags;
    const req = _text.inRows(gb, req_given);
    const target = _text.inRows(gb, target_given);
    if (req.y_size == 0 or target.y_size == 0) return 0;
    var weight: i32 = graphics.MAXFONTMATCHWEIGHT;

    const rows = @as(i32, req.y_size) - @as(i32, target.y_size);
    weight -= if (rows >= 0) rows * 32 else -rows * 128;

    for (style_weights) |entry| {
        const asked = req.style & entry.style != 0;
        const drawn = target.style & entry.style != 0;
        if (asked and !drawn) weight -= entry.missing;
        if (drawn and !asked) weight -= entry.unasked;
    }

    // A font in the ROM or from a disk was drawn at its size, whatever
    // its own flags say.
    const made = graphics.FPF_ROMFONT | graphics.FPF_DISKFONT;
    const designed = target.flags & (graphics.FPF_DESIGNED | made) != 0;
    if (req.flags & graphics.FPF_DESIGNED != 0 and !designed) return 0;

    return @max(weight, 0);
}

/// What each style costs: `missing` when it is asked for and the font
/// lacks it, `unasked` when the font has it and it was not asked for.
const StyleWeight = struct {
    style: graphics.FontStyle,
    missing: i32,
    unasked: i32,
};

const style_weights = [_]StyleWeight{
    .{ .style = graphics.FSF_ITALIC, .missing = 16, .unasked = 1024 },
    .{ .style = graphics.FSF_BOLD, .missing = 8, .unasked = 512 },
    .{ .style = graphics.FSF_UNDERLINED, .missing = 4, .unasked = 2048 },
    .{ .style = graphics.FSF_EXTENDED, .missing = 0, .unasked = 0 },
};
