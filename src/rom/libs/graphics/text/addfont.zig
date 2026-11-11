// SPDX-License-Identifier: MPL-2.0
//! AddFont: puts a font on the library's list.

const sdk = @import("sdk");
const exec = sdk.exec;
const graphics = sdk.graphics;
const rtg = sdk.rtg;
const TagItem = sdk.utility.TagItem;
const GraphicsBase = @import("../graphics.zig").GraphicsBase;
const _text = @import("_text.zig");
const kept = @import("_kept.zig");
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
/// - `font` - a font somebody built: `node.name` its name, `image` its
///   glyphs, `fallback` the font with the characters it lacks, `render`
///   the hook that makes the glyphs the image does not hold. The name,
///   height and style are what `OpenFont` weighs.
///
/// RESULT:
/// False if it is already on the list, if its image does not hold
/// together (`fontimage.check`): a table or a glyph's pixels outside the
/// block, ranges out of order, or no default character - or, for a font
/// with a `render` hook, without the memory to keep its glyphs in.
///
/// BEHAVIOR:
/// This is the way in for fonts that are not in this ROM. Something that
/// reads a font out of a file builds a `TextFont` and calls this, and a
/// later plain `OpenFont` finds it - which is why `OpenFont` walks a list.
/// The count of who has it open starts at 0.
///
/// A font with a `render` hook draws more than its image holds (since
/// 0.41). A character the image has no glyph for is asked of the hook,
/// with a `GlyphRequest`, on the task that draws it and the first time
/// it is drawn or measured; the glyph the hook writes is kept with the
/// font until `RemFont`, and so is the answer that the font has none,
/// so each is asked for once. Two tasks that want the same glyph at the
/// same moment get one rendering: the second waits for the first. A
/// font that was never added draws from its image alone.
/// The library itself never reads files, for the same reason rtg.library
/// does not read the board file and ramlib exists rather than exec loading
/// libraries itself: each layer keeps to what it can do on its own.
///
/// CONTEXT:
/// - Waits: yes, while another task holds the font list.
/// - Interrupts: no.
/// - Locks: no spinlock may be held: it waits for the font list's semaphore.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The font, its name, its image and its hook stay the caller's. The
/// library only holds it on a list, and `RemFont` takes it off again;
/// the caller frees it after that, never before. The glyphs the hook
/// made are the library's, in memory of the system's, and `RemFont`
/// frees them; `TextFont.cache` is the library's to write.
///
/// NOTES:
/// The hook runs on the stack of whatever task draws the text, and
/// under the lock of the font's kept glyphs: it reads no file and waits
/// for nothing a drawing task may hold.
///
/// BUGS:
/// The glyphs a font has made stay until the font leaves the list: a
/// font that is always open only ever holds more.
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
    // Text draws from the image without checking anything again, so a
    // block that would have it read past its end is refused here, once.
    if (!graphics.fontimage.check(@ptrCast(font.image), font.image.size)) return false;
    sys.ObtainSemaphore(&gb.font_lock);
    defer sys.ReleaseSemaphore(&gb.font_lock);
    var at = gb.fonts.first();
    while (at) |node| : (at = node.succ) {
        if (node.succ == null) break;
        if (node == &font.node) return false;
    }
    // Where the glyphs its hook makes are kept, for a font that has one.
    if (!kept.make(gb, font)) return false;
    font.open_count = 0;
    font.node.type = .font;
    sys.AddTail(&gb.fonts, &font.node);
    return true;
}
