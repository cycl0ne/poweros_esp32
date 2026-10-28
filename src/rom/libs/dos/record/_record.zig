// SPDX-License-Identifier: MPL-2.0
//! Record locks: what LockRecord and UnLockRecord share - a packet about
//! an open file, sent with all seven slots, since a record's 64-bit
//! offset and length take two each where a slot is 32 bits.

const sdk = @import("sdk");
const dos = sdk.dos;
const DosBase = @import("../dos_base.zig").DosBase;
const packets = @import("../packet/_packet.zig");
const _request = @import("../file/_request.zig");
const FileHandle = dos.FileHandle;

/// Sends LOCK_RECORD or FREE_RECORD about `file` to its handler.
///
/// INPUTS:
/// - `db` - the library's base.
/// - `file` - the handle; null is `ERROR_INVALID_LOCK`.
/// - `action` - `.lock_record` or `.free_record`.
/// - `args` - the packet's arguments, through its view.
///
/// RESULT:
/// True when the handler said DOSTRUE. False with `IoErr()` its dp_Res2,
/// `ERROR_INVALID_LOCK` for a handle without a handler, or
/// `ERROR_NO_FREE_STORE` when no packet can be sent.
pub fn send(db: *DosBase, file: ?*FileHandle, action: dos.ActionCode, args: dos.PacketArgs) bool {
    const dos_lib = db.iface();
    const fh = file orelse return refuse(db, dos.ERROR_INVALID_LOCK);
    const port = fh.task orelse return refuse(db, dos.ERROR_INVALID_LOCK);
    _request.settle(db, fh);
    const answer = packets.exchangeArgs(db.sys_base, port, @intFromEnum(action), args) orelse
        return refuse(db, dos.ERROR_NO_FREE_STORE);
    if (answer.res1 == dos.DOSFALSE) {
        _ = dos_lib.SetIoErr(answer.res2);
        return false;
    }
    return true;
}

/// Sets `IoErr()` and answers false.
///
/// INPUTS:
/// - `db` - the library's base.
/// - `code` - the error.
pub fn refuse(db: *DosBase, code: i32) bool {
    const dos_lib = db.iface();
    _ = dos_lib.SetIoErr(code);
    return false;
}
