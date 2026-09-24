// SPDX-License-Identifier: MPL-2.0
//! ModifyIDCMP: changes which messages a window gets.

const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _window = @import("_window.zig");
const Window = _window.Window;
const dropPort = _window.dropPort;
const lock = _window.lock;
const unlock = _window.unlock;

/// Changes which messages a window gets.
///
/// SYNOPSIS:
/// ```zig
/// fn ModifyIDCMP(ib: *IntuitionBase, window: *Window, flags: u32) bool
/// ```
///
/// SINCE: 0.5. LVO -168.
///
/// INPUTS:
/// - `window` - the window.
/// - `flags` - the `IDCMP_` classes to be told about from now on.
///
/// RESULT:
/// True, or false when it needed a port and none could be made - the
/// flags are then as they were.
///
/// BEHAVIOR:
/// 0 takes the port away, with every message still waiting on it. From 0
/// to anything, the window gets a port, made for the calling task.
///
/// CONTEXT:
/// - Waits: for the screen list's semaphore, and the layers' locks.
/// - Interrupts: no.
/// - Forbid: not held and not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// A port taken away is gone, and so is any message still on it; every
/// message the program took off it must have been replied first.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `OpenWindowTagList` (`WA_IDCMP`)
///
/// EXAMPLES:
/// ```zig
/// if (!ib.ModifyIDCMP(window, IDCMP_REFRESHWINDOW | IDCMP_NEWSIZE)) return;
/// ```
pub fn ModifyIDCMP(ib: *IntuitionBase, window: *Window, flags: u32) bool {
    lock(ib);
    defer unlock(ib);
    if (flags == 0) {
        dropPort(ib, window);
    } else if (window.user_port == null) {
        window.user_port = ib.sys_base.CreateMsgPort() orelse return false;
    }
    window.idcmp = flags;
    return true;
}
