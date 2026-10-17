// SPDX-License-Identifier: MPL-2.0
//! UnLockRecords: every record of a LockRecords array given back.

const sdk = @import("sdk");
const dos = sdk.dos;
const DosBase = @import("../dos_base.zig").DosBase;
const RecordLock = dos.record.RecordLock;

/// Gives back the records `LockRecords` locked.
///
/// SYNOPSIS:
/// ```zig
/// fn UnLockRecords(db: *DosBase, records: ?[*]const RecordLock) bool
/// ```
///
/// SINCE: 1.7. LVO -584.
///
/// INPUTS:
/// - `records` - the array `LockRecords` was given, ended by an entry
///   whose `fh` is null. Null gives back nothing.
///
/// RESULT:
/// True when every record was locked and is given back. False when one
/// was not, with `IoErr()` the first failure's code as `UnLockRecord`
/// gives it.
///
/// BEHAVIOR:
/// `UnLockRecord` for each record, in the array's order. A failure does
/// not stop it: every record is given back that can be.
///
/// CONTEXT:
/// - Waits: yes, for the handlers.
/// - Interrupts: no.
/// - Locks: no spinlock may be held around it: it waits.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The array stays the caller's.
///
/// NOTES:
/// - Every `LockRecords` that succeeded wants its `UnLockRecords` with the
///   same array; closing a handle gives back its records as well.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `LockRecords`, `UnLockRecord`, `LockRecord`
///
/// EXAMPLES:
/// ```zig
/// if (dos_lib.LockRecords(&records, 50)) {
///     // change both records
///     _ = dos_lib.UnLockRecords(&records);
/// }
/// ```
pub fn UnLockRecords(db: *DosBase, records: ?[*]const RecordLock) bool {
    const dos_lib = db.iface();
    const array = records orelse return true;
    var all = true;
    var code: i32 = 0;
    var index: usize = 0;
    while (array[index].fh) |fh| : (index += 1) {
        const record = array[index];
        if (dos_lib.UnLockRecord(fh, record.offset, record.length)) continue;
        if (all) code = dos_lib.IoErr();
        all = false;
    }
    if (!all) _ = dos_lib.SetIoErr(code);
    return all;
}
