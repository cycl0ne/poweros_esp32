// SPDX-License-Identifier: MPL-2.0
//! UnlockFonts: lets the font list go again.

const sdk = @import("sdk");
const GraphicsBase = @import("../graphics.zig").GraphicsBase;

/// Lets the font list go again.
///
/// SYNOPSIS:
/// ```zig
/// fn UnlockFonts(gb: *GraphicsBase) void
/// ```
///
/// SINCE: 0.19. LVO -296.
///
/// INPUTS:
/// None.
///
/// RESULT:
/// Nothing. A font `NextFont` answered may go from here on, so nothing
/// read from one is to be used past this but what was copied.
///
/// BEHAVIOR:
/// Ends one `LockFonts`; the list may change once every walker has
/// ended theirs.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Forbid: not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The lock goes back.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `LockFonts`, `NextFont`
///
/// EXAMPLES:
/// ```zig
/// gb.LockFonts();
/// defer gb.UnlockFonts();
/// ```
pub fn UnlockFonts(gb: *GraphicsBase) void {
    gb.sys_base.ReleaseSemaphore(&gb.font_lock);
}
