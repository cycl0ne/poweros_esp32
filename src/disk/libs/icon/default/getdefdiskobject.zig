// SPDX-License-Identifier: MIT
//! GetDefDiskObject: the default icon of a kind.

const sdk = @import("sdk");
const dos = sdk.dos;
const icon = sdk.icon;
const IconBase = @import("../icon_base.zig").IconBase;
const _default = @import("_default.zig");

/// The default icon of a kind.
///
/// SYNOPSIS:
/// ```zig
/// fn GetDefDiskObject(base: *IconBase, kind: u32) ?*DiskObject
/// ```
///
/// SINCE: 1.0. LVO -40.
///
/// INPUTS:
/// - `kind` - `WBDISK`, `WBDRAWER`, `WBTOOL`, `WBPROJECT` or
///   `WBGARBAGE`.
///
/// RESULT:
/// A new icon of that kind, without a place; null for another kind
/// (IoErr `ERROR_BAD_NUMBER`) or without the memory.
///
/// BEHAVIOR:
/// `ENV:Sys/def_<disk|drawer|tool|project|trashcan>.info` when it is
/// there and of that kind; else the one built into the library. What is
/// read is kept and shared: the next call looks at the file's date and
/// size and reads it again only when they changed, and every icon made
/// from a default shows the one picture. No requester is put up for
/// `ENV:` while it is looked at.
///
/// CONTEXT:
/// - Waits: yes - it may read a file.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: a Process.
///
/// OWNERSHIP:
/// The icon is the caller's to give back with `FreeDiskObject`; the
/// picture is shared and read only.
///
/// NOTES:
/// What a program writes as the icon of a drawer it made, with a place
/// of its own.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `PutDefDiskObject`, `GetDiskObjectNew`
///
/// EXAMPLES:
/// ```zig
/// const object = ib.GetDefDiskObject(icon.WBDRAWER) orelse return;
/// defer ib.FreeDiskObject(object);
/// _ = ib.PutDiskObject("RAM:Work", object);
/// ```
pub fn GetDefDiskObject(base: *IconBase, kind: u32) ?*icon.DiskObject {
    if (kind < icon.WBDISK or kind > icon.WBGARBAGE) {
        _ = base.dos_base.SetIoErr(dos.ERROR_BAD_NUMBER);
        return null;
    }
    return _default.get(base, kind - 1);
}
