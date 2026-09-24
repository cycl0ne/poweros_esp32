// SPDX-License-Identifier: MPL-2.0
//! AddPart: appends a name to a path in the caller's buffer.

const sdk = @import("sdk");
const dos = sdk.dos;
const DosBase = @import("../dos_base.zig").DosBase;

/// Appends a name to a path in the caller's buffer.
///
/// SYNOPSIS:
/// ```zig
/// fn AddPart(db: *DosBase, dirname: [*:0]u8, filename: [*:0]const u8, size: u32) bool
/// ```
///
/// SINCE: 1.0. LVO -104.
///
/// INPUTS:
/// - `dirname` - the path, in a buffer that gets the result.
/// - `filename` - the name to add.
/// - `size` - the buffer's size in bytes, the NUL included.
///
/// RESULT:
/// True with the joined path in `dirname`; false, with IoErr
/// ERROR_LINE_TOO_LONG, when it would not fit (a `size` of 0 included).
/// `dirname` is then unchanged.
///
/// BEHAVIOR:
/// A '/' goes between the two unless `dirname` is empty or already ends in
/// ':' or '/'. A `filename` with a colon is a whole path of its own: it
/// replaces `dirname`, except that one starting with ':' - the root of a
/// volume - keeps `dirname`'s device part and replaces what follows it.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no; it sets IoErr.
/// - Forbid: not needed.
/// - Process: a Task will do; IoErr is then not set.
///
/// OWNERSHIP:
/// Nothing is allocated. Both strings stay the caller's.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `FilePart`, `PathPart`, `SplitName`
///
/// EXAMPLES:
/// ```zig
/// var path: [256]u8 = undefined;
/// _ = utility_lib.Strlcpy(&path, path.len, "SYS:c");
/// if (!dos_lib.AddPart(@ptrCast(&path), "dir", path.len)) return dos_lib.IoErr();
/// // path is "SYS:c/dir"
/// ```
pub fn AddPart(db: *DosBase, dirname: [*:0]u8, filename: [*:0]const u8, size: u32) bool {
    const dos_lib = db.iface();
    const utility_lib = db.utility_base;
    const dir = dirname[0..utility_lib.Strlen(dirname)];
    const file = filename[0..utility_lib.Strlen(filename)];
    var at: usize = dir.len;
    var slash = false;
    if (utility_lib.Strchr(filename, ':') != null) {
        at = if (file[0] == ':') (if (utility_lib.Strchr(dirname, ':')) |colon| @intFromPtr(colon) - @intFromPtr(dirname) else 0) else 0;
    } else if (dir.len != 0 and dir[dir.len - 1] != ':' and dir[dir.len - 1] != '/') {
        slash = true;
        at += 1;
    }
    if (size == 0 or at + file.len + 1 > size) {
        _ = dos_lib.SetIoErr(dos.ERROR_LINE_TOO_LONG);
        return false;
    }
    if (slash) dirname[dir.len] = '/';
    db.sys_base.CopyMem(filename, dirname + at, file.len);
    dirname[at + file.len] = 0;
    return true;
}
