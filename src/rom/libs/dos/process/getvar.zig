// SPDX-License-Identifier: MPL-2.0
//! GetVar: reads a variable's value, local first, then global.

const sdk = @import("sdk");
const dos = sdk.dos;
const DosBase = @import("../dos_base.zig").DosBase;
const _process = @import("_process.zig");
const varPath = _process.varPath;
const deliver = _process.deliver;
const findIn = _process.findIn;
const fail = _process.fail;

/// Reads a variable's value into a buffer.
///
/// SYNOPSIS:
/// ```zig
/// fn GetVar(db: *DosBase, name: [*:0]const u8, buffer: [*]u8, size: isize, flags: u32) isize
/// ```
///
/// SINCE: 1.0. LVO -496.
///
/// INPUTS:
/// - `name` - the variable's name.
/// - `buffer` - where the value goes.
/// - `size` - the buffer's size in bytes, at least 1.
/// - `flags` - the type in the low byte (LV_VAR or LV_ALIAS), with
///   GVF_GLOBAL_ONLY, GVF_LOCAL_ONLY, GVF_BINARY_VAR and
///   GVF_DONT_NULL_TERM.
///
/// RESULT:
/// The bytes put in the buffer, the NUL not counted, with IoErr set to the
/// value's whole length - more than the result when it was cut. -1 on
/// failure, with IoErr set: ERROR_BAD_NUMBER for a size below 1,
/// ERROR_OBJECT_NOT_FOUND when there is no such variable,
/// ERROR_LINE_TOO_LONG for a name that makes too long a path.
///
/// BEHAVIOR:
/// The process's local variable of that name and type comes first (unless
/// GVF_GLOBAL_ONLY), then the file ENV:name (unless GVF_LOCAL_ONLY; only
/// for LV_VAR). A text value is cut at its first newline and ended with a
/// NUL, which takes one byte of `size`. With GVF_BINARY_VAR the value is
/// copied as it is, and with GVF_DONT_NULL_TERM as well, no NUL is added.
///
/// CONTEXT:
/// - Waits: yes, for a global variable (file system packets); not for a
///   local one.
/// - Interrupts: not callable.
/// - Forbid: must not be held.
/// - Process: a Task will do for a global variable; only a process has
///   local ones and gets IoErr.
///
/// OWNERSHIP:
/// The buffer is the caller's. Nothing is kept.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `SetVar`, `FindVar`, `DeleteVar`
///
/// EXAMPLES:
/// ```zig
/// var value: [64]u8 = undefined;
/// if (dos_lib.GetVar("Editor", &value, value.len, dos.LV_VAR) < 0) return;
/// ```
pub fn GetVar(db: *DosBase, name: [*:0]const u8, buffer: [*]u8, size: isize, flags: u32) isize {
    const dos_lib = db.iface();
    if (size <= 0) {
        _ = fail(db, dos.ERROR_BAD_NUMBER);
        return -1;
    }
    const room: usize = @intCast(size);
    const var_type: u8 = @truncate(flags);
    const binary = flags & dos.GVF_BINARY_VAR != 0;
    const null_term = !(binary and flags & dos.GVF_DONT_NULL_TERM != 0);
    if (flags & dos.GVF_GLOBAL_ONLY == 0) {
        if (_process.currentProcess(db.sys_base)) |proc| {
            if (findIn(db, proc, name, var_type)) |v| return deliver(db, v.value[0..v.len], v.len, buffer, room, binary, null_term);
        }
    }
    if (flags & dos.GVF_LOCAL_ONLY != 0 or var_type != dos.LV_VAR) {
        _ = fail(db, dos.ERROR_OBJECT_NOT_FOUND);
        return -1;
    }
    var path: [256]u8 = undefined;
    const env = varPath(db, &path, "ENV:", name) orelse {
        _ = fail(db, dos.ERROR_LINE_TOO_LONG);
        return -1;
    };
    const fh = dos_lib.Open(env, dos.MODE_OLDFILE) orelse {
        _ = fail(db, dos.ERROR_OBJECT_NOT_FOUND);
        return -1;
    };
    defer _ = dos_lib.Close(fh);
    _ = dos_lib.Seek(fh, 0, dos.OFFSET_END);
    const total = dos_lib.Seek(fh, 0, dos.OFFSET_BEGINNING);
    const got = dos_lib.Read(fh, buffer, @intCast(room));
    if (total < 0 or got < 0) return -1;
    return deliver(db, buffer[0..@intCast(got)], @intCast(total), buffer, room, binary, null_term);
}
