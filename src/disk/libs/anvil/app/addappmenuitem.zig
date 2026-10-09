// SPDX-License-Identifier: MIT
//! AddAppMenuItem: an item in the desktop's Tools menu.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const anvil = sdk.anvil;
const utility = sdk.utility;
const AnvilBase = @import("../anvil_base.zig").AnvilBase;
const _app = @import("_app.zig");

/// Adds an item to the Tools menu.
///
/// SYNOPSIS:
/// ```zig
/// fn AddAppMenuItem(base: *AnvilBase, id: u32, user_data: usize, text: [*:0]const u8, port: *exec.MsgPort, tags: ?[*]const utility.TagItem) ?*anvil.AppMenuItem
/// ```
///
/// SINCE: 1.0. LVO -44.
///
/// INPUTS:
/// - `id`, `user_data` - the program's own, handed back in each message.
/// - `text` - the item's words; the first 63 bytes are kept.
/// - `port` - where the messages go.
/// - `tags` - none yet: null.
///
/// RESULT:
/// The handle `RemoveAppMenuItem` takes; null when the desktop does not
/// run (IoErr ERROR_OBJECT_NOT_FOUND) or there is no memory
/// (ERROR_NO_FREE_STORE).
///
/// BEHAVIOR:
/// The item goes at the end of the desktop's Tools menu, which is off
/// while it has none. Choosing it sends `port` an `AppMessage` of kind
/// `AMTYPE_APPMENUITEM` with the files of every icon picked, on the
/// desktop and in its drawers, as lock-and-name pairs. The program
/// replies it. The menu holds 32 items; one past them is not shown.
///
/// CONTEXT:
/// - Waits: yes, for the desktop's list.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: any task.
///
/// OWNERSHIP:
/// `text` is copied. The port stays the program's and must stay until
/// `RemoveAppMenuItem`.
///
/// NOTES:
/// The items come in the order they were added.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `RemoveAppMenuItem`, `AddAppIcon`
///
/// EXAMPLES:
/// ```zig
/// const app = ab.AddAppMenuItem(0, 0, "Show picked", port, null);
/// ```
pub fn AddAppMenuItem(base: *AnvilBase, id: u32, user_data: usize, text: [*:0]const u8, port: *exec.MsgPort, tags: ?[*]const utility.TagItem) ?*anvil.AppMenuItem {
    _ = tags;
    const dl = base.dos_base;
    const record = _app.make(base, .menu_item, id, user_data, port) orelse {
        _ = dl.SetIoErr(dos.ERROR_NO_FREE_STORE);
        return null;
    };
    _app.setText(record, text);
    if (!_app.add(base, record)) {
        _app.free(base.sys_base, record);
        _ = dl.SetIoErr(dos.ERROR_OBJECT_NOT_FOUND);
        return null;
    }
    return @ptrCast(record);
}
