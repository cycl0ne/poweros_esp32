// SPDX-License-Identifier: MPL-2.0
//! SetPubScreenModes: how public screens behave, for every program.

const sdk = @import("sdk");
const sc = sdk.intuition.screens;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _screen = @import("_screen.zig");
const lock = _screen.lock;
const unlock = _screen.unlock;

/// Sets how public screens behave, for every program.
///
/// SYNOPSIS:
/// ```zig
/// fn SetPubScreenModes(ib: *IntuitionBase, modes: u32) u32
/// ```
///
/// SINCE: 0.14. LVO -380.
///
/// INPUTS:
/// - `modes` - the new bits: `POPPUBSCREEN`, or 0.
///
/// RESULT:
/// The bits there were before.
///
/// BEHAVIOR:
/// With `POPPUBSCREEN` a window opened on a public screen by name, or on
/// the default one, brings that screen to the front.
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
/// The modes are the whole system's, not the caller's: they are for the
/// program that manages the screens, which reads them first and keeps the
/// bits it does not mean to change.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `LockPubScreen`, `ScreenToFront`
///
/// EXAMPLES:
/// ```zig
/// const old = ib.SetPubScreenModes(sc.POPPUBSCREEN);
/// _ = old;
/// ```
pub fn SetPubScreenModes(ib: *IntuitionBase, modes: u32) u32 {
    lock(ib);
    defer unlock(ib);
    const old = ib.pub_modes;
    ib.pub_modes = modes & sc.POPPUBSCREEN;
    return old;
}
