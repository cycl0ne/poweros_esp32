// SPDX-License-Identifier: MPL-2.0
//! HelpControl: turns gadget help on or off for a window's help group.

const sdk = @import("sdk");
const wn = sdk.intuition.windows;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _window = @import("../window/_window.zig");
const Window = _window.Window;

/// Turns gadget help on or off for a window and its help group.
///
/// SYNOPSIS:
/// ```zig
/// fn HelpControl(ib: *IntuitionBase, window: *Window, flags: u32) void
/// ```
///
/// SINCE: 0.14. LVO -424.
///
/// INPUTS:
/// - `window` - the window.
/// - `flags` - `HC_GADGETHELP` for on, 0 for off.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// Every window of the window's help group (`WA_HelpGroup`) is changed
/// with it. With help on, while one of them is active, each time the
/// pointer comes to rest somewhere new the window under it is sent
/// IDCMP_GADGETHELP: the help-aware gadget there (`GA_GadgetHelp`), or the
/// window itself; and the active window is sent one with a null address
/// when the pointer is over no window of the group. Only a window whose
/// IDCMP asks for IDCMP_GADGETHELP hears it.
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
/// "Rest" is the pointer having moved no more than six pixels across and
/// three down between two of intuition's timer events, which come ten
/// times a second.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `OpenWindowTagList` (`WA_HelpGroup`), `ModifyIDCMP`
///
/// EXAMPLES:
/// ```zig
/// ib.HelpControl(window, wn.HC_GADGETHELP); // the Help key was pressed
/// ```
pub fn HelpControl(ib: *IntuitionBase, window: *Window, flags: u32) void {
    _window.lock(ib);
    defer _window.unlock(ib);
    const Change = struct { group: u32, on: bool };
    const change = Change{ .group = window.help_group, .on = flags & wn.HC_GADGETHELP != 0 };
    _window.eachWindow(ib, change, struct {
        fn visit(c: Change, w: *Window) void {
            if (w.help_group != c.group) return;
            if (c.on) w.more_flags |= _window.WMF_GADGETHELP else w.more_flags &= ~_window.WMF_GADGETHELP;
        }
    }.visit);
}
