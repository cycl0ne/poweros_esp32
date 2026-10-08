// SPDX-License-Identifier: MIT
//! FreeDiskObject: an icon given back.

const sdk = @import("sdk");
const icon = sdk.icon;
const IconBase = @import("../icon_base.zig").IconBase;
const _object = @import("_object.zig");
const _picture = @import("../picture/_picture.zig");

/// Gives back an icon the library made.
///
/// SYNOPSIS:
/// ```zig
/// fn FreeDiskObject(base: *IconBase, object: ?*DiskObject) void
/// ```
///
/// SINCE: 1.0. LVO -28.
///
/// INPUTS:
/// - `object` - an icon from `GetDiskObject`, `GetDiskObjectNew` or
///   `GetDefDiskObject`; null does nothing.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// What the library made for the icon is freed - its block, its strings,
/// its tool type array - and its picture let go of, which goes with the
/// last icon that shows it. What the fields point at now is not looked
/// at: a program that pointed `tool_types` or `default_tool` at its own
/// keeps those, and frees them itself.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The icon is the library's again; neither it nor its picture may be
/// used after.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `GetDiskObject`, `GetDiskObjectNew`, `GetDefDiskObject`
///
/// EXAMPLES:
/// ```zig
/// const object = ib.GetDiskObjectNew("SYS:C/List") orelse return;
/// ib.FreeDiskObject(object);
/// ```
pub fn FreeDiskObject(base: *IconBase, object: ?*icon.DiskObject) void {
    const given = object orelse return;
    const made = _object.madeOf(given);
    if (made.picture) |picture| _picture.release(base, picture);
    base.sys_base.FreeVec(made);
}
