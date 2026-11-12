// SPDX-License-Identifier: MIT
//! OpenOutlineFont: a family's outline, for drawing it at any size and
//! angle with truetype.library.

const sdk = @import("sdk");
const graphics = sdk.graphics;
const diskfont = sdk.diskfont;
const _base = @import("../diskfont_base.zig");
const DiskfontBase = _base.DiskfontBase;
const _outline = @import("_outline.zig");

/// A family's outline, for drawing it at any size and angle with
/// truetype.library.
///
/// SYNOPSIS:
/// ```zig
/// fn OpenOutlineFont(dfb: *DiskfontBase, name: [*:0]const u8, style: graphics.FontStyle) ?*diskfont.OutlineFont
/// ```
///
/// SINCE: 1.4. LVO -40.
///
/// INPUTS:
/// - `name` - the family's name, "sans.font", or a path to its contents
///   file.
/// - `style` - the styles wanted: `FSF_BOLD` and `FSF_ITALIC` count,
///   the others are a program's own to draw.
///
/// RESULT:
/// The outline, open: its `outline` for truetype.library's calls, and the
/// styles its face is drawn in. Null if the family is not there, has no
/// outline (a family of bitmap sizes only), or its file cannot be read
/// or is no font truetype.library reads, or there is no memory.
///
/// BEHAVIOR:
/// **The family's own face for the styles asked**, where one is
/// installed beside it, as `OpenDiskFont` finds them: `sans-bolditalic.font`,
/// `sans-bold.font`, `sans-italic.font` beside `sans.font`, each only for
/// styles asked, the one drawing the most of them first; the family's
/// own outline otherwise. `style` in the result says which styles the
/// face is drawn in, so a program can draw the rest - lean it for an
/// italic the family has no face of.
///
/// The face's font file is read whole and opened once: everyone who
/// asks for it is given the same, until the last has closed it. It then
/// stays, for the next to ask, until memory runs short. truetype.library
/// is opened the first time an outline is.
///
/// CONTEXT:
/// - Waits: yes: for the disk, and for another task loading a font.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: a Process, since it reads files.
///
/// OWNERSHIP:
/// The outline is the library's, shared; the caller holds it open until
/// `CloseOutlineFont`, and keeps diskfont.library open as long. It does
/// not call truetype.library's `CloseOutline` on it. The calls that read
/// it - `GlyphSegments` and the rest - change nothing in it, so any
/// number of tasks may read it at once.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CloseOutlineFont`, `OpenDiskFont`, `truetype.library/GlyphSegments`
///
/// EXAMPLES:
/// ```zig
/// const face = dfb.OpenOutlineFont("serif.font", sdk.graphics.FSF_ITALIC) orelse return error.NoFont;
/// defer dfb.CloseOutlineFont(face);
/// const glyph = tb.GlyphIndex(face.outline, 'g');
/// ```
pub fn OpenOutlineFont(dfb: *DiskfontBase, name: [*:0]const u8, style: graphics.FontStyle) ?*diskfont.OutlineFont {
    const sys = dfb.sys_base;
    sys.ObtainSemaphore(&dfb.load_lock);
    defer sys.ReleaseSemaphore(&dfb.load_lock);
    return _outline.open(dfb, name, style);
}
