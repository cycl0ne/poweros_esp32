// SPDX-License-Identifier: MPL-2.0
//! SetDefaultPubScreen: chooses the screen windows open on by default.

const sdk = @import("sdk");
const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _screen = @import("_screen.zig");
const Screen = _screen.Screen;
const findVisitable = _screen.findVisitable;
const lock = _screen.lock;
const unlock = _screen.unlock;

/// Chooses the public screen windows open on by default.
///
/// SYNOPSIS:
/// ```zig
/// fn SetDefaultPubScreen(ib: *IntuitionBase, name: ?[*:0]const u8) void
/// ```
///
/// SINCE: 0.14. LVO -372.
///
/// INPUTS:
/// - `name` - the public screen's name, in any case, or null for the
///   Workbench screen.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// From now on `LockPubScreen(null)`, and a window given no screen or
/// falling back from a name that is not there, get that screen. A name
/// that is not a public screen open to visitors changes nothing. It stops
/// being the default when it closes or goes private.
///
/// CONTEXT:
/// - Waits: for the screen list's semaphore.
/// - Interrupts: no.
/// - Forbid: not held and not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing changes hands; the screen is not locked by being the default.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `GetDefaultPubScreen`, `LockPubScreen`, `PubScreenStatus`
///
/// EXAMPLES:
/// ```zig
/// ib.SetDefaultPubScreen("PAINT");
/// ```
pub fn SetDefaultPubScreen(ib: *IntuitionBase, name: ?[*:0]const u8) void {
    lock(ib);
    defer unlock(ib);
    const wanted = name orelse {
        ib.default_pub = null;
        return;
    };
    if (findVisitable(ib, wanted)) |s| ib.default_pub = s;
}
