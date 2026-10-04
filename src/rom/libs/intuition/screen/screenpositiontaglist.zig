// SPDX-License-Identifier: MPL-2.0
//! ScreenPositionTagList: a screen put where its tags say on its display.

const sdk = @import("sdk");
const utility = sdk.utility;
const sc = sdk.intuition.screens;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _screen = @import("_screen.zig");
const Screen = _screen.Screen;

/// Puts a screen at a place on its display, or moves it by an amount.
///
/// SYNOPSIS:
/// ```zig
/// fn ScreenPositionTagList(ib: *IntuitionBase, screen: *Screen, tags: ?[*]const utility.TagItem) void
/// ```
///
/// SINCE: 0.29. LVO -504.
///
/// INPUTS:
/// - `screen` - the screen.
/// - `tags`:
///   - `SPOS_Top` (i32) - the display line its top edge goes to, or with
///     `SPOS_Relative` how far down it moves (up for less than 0); left
///     where it is without the tag.
///   - `SPOS_Left` (i32) - the same across; screens are as wide as their
///     display, so it stays at 0.
///   - `SPOS_Relative` (bool) - the two are a move, not a place (false).
///   - `SPOS_ForceDrag` (bool) - move a screen opened with
///     `{SA_Draggable, false}` as well (false).
///
/// RESULT:
/// Nothing. GetScreenAttrs' `SA_Top` says where it went.
///
/// BEHAVIOR:
/// As `MoveScreen`: the screen goes as far as it may - not above the top,
/// its bar kept on the glass - and the screens behind show above it. A
/// screen that may not be dragged moves only with `SPOS_ForceDrag`; an
/// exclusive one stays at the top.
///
/// CONTEXT:
/// - Waits: for the screen list's semaphore, and for the display to take
///   the new picture up at its next frame.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing changes hands. The tags are read, not kept.
///
/// NOTES:
/// Only the screen's owner should set `SPOS_ForceDrag`: a screen that may
/// not be dragged is that way for a reason of its own.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `MoveScreen`, `ScreenDepth`, `GetScreenAttrs`
///
/// EXAMPLES:
/// ```zig
/// // Half way down the display.
/// ib.ScreenPositionTagList(screen, &[_]utility.TagItem{
///     .{ .tag = sc.SPOS_Top, .data = 300 },
///     .{},
/// });
/// ```
pub fn ScreenPositionTagList(ib: *IntuitionBase, screen: *Screen, tags: ?[*]const utility.TagItem) void {
    const ub = ib.utility_base;
    _screen.lock(ib);
    defer _screen.unlock(ib);
    if (!screen.draggable and ub.GetTagData(sc.SPOS_ForceDrag, 0, tags) == 0) return;
    const item = ub.FindTagItem(sc.SPOS_Top, tags) orelse return;
    const value: i32 = @truncate(@as(isize, @bitCast(item.data)));
    const top = if (ub.GetTagData(sc.SPOS_Relative, 0, tags) != 0) screen.top +| value else value;
    _screen.moveTo(ib, screen, top);
}
