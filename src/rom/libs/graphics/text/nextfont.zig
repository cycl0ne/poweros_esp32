// SPDX-License-Identifier: MPL-2.0
//! NextFont: the fonts on the list, one after another.

const sdk = @import("sdk");
const GraphicsBase = @import("../graphics.zig").GraphicsBase;
const _text = @import("_text.zig");
const TextFont = _text.TextFont;

/// The fonts on the list, one after another.
///
/// SYNOPSIS:
/// ```zig
/// fn NextFont(gb: *GraphicsBase, previous: ?*TextFont) ?*TextFont
/// ```
///
/// SINCE: 0.19. LVO -292.
///
/// INPUTS:
/// - `previous` - the font `NextFont` answered last, or null to start.
///
/// RESULT:
/// The next font on the list, or null after the last.
///
/// BEHAVIOR:
/// A font answered is not opened: it is there to be read - its name,
/// its image's measures, its flags - while `LockFonts` holds the list,
/// and to be opened by what it says with `OpenFont` after.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do; it must hold `LockFonts`.
///
/// OWNERSHIP:
/// Nothing changes hands; the font is the list's.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `LockFonts`, `UnlockFonts`, `OpenFont`
///
/// EXAMPLES:
/// ```zig
/// gb.LockFonts();
/// defer gb.UnlockFonts();
/// var font = gb.NextFont(null);
/// while (font) |f| : (font = gb.NextFont(f)) show(f.node.name.?, f.image.height);
/// ```
pub fn NextFont(gb: *GraphicsBase, previous: ?*TextFont) ?*TextFont {
    const node = if (previous) |font| font.node.next() else gb.fonts.first();
    const found = node orelse return null;
    return @fieldParentPtr("node", found);
}
