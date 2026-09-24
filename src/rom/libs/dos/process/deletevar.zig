// SPDX-License-Identifier: MPL-2.0
//! DeleteVar: deletes a local variable or alias, or a global variable.

const DosBase = @import("../dos_base.zig").DosBase;

/// Deletes a local variable or alias, or a global variable.
///
/// SYNOPSIS:
/// ```zig
/// fn DeleteVar(db: *DosBase, name: [*:0]const u8, flags: u32) bool
/// ```
///
/// SINCE: 1.0. LVO -500.
///
/// INPUTS:
/// - `name` - the variable's name.
/// - `flags` - the type in the low byte (LV_VAR or LV_ALIAS), with
///   GVF_GLOBAL_ONLY, GVF_LOCAL_ONLY and GVF_SAVE_VAR, as for SetVar.
///
/// RESULT:
/// True when the variable was deleted. False otherwise, with IoErr set, as
/// SetVar answers.
///
/// BEHAVIOR:
/// The same as SetVar with a null buffer: the local variable if there is
/// one, else the global file ENV:name (unless GVF_LOCAL_ONLY), and
/// ENVARC:name as well with GVF_SAVE_VAR.
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
/// Nothing is kept.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `SetVar`, `GetVar`
///
/// EXAMPLES:
/// ```zig
/// _ = dos_lib.DeleteVar("Editor", dos.LV_VAR | dos.GVF_GLOBAL_ONLY);
/// ```
pub fn DeleteVar(db: *DosBase, name: [*:0]const u8, flags: u32) bool {
    const dos_lib = db.iface();
    return dos_lib.SetVar(name, null, 0, flags);
}
