// SPDX-License-Identifier: MPL-2.0
//! LockRecords: every record of an array locked, or none.

const sdk = @import("sdk");
const dos = sdk.dos;
const DosBase = @import("../dos_base.zig").DosBase;
const RecordLock = dos.record.RecordLock;

/// Locks a series of records.
///
/// SYNOPSIS:
/// ```zig
/// fn LockRecords(db: *DosBase, records: ?[*]const RecordLock, timeout: u32) bool
/// ```
///
/// SINCE: 1.7. LVO -576.
///
/// INPUTS:
/// - `records` - the records, each a handle, an offset, a length and a
///   mode as `LockRecord` takes them; the array ends at the first entry
///   whose `fh` is null. Null locks nothing.
/// - `timeout` - how long each record may wait, in ticks of 1/50 s.
///
/// RESULT:
/// True when every record is locked. False when one could not be, with
/// `IoErr()` saying why as `LockRecord` does; then none is locked.
///
/// BEHAVIOR:
/// `LockRecord` for each record, in the array's order, each waiting up to
/// `timeout`. When one fails, the ones already locked are given back, the
/// last first, and `IoErr()` keeps the failure's code.
///
/// CONTEXT:
/// - Waits: yes, for the handlers, and up to `timeout` for each record.
/// - Interrupts: no.
/// - Locks: no spinlock may be held around it: it waits.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The array stays the caller's, and must not change while its records
/// are locked: `UnLockRecords` takes the same one back.
///
/// NOTES:
/// - Programs that lock the same records should list them in one order,
///   so that two of them never wait for each other.
/// - The records may be in different files and on different volumes.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `LockRecord`, `UnLockRecords`, `UnLockRecord`
///
/// EXAMPLES:
/// ```zig
/// // An index entry and the data it points at, both or neither.
/// const records = [_]dos.record.RecordLock{
///     .{ .fh = index, .offset = entry * 16, .length = 16 },
///     .{ .fh = data, .offset = place, .length = size },
///     .{},
/// };
/// if (!dos_lib.LockRecords(&records, 100)) return dos_lib.IoErr();
/// defer _ = dos_lib.UnLockRecords(&records);
/// ```
pub fn LockRecords(db: *DosBase, records: ?[*]const RecordLock, timeout: u32) bool {
    const dos_lib = db.iface();
    const array = records orelse return true;
    var count: usize = 0;
    while (array[count].fh) |fh| : (count += 1) {
        const record = array[count];
        if (dos_lib.LockRecord(fh, record.offset, record.length, record.mode, timeout)) continue;
        const code = dos_lib.IoErr();
        while (count > 0) {
            count -= 1;
            _ = dos_lib.UnLockRecord(array[count].fh, array[count].offset, array[count].length);
        }
        _ = dos_lib.SetIoErr(code);
        return false;
    }
    return true;
}
