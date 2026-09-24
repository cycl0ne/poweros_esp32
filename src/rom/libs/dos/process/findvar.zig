// SPDX-License-Identifier: MPL-2.0
//! FindVar: finds the running process's local variable or alias.

const sdk = @import("sdk");
const dos = sdk.dos;
const DosBase = @import("../dos_base.zig").DosBase;
const _process = @import("_process.zig");
const findIn = _process.findIn;

/// Finds a process's local variable or alias by name.
///
/// SYNOPSIS:
/// ```zig
/// fn FindVar(db: *DosBase, name: [*:0]const u8, var_type: u32) ?*dos.LocalVar
/// ```
///
/// SINCE: 1.0. LVO -504.
///
/// INPUTS:
/// - `name` - the variable's name, matched in any case.
/// - `var_type` - LV_VAR or LV_ALIAS, in the low byte.
///
/// RESULT:
/// The LocalVar, or null when the running process has none of that name and
/// type, or the caller is a plain task.
///
/// BEHAVIOR:
/// Only the local list is searched, never ENV:. A variable with LVF_IGNORE
/// set matches nothing. IoErr is not set.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: not callable.
/// - Forbid: not needed, and not taken.
/// - Process: required for a result; a plain task gets null.
///
/// OWNERSHIP:
/// The LocalVar stays the process's. It is valid until the variable is set
/// or deleted, and only the process itself should use it.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `GetVar`, `SetVar`
///
/// EXAMPLES:
/// ```zig
/// if (dos_lib.FindVar("ll", dos.LV_ALIAS)) |alias| run(alias.value[0..alias.len]);
/// ```
pub fn FindVar(db: *DosBase, name: [*:0]const u8, var_type: u32) ?*dos.LocalVar {
    const proc = _process.currentProcess(db.sys_base) orelse return null;
    return findIn(db, proc, name, @truncate(var_type));
}
