// SPDX-License-Identifier: MPL-2.0
//! ChangeMode: changes the access a lock or an open file has.

const sdk = @import("sdk");
const dos = sdk.dos;
const DosBase = @import("../dos_base.zig").DosBase;
const _lock = @import("_lock.zig");
const packets = @import("../packet/_packet.zig");
const asArg = _lock.asArg;
const ActionCode = dos.ActionCode;
const FileHandle = dos.FileHandle;
const FileLock = dos.FileLock;
const MsgPort = sdk.exec.MsgPort;
const failZero = _lock.failZero;

/// Changes a lock or an open file between shared and exclusive access.
///
/// SYNOPSIS:
/// ```zig
/// fn ChangeMode(db: *DosBase, kind: i32, object: ?*anyopaque, mode: i32) bool
/// ```
///
/// SINCE: 1.0. LVO -388.
///
/// INPUTS:
/// - `kind` - CHANGE_LOCK for a FileLock, CHANGE_FH for a FileHandle.
/// - `object` - the lock or the handle.
/// - `mode` - for a lock SHARED_LOCK or EXCLUSIVE_LOCK; for a handle
///   MODE_NEWFILE for exclusive, anything else for shared.
///
/// RESULT:
/// True if the access changed; false with IoErr(): ERROR_INVALID_LOCK for a
/// null object or one without a handler, ERROR_OBJECT_WRONG_TYPE for an
/// unknown `kind`, ERROR_OBJECT_IN_USE while others hold it, or the
/// handler's error.
///
/// BEHAVIOR:
/// The object's handler is sent ACTION_CHANGE_MODE with `kind`, the object
/// and `mode`; the handler decides.
///
/// CONTEXT:
/// - Waits: yes, for the handler's answer to a packet.
/// - Interrupts: no.
/// - Forbid: must not be held.
/// - Process: a Task will do; a process gets IoErr().
///
/// OWNERSHIP:
/// The object stays the caller's.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `Lock`, `Open`
///
/// EXAMPLES:
/// ```zig
/// if (!dos_lib.ChangeMode(dos.CHANGE_LOCK, lock, dos.EXCLUSIVE_LOCK)) return error.InUse;
/// ```
pub fn ChangeMode(db: *DosBase, kind: i32, object: ?*anyopaque, mode: i32) bool {
    const obj = object orelse return failZero(db, dos.ERROR_INVALID_LOCK) != 0;
    const target: ?*MsgPort = switch (kind) {
        dos.CHANGE_LOCK => @as(*FileLock, @ptrCast(@alignCast(obj))).task,
        dos.CHANGE_FH => @as(*FileHandle, @ptrCast(@alignCast(obj))).task,
        else => return failZero(db, dos.ERROR_OBJECT_WRONG_TYPE) != 0,
    };
    const port = target orelse return failZero(db, dos.ERROR_INVALID_LOCK) != 0;
    const answer = packets.exchange(db.sys_base, port, @intFromEnum(ActionCode.change_mode), .{ kind, asArg(obj), mode, 0, 0 }) orelse
        return failZero(db, dos.ERROR_NO_FREE_STORE) != 0;
    if (answer.res1 == 0) return failZero(db, answer.res2) != 0;
    return true;
}
