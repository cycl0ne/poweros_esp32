// SPDX-License-Identifier: MIT
//! PutDefDiskObject: an icon made the default of its kind.

const sdk = @import("sdk");
const dos = sdk.dos;
const icon = sdk.icon;
const _base = @import("../icon_base.zig");
const IconBase = _base.IconBase;
const _default = @import("_default.zig");

/// Makes `object` the default icon of its kind.
///
/// SYNOPSIS:
/// ```zig
/// fn PutDefDiskObject(base: *IconBase, object: *const DiskObject) bool
/// ```
///
/// SINCE: 1.0. LVO -44.
///
/// INPUTS:
/// - `object` - an icon of kind `WBDISK` to `WBGARBAGE`, its picture made
///   by this library.
///
/// RESULT:
/// True when it was written to `ENVARC:`; false with IoErr saying why -
/// `ERROR_BAD_NUMBER` for another kind, or what `PutDiskObject`
/// answered.
///
/// BEHAVIOR:
/// Written as `PutDiskObject` writes an icon, to
/// `ENV:Sys/def_<disk|drawer|tool|project|trashcan>.info` - in force at
/// once - and to the same name in `ENVARC:`, which keeps it past a
/// restart. The default the library kept for the kind is forgotten, so
/// the next icon of it is made from the new one.
///
/// CONTEXT:
/// - Waits: yes - it writes files.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: a Process.
///
/// OWNERSHIP:
/// `object` stays the caller's.
///
/// NOTES:
/// A script's default and the groups' are files of the same form, put in
/// `ENV:Sys` and `ENVARC:Sys` by hand: `def_script.info`,
/// `def_picture.info`, `def_text.info` and the rest.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `GetDefDiskObject`, `PutDiskObject`
///
/// EXAMPLES:
/// ```zig
/// const object = ib.GetDiskObject("RAM:MyDrawer") orelse return;
/// defer ib.FreeDiskObject(object);
/// _ = ib.PutDefDiskObject(object);
/// ```
pub fn PutDefDiskObject(base: *IconBase, object: *const icon.DiskObject) bool {
    const ib = _base.interface(base);
    if (object.kind < icon.WBDISK or object.kind > icon.WBGARBAGE) {
        _ = base.dos_base.SetIoErr(dos.ERROR_BAD_NUMBER);
        return false;
    }
    const slot = object.kind - 1;
    var path: [64]u8 = undefined;
    _ = ib.PutDiskObject(_default.pathOf(&path, "ENV:Sys/def_", _default.names[slot], ""), object);
    const kept = ib.PutDiskObject(_default.pathOf(&path, "ENVARC:Sys/def_", _default.names[slot], ""), object);
    _default.forget(base, slot);
    return kept;
}
