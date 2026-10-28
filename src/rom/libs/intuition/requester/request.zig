// SPDX-License-Identifier: MPL-2.0
//! Request: puts a requester up in a window.

const sdk = @import("sdk");
const Requester = sdk.intuition.Requester;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _window = @import("../window/_window.zig");
const Window = _window.Window;
const _requester = @import("_requester.zig");

/// Puts a requester up in a window.
///
/// SYNOPSIS:
/// ```zig
/// fn Request(ib: *IntuitionBase, requester: *Requester, window: *Window) bool
/// ```
///
/// SINCE: 0.13. LVO -304.
///
/// INPUTS:
/// - `requester` - what it is: its box, gadgets, image and flags.
/// - `window` - the window it goes up in.
///
/// RESULT:
/// True when it is up; false when there was no memory for its layer, or
/// it is already up.
///
/// BEHAVIOR:
/// The requester becomes a layer in front of the window and of every
/// requester already up in it, cut at the window's inner edges. With
/// `POINTREL` it is put at the middle of the window, moved by `rel_left`
/// and `rel_top`, and kept inside it; otherwise at `left` and `top`. Its
/// face is drawn: the box filled with `back_fill` unless `NOREQBACKFILL`,
/// its image over that, then its gadgets. The window gets `IDCMP_REQSET`
/// with the requester in `iaddress`, and `WFLG_INREQUEST` is set.
///
/// From then on a press on the window reaches only this requester's
/// gadgets. Its drag bar, depth, zoom and size gadgets still work; its
/// close gadget, its own gadgets, its menus and its keys do not - the keys
/// reach a gadget of the requester that has the input, and with
/// `NOISYREQ` whatever the requester does not use still reaches the window
/// as `IDCMP_MOUSEBUTTONS`, `IDCMP_RAWKEY` and the rest. The requester moves
/// with the window and stays in front of it.
///
/// A popup (`POPUPREQ`) is one a gadget puts up from where it is pressed,
/// its `owner`: a gadget of it used the way that counts takes it down
/// after the window has had its `IDCMP_GADGETUP`, and so do a press
/// anywhere but on it - which does nothing else - the menu button, Escape,
/// and the window losing the activation. The owner is told with
/// `GM_POPDOWN` once what the popup covered is back. An owner can be a
/// gadget of a popup itself: a gadget used in the popup it put up takes
/// that one down too, while a press beside the newer one, Escape and the
/// menu button take down that one alone. A popup is not cut at the
/// window: it lies in front of every window, cut only at the screen's
/// edges, and is moved onto the screen - its `left` and `top` changed - as
/// it is put up where some of it would be off it.
///
/// CONTEXT:
/// - Waits: for the screen list's semaphore and the layers' locks.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do; intuition's own too, from a gadget's
///   `GM_GOACTIVE`, which is where a popup is put up.
///
/// OWNERSHIP:
/// The requester, its gadgets and its image stay the caller's and must
/// stay where they are, unchanged, until `EndRequest` or an end gadget
/// takes it down. A gadget of it must not be on any other list meanwhile.
///
/// NOTES:
/// A gadget with `GA_EndGadget` takes the requester down when it is used,
/// after the window has had its `IDCMP_GADGETUP`; the window hears
/// `IDCMP_REQCLEAR` then as for `EndRequest`.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `EndRequest`, `InitRequester`, `SetDMRequest`,
/// `sdk.intuition.requesters.Requester`
///
/// EXAMPLES:
/// ```zig
/// ib.InitRequester(&box);
/// box.width = 200;
/// box.height = 60;
/// box.flags = POINTREL;
/// box.gadgets = ok_button;
/// if (!ib.Request(&box, window)) return error.NoMemory;
/// ```
pub fn Request(ib: *IntuitionBase, requester: *Requester, window: *Window) bool {
    _window.lock(ib);
    defer _window.unlock(ib);
    return _requester.put(ib, window, requester, false);
}
