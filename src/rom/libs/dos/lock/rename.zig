// SPDX-License-Identifier: MPL-2.0
//! Rename: renames or moves an object within its volume.

const sdk = @import("sdk");
const dos = sdk.dos;
const DosBase = @import("../dos_base.zig").DosBase;
const _lock = @import("_lock.zig");
const packets = @import("../packet/_packet.zig");
const asArg = _lock.asArg;
const fail = _lock.fail;
/// The longest name a handler is sent.
const max_name = 255;

/// Renames or moves an object on its volume.
///
/// SYNOPSIS:
/// ```zig
/// fn Rename(db: *DosBase, from: [*:0]const u8, to: [*:0]const u8) bool
/// ```
///
/// SINCE: 1.0. LVO -348.
///
/// INPUTS:
/// - `from` - the object's name, as for Lock.
/// - `to` - its new name, which may be in another directory of the same
///   volume ("RAM:a" to "RAM:d/b").
///
/// RESULT:
/// True when the object was renamed. False otherwise, with IoErr set:
/// ERROR_LINE_TOO_LONG for a name over 255 characters,
/// ERROR_RENAME_ACROSS_DEVICES when the two names are on different
/// handlers, ERROR_DEVICE_NOT_MOUNTED for a node with no handler,
/// ERROR_NO_FREE_STORE when the packet could not be sent, and whatever the
/// handler answers - ERROR_OBJECT_EXISTS when `to` is already there,
/// ERROR_OBJECT_NOT_FOUND when `from` isn't.
///
/// BEHAVIOR:
/// Both names are resolved with GetDeviceProc. `to` is taken in the first
/// directory of its path, where a new object would be made. `from` is
/// looked for along its multi-assign: while the handler answers
/// ERROR_OBJECT_NOT_FOUND and the name is an assign, the next directory is
/// tried. ACTION_RENAME_OBJECT is sent as (source directory, `from`, target
/// directory, `to`); the handler strips the device part of each name.
///
/// CONTEXT:
/// - Waits: yes, for the handler's answer.
/// - Interrupts: not callable.
/// - Forbid: must not be held.
/// - Process: a Task will do; only a process gets IoErr.
///
/// OWNERSHIP:
/// Nothing is kept. The strings stay the caller's; the handler copies what
/// it needs.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `Lock`, `DeleteFile`, `GetDeviceProc`
///
/// EXAMPLES:
/// ```zig
/// if (!dos_lib.Rename("RAM:draft", "RAM:done/final")) {
///     _ = dos_lib.PrintFault(dos_lib.IoErr(), "Rename");
/// }
/// ```
pub fn Rename(db: *DosBase, from: [*:0]const u8, to: [*:0]const u8) bool {
    const dos_lib = db.iface();
    const sys = db.sys_base;
    if (db.utility_base.Strlen(from) > max_name or db.utility_base.Strlen(to) > max_name) return fail(db, dos.ERROR_LINE_TOO_LONG);
    const target = dos_lib.GetDeviceProc(to, null) orelse return false;
    defer dos_lib.FreeDeviceProc(target);
    var dp = dos_lib.GetDeviceProc(from, null) orelse return false;
    while (true) {
        if (dp.port != target.port) {
            dos_lib.FreeDeviceProc(dp);
            return fail(db, dos.ERROR_RENAME_ACROSS_DEVICES);
        }
        const port = dp.port orelse {
            dos_lib.FreeDeviceProc(dp);
            return fail(db, dos.ERROR_DEVICE_NOT_MOUNTED);
        };
        const answer = packets.exchange(sys, port, @intFromEnum(dos.ActionCode.rename_object), .{
            asArg(dp.lock), asArg(from), asArg(target.lock), asArg(to), 0,
        }) orelse {
            dos_lib.FreeDeviceProc(dp);
            return fail(db, dos.ERROR_NO_FREE_STORE);
        };
        if (answer.res1 != 0) {
            dos_lib.FreeDeviceProc(dp);
            return true;
        }
        if (answer.res2 != dos.ERROR_OBJECT_NOT_FOUND or dp.flags & dos.DVPF_ASSIGN == 0) {
            dos_lib.FreeDeviceProc(dp);
            return fail(db, answer.res2);
        }
        // The source's next directory.
        const next = dos_lib.GetDeviceProc(from, dp) orelse {
            dos_lib.FreeDeviceProc(dp);
            return fail(db, dos.ERROR_OBJECT_NOT_FOUND);
        };
        if (next != dp) dos_lib.FreeDeviceProc(dp);
        dp = next;
    }
}
