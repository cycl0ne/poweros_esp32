// SPDX-License-Identifier: MIT
//! DisposeFontContents: frees what NewFontContents made.

const sdk = @import("sdk");
const fontfile = sdk.diskfont.fontfile;
const _base = @import("../diskfont_base.zig");
const DiskfontBase = _base.DiskfontBase;

/// Frees what NewFontContents made.
///
/// SYNOPSIS:
/// ```zig
/// fn DisposeFontContents(dfb: *DiskfontBase, contents: ?*fontfile.ContentsHeader) void
/// ```
///
/// SINCE: 1.0. LVO -32.
///
/// INPUTS:
/// - `contents` - what `NewFontContents` answered, or null.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// The image goes back to the system; null does nothing.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The image is gone; nothing may read it after.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `NewFontContents`
///
/// EXAMPLES:
/// ```zig
/// dfb.DisposeFontContents(made);
/// ```
pub fn DisposeFontContents(dfb: *DiskfontBase, contents: ?*fontfile.ContentsHeader) void {
    dfb.sys_base.FreeVec(contents);
}
