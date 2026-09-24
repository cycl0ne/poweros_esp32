// SPDX-License-Identifier: MPL-2.0
//! InitCode: starts every resident of a start class, highest priority
//! first, each with `InitResident`. A resident that fails stops the walk;
//! one that is a library or device exec had to build stops the machine,
//! since what comes after may depend on it.

const sdk = @import("sdk");
const Alert = @import("../interrupt/alert.zig").Alert;

const ExecBase = @import("../exec.zig").ExecBase;

/// Starts every resident module of a start class, highest priority first.
///
/// SYNOPSIS:
/// ```zig
/// fn InitCode(base: *ExecBase, start_class: u32, version: u32) ?*anyopaque
/// ```
///
/// SINCE: 1.0. LVO -356.
///
/// INPUTS:
/// - `start_class` - the flag bits a tag must **all** have:
///   `RTF_SINGLETASK` before multitasking, `RTF_COLDSTART` for the ordinary
///   boot, `RTF_AFTERDOS` once dos.library is up.
/// - `min_version` - the lowest version to start, or 0 for any.
///
/// RESULT:
/// SysBase if every one of them started, or null if one failed - and the
/// rest are then not started at all.
///
/// BEHAVIOR:
/// Priority order is the machine's boot order, and it is the only thing
/// sequencing the modules: a driver at a lower priority than the library it
/// registers with can rely on that library being there.
///
/// **A module that fails stops the boot.** For an `RTF_AUTOINIT` tag that
/// is a dead-end alert rather than a return, since a library that could not
/// be built leaves everything above it with nothing to open.
///
/// CONTEXT:
/// - Waits: whatever the modules do. Cold start runs on the exec task after
///   `Permit`, so a module may wait, allocate and open other modules.
/// - Interrupts: no.
/// - Forbid: **not held.** A module that needs the machine to itself takes
///   Forbid for itself - which is what the display driver does, since the
///   panel is held in reset for tens of milliseconds.
/// - Process: a Task. There is no Process until dos.library is up, which is
///   itself a cold-start module.
///
/// OWNERSHIP:
/// Each module owns what it made.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `InitResident`, `FindResident`
///
/// EXAMPLES:
/// ```zig
/// _ = sys.InitCode(exec.RTF_AFTERDOS, 0);
/// ```
pub fn InitCode(base: *ExecBase, start_class: u32, version: u32) ?*anyopaque {
    const table = base.res_modules orelse return base;
    var index: usize = 0;
    while (table[index]) |tag| : (index += 1) {
        if (tag.flags & start_class != start_class) continue;
        if (version != 0 and tag.version < version) continue;
        if (base.iface().InitResident(tag, null) == null) {
            // Alert direct, not through the table: the path that reports a
            // broken machine must not depend on a replaced vector
            // (codex rule 1).
            if (tag.flags & sdk.exec.RTF_AUTOINIT != 0) Alert(base, sdk.exec.AT_DeadEnd | sdk.exec.AG_MakeLib);
            return null;
        }
    }
    return base;
}
