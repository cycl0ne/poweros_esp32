// SPDX-License-Identifier: MPL-2.0
//! LockPubScreen: locks a public screen, opening the default one if needed.

const sdk = @import("sdk");
const utility = sdk.utility;
const intuition = sdk.intuition;
const sc = intuition.screens;
const TagItem = utility.TagItem;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _screen = @import("_screen.zig");
const Screen = _screen.Screen;
const findVisitable = _screen.findVisitable;
const visit = _screen.visit;
const lock = _screen.lock;
const unlock = _screen.unlock;

/// Locks a public screen, opening the default one if needed.
///
/// SYNOPSIS:
/// ```zig
/// fn LockPubScreen(ib: *IntuitionBase, name: ?[*:0]const u8) ?*Screen
/// ```
///
/// SINCE: 0.4. LVO -124.
///
/// INPUTS:
/// - `name` - the public screen's name, in any case, or null for the
///   default public screen: the one `SetDefaultPubScreen` chose, or else
///   `WBENCHNAME`.
///
/// RESULT:
/// The screen, locked, or null: no public screen of that name, or it is
/// private, or - for null - the Workbench screen could not be opened (no
/// display, or the display already shows another screen).
///
/// BEHAVIOR:
/// The screen cannot close until each lock has its `UnlockPubScreen`. Null
/// opens the Workbench screen the first time, public at once; a name opens
/// nothing. A screen its owner has not yet opened to visitors with
/// `PubScreenStatus` is not found.
///
/// CONTEXT:
/// - Waits: for the screen list's semaphore.
/// - Interrupts: no.
/// - Forbid: not held and not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The screen stays its owner's. The Workbench screen opened here belongs
/// to nobody in particular and stays open when the last lock goes.
///
/// NOTES:
/// - This is how a program finds a screen to open its window on.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `UnlockPubScreen`, `OpenScreenTagList`
///
/// EXAMPLES:
/// ```zig
/// const screen = ib.LockPubScreen(null) orelse return;
/// defer ib.UnlockPubScreen(null, screen);
/// ```
pub fn LockPubScreen(ib: *IntuitionBase, name: ?[*:0]const u8) ?*Screen {
    lock(ib);
    defer unlock(ib);
    const s: *Screen = if (name) |wanted|
        (findVisitable(ib, wanted) orelse return null)
    else if (ib.default_pub) |default|
        default
    else
        findVisitable(ib, sc.WBENCHNAME) orelse blk: {
            // Only the Workbench screen is opened on demand; any other is
            // a screen its owner opens. It is public from the start: it
            // belongs to nobody who would open it later.
            const open = [_]TagItem{
                .{ .tag = sc.SA_PubName, .data = @intFromPtr(sc.WBENCHNAME) },
                .{ .tag = sc.SA_Title, .data = @intFromPtr(sdk.release.NAME ++ " Screen") },
                .{},
            };
            const opened = ib.iface().OpenScreenTagList(&open) orelse return null;
            const wb: *Screen = @ptrCast(@alignCast(opened));
            wb.pub_node.flags &= ~sc.PSNF_PRIVATE;
            break :blk wb;
        };
    visit(s);
    return s;
}
