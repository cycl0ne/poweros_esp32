// SPDX-License-Identifier: MPL-2.0
//! RemFont: takes a font off the list.

const sdk = @import("sdk");
const exec = sdk.exec;
const graphics = sdk.graphics;
const rtg = sdk.rtg;
const TagItem = sdk.utility.TagItem;
const GraphicsBase = @import("../graphics.zig").GraphicsBase;
const rastport = @import("../rastport/_rastport.zig");
const _text = @import("_text.zig");
const RastPort = rastport.RastPort;
const drawing = @import("../draw/_draw.zig");
const TextFont = _text.TextFont;

/// Takes a font off the list.
///
/// SYNOPSIS:
/// ```zig
/// fn RemFont(gb: *GraphicsBase, font: *TextFont) bool
/// ```
///
/// SINCE: 0.15. LVO -180.
///
/// INPUTS:
/// - `font` - a font on the list.
///
/// RESULT:
/// False while anything still has it open. Taking it off then would leave
/// a RastPort drawing out of memory that is about to go, so it is refused
/// rather than trusted.
///
/// BEHAVIOR:
/// The font leaves the list, so `OpenFont` no longer finds it; a font
/// still open is refused.
///
/// CONTEXT:
/// - Waits: yes, while another task holds the font list.
/// - Interrupts: no.
/// - Forbid: must not be held: it waits on the font list's semaphore.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The font is the caller's again, to free.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AddFont`, `CloseFont`
///
/// EXAMPLES:
/// ```zig
/// if (gb.RemFont(loaded)) freeFont(loaded);
/// ```
pub fn RemFont(gb: *GraphicsBase, font: *TextFont) bool {
    const sys = gb.sys_base;
    // Held from the count to the Remove, so no OpenFont finds it between.
    sys.ObtainSemaphore(&gb.font_lock);
    defer sys.ReleaseSemaphore(&gb.font_lock);
    // Taking a font off while something is drawing with it would leave a
    // RastPort pointing at freed memory, so it is refused instead.
    if (font.open_count != 0) return false;
    sys.Remove(&font.node);
    return true;
}
