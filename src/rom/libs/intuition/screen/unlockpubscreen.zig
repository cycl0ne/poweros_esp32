// SPDX-License-Identifier: MPL-2.0
//! UnlockPubScreen: unlocks a public screen.

const sdk = @import("sdk");
const intuition = sdk.intuition;
const sc = intuition.screens;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _screen = @import("_screen.zig");
const Screen = _screen.Screen;
const findPublic = _screen.findPublic;
const lock = _screen.lock;
const unlock = _screen.unlock;

/// Unlocks a public screen.
///
/// SYNOPSIS:
/// ```zig
/// fn UnlockPubScreen(ib: *IntuitionBase, name: ?[*:0]const u8,
///     screen: ?*Screen) void
/// ```
///
/// SINCE: 0.4. LVO -128.
///
/// INPUTS:
/// - `name` - the screen's name, used when `screen` is null; null names
///   the default public screen.
/// - `screen` - the screen LockPubScreen answered, or null.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// One lock fewer. A screen with none can close.
///
/// CONTEXT:
/// - Waits: for the screen list's semaphore.
/// - Interrupts: no.
/// - Forbid: not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The caller may not use the screen after this unless it holds another
/// lock or opened it.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `LockPubScreen`
///
/// EXAMPLES:
/// ```zig
/// ib.UnlockPubScreen(null, screen);
/// ```
pub fn UnlockPubScreen(ib: *IntuitionBase, name: ?[*:0]const u8, screen: ?*Screen) void {
    lock(ib);
    defer unlock(ib);
    const s = if (screen) |given| given else (findPublic(ib, name orelse sc.WBENCHNAME) orelse return);
    if (s.visitors > 0) s.visitors -= 1;
}
