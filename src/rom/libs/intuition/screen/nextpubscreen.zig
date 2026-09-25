// SPDX-License-Identifier: MPL-2.0
//! NextPubScreen: the name of the public screen after a given one.

const sdk = @import("sdk");
const sc = sdk.intuition.screens;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _screen = @import("_screen.zig");
const Screen = _screen.Screen;
const lock = _screen.lock;
const nameLen = _screen.nameLen;
const unlock = _screen.unlock;

/// Names the public screen after a given one, going round.
///
/// SYNOPSIS:
/// ```zig
/// fn NextPubScreen(ib: *IntuitionBase, screen: ?*Screen, name_buffer: *[32]u8) ?[*:0]u8
/// ```
///
/// SINCE: 0.14. LVO -368.
///
/// INPUTS:
/// - `screen` - the screen to go on from, or null to start at the first.
/// - `name_buffer` - where the name is written, NUL-terminated.
///
/// RESULT:
/// `name_buffer`, or null when there is no public screen.
///
/// BEHAVIOR:
/// The public screens are taken in the order they opened; after the last
/// comes the first again, and a screen that is not public starts at the
/// first. Private screens are named too.
///
/// CONTEXT:
/// - Waits: for the screen list's semaphore.
/// - Interrupts: no.
/// - Forbid: not held and not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The name is a copy in the caller's buffer.
///
/// NOTES:
/// The screen named may have closed, or gone private, by the time it is
/// locked; `LockPubScreen` answers null then and the caller moves on.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `LockPubScreen`, `LockPubScreenList`
///
/// EXAMPLES:
/// ```zig
/// var name: [sc.MAXPUBSCREENNAME + 1]u8 = undefined;
/// // A gadget that jumps the window to the next screen.
/// if (ib.NextPubScreen(current, &name)) |next| reopenOn(next);
/// ```
pub fn NextPubScreen(ib: *IntuitionBase, screen: ?*Screen, name_buffer: *[32]u8) ?[*:0]u8 {
    lock(ib);
    defer unlock(ib);
    const list = &ib.pub_screens;
    if (list.isEmpty()) return null;
    var node = list.head.?;
    if (screen) |s| {
        if (s.public) {
            const succ = s.pub_node.node.succ.?;
            if (succ.succ != null) node = succ;
        }
    }
    const psn: *sc.PubScreenNode = @ptrCast(@alignCast(node));
    const name = psn.node.name.?;
    const len = nameLen(name);
    for (0..len) |i| name_buffer[i] = name[i];
    name_buffer[len] = 0;
    return @ptrCast(name_buffer);
}
