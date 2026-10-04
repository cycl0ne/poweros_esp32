// SPDX-License-Identifier: MPL-2.0
//! SetWindowPointerA: the pointer a window has while it is active.

const sdk = @import("sdk");
const utility = sdk.utility;
const wn = sdk.intuition.windows;
const TagItem = utility.TagItem;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _window = @import("_window.zig");
const Window = _window.Window;
const pointer = @import("../input/pointer.zig");

/// Gives a window its own mouse pointer, the busy pointer, the default, or
/// none at all.
///
/// SYNOPSIS:
/// ```zig
/// fn SetWindowPointerA(ib: *IntuitionBase, window: *Window, tags: ?[*]const TagItem) void
/// ```
///
/// SINCE: 0.18. LVO -452.
///
/// INPUTS:
/// - `window` - the window.
/// - `tags` - any of:
///   - `WA_Pointer` - a `pointerclass` object, or null (the default) for
///     the default pointer.
///   - `WA_BusyPointer` - true for the standard busy pointer in place of
///     `WA_Pointer`'s.
///   - `WA_HidePointer` - true for no pointer at all, in place of either.
///   - `WA_PointerDelay` - true to make the change three tenths of a
///     second from now, unless another comes first.
///   No tags at all is the default pointer again.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// The window keeps the pointer, and the mouse pointer takes it whenever
/// the window is the active one - at once if it is now. With
/// `WA_PointerDelay` the change waits for three of input.device's ticks;
/// another call before then replaces it, so a program that puts up the
/// busy pointer with a delay and takes it down again as soon as a short
/// piece of work is done never shows it. `OpenWindowTagList` takes the
/// same three tags.
///
/// A hidden pointer is hidden only from sight: the mouse still moves it,
/// and the window still hears its moves and buttons - which is what a
/// program drawing a cursor of its own wants.
///
/// The pointer is seen once a mouse has been used: on a touch panel with
/// no mouse the call changes what a mouse would show, and nothing else.
///
/// CONTEXT:
/// - Waits: for the screen list's semaphore.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The pointerclass object stays the caller's and must outlive its use by
/// the window - or be disposed of, which takes it off every window.
///
/// NOTES:
/// A picture the board will not take - too large, or with no alpha - shows
/// the default pointer.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `OpenWindowTagList`, `NewObjectTagList` (pointerclass)
///
/// EXAMPLES:
/// ```zig
/// ib.SetWindowPointerA(window, &.{
///     .{ .tag = wn.WA_BusyPointer, .data = 1 },
///     .{ .tag = wn.WA_PointerDelay, .data = 1 },
///     .{},
/// });
/// work();
/// ib.SetWindowPointerA(window, null);
/// ```
pub fn SetWindowPointerA(ib: *IntuitionBase, window: *Window, tags: ?[*]const TagItem) void {
    const ub = ib.utility_base;
    _window.lock(ib);
    defer _window.unlock(ib);
    const object: ?*sdk.intuition.Object = @ptrFromInt(ub.GetTagData(wn.WA_Pointer, 0, tags));
    const busy = ub.GetTagData(wn.WA_BusyPointer, 0, tags) != 0;
    const hidden = ub.GetTagData(wn.WA_HidePointer, 0, tags) != 0;
    const delayed = ub.GetTagData(wn.WA_PointerDelay, 0, tags) != 0;
    pointer.set(ib, window, object, busy, hidden, delayed);
}
