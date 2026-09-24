// SPDX-License-Identifier: MPL-2.0
//! ExAllEnd: stops an ExAll listing before its end.

const sdk = @import("sdk");
const dos = sdk.dos;
const DosBase = @import("../dos_base.zig").DosBase;
const _lock = @import("_lock.zig");
const packets = @import("../packet/_packet.zig");
const takeNothing = _lock.takeNothing;
const Hook = sdk.utility.Hook;
const ActionCode = dos.ActionCode;
const asArg = _lock.asArg;
const portFor = _lock.portFor;
const FileLock = dos.FileLock;

/// Stops an ExAll listing before its end.
///
/// SYNOPSIS:
/// ```zig
/// fn ExAllEnd(db: *DosBase, lock: ?*FileLock, buffer: [*]u8, size: isize, data_type: i32, control: *dos.ExAllControl) void
/// ```
///
/// SINCE: 1.0. LVO -248.
///
/// INPUTS:
/// - `lock` - the directory, as given to `ExAll`.
/// - `buffer` - the buffer, as given to `ExAll`.
/// - `size` - its size.
/// - `data_type` - the level, as given to `ExAll`.
/// - `control` - the listing's control.
///
/// RESULT:
/// Nothing. IoErr is as it was before the call.
///
/// BEHAVIOR:
/// ACTION_EXAMINE_ALL_END to the handler. One that doesn't know it has
/// its listing run to the end instead, with a MatchFunc that takes nothing
/// so the buffer isn't written; the caller's hook is put back after. A
/// listing dos was doing for the handler has its FileInfoBlock freed and
/// last_key set to 0.
///
/// CONTEXT:
/// - Waits: yes, for the handler.
/// - Interrupts: no.
/// - Forbid: never under Forbid.
/// - Process: a Process.
///
/// OWNERSHIP:
/// Whatever the listing held is freed. The control is the caller's, ready
/// for a new listing.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ExAll`
///
/// EXAMPLES:
/// ```zig
/// if (found) dos_lib.ExAllEnd(dir, &buffer, buffer.len, dos.ED_NAME, control);
/// ```
pub fn ExAllEnd(db: *DosBase, lock: ?*FileLock, buffer: [*]u8, size: isize, data_type: i32, control: *dos.ExAllControl) void {
    const dos_lib = db.iface();
    const sys = db.sys_base;
    const saved = dos_lib.IoErr();
    defer _ = dos_lib.SetIoErr(saved);
    const port = portFor(db, lock) orelse return;
    const args: [5]isize = .{ asArg(lock), asArg(buffer), size, data_type, asArg(control) };
    const answer = packets.exchange(sys, port, @intFromEnum(ActionCode.examine_all_end), args) orelse return;
    if (answer.res1 != 0 or answer.res2 != dos.ERROR_ACTION_NOT_KNOWN) return;
    var nothing: Hook = .{ .entry = &takeNothing };
    const hook = control.match_func;
    control.match_func = &nothing;
    defer control.match_func = hook;
    while (true) {
        const more = packets.exchange(sys, port, @intFromEnum(ActionCode.examine_all), args) orelse return;
        if (more.res1 != 0) continue;
        if (more.res2 == dos.ERROR_ACTION_NOT_KNOWN and control.last_key != 0) {
            dos_lib.FreeDosObject(dos.DOS_FIB, @ptrFromInt(control.last_key));
            control.last_key = 0;
        }
        return;
    }
}
