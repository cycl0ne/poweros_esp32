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
/// rather than trusted. True once it is off the list - also when it was
/// not on it - so true means nobody holds it and nobody can open it: the
/// one test a builder needs before freeing it.
///
/// BEHAVIOR:
/// The font leaves the list, so `OpenFont` no longer finds it; a font
/// still open is refused. The count and the list are read and changed
/// under the font list's lock, so no `OpenFont` can open it between the
/// test and the removal.
///
/// CONTEXT:
/// - Waits: yes, while another task holds the font list.
/// - Interrupts: no.
/// - Locks: no spinlock may be held: it waits for the font list's semaphore.
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
    return _text.takeOff(gb, font);
}
