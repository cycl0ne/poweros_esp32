// SPDX-License-Identifier: MPL-2.0
//! BeginSystemMemory: from here to the matching EndSystemMemory, what the
//! calling task allocates is the system's.

const ExecBase = @import("../exec.zig").ExecBase;

/// Makes what the calling task allocates the system's, until the matching
/// `EndSystemMemory`.
///
/// SYNOPSIS:
/// ```zig
/// fn BeginSystemMemory(base: *ExecBase) void
/// ```
///
/// SINCE: 1.11. LVO -548.
///
/// INPUTS:
/// None.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// Every block the task allocates from here is marked as the system's
/// (`MEMOWNER_SYSTEM`), as if each call had asked for `MEMF_SYSTEM`: the
/// blocks of `AllocMem` and `AllocVec`, a pool made, and whatever library
/// code the task calls allocates on its behalf. Pairs nest: the task's
/// count (`Task.system_memory_nest`) goes up by one here and down by one in
/// `EndSystemMemory`, and allocations are the system's while it is above 0.
///
/// It is for code that makes something the system keeps without knowing
/// what the code it calls allocates: a loader reading a module's segments
/// and running its init, which `InitResident` does inside such a pair
/// itself.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no: it is the calling task's.
/// - Locks: none taken, none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing changes hands; blocks allocated meanwhile are the system's.
///
/// NOTES:
/// Only the calling task's allocations change. A task started meanwhile
/// owns its own block and counts from 0.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `EndSystemMemory`, `AllocMem`, `InitResident`
///
/// EXAMPLES:
/// ```zig
/// sys.BeginSystemMemory();
/// defer sys.EndSystemMemory();
/// const seg_list = dos_lib.LoadSeg("LIBS:mine.library") orelse return null;
/// ```
pub fn BeginSystemMemory(base: *ExecBase) void {
    // Before the boot task nothing is any task's anyway.
    if (base.boot_task == null) return;
    const task = base.iface().FindTask(null) orelse return;
    task.system_memory_nest += 1;
}
