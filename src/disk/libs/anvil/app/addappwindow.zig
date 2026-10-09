// SPDX-License-Identifier: MIT
//! AddAppWindow: a program's window made one that files can be dropped on.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const anvil = sdk.anvil;
const utility = sdk.utility;
const intuition = sdk.intuition;
const AnvilBase = @import("../anvil_base.zig").AnvilBase;
const _app = @import("_app.zig");

/// Adds a window that files can be dropped on.
///
/// SYNOPSIS:
/// ```zig
/// fn AddAppWindow(base: *AnvilBase, id: u32, user_data: usize, window: *intuition.Window, port: *exec.MsgPort, tags: ?[*]const utility.TagItem) ?*anvil.AppWindow
/// ```
///
/// SINCE: 1.0. LVO -28.
///
/// INPUTS:
/// - `id`, `user_data` - the program's own, handed back in each message.
/// - `window` - the program's window, on the desktop's screen.
/// - `port` - where the messages go.
/// - `tags` - none yet: null.
///
/// RESULT:
/// The handle `RemoveAppWindow` takes; null when the desktop does not
/// run (IoErr ERROR_OBJECT_NOT_FOUND) or there is no memory
/// (ERROR_NO_FREE_STORE).
///
/// BEHAVIOR:
/// Icons dragged from the desktop and let go over the window - over any
/// of it the pointer reaches, its border included - no longer fly back:
/// the desktop sends `port` an `AppMessage` of kind `AMTYPE_APPWINDOW`
/// with the files of the icons dragged as lock-and-name pairs (a drawer
/// or a disk as a lock on itself and an empty name) and where they were
/// let go, in the window's own coordinates. The program replies it; the
/// pairs go with the reply.
///
/// CONTEXT:
/// - Waits: yes, for the desktop's list.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: any task.
///
/// OWNERSHIP:
/// The window and the port stay the program's and must stay until
/// `RemoveAppWindow`. The handle is the desktop's.
///
/// NOTES:
/// A window that closes is removed first. The desktop does not quit while
/// a window, an icon or a menu item a program added is on its lists.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `RemoveAppWindow`, `AddAppIcon`, `sdk.anvil.DropTarget`
///
/// EXAMPLES:
/// ```zig
/// const app = ab.AddAppWindow(0, 0, window, port, null);
/// defer _ = ab.RemoveAppWindow(app);
/// ```
pub fn AddAppWindow(base: *AnvilBase, id: u32, user_data: usize, window: *intuition.Window, port: *exec.MsgPort, tags: ?[*]const utility.TagItem) ?*anvil.AppWindow {
    _ = tags;
    const dl = base.dos_base;
    const record = _app.make(base, .window, id, user_data, port) orelse {
        _ = dl.SetIoErr(dos.ERROR_NO_FREE_STORE);
        return null;
    };
    record.window = window;
    if (!_app.add(base, record)) {
        _app.free(base.sys_base, record);
        _ = dl.SetIoErr(dos.ERROR_OBJECT_NOT_FOUND);
        return null;
    }
    return @ptrCast(record);
}
