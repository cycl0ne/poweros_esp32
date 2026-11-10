// SPDX-License-Identifier: MIT
//! CloseOutlineFont: what OpenOutlineFont gave, given back.

const sdk = @import("sdk");
const diskfont = sdk.diskfont;
const _base = @import("../diskfont_base.zig");
const DiskfontBase = _base.DiskfontBase;
const _outline = @import("_outline.zig");

/// What OpenOutlineFont gave, given back.
///
/// SYNOPSIS:
/// ```zig
/// fn CloseOutlineFont(dfb: *DiskfontBase, font: ?*diskfont.OutlineFont) void
/// ```
///
/// SINCE: 1.4. LVO -44.
///
/// INPUTS:
/// - `font` - what `OpenOutlineFont` answered, or null.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// One holder fewer; null does nothing. The last one's close leaves the
/// outline loaded, for the next to ask for it, until memory runs short.
///
/// CONTEXT:
/// - Waits: yes: for another task loading a font.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The outline is no longer the caller's to read.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `OpenOutlineFont`
///
/// EXAMPLES:
/// ```zig
/// dfb.CloseOutlineFont(face);
/// ```
pub fn CloseOutlineFont(dfb: *DiskfontBase, font: ?*diskfont.OutlineFont) void {
    const held = font orelse return;
    const sys = dfb.sys_base;
    sys.ObtainSemaphore(&dfb.load_lock);
    defer sys.ReleaseSemaphore(&dfb.load_lock);
    _outline.close(held);
}
