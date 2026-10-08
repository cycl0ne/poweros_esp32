// SPDX-License-Identifier: MIT
//! DeleteDiskObject: an icon's file deleted.

const sdk = @import("sdk");
const dos = sdk.dos;
const IconBase = @import("../icon_base.zig").IconBase;
const _object = @import("_object.zig");

/// Deletes the icon of `name`, its file `<name>.info`.
///
/// SYNOPSIS:
/// ```zig
/// fn DeleteDiskObject(base: *IconBase, name: [*:0]const u8) bool
/// ```
///
/// SINCE: 1.0. LVO -36.
///
/// INPUTS:
/// - `name` - the file, drawer or volume the icon belongs to, without
///   `.info`; a name ending in `:` deletes `<name>Disk.info`.
///
/// RESULT:
/// True when the icon is gone, also when there was none; false with
/// IoErr saying why when it is there and could not be deleted.
///
/// BEHAVIOR:
/// Only the icon's file is deleted, never the file it belongs to. An icon
/// that was not there answers true, so a program deleting a file and its
/// icon need not ask first whether it had one.
///
/// CONTEXT:
/// - Waits: yes - it deletes the file.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: a Process.
///
/// OWNERSHIP:
/// None.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `PutDiskObject`, `GetDiskObject`
///
/// EXAMPLES:
/// ```zig
/// if (dl.DeleteFile("RAM:Notes")) _ = ib.DeleteDiskObject("RAM:Notes");
/// ```
pub fn DeleteDiskObject(base: *IconBase, name: [*:0]const u8) bool {
    const dl = base.dos_base;
    const path = _object.infoName(base, name) orelse return false;
    defer base.sys_base.FreeVec(path);
    if (dl.DeleteFile(path)) return true;
    if (dl.IoErr() != dos.ERROR_OBJECT_NOT_FOUND) return false;
    _ = dl.SetIoErr(0);
    return true;
}
