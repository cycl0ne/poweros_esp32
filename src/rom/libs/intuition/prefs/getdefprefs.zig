// SPDX-License-Identifier: MPL-2.0
//! GetDefPrefs: the settings the system starts with.

const sdk = @import("sdk");
const utility = sdk.utility;
const TagItem = utility.TagItem;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _prefs = @import("_prefs.zig");

/// The settings the system starts with.
///
/// SYNOPSIS:
/// ```zig
/// fn GetDefPrefs(ib: *IntuitionBase, tags: ?[*]const TagItem) u32
/// ```
///
/// SINCE: 1.0. LVO -468.
///
/// INPUTS:
/// - `ib` - intuition.library's base.
/// - `tags` - the settings wanted, as `GetPrefs` takes them.
///
/// RESULT:
/// How many were written.
///
/// BEHAVIOR:
/// What the system is born with, whatever has been set since: a
/// double-click of 1500 milliseconds, a screen font 16 rows tall, the
/// keyboard on the screen on a board with none, pospaz from the ROM for
/// all three fonts, the built-in pens. Written as `GetPrefs` writes them;
/// what a settings editor's "use the defaults" hands to `SetPrefs`. The
/// style is the default when none is set: `IPREFS_Style` with null.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The storage is the caller's; a font written is the caller's to close.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `GetPrefs`, `SetPrefs`
///
/// EXAMPLES:
/// ```zig
/// var ms: u32 = 0;
/// _ = ib.GetDefPrefs(&[_]TagItem{ .{ .tag = intuition.IPREFS_DoubleClick, .data = @intFromPtr(&ms) }, .{} });
/// _ = ib.SetPrefs(&[_]TagItem{ .{ .tag = intuition.IPREFS_DoubleClick, .data = ms }, .{} });
/// ```
pub fn GetDefPrefs(ib: *IntuitionBase, tags: ?[*]const TagItem) u32 {
    return _prefs.answer(ib, tags, true);
}
