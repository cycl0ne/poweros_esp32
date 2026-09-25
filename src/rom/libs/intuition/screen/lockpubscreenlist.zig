// SPDX-License-Identifier: MPL-2.0
//! LockPubScreenList: holds the public screen list, and answers it.

const sdk = @import("sdk");
const exec = sdk.exec;
const sc = sdk.intuition.screens;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _screen = @import("_screen.zig");
const Screen = _screen.Screen;
const lock = _screen.lock;
const unlock = _screen.unlock;

/// Holds the list of public screens, and answers it.
///
/// SYNOPSIS:
/// ```zig
/// fn LockPubScreenList(ib: *IntuitionBase) *exec.List
/// ```
///
/// SINCE: 0.14. LVO -360.
///
/// INPUTS:
/// None.
///
/// RESULT:
/// The list, whose nodes are `PubScreenNode`s, oldest first.
///
/// BEHAVIOR:
/// Until `UnlockPubScreenList`, no screen opens, closes, or changes its
/// status or visitors. Each node names its screen, whether it is private,
/// and how many visitors it has.
///
/// CONTEXT:
/// - Waits: for the screen list's semaphore.
/// - Interrupts: no.
/// - Forbid: must not be held.
/// - Process: a Task will do; while it holds the list it must not wait for
///   anything that opens, closes or draws on a screen.
///
/// OWNERSHIP:
/// The list stays intuition's; copy what is wanted out of it and let it go
/// soon.
///
/// NOTES:
/// This is for a program that shows the screens and lets someone choose
/// one; a program that only wants to open a window uses `LockPubScreen`.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `UnlockPubScreenList`, `NextPubScreen`, `LockPubScreen`
///
/// EXAMPLES:
/// ```zig
/// const list = ib.LockPubScreenList();
/// defer ib.UnlockPubScreenList();
/// var node = list.head;
/// while (node) |n| : (node = n.succ) {
///     if (n.succ == null) break;
///     const psn: *sc.PubScreenNode = @ptrCast(n);
///     show(psn.node.name.?);
/// }
/// ```
pub fn LockPubScreenList(ib: *IntuitionBase) *exec.List {
    lock(ib);
    return &ib.pub_screens;
}
