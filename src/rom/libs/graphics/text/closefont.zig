// SPDX-License-Identifier: MPL-2.0
//! CloseFont: gives a font back.

const sdk = @import("sdk");
const exec = sdk.exec;
const graphics = sdk.graphics;
const rtg = sdk.rtg;
const TagItem = sdk.utility.TagItem;
const GraphicsBase = @import("../graphics.zig").GraphicsBase;
const _text = @import("_text.zig");
const TextFont = _text.TextFont;

/// Gives a font back.
///
/// SYNOPSIS:
/// ```zig
/// fn CloseFont(gb: *GraphicsBase, font: ?*TextFont) void
/// ```
///
/// SINCE: 0.11. LVO -128.
///
/// INPUTS:
/// - `font` - the font, or null, which does nothing.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// One open given back. A font in the ROM stays whatever the count says.
///
/// CONTEXT:
/// - Waits: yes, while another task holds the font list.
/// - Interrupts: no.
/// - Forbid: must not be held: it waits on the font list's semaphore.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The caller's open is gone.
///
/// NOTES:
/// - A RastPort still drawing with it should be given another font first.
///   Nothing goes wrong today, since a font in the ROM stays, but that is
///   the ROM's doing rather than this call's.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `OpenFont`, `RemFont`
///
/// EXAMPLES:
/// ```zig
/// gb.CloseFont(font);
/// ```
pub fn CloseFont(gb: *GraphicsBase, font: ?*TextFont) void {
    const f = font orelse return;
    const sys = gb.sys_base;
    // The count RemFont reads, changed where RemFont cannot be halfway.
    sys.ObtainSemaphore(&gb.font_lock);
    defer sys.ReleaseSemaphore(&gb.font_lock);
    if (f.open_count != 0) f.open_count -= 1;
}
