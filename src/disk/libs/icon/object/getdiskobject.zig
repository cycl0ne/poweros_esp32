// SPDX-License-Identifier: MIT
//! GetDiskObject: a file's icon read.

const sdk = @import("sdk");
const dos = sdk.dos;
const icon = sdk.icon;
const iconfile = icon.file;
const IconBase = @import("../icon_base.zig").IconBase;
const _object = @import("_object.zig");
const _picture = @import("../picture/_picture.zig");

/// Reads the icon of `name` from `<name>.info`.
///
/// SYNOPSIS:
/// ```zig
/// fn GetDiskObject(base: *IconBase, name: ?[*:0]const u8) ?*DiskObject
/// ```
///
/// SINCE: 1.0. LVO -20.
///
/// INPUTS:
/// - `name` - the file, drawer or volume the icon belongs to, without
///   `.info`. A name ending in `:` - a volume, a device, an assign -
///   reads `<name>Disk.info`. Null makes an empty icon: no kind, no
///   picture, every field at its default, for a program to fill in.
///
/// RESULT:
/// The icon, or null with IoErr saying why: `ERROR_OBJECT_NOT_FOUND`
/// when there is no icon file, `ERROR_OBJECT_WRONG_TYPE` when it is not
/// a PNG this reads, `ERROR_OBJECT_TOO_LARGE` for a picture of more than
/// 256 pixels either way, `ERROR_INVALID_COMPONENT_NAME` for a name too
/// long to have an icon, `ERROR_NO_FREE_STORE`.
///
/// BEHAVIOR:
/// The file is read whole and its picture decoded. Its fields are the
/// text of its `icOn` chunk (`sdk.icon.file`); a field it leaves out has
/// its default. A file without the chunk, or without a KIND, has the
/// kind the thing it belongs to has - a disk, a drawer, a tool, a
/// project - so a picture drawn anywhere and named `x.info` is `x`'s
/// icon. A disk's, a drawer's and the trash's icon have `drawer_data`.
///
/// CONTEXT:
/// - Waits: yes - it reads the file.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: a Process; a Task only for a null name.
///
/// OWNERSHIP:
/// The icon is the caller's to give back with `FreeDiskObject`. Its
/// picture is shared and read only.
///
/// NOTES:
/// `GetDiskObjectNew` falls back to a default icon when there is no icon
/// file - what a program wants that shows any file.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `GetDiskObjectNew`, `PutDiskObject`, `FreeDiskObject`,
/// `DeleteDiskObject`
///
/// EXAMPLES:
/// ```zig
/// if (ib.GetDiskObject("SYS:Programs/Notepad")) |object| {
///     defer ib.FreeDiskObject(object);
///     const width = object.image.?.width;
///     _ = width;
/// }
/// ```
pub fn GetDiskObject(base: *IconBase, name: ?[*:0]const u8) ?*icon.DiskObject {
    const sys = base.sys_base;
    const dl = base.dos_base;
    const given = name orelse return _object.make(base, "", 0, null);
    const path = _object.infoName(base, given) orelse return null;
    defer sys.FreeVec(path);
    const bytes = switch (_object.readWhole(base, path)) {
        .got => |got| got,
        .failed => |failure| {
            _ = dl.SetIoErr(failure);
            return null;
        },
    };
    defer sys.FreeVec(bytes.ptr);
    const fields = (iconfile.fieldsOf(bytes) catch {
        _ = dl.SetIoErr(dos.ERROR_OBJECT_WRONG_TYPE);
        return null;
    }) orelse "";
    const picture = _picture.make(base, bytes) catch |failure| {
        _ = dl.SetIoErr(switch (failure) {
            error.WrongType => dos.ERROR_OBJECT_WRONG_TYPE,
            error.TooLarge => dos.ERROR_OBJECT_TOO_LARGE,
            error.NoMemory => dos.ERROR_NO_FREE_STORE,
        });
        return null;
    };
    const kind = _object.kindIn(fields) orelse
        if (_object.natureOf(base, given)) |nature| _object.kindOf(nature) else icon.WBPROJECT;
    return _object.make(base, fields, kind, picture);
}
