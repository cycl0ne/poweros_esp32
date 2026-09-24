// SPDX-License-Identifier: MPL-2.0
//! Disable: masks interrupts, nesting. Only the outermost Disable saves
//! the state the matching `Enable` puts back.

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
/// CONTEXT:
/// - Waits: no. Never `Wait` while holding it, for the same reason as
///   Forbid and more so.
/// - Interrupts: safe, and the nesting is what makes it so.
/// - Forbid: neither implies the other. Task switching is not stopped by
///   this, except that a switch cannot be delivered while interrupts are
///   masked.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated. The caller owes an `Enable`.
///
/// NOTES:
/// Hold it for as short a span as will do. Every interrupt the machine has
/// is late by however long it is held, and on this board that includes the
/// panel's refill, which has 460 microseconds to do 230 microseconds of
/// work before the picture tears.
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
    base.id_nest_cnt += 1;
    if (base.id_nest_cnt == 0) base.id_saved = state;
}
