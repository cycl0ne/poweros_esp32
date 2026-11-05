// SPDX-License-Identifier: MPL-2.0
//! Enable: undoes one `Disable`. The outermost one lets the system's
//! interrupt lock go - as far as it is this Disable's to let go - puts
//! the interrupt state back and takes a task switch that fell due while
//! interrupts were off.

const _interrupt = @import("_interrupt.zig");
const _task = @import("../task/_task.zig");

const ExecBase = @import("../exec.zig").ExecBase;

/// Unmasks interrupts again, and takes any task switch that came due.
///
/// SYNOPSIS:
/// ```zig
/// fn Enable(base: *ExecBase) void
/// ```
///
/// SINCE: 1.0. LVO -144.
///
/// INPUTS:
/// None.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// Only the outermost Enable unmasks, and it restores the state from before
/// the outermost Disable rather than simply enabling - so this never turns
/// interrupts on in a context that had them off. It lets the system's
/// interrupt lock go first, so the other cores' interrupts and Disables
/// come in again - unless what holds it is the handler this runs inside,
/// which keeps it until its chain is done, or the task lost it across a
/// wait, in which case there is nothing to let go.
///
/// A switch asked for while interrupts were masked - by a `Signal` or an
/// `AddTask` from inside one - is taken here, so like `ReleaseLock` this is
/// a point at which the caller may lose the processor.
///
/// CONTEXT:
/// - Waits: no, but it may switch.
/// - Interrupts: safe. Inside one, the nesting means it does not unmask.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `Disable`, `ReleaseLock`
///
/// EXAMPLES:
/// ```zig
/// sys.Disable();
/// defer sys.Enable();
/// ```
pub fn Enable(base: *ExecBase) void {
    // Inside Disable, so masked: the caller is on this core.
    const cpu = base.cpu();
    cpu.id_nest_cnt -= 1;
    if (cpu.id_nest_cnt >= 0) return;
    // Nothing to let go when the task lost it across a wait, or when
    // what holds it is the handler this runs in.
    _interrupt.dropSystemInterrupts(base);
    // A Signal or AddTask may have asked for a switch; taken once the
    // interrupts are back.
    const due = _task.switchDue(base);
    _interrupt.unmask(cpu.id_saved);
    if (due) _task.task_hardware.switch_now();
}
