// SPDX-License-Identifier: MIT
//! GetDiskObjectNew: a file's icon, or the default that fits it.

const sdk = @import("sdk");
const dos = sdk.dos;
const icon = sdk.icon;
const _base = @import("../icon_base.zig");
const IconBase = _base.IconBase;
const _object = @import("_object.zig");
const _default = @import("../default/_default.zig");

/// The icon of `name`, read as `GetDiskObject` reads it, or else the
/// default icon that fits what `name` is.
///
/// SYNOPSIS:
/// ```zig
/// fn GetDiskObjectNew(base: *IconBase, name: [*:0]const u8) ?*DiskObject
/// ```
///
/// SINCE: 1.0. LVO -32.
///
/// INPUTS:
/// - `name` - the file, drawer or volume, without `.info`.
///
/// RESULT:
/// An icon, or null when there is neither an icon nor a `name`, with
/// IoErr saying why.
///
/// BEHAVIOR:
/// Without an icon file, `name` itself is looked at. A volume's root is
/// a disk and any other directory a drawer. A file is a tool when its
/// protection lets it run (`FIBF_EXECUTE` clear) and it starts as a
/// program does (`PSG1`, what LoadSeg loads); the protection alone would
/// not do, since a new file may be run until told otherwise. A file with
/// its script bit set is a project with the default `script` when there
/// is one. Anything else is a project, and when datatypes.library is
/// there and knows the file's group, it gets that group's default
/// (`picture`, `text`, `document`, `sound`, `instrument`, `music`,
/// `animation`, `movie`) when there is one. A name that is not there
/// but is `Disk` - a volume's own icon - is a disk. Defaults are as
/// `GetDefDiskObject` gives them: from `ENV:Sys/def_<name>.info`, else
/// built in, and without a place.
///
/// CONTEXT:
/// - Waits: yes - it reads files.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: a Process.
///
/// OWNERSHIP:
/// The icon is the caller's to give back with `FreeDiskObject`. Its
/// picture is shared and read only: a drawer of files without icons
/// shares one picture per kind.
///
/// NOTES:
/// What a desktop calls for every file it shows, and what a window that
/// takes dropped files calls for each of them.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `GetDiskObject`, `GetDefDiskObject`, `FreeDiskObject`
///
/// EXAMPLES:
/// ```zig
/// const object = ib.GetDiskObjectNew("RAM:Notes.txt") orelse return;
/// defer ib.FreeDiskObject(object);
/// if (object.kind == icon.WBPROJECT) {}
/// ```
pub fn GetDiskObjectNew(base: *IconBase, name: [*:0]const u8) ?*icon.DiskObject {
    const ib = _base.interface(base);
    const dl = base.dos_base;
    if (ib.GetDiskObject(name)) |object| return object;
    const failure = dl.IoErr();
    const nature = _object.natureOf(base, name) orelse {
        if (isDisk(dl.FilePart(name))) return ib.GetDefDiskObject(icon.WBDISK);
        _ = dl.SetIoErr(if (failure != 0) failure else dos.ERROR_OBJECT_NOT_FOUND);
        return null;
    };
    const slot: ?usize = switch (nature) {
        .script => _default.SCRIPT,
        .project => groupOf(base, name),
        else => null,
    };
    if (slot) |special| {
        if (_default.get(base, special)) |object| return object;
    }
    return ib.GetDefDiskObject(_object.kindOf(nature));
}

/// The default slot of the group `name` is in, when it is in one.
fn groupOf(base: *IconBase, name: [*:0]const u8) ?usize {
    const dl = base.dos_base;
    const lock = dl.Lock(name, dos.SHARED_LOCK) orelse return null;
    defer dl.UnLock(lock);
    return _default.groupSlot(base, lock);
}

fn isDisk(part: [*:0]const u8) bool {
    const word = "disk";
    for (word, 0..) |char, index| {
        const have = part[index];
        if (have == 0) return false;
        const lower = if (have >= 'A' and have <= 'Z') have + 32 else have;
        if (lower != char) return false;
    }
    return part[word.len] == 0;
}
