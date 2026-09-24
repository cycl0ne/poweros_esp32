// SPDX-License-Identifier: MPL-2.0
//! LockIBase: holds the semaphore that guards the screens, their windows
//! and which window is active, for a caller that reads several of them and
//! needs the answers to agree.

const IntuitionBase = @import("../intuition.zig").IntuitionBase;

/// Holds the screens and windows still.
///
/// SYNOPSIS:
/// ```zig
/// fn LockIBase(ib: *IntuitionBase, lock_number: u32) u32
/// ```
///
/// SINCE: 0.9. LVO -220.
///
/// INPUTS:
/// - `lock_number` - which lock. There is one, so every number takes it;
///   0 is the one to pass.
///
/// RESULT:
/// What to hand to `UnlockIBase`: `lock_number`, back.
///
/// BEHAVIOR:
/// Obtains the semaphore every screen and window call takes. Until
/// `UnlockIBase`, no screen or window opens, closes, moves, sizes or
/// changes places, and the active window stays the active one - which
/// includes everything the pointer would do, since intuition's input is
/// handled under the same semaphore.
///
/// CONTEXT:
/// - Waits: yes, for whoever holds the screens - another program, or
///   intuition's own input task.
/// - Interrupts: no.
/// - Forbid: must not be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The caller holds the lock and must give it back with `UnlockIBase`,
/// soon: all input waits while it is held.
///
/// NOTES:
/// - The semaphore nests, so the holder may call intuition's calls that
///   take it - `GetWindowAttrs`, `GetScreenAttrs` and the like - and read
///   what they answer as one picture.
///
/// BUGS:
/// - A caller holding a layer's lock must not take this one: intuition's
///   input task takes the screens first and then a window's layer, and
///   the two would wait for each other for good.
///
/// SEE ALSO:
/// `UnlockIBase`, `LockPubScreen`, `LockClassList`
///
/// EXAMPLES:
/// ```zig
/// const held = ib.LockIBase(0);
/// ib.GetWindowAttrs(window, &tags);
/// ib.UnlockIBase(held);
/// ```
pub fn LockIBase(ib: *IntuitionBase, lock_number: u32) u32 {
    ib.sys_base.ObtainSemaphore(&ib.screen_lock);
    return lock_number;
}
