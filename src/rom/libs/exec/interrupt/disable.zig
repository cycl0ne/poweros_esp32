// SPDX-License-Identifier: MPL-2.0
//! Disable: masks interrupts, nesting. Only the outermost Disable saves
//! the state the matching `Enable` puts back, and takes the system's
//! interrupt lock, which keeps the other core's interrupts and Disables
//! out as well.

const _interrupt = @import("_interrupt.zig");

const ExecBase = @import("../exec.zig").ExecBase;

/// Masks every interrupt until the matching `Enable`.
///
/// SYNOPSIS:
/// ```zig
/// fn Disable(base: *ExecBase) void
/// ```
///
/// SINCE: 1.0. LVO -140.
///
/// INPUTS:
/// None.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// It nests, and the state from before the **outermost** Disable is what
/// the outermost Enable puts back - so a Disable/Enable pair inside an
/// interrupt leaves interrupts masked, which is what they already were.
///
/// It guards what interrupts themselves touch: the interrupt vectors, the
/// server chains and the software interrupt queues. What only tasks touch -
/// the library, device, memory, port and semaphore lists - is Forbid's, and
/// Disable is the heavier of the two because it stops the machine
/// responding to its hardware.
///
/// **Both cores.** The outermost Disable also takes the system's
/// interrupt lock, which every exception on either core takes as well. So
/// while a task is inside Disable no interrupt runs on either core and no
/// task on the other core gets into Disable: a core that wants the lock
/// waits for it with its own interrupts masked. The device interrupts are
/// all core 0's; core 1 has its tick and the cross-core interrupt.
///
/// CONTEXT:
/// - Waits: no. Never `Wait` while holding it, for the same reason as
///   Forbid and more so.
/// - Interrupts: safe, and the nesting is what makes it so.
/// - Forbid: neither implies the other. Task switching is not stopped by
///   this, except that a switch cannot be delivered while interrupts are
///   masked. Forbid inside Disable, while the other core holds Forbid,
///   lets the interrupt lock go until it has its own (see `Forbid`).
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated. The caller owes an `Enable`.
///
/// NOTES:
/// Hold it for as short a span as will do. Every interrupt the machine has
/// is late by however long it is held - on both cores - and on this board
/// that includes the panel's refill, which has 460 microseconds to do 230
/// microseconds of work before the picture tears.
///
/// The count starts at -1, so one Disable brings it to 0, which is the
/// point at which the state to be put back is saved.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `Enable`, `Forbid`, `Cause`
///
/// EXAMPLES:
/// ```zig
/// sys.Disable();
/// defer sys.Enable();
/// ```
pub fn Disable(base: *ExecBase) void {
    const state = _interrupt.interrupt_hardware.disable();
    // Masked, the caller stays on this core.
    const cpu = base.cpu();
    cpu.id_nest_cnt += 1;
    if (cpu.id_nest_cnt != 0) return;
    cpu.id_saved = state;
    // An exception holds the lock already.
    if (cpu.int_depth == 0) _interrupt.takeSystemInterrupts(base, @returnAddress());
}
