// SPDX-License-Identifier: MPL-2.0
//! PubScreenStatus: opens a public screen to visitors, or closes it to them.

const sdk = @import("sdk");
const sc = sdk.intuition.screens;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _screen = @import("_screen.zig");
const Screen = _screen.Screen;
const lock = _screen.lock;
const unlock = _screen.unlock;

/// Opens a public screen to visitors, or closes it to them.
///
/// SYNOPSIS:
/// ```zig
/// fn PubScreenStatus(ib: *IntuitionBase, screen: *Screen, flags: u32) u32
/// ```
///
/// SINCE: 0.14. LVO -384.
///
/// INPUTS:
/// - `screen` - a public screen the caller opened.
/// - `flags` - `PSNF_PRIVATE` to close it to visitors, 0 to open it.
///
/// RESULT:
/// 1 when it is done; 0 when the screen is not public, or cannot go
/// private because it still has visitors.
///
/// BEHAVIOR:
/// A public screen opens private: nobody finds it until its owner has
/// set it up and calls this with 0. Going private, it also stops being
/// the default public screen.
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
/// An owner that wants to close its screen makes it private first, so no
/// new visitor comes while it waits for the last to go.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `OpenScreenTagList` (`SA_PubName`, `SA_PubSig`), `LockPubScreen`
///
/// EXAMPLES:
/// ```zig
/// const screen = ib.OpenScreenTagList(&tags) orelse return;
/// // Set up, now visitors are welcome.
/// _ = ib.PubScreenStatus(screen, 0);
/// ```
pub fn PubScreenStatus(ib: *IntuitionBase, screen: *Screen, flags: u32) u32 {
    lock(ib);
    defer unlock(ib);
    if (!screen.public) return 0;
    const psn = &screen.pub_node;
    if (flags & sc.PSNF_PRIVATE == 0) {
        psn.flags &= ~sc.PSNF_PRIVATE;
        return 1;
    }
    if (psn.visitor_count != 0) return 0;
    psn.flags |= sc.PSNF_PRIVATE;
    if (ib.default_pub == screen) ib.default_pub = null;
    return 1;
}
