// SPDX-License-Identifier: MPL-2.0
//! AddFont: puts a font on the library's list.

const sdk = @import("sdk");
const exec = sdk.exec;
const graphics = sdk.graphics;
const rtg = sdk.rtg;
const TagItem = sdk.utility.TagItem;
const GraphicsBase = @import("../graphics.zig").GraphicsBase;
const _text = @import("_text.zig");
const TextFont = _text.TextFont;

/// Puts a font on the library's list.
///
/// SYNOPSIS:
/// ```zig
/// fn AddFont(gb: *GraphicsBase, font: *TextFont) bool
/// ```
///
/// SINCE: 0.15. LVO -176.
///
/// INPUTS:
/// - `font` - a font somebody built. Its name and height are what
///   `OpenFont` will match on.
///
/// RESULT:
/// False if it is already on the list.
///
/// BEHAVIOR:
/// This is the way in for fonts that are not in this ROM. Something that
/// reads a font out of a file builds a `TextFont` and calls this, and a
/// later plain `OpenFont` finds it - which is why `OpenFont` walks a list.
/// The library itself never reads files, for the same reason rtg.library
/// does not read the board file and ramlib exists rather than exec loading
/// libraries itself: each layer keeps to what it can do on its own.
///
/// CONTEXT:
/// - Waits: yes, while another task holds the font list.
/// - Interrupts: no.
/// - Forbid: must not be held: it waits on the font list's semaphore.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The font stays the caller's. The library only holds it on a list, and
/// `RemFont` takes it off again.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `RemFont`, `OpenFont`
///
/// EXAMPLES:
/// ```zig
/// if (!gb.AddFont(loaded)) return error.AlreadyThere;
/// ```
pub fn AddFont(gb: *GraphicsBase, font: *TextFont) bool {
    const sys = gb.sys_base;
    sys.ObtainSemaphore(&gb.font_lock);
    defer sys.ReleaseSemaphore(&gb.font_lock);
    var at = gb.fonts.first();
    while (at) |node| : (at = node.succ) {
        if (node.succ == null) break;
        if (node == &font.node) return false;
    }
    font.node.name = font.name;
    sys.AddTail(&gb.fonts, &font.node);
    return true;
}
