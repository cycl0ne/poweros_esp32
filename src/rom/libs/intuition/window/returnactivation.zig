// SPDX-License-Identifier: MPL-2.0
//! ReturnActivation: a window that took the keyboard for a while gives it
//! back to the window it took it from.
//!
//! Each window keeps the number of the window that was the active one
//! when it last became it (`activated_from`, set as it is activated), and
//! the gadget of its own that had the input when it last stopped being
//! the active one (`input_left`, set as the gadget is told it has lost
//! the input - the window made inactive under it, or a press on another
//! window - and forgotten when the gadget leaves the window). The call
//! finds the first by its number, makes it the active one, and gives the
//! second the input as `ActivateGadget` would.

const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _input = @import("../input/_input.zig");
const _window = @import("_window.zig");
const gadgetclass = @import("../classes/gadgetclass.zig");
const Window = _window.Window;
const activate = _window.activate;
const lock = _window.lock;
const unlock = _window.unlock;

/// Gives the keyboard back to the window `window` took it from.
///
/// SYNOPSIS:
/// ```zig
/// fn ReturnActivation(ib: *IntuitionBase, window: *Window) bool
/// ```
///
/// SINCE: 0.95. LVO -560.
///
/// INPUTS:
/// - `window` - the window that took the keyboard: one of the caller's.
///
/// RESULT:
/// True when the window `window` took the keyboard from is the active
/// one. False, with nothing changed, when no window was active as
/// `window` last became it, when that window has closed since, and when
/// it cannot be made active - it is hidden, or never takes the
/// activation.
///
/// BEHAVIOR:
/// The window that was the active one when `window` last became it is
/// made the active one, as `ActivateWindow` makes it. If a gadget of it
/// had the input at that time - a string being typed into - and is still
/// in the window, that gadget is given the input again, as
/// `ActivateGadget` gives it: typing goes on where it was.
///
/// That is what a window does that is worked in for a moment on behalf of
/// another: one a character is picked from, which is then typed
/// (`AddIEvents`) into the text its user was writing. A press on such a
/// window has made it the active one by the time its program hears of the
/// press, and has taken the input from the gadget that had it; this call
/// undoes both.
///
/// It goes by `window`, not by which window is active now, so it does the
/// same when a third window has become the active one meanwhile. The
/// gadget is given the input only when the activation moves: when the
/// window to go back to is the active one already, its input is left as
/// it is.
///
/// CONTEXT:
/// - Waits: for the screen list's semaphore, and the layers' locks.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing changes hands.
///
/// NOTES:
/// - A gadget takes the input back only if `ActivateGadget` would give it
///   to it: one disabled since, or in a requester that is no longer the
///   one in front, is passed by, and the window is active without it.
/// - A window made active any other way - a press on it, `ActivateWindow`
///   - leaves its gadgets as they are: the gadget that had the input waits
///   to be chosen.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ActivateWindow`, `ActivateGadget`, `FindWindowNumber`
///
/// EXAMPLES:
/// ```zig
/// // A character picked in `window`: typed where its user was writing.
/// if (ib.ReturnActivation(window)) {
///     var typed = ie.InputEvent{ .class = ie.IECLASS_CHARACTER, .code = 0x1F600 };
///     cb.AddIEvents(&typed);
/// } else {
///     ib.DisplayBeep(null);
/// }
/// ```
pub fn ReturnActivation(ib: *IntuitionBase, window: *Window) bool {
    lock(ib);
    defer unlock(ib);
    const found = ib.iface().FindWindowNumber(window.activated_from) orelse return false;
    const from: *Window = @ptrCast(@alignCast(found));
    const before = ib.active_window;
    // Read first: a window made active is one whose gadget has not lost
    // the input.
    const gadget = from.input_left;
    activate(ib, from);
    if (ib.active_window != from) return false;
    if (before == from) return true;
    if (gadget) |o| _ = _input.activateFor(ib, from, o, gadgetclass.gadgetOf(ib, o).requester);
    return true;
}
