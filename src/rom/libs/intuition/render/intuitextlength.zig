// SPDX-License-Identifier: MPL-2.0
//! IntuiTextLength: how wide one run of text is, measured by graphics in a
//! RastPort made for the purpose over a single pixel that is never drawn.

const sdk = @import("sdk");
const utility = sdk.utility;
const graphics = sdk.graphics;
const rtg = sdk.rtg;
const TagItem = utility.TagItem;
const IntuiText = sdk.intuition.IntuiText;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;

/// How wide one run of text is, in pixels.
///
/// SYNOPSIS:
/// ```zig
/// fn IntuiTextLength(ib: *IntuitionBase, itext: *const IntuiText) i32
/// ```
///
/// SINCE: 0.9. LVO -216.
///
/// INPUTS:
/// - `itext` - the run. Only its `text` and `font` are read.
///
/// RESULT:
/// How far graphics' `Text` would move along drawing it, in the run's own
/// font or, when it names none, in the ROM's font at the height a screen
/// opens with when it is given no font. 0 for no text, or when there is
/// no memory to measure in.
///
/// BEHAVIOR:
/// The run is measured by itself: the runs linked after it are drawn
/// where each says, not after it, so adding them up would be a width of
/// nothing in particular.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no: it allocates.
/// - Forbid: not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing changes hands. The RastPort it measures in is its own and is
/// freed before it returns.
///
/// NOTES:
/// - A run drawn with `PrintIText` in a RastPort whose font is not the
///   default, and naming no font of its own, comes out in that font, so
///   this measure is not its width. Name the font in the run to measure
///   what will be drawn.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `PrintIText`, graphics' `TextLength`
///
/// EXAMPLES:
/// ```zig
/// const width = ib.IntuiTextLength(&label);
/// ```
pub fn IntuiTextLength(ib: *IntuitionBase, itext: *const IntuiText) i32 {
    const gb = ib.graphics_base;
    const words = itext.text orelse return 0;
    const count: u32 = @intCast(ib.utility_base.Strlen(words));
    if (count == 0) return 0;

    const font = itext.font orelse gb.OpenFont(graphics.POSPAZNAME, ib.font_height) orelse return 0;
    defer if (itext.font == null) gb.CloseFont(font);

    // A RastPort needs something to draw into; nothing is drawn, so one
    // pixel on the stack is all it gets.
    var pixel: u32 = 0;
    var surface = rtg.bitmaps.Surface{
        .pixels = @ptrCast(&pixel),
        .width = 1,
        .height = 1,
        .pitch = @sizeOf(u32),
        .size_bytes = @sizeOf(u32),
        .format = .rgba32,
    };
    const rp = gb.CreateRastPortTagList(&[_]TagItem{
        .{ .tag = graphics.RPTAG_Surface, .data = @intFromPtr(&surface) },
        .{ .tag = graphics.RPTAG_Font, .data = @intFromPtr(font) },
        .{},
    }) orelse return 0;
    defer gb.FreeRastPort(rp);
    return gb.TextLength(rp, words, count);
}
