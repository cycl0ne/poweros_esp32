// SPDX-License-Identifier: MPL-2.0
//! SetVar: sets or deletes a local variable or alias, or a global variable.

const sdk = @import("sdk");
const dos = sdk.dos;
const DosBase = @import("../dos_base.zig").DosBase;
const _process = @import("_process.zig");
const setGlobal = _process.setGlobal;
const insertSorted = _process.insertSorted;
const freeVar = _process.freeVar;
const fail = _process.fail;
const newVar = _process.newVar;
const findIn = _process.findIn;

/// Sets or deletes a local variable or alias, or a global variable.
///
/// SYNOPSIS:
/// ```zig
/// fn SetVar(db: *DosBase, name: [*:0]const u8, buffer: ?[*]const u8, size: isize, flags: u32) bool
/// ```
///
/// SINCE: 1.0. LVO -492.
///
/// INPUTS:
/// - `name` - the variable's name.
/// - `buffer` - its value; null deletes the variable.
/// - `size` - the value's length in bytes; -1 takes `buffer` as a string
///   and counts it.
/// - `flags` - the type in the low byte (LV_VAR or LV_ALIAS), with
///   GVF_GLOBAL_ONLY, GVF_LOCAL_ONLY, GVF_BINARY_VAR and GVF_SAVE_VAR.
///
/// RESULT:
/// True on success. False otherwise, with IoErr set: ERROR_NO_FREE_STORE,
/// ERROR_OBJECT_NOT_FOUND when deleting a local variable that isn't there
/// with GVF_LOCAL_ONLY or deleting an alias that isn't there,
/// ERROR_OBJECT_WRONG_TYPE for setting a global alias,
/// ERROR_LINE_TOO_LONG for a global name that makes a path over 255
/// characters, or the file system's error for a global one.
///
/// BEHAVIOR:
/// Without GVF_GLOBAL_ONLY, a process's local variable of that name and
/// type is replaced by a new one (or deleted), kept sorted by name. A null
/// `buffer` with no local variable goes on to delete the global one, unless
/// GVF_LOCAL_ONLY. A global variable is the file ENV:name, written whole;
/// when ENV: is a late assign whose directory is missing, the directory is
/// made and the write tried again. GVF_SAVE_VAR writes, or deletes,
/// ENVARC:name too, and a failure there is ignored. A plain task has no
/// local variables, so it always sets the global one.
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
/// dos keeps a copy of the name and value; `buffer` stays the caller's.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `GetVar`, `DeleteVar`, `FindVar`
///
/// EXAMPLES:
/// ```zig
/// _ = dos_lib.SetVar("Editor", "Ed", -1, dos.LV_VAR | dos.GVF_GLOBAL_ONLY);
/// ```
pub fn SetVar(db: *DosBase, name: [*:0]const u8, buffer: ?[*]const u8, size: isize, flags: u32) bool {
    const var_type: u8 = @truncate(flags);
    const value_len: usize = if (buffer) |b|
        (if (size < 0) db.utility_base.Strlen(@as([*:0]const u8, @ptrCast(b))) else @intCast(size))
    else
        0;
    if (flags & dos.GVF_GLOBAL_ONLY == 0) {
        if (_process.currentProcess(db.sys_base)) |proc| {
            const old = findIn(db, proc, name, var_type);
            if (buffer) |b| {
                const v = newVar(db, name, b[0..value_len], var_type, @truncate(flags & dos.GVF_BINARY_VAR)) orelse
                    return fail(db, dos.ERROR_NO_FREE_STORE);
                if (old) |o| freeVar(db, o);
                insertSorted(db, proc, v);
                return true;
            }
            if (old) |o| {
                freeVar(db, o);
                return true;
            }
        }
        if (flags & dos.GVF_LOCAL_ONLY != 0) return fail(db, dos.ERROR_OBJECT_NOT_FOUND);
    }
    if (var_type != dos.LV_VAR) {
        // Aliases are only ever local: one to delete that wasn't found
        // there is not anywhere.
        if (buffer == null) return fail(db, dos.ERROR_OBJECT_NOT_FOUND);
        return fail(db, dos.ERROR_OBJECT_WRONG_TYPE);
    }
    return setGlobal(db, name, buffer, value_len, flags);
}
