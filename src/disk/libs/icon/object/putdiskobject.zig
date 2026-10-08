// SPDX-License-Identifier: MIT
//! PutDiskObject: an icon written to its file.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const icon = sdk.icon;
const iconfile = icon.file;
const decode = sdk.datatypes.png.decode;
const IconBase = @import("../icon_base.zig").IconBase;
const _object = @import("_object.zig");
const _picture = @import("../picture/_picture.zig");

/// Writes `object` to `<name>.info`.
///
/// SYNOPSIS:
/// ```zig
/// fn PutDiskObject(base: *IconBase, name: [*:0]const u8, object: *const DiskObject) bool
/// ```
///
/// SINCE: 1.0. LVO -24.
///
/// INPUTS:
/// - `name` - the file, drawer or volume the icon belongs to, without
///   `.info`; a name ending in `:` writes `<name>Disk.info`.
/// - `object` - the icon. Its picture must be one this library made:
///   from `GetDiskObject`, `GetDiskObjectNew` or `GetDefDiskObject`.
///
/// RESULT:
/// True, or false with IoErr saying why: `ERROR_REQUIRED_ARG_MISSING`
/// for an icon without a picture, `ERROR_OBJECT_WRONG_TYPE` for a
/// picture not made here, `ERROR_OBJECT_TOO_LARGE` for fields of more
/// than 16 KiB of text, `ERROR_INVALID_COMPONENT_NAME`, or what dos
/// answered.
///
/// BEHAVIOR:
/// The file is the picture's PNG as it was read, with the icon's fields
/// as the text of an `icOn` chunk after `IHDR` (`sdk.icon.file`): the
/// kind, the place unless it is `NO_ICON_POSITION`, the default tool,
/// each tool type, the stack unless 0, and for a drawer its window, its
/// scroll, its view and what it shows where they are not the defaults.
/// A string ends at its first line end. The file written is marked not
/// to be run (`FIBF_EXECUTE`); a file only half written is deleted.
///
/// CONTEXT:
/// - Waits: yes - it writes the file.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: a Process.
///
/// OWNERSHIP:
/// `object` stays the caller's; the fields may point at the caller's
/// own strings and arrays.
///
/// NOTES:
/// To copy an icon, read it with `GetDiskObject` and write it with
/// `PutDiskObject` rather than copying the file: the copy is the same,
/// and anything that follows the drawer sees an icon written.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `GetDiskObject`, `DeleteDiskObject`, `PutDefDiskObject`
///
/// EXAMPLES:
/// ```zig
/// const object = ib.GetDefDiskObject(icon.WBDRAWER) orelse return;
/// defer ib.FreeDiskObject(object);
/// object.current_x = 20;
/// object.current_y = 10;
/// _ = ib.PutDiskObject("RAM:Work", object);
/// ```
pub fn PutDiskObject(base: *IconBase, name: [*:0]const u8, object: *const icon.DiskObject) bool {
    const sys = base.sys_base;
    const dl = base.dos_base;
    const image = object.image orelse {
        _ = dl.SetIoErr(dos.ERROR_REQUIRED_ARG_MISSING);
        return false;
    };
    const picture = _picture.ofImage(image) orelse {
        _ = dl.SetIoErr(dos.ERROR_OBJECT_WRONG_TYPE);
        return false;
    };
    const path = _object.infoName(base, name) orelse return false;
    defer sys.FreeVec(path);

    // The fields' text first, then the whole file in one block:
    // signature, IHDR, the fields' chunk, the rest of the picture's chunks.
    const text_memory = sys.AllocVec(iconfile.FIELDS_MAX, exec.MEMF_ANY) orelse {
        _ = dl.SetIoErr(dos.ERROR_NO_FREE_STORE);
        return false;
    };
    defer sys.FreeVec(text_memory);
    const text: [*]u8 = @ptrCast(text_memory);
    const length = iconfile.writeFields(object, text[0..iconfile.FIELDS_MAX]) orelse {
        _ = dl.SetIoErr(dos.ERROR_OBJECT_TOO_LARGE);
        return false;
    };
    const kept = picture.kept();
    const size = decode.signature.len + picture.header.len + length + 12 + kept.len;
    const memory = sys.AllocVec(size, exec.MEMF_ANY) orelse {
        _ = dl.SetIoErr(dos.ERROR_NO_FREE_STORE);
        return false;
    };
    defer sys.FreeVec(memory);
    const bytes: [*]u8 = @ptrCast(memory);
    var at: usize = 0;
    @memcpy(bytes[at..][0..decode.signature.len], &decode.signature);
    at += decode.signature.len;
    @memcpy(bytes[at..][0..picture.header.len], &picture.header);
    at += picture.header.len;
    at += iconfile.putChunk(iconfile.CHUNK_ID, text[0..length], bytes[at..][0 .. length + 12]);
    @memcpy(bytes[at..][0..kept.len], kept);
    at += kept.len;

    const file = dl.Open(path, dos.MODE_NEWFILE) orelse return false;
    var ok = dl.Write(file, bytes, @intCast(at)) == @as(isize, @intCast(at));
    var failure = dl.IoErr();
    if (!dl.Close(file) and ok) {
        ok = false;
        failure = dl.IoErr();
    }
    if (!ok) {
        _ = dl.DeleteFile(path);
        _ = dl.SetIoErr(if (failure != 0) failure else dos.ERROR_DISK_FULL);
        return false;
    }
    _ = dl.SetProtection(path, dos.FIBF_EXECUTE);
    return true;
}
