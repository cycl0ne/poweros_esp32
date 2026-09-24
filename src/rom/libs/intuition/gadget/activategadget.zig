// SPDX-License-Identifier: MPL-2.0
//! ActivateGadget: gives a gadget the input without it being pressed.

const sdk = @import("sdk");
const Object = sdk.intuition.Object;
const Requester = sdk.intuition.Requester;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _window = @import("../window/_window.zig");
const Window = _window.Window;
const _input = @import("../input/_input.zig");

/// Gives a gadget the input without it being pressed.
///
/// SYNOPSIS:
/// ```zig
/// fn ActivateGadget(ib: *IntuitionBase, gadget: *Object, window: *Window, requester: ?*Requester) bool
/// ```
///
/// SINCE: 0.12. LVO -292.
///
/// INPUTS:
/// - `gadget` - a gadget on the window's list, or of the requester in front
///   in it.
/// - `window` - its window, which must be the active one.
/// - `requester` - the requester the gadget is in, or null for one of the
///   window's own.
///
/// RESULT:
/// True when the gadget has the input; false otherwise.
///
/// BEHAVIOR:
/// The gadget is sent `GM_GOACTIVE` with no input event - which is how a
/// class tells this from a press - as Tab does when it arrives at a gadget.
/// If it answers `GMR_MEACTIVE` it has every event from then on until it
/// is done, as though it had been clicked: a strgclass line takes the keys
/// at once, its cursor shown. A gadget that answers anything else is done
/// straight away, and the window is told as for a press (`IDCMP_GADGETUP`
/// with `GA_RelVerify`).
///
/// Nothing is interrupted to make room for it: it fails when the window is
/// not the active one, when a gadget or a border gadget already has the
/// pointer or the input, while a menu session runs, when the gadget is
/// disabled or not on this window, and when `requester` is not the one it
/// is in. While a requester is up only a gadget of the one in front may
/// be given the input, since the window's own do not take any.
///
/// CONTEXT:
/// - Waits: for the screen list's semaphore.
/// - Interrupts: no.
/// - Forbid: not held and not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing changes hands.
///
/// NOTES:
/// A window is not necessarily active the moment `OpenWindowTagList`
/// returns with `WA_Activate`; a program that wants a field ready for typing
/// calls this when `IDCMP_ACTIVEWINDOW` arrives, and again after the field
/// is done if it should stay ready.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `DoGadgetMethodA`, `AddGList`, `ActivateWindow`
///
/// EXAMPLES:
/// ```zig
/// if (message.class == IDCMP_ACTIVEWINDOW) _ = ib.ActivateGadget(name_field, window, null);
/// ```
pub fn ActivateGadget(ib: *IntuitionBase, gadget: *Object, window: *Window, requester: ?*Requester) bool {
    _window.lock(ib);
    defer _window.unlock(ib);
    return _input.activateFor(ib, window, gadget, requester);
}
