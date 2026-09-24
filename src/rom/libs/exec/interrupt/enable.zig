// SPDX-License-Identifier: MPL-2.0
//! Enable: undoes one `Disable`. The outermost one puts the interrupt state
//! back and takes a task switch that fell due while interrupts were off.

const _interrupt = @import("_interrupt.zig");
const switchIfPending = @import("../task/_task.zig").switchIfPending;

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
/// interrupts on in a context that had them off.
///
/// A switch asked for while interrupts were masked - by a `Signal` or an
/// `AddTask` from inside one - is taken here, so like `Permit` this is a
/// point at which the caller may lose the processor.
///
/// CONTEXT:
/// - Waits: no, but it may switch.
/// - Interrupts: safe. Inside one, the nesting means it does not unmask.
/// - Forbid: unrelated.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `Disable`, `Permit`
///
/// EXAMPLES:
/// ```zig
/// sys.Disable();
/// defer sys.Enable();
/// ```
pub fn Enable(base: *ExecBase) void {
    base.id_nest_cnt -= 1;
    if (base.id_nest_cnt < 0) {
        _interrupt.interrupt_hardware.restore(base.id_saved);
        switchIfPending(base); // a Signal or AddTask may have asked for one
    }
}
