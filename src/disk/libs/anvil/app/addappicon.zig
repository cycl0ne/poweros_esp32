// SPDX-License-Identifier: MIT
//! AddAppIcon: an icon of a program's on the desktop's ground.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const icon = sdk.icon;
const anvil = sdk.anvil;
const utility = sdk.utility;
const AnvilBase = @import("../anvil_base.zig").AnvilBase;
const _app = @import("_app.zig");

/// Adds an icon to the desktop.
///
/// SYNOPSIS:
/// ```zig
/// fn AddAppIcon(base: *AnvilBase, id: u32, user_data: usize, text: [*:0]const u8, port: *exec.MsgPort, object: *const icon.DiskObject, tags: ?[*]const utility.TagItem) ?*anvil.AppIcon
/// ```
///
/// SINCE: 1.0. LVO -36.
///
/// INPUTS:
/// - `id`, `user_data` - the program's own, handed back in each message.
/// - `text` - the name under the icon; the first 63 bytes are kept.
/// - `port` - where the messages go.
/// - `object` - its picture (`image`), and where it lies (`current_x`,
///   `current_y`, or `NO_ICON_POSITION` for the first free place down the
///   desktop's edge); nothing else of it is read.
/// - `tags` - none yet: null.
///
/// RESULT:
/// The handle `RemoveAppIcon` takes; null when the desktop does not run
/// (IoErr ERROR_OBJECT_NOT_FOUND), when `object` has no picture
/// (ERROR_REQUIRED_ARG_MISSING) or there is no memory
/// (ERROR_NO_FREE_STORE).
///
/// BEHAVIOR:
/// The icon is drawn on the desktop's ground among the disks, picked and
/// moved as they are. A double click on it sends `port` an `AppMessage`
/// of kind `AMTYPE_APPICON` with no files; icons dragged onto it send one
/// with their files as lock-and-name pairs. The program replies each.
/// The Icons menu opens it; it is not copied, renamed, snapshot, or
/// asked about, and it is not dropped on anything.
///
/// CONTEXT:
/// - Waits: yes, for the desktop's list.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: any task.
///
/// OWNERSHIP:
/// `text` and the picture are copied: `object` may go once the call
/// returns. The port stays the program's and must stay until
/// `RemoveAppIcon`.
///
/// NOTES:
/// A program reads its picture with icon.library and frees it after:
/// `GetDiskObjectNew("PROGDIR:Name")` gives it the program's own icon or
/// the default one.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `RemoveAppIcon`, `AddAppWindow`, `AddAppMenuItem`
///
/// EXAMPLES:
/// ```zig
/// const object = ib.GetDiskObjectNew("PROGDIR:Clock") orelse return;
/// defer ib.FreeDiskObject(object);
/// object.current_x = icon.NO_ICON_POSITION;
/// const app = ab.AddAppIcon(0, 0, "Clock", port, object, null);
/// ```
pub fn AddAppIcon(base: *AnvilBase, id: u32, user_data: usize, text: [*:0]const u8, port: *exec.MsgPort, object: *const icon.DiskObject, tags: ?[*]const utility.TagItem) ?*anvil.AppIcon {
    _ = tags;
    const sys = base.sys_base;
    const dl = base.dos_base;
    const image = object.image orelse {
        _ = dl.SetIoErr(dos.ERROR_REQUIRED_ARG_MISSING);
        return null;
    };
    const record = _app.make(base, .icon, id, user_data, port) orelse {
        _ = dl.SetIoErr(dos.ERROR_NO_FREE_STORE);
        return null;
    };
    _app.setText(record, text);
    // The picture copied: the program's icon may go at once.
    const bytes: usize = @as(usize, image.width) * image.height * 4;
    const pixels: [*]u8 = @ptrCast(sys.AllocVec(@max(bytes, 1), exec.MEMF_ANY) orelse {
        _app.free(sys, record);
        _ = dl.SetIoErr(dos.ERROR_NO_FREE_STORE);
        return null;
    });
    @memcpy(pixels[0..bytes], image.pixels[0..bytes]);
    record.pixels = pixels;
    record.image = .{ .width = image.width, .height = image.height, .pixels = pixels };
    record.object = .{ .kind = icon.WBAPPICON, .current_x = object.current_x, .current_y = object.current_y, .image = &record.image };
    if (!_app.add(base, record)) {
        _app.free(sys, record);
        _ = dl.SetIoErr(dos.ERROR_OBJECT_NOT_FOUND);
        return null;
    }
    return @ptrCast(record);
}
