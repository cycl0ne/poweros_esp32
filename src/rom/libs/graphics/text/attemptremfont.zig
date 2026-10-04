// SPDX-License-Identifier: MPL-2.0
//! AttemptRemFont: RemFont that never waits.

const sdk = @import("sdk");
const GraphicsBase = @import("../graphics.zig").GraphicsBase;
const _text = @import("_text.zig");
const TextFont = _text.TextFont;

/// RemFont that never waits.
///
/// SYNOPSIS:
/// ```zig
/// fn AttemptRemFont(gb: *GraphicsBase, font: *TextFont) bool
/// ```
///
/// SINCE: 0.19. LVO -300.
///
/// INPUTS:
/// - `font` - a font, on the list or not.
///
/// RESULT:
/// True once the font is off the list, as `RemFont`. False while
/// anything has it open, and false when another task holds the font
/// list just now - where `RemFont` would wait for it.
///
/// BEHAVIOR:
/// The one way to take a font off from where waiting is not allowed: a
/// low-memory handler runs inside AllocMem, whose caller may hold
/// anything, and a font loader freeing the fonts nobody holds there calls
/// this, skipping any it cannot have.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: any may be held: it only tries the font list's lock, which is what
///   it is for.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// As `RemFont`: on true the font is the caller's to free.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `RemFont`, `AddFont`
///
/// EXAMPLES:
/// ```zig
/// if (gb.AttemptRemFont(font)) sys.FreeVec(record);
/// ```
pub fn AttemptRemFont(gb: *GraphicsBase, font: *TextFont) bool {
    const sys = gb.sys_base;
    if (!sys.AttemptSemaphore(&gb.font_lock)) return false;
    defer sys.ReleaseSemaphore(&gb.font_lock);
    return _text.takeOff(gb, font);
}
