// SPDX-License-Identifier: MPL-2.0
//! LockFonts: holds the font list still, for a walk with NextFont.

const sdk = @import("sdk");
const GraphicsBase = @import("../graphics.zig").GraphicsBase;

/// Holds the font list still, for a walk with NextFont.
///
/// SYNOPSIS:
/// ```zig
/// fn LockFonts(gb: *GraphicsBase) void
/// ```
///
/// SINCE: 0.19. LVO -288.
///
/// INPUTS:
/// None.
///
/// RESULT:
/// Nothing. The list cannot change until `UnlockFonts`.
///
/// BEHAVIOR:
/// The lock is shared: any number of tasks may walk the list at once,
/// and a task that adds, removes, opens or closes a font waits until the
/// last of them lets go. That includes the task holding it, so between
/// `LockFonts` and `UnlockFonts` the only font call is `NextFont`.
///
/// CONTEXT:
/// - Waits: yes, while a task changes the list.
/// - Interrupts: no.
/// - Locks: no spinlock may be held: it may wait.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The lock is the caller's until `UnlockFonts`.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `NextFont`, `UnlockFonts`
///
/// EXAMPLES:
/// ```zig
/// gb.LockFonts();
/// var font = gb.NextFont(null);
/// while (font) |f| : (font = gb.NextFont(f)) count += 1;
/// gb.UnlockFonts();
/// ```
pub fn LockFonts(gb: *GraphicsBase) void {
    gb.sys_base.ObtainSemaphoreShared(&gb.font_lock);
}
