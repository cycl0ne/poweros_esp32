// SPDX-License-Identifier: MPL-2.0
//! FindWindowNumber: the window with a number, while it is open.

const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _window = @import("_window.zig");
const Window = _window.Window;
const lock = _window.lock;
const unlock = _window.unlock;

/// The open window with a number, or null once it has closed.
///
/// SYNOPSIS:
/// ```zig
/// fn FindWindowNumber(ib: *IntuitionBase, number: u32) ?*Window
/// ```
///
/// SINCE: 0.47. LVO -524.
///
/// INPUTS:
/// - `number` - a window's number, as `GetWindowAttrs` read it
///   (`WA_Number`).
///
/// RESULT:
/// The window, or null when no open window has the number - it has
/// closed, or the number was never one.
///
/// BEHAVIOR:
/// Every screen's windows are looked through. A number is given to one
/// window and never again while the machine runs, so the answer is that
/// window or nothing - never another window opened since in the memory
/// the first one had, which a pointer kept and compared would take for
/// it.
///
/// CONTEXT:
/// - Waits: yes, for the screens' semaphore.
/// - Interrupts: no.
/// - Locks: no layer's lock may be held (`LockIBase`).
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The window is its opener's. It stays open only while the caller holds
/// `LockIBase`: without it, the window may close the moment the answer is
/// given.
///
/// NOTES:
/// - What another task draws into keeps the number: a library rendering
///   into a program's window from a task of its own - the program may end,
///   and its windows close with it, at any time - finds the window under
///   `LockIBase`, takes the window's layer, lets the screens go and draws,
///   and finds it gone instead of drawing into memory that was freed.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `GetWindowAttrs`, `LockIBase`, `OpenWindowTagList`
///
/// EXAMPLES:
/// ```zig
/// const held = ib.LockIBase(0);
/// const window = ib.FindWindowNumber(number) orelse {
///     ib.UnlockIBase(held);
///     return error.WindowClosed;
/// };
/// var layer: usize = 0;
/// const ask = [_]TagItem{ .{ .tag = WA_Layer, .data = @intFromPtr(&layer) }, .{} };
/// ib.GetWindowAttrs(window, &ask);
/// layers_base.LockLayer(@ptrFromInt(layer));
/// ib.UnlockIBase(held);
/// ```
pub fn FindWindowNumber(ib: *IntuitionBase, number: u32) ?*Window {
    if (number == 0) return null;
    lock(ib);
    defer unlock(ib);
    const Search = struct { number: u32, found: ?*Window = null };
    var search = Search{ .number = number };
    _window.eachWindow(ib, &search, struct {
        fn visit(context: *Search, w: *Window) void {
            if (w.number == context.number) context.found = w;
        }
    }.visit);
    return search.found;
}
