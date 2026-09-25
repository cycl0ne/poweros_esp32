// SPDX-License-Identifier: MPL-2.0
//! GetDefaultPubScreen: the default public screen and its name.

const sdk = @import("sdk");
const sc = sdk.intuition.screens;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _screen = @import("_screen.zig");
const Screen = _screen.Screen;
const lock = _screen.lock;
const nameLen = _screen.nameLen;
const unlock = _screen.unlock;

/// Names the default public screen.
///
/// SYNOPSIS:
/// ```zig
/// fn GetDefaultPubScreen(ib: *IntuitionBase, name_buffer: ?*[32]u8) ?*Screen
/// ```
///
/// SINCE: 0.14. LVO -376.
///
/// INPUTS:
/// - `name_buffer` - where its name is written, NUL-terminated, or null.
///
/// RESULT:
/// The screen `SetDefaultPubScreen` chose, or null when that is the
/// Workbench screen; `name_buffer` gets `WBENCHNAME` then.
///
/// BEHAVIOR:
/// Only the name is safe to keep: the screen answered is not locked and
/// may close at any moment. It is for comparing with a screen the caller
/// holds, to tell whether that one is the default.
///
/// CONTEXT:
/// - Waits: for the screen list's semaphore.
/// - Interrupts: no.
/// - Forbid: not held and not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing changes hands. The name is a copy in the caller's buffer.
///
/// NOTES:
/// To open a window on the default screen there is no need for its name:
/// `LockPubScreen(null)` does that.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `SetDefaultPubScreen`, `LockPubScreen`
///
/// EXAMPLES:
/// ```zig
/// var name: [sc.MAXPUBSCREENNAME + 1]u8 = undefined;
/// const is_default = ib.GetDefaultPubScreen(&name) == my_screen;
/// ```
pub fn GetDefaultPubScreen(ib: *IntuitionBase, name_buffer: ?*[32]u8) ?*Screen {
    lock(ib);
    defer unlock(ib);
    const s = ib.default_pub;
    if (name_buffer) |buffer| {
        const name: [*:0]const u8 = if (s) |default| @ptrCast(&default.pub_name) else sc.WBENCHNAME;
        const len = nameLen(name);
        for (0..len) |i| buffer[i] = name[i];
        buffer[len] = 0;
    }
    return s;
}
