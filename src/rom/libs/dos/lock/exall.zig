// SPDX-License-Identifier: MPL-2.0
//! ExAll: many entries of a directory into a buffer at once.

const sdk = @import("sdk");
const dos = sdk.dos;
const DosBase = @import("../dos_base.zig").DosBase;
const _lock = @import("_lock.zig");
const packets = @import("../packet/_packet.zig");
const emulate = _lock.emulate;
const asArg = _lock.asArg;
const ActionCode = dos.ActionCode;
const portFor = _lock.portFor;
const fail = _lock.fail;
const FileLock = dos.FileLock;

/// Reads entries of a directory into a buffer, as many as fit.
///
/// SYNOPSIS:
/// ```zig
/// fn ExAll(db: *DosBase, lock: ?*FileLock, buffer: [*]u8, size: isize, data_type: i32, control: *dos.ExAllControl) bool
/// ```
///
/// SINCE: 1.0. LVO -244.
///
/// INPUTS:
/// - `lock` - the directory; null is the current file system's root.
/// - `buffer` - where the ExAllData records go, linked through `next`.
/// - `size` - the buffer's size in bytes.
/// - `data_type` - which fields each record has, ED_NAME .. ED_OWNER.
/// - `control` - from AllocDosObject(DOS_EXALLCONTROL), last_key 0 at the
///   start; match_string and match_func choose entries.
///
/// RESULT:
/// True: records are in the buffer (control.entries of them, which may be
/// 0) and more are to come, so call again. False: the listing is over,
/// with IoErr ERROR_NO_MORE_ENTRIES, or failed. When dos does the listing,
/// a buffer that cannot hold even one record ends it with
/// ERROR_BUFFER_OVERFLOW. A `data_type` outside
/// ED_NAME .. ED_OWNER fails with ERROR_BAD_NUMBER before the handler is
/// asked; no handler for a null lock is ERROR_DEVICE_NOT_MOUNTED.
///
/// BEHAVIOR:
/// ACTION_EXAMINE_ALL to the handler. A handler that doesn't know it gets
/// the listing done for it with EXAMINE_OBJECT and EXAMINE_NEXT, which
/// comes out the same: records aligned for their pointers, the strings
/// after the fields, match_string (a pattern from ParsePatternNoCase)
/// tried before match_func, and an entry either leaves out taking no room.
///
/// CONTEXT:
/// - Waits: yes, for the handler.
/// - Interrupts: no.
/// - Forbid: never under Forbid.
/// - Process: a Process, for IoErr.
///
/// OWNERSHIP:
/// The buffer is the caller's; a listing done for the handler holds a
/// FileInfoBlock of dos's until it ends or `ExAllEnd` stops it. Stop a
/// listing that isn't run to its end with `ExAllEnd`.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ExAllEnd`, `Examine`, `ExNext`, `AllocDosObject`
///
/// EXAMPLES:
/// ```zig
/// const control: *dos.ExAllControl = @ptrCast(@alignCast(dos_lib.AllocDosObject(dos.DOS_EXALLCONTROL, null).?));
/// defer dos_lib.FreeDosObject(dos.DOS_EXALLCONTROL, control);
/// var buffer: [1024]u8 align(8) = undefined;
/// while (true) {
///     const more = dos_lib.ExAll(dir, &buffer, buffer.len, dos.ED_SIZE, control);
///     var rec: ?*dos.ExAllData = if (control.entries > 0) @ptrCast(&buffer) else null;
///     while (rec) |r| : (rec = r.next) {
///         // r.name, r.size
///     }
///     if (!more) break;
/// }
/// ```
pub fn ExAll(db: *DosBase, lock: ?*FileLock, buffer: [*]u8, size: isize, data_type: i32, control: *dos.ExAllControl) bool {
    if (data_type < dos.ED_NAME or data_type > dos.ED_OWNER) return fail(db, dos.ERROR_BAD_NUMBER);
    const port = portFor(db, lock) orelse return fail(db, dos.ERROR_DEVICE_NOT_MOUNTED);
    const answer = packets.exchange(db.sys_base, port, @intFromEnum(ActionCode.examine_all), .{
        asArg(lock), asArg(buffer), size, data_type, asArg(control),
    }) orelse return fail(db, dos.ERROR_NO_FREE_STORE);
    if (answer.res1 != 0) return true;
    if (answer.res2 != dos.ERROR_ACTION_NOT_KNOWN) return fail(db, answer.res2);
    return emulate(db, lock, buffer, size, data_type, control);
}
