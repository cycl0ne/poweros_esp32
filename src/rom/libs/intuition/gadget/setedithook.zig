// SPDX-License-Identifier: MPL-2.0
//! SetEditHook: the global edit hook every string gadget's keys go through.

const sdk = @import("sdk");
const utility = sdk.utility;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _window = @import("../window/_window.zig");

/// Puts the global edit hook every string gadget's keys go through first.
///
/// SYNOPSIS:
/// ```zig
/// fn SetEditHook(ib: *IntuitionBase, hook: ?*Hook) *Hook
/// ```
///
/// SINCE: 0.14. LVO -428.
///
/// INPUTS:
/// - `hook` - the new global hook, or null for intuition's own editing
///   again.
///
/// RESULT:
/// The hook it replaces - intuition's own the first time.
///
/// BEHAVIOR:
/// For every key typed into a strgclass gadget, the global hook is called
/// with the `SGWork` and `SGH_KEY` (`sghooks.zig`) before the gadget's own
/// hook. It *is* the editing: a hook that calls none other decides alone
/// what every key does. A hook that means to add to intuition's editing
/// rather than replace it calls the hook this answered for the keys it
/// leaves alone, with the same object and message, through
/// `CallHookPkt`.
///
/// CONTEXT:
/// - Waits: for the screen list's semaphore.
/// - Interrupts: no.
/// - Forbid: not held and not needed.
/// - Process: a Task will do. The hook is called on intuition's input
///   task: it must not wait, nor draw.
///
/// OWNERSHIP:
/// The hook stays the caller's, and must stay where it is until it is
/// replaced again.
///
/// NOTES:
/// It changes every string gadget of every program. For one gadget, give
/// that gadget `STRINGA_EditHook` instead.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// strgclass (`STRINGA_EditHook`), utility.library's `CallHookPkt`
///
/// EXAMPLES:
/// ```zig
/// var upper = utility.Hook{ .entry = &upperCase };
/// previous = ib.SetEditHook(&upper); // upperCase calls `previous` for the rest
/// ```
pub fn SetEditHook(ib: *IntuitionBase, hook: ?*utility.Hook) *utility.Hook {
    _window.lock(ib);
    defer _window.unlock(ib);
    const old = ib.edit_hook;
    ib.edit_hook = hook orelse &ib.default_edit_hook;
    return old;
}
