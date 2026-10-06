// SPDX-License-Identifier: MPL-2.0
//! GetPrefs: the system's settings as they are now.

const sdk = @import("sdk");
const utility = sdk.utility;
const TagItem = utility.TagItem;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _prefs = @import("_prefs.zig");

/// The system's settings as they are now.
///
/// SYNOPSIS:
/// ```zig
/// fn GetPrefs(ib: *IntuitionBase, tags: ?[*]const TagItem) u32
/// ```
///
/// SINCE: 1.0. LVO -464.
///
/// INPUTS:
/// - `ib` - intuition.library's base.
/// - `tags` - the settings wanted, each an `IPREFS_` tag whose data is
///   where its value is written: a `*u32` for `IPREFS_DoubleClick`
///   (milliseconds), `IPREFS_ScreenFontHeight` (rows), `IPREFS_Keyboard`
///   and `IPREFS_OffScreen`; a `*?*graphics.TextFont` for the three fonts; a
///   `*[NUMDRIPENS]graphics.Pen` for `IPREFS_Pens`.
///
/// RESULT:
/// How many were written.
///
/// BEHAVIOR:
/// Each tag asked is written; a data of 0, a tag that is not a setting,
/// and `IPREFS_Style` - a style once read is intuition's own and has no
/// list to give back - are passed over. A font is opened for the caller,
/// as `OpenSystemFont` opens it.
///
/// CONTEXT:
/// - Waits: for a font asked for, while another task sets the fonts.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The storage is the caller's. What is written is a copy: changing it
/// changes nothing until `SetPrefs`. A font written is the caller's to
/// close with `CloseFont`.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `SetPrefs`, `GetDefPrefs`, `OpenSystemFont`
///
/// EXAMPLES:
/// ```zig
/// var ms: u32 = 0;
/// var pens: [sc.NUMDRIPENS]graphics.Pen = undefined;
/// _ = ib.GetPrefs(&[_]TagItem{
///     .{ .tag = intuition.IPREFS_DoubleClick, .data = @intFromPtr(&ms) },
///     .{ .tag = intuition.IPREFS_Pens, .data = @intFromPtr(&pens) },
///     .{},
/// });
/// ```
pub fn GetPrefs(ib: *IntuitionBase, tags: ?[*]const TagItem) u32 {
    return _prefs.answer(ib, tags, false);
}
