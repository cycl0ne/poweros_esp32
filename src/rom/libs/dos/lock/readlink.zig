// SPDX-License-Identifier: MPL-2.0
//! ReadLink: the path that takes the place of a name that met a soft link.

const sdk = @import("sdk");
const dos = sdk.dos;
const DosBase = @import("../dos_base.zig").DosBase;
const _lock = @import("_lock.zig");
const packets = @import("../packet/_packet.zig");
const asArg = _lock.asArg;
const failZero = _lock.failZero;
const MsgPort = sdk.exec.MsgPort;
const FileLock = dos.FileLock;

/// Asks a handler for the path a soft link gives, in place of the name
/// that met it.
///
/// SYNOPSIS:
/// ```zig
/// fn ReadLink(db: *DosBase, port: *MsgPort, lock: ?*FileLock, path: [*:0]const u8, buffer: [*]u8, size: u32) i32
/// ```
///
/// SINCE: 1.9. LVO -600.
///
/// INPUTS:
/// - `port` - the handler's port: the one that answered
///   ERROR_IS_SOFT_LINK.
/// - `lock` - the directory `path` is from, on that handler; null for its
///   volume's root.
/// - `path` - the name that met the link, as it was sent.
/// - `buffer` - where the new path goes, with its NUL.
/// - `size` - the buffer's bytes; `sdk.dos.path_max + 1` holds every path.
///
/// RESULT:
/// The new path's length, without its NUL. -1 with IoErr saying why: what
/// the handler answered - ERROR_OBJECT_WRONG_TYPE when `path` meets no soft
/// link, ERROR_OBJECT_NOT_FOUND - or ERROR_NO_FREE_STORE when no packet
/// could be sent. -2 with IoErr ERROR_BUFFER_OVERFLOW when `size` bytes do
/// not hold the path and its NUL.
///
/// BEHAVIOR:
/// ACTION_READ_LINK to the handler, with (`lock`, `path`, `buffer`,
/// `size`). The handler walks `path` from `lock` to the first soft link on
/// it and answers the link's path with what of `path` came after the link
/// added behind it: the name, with the link resolved. The answer is a path
/// from `lock` too, unless it has a device part of its own (`Work:new`) or
/// begins with a colon, for the root of the link's volume. dos calls this
/// itself whenever a handler answers ERROR_IS_SOFT_LINK, so a caller of
/// Lock, Open and the others never needs it; it is for one that sends its
/// own packets.
///
/// CONTEXT:
/// - Waits: yes, for the handler.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: a Task will do; a process gets IoErr.
///
/// OWNERSHIP:
/// `path` is read and `buffer` written while the call lasts; both stay the
/// caller's.
///
/// NOTES:
/// A handler that knows no soft links answers ERROR_ACTION_NOT_KNOWN.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `MakeLink`, `Lock`, `GetDeviceProc`
///
/// EXAMPLES:
/// ```zig
/// var path: [sdk.dos.path_max + 1]u8 = undefined;
/// if (dos_lib.ReadLink(port, dir, name, &path, path.len) >= 0) {
///     _ = dos_lib.PutStr(@ptrCast(&path));
/// }
/// ```
pub fn ReadLink(db: *DosBase, port: *MsgPort, lock: ?*FileLock, path: [*:0]const u8, buffer: [*]u8, size: u32) i32 {
    const dos_lib = db.iface();
    const answer = packets.exchange(db.sys_base, port, @intFromEnum(dos.ActionCode.read_link), .{
        asArg(lock), asArg(path), asArg(buffer), @bitCast(@as(usize, size)), 0,
    }) orelse {
        _ = failZero(db, dos.ERROR_NO_FREE_STORE);
        return -1;
    };
    if (answer.res1 == -2 or answer.res1 >= size) {
        _ = failZero(db, dos.ERROR_BUFFER_OVERFLOW);
        return -2;
    }
    // An empty path is no link's: a handler answers DOSFALSE for an
    // action it does not know.
    if (answer.res1 <= 0) {
        _ = dos_lib.SetIoErr(if (answer.res2 != 0) answer.res2 else dos.ERROR_OBJECT_WRONG_TYPE);
        return -1;
    }
    return @intCast(answer.res1);
}
