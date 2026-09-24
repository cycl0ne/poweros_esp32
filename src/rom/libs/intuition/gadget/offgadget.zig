// SPDX-License-Identifier: MPL-2.0
//! OffGadget: keeps a gadget from being pressed, and shows it so.

const sdk = @import("sdk");
const Object = sdk.intuition.Object;
const Requester = sdk.intuition.Requester;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const Window = @import("../window/_window.zig").Window;
const setDisabled = @import("_gadget.zig").setDisabled;

/// Keeps a gadget from being pressed, and shows it so.
///
/// SYNOPSIS:
/// ```zig
/// fn OffGadget(ib: *IntuitionBase, gadget: *Object, window: *Window,
///     requester: ?*Requester) void
/// ```
///
/// SINCE: 0.10. LVO -244.
///
/// INPUTS:
/// - `gadget` - the gadget.
/// - `window` - the window it is in.
/// - `requester` - the requester it is in, or null for one of the window's
///   own. A gadget knows which requester it is in, so this is not read.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// `GA_Disabled` is set through `SetGadgetAttrsTagList`, and the gadget drawn
/// again - by its class, or with `RefreshGList` when the class leaves that
/// to the caller - ghosted: one pixel in four of its box in the window's
/// block pen. A press on it is swallowed: it goes neither to the gadget nor
/// to one behind it.
///
/// Only this gadget is drawn.
///
/// CONTEXT:
/// - Waits: for the screen list's semaphore and the window's layer.
/// - Interrupts: no.
/// - Forbid: not held and not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing changes hands.
///
/// NOTES:
/// Not while holding the window's layer lock.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `OnGadget`, `SetGadgetAttrsTagList`
///
/// EXAMPLES:
/// ```zig
/// ib.OffGadget(save_button, window, null);
/// ```
pub fn OffGadget(ib: *IntuitionBase, gadget: *Object, window: *Window, requester: ?*Requester) void {
    _ = requester;
    setDisabled(ib, gadget, window, true);
}
