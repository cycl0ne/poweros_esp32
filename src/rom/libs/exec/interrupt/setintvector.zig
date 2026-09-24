// SPDX-License-Identifier: MPL-2.0
//! SetIntVector: gives an interrupt number its one handler, or takes it
//! away, and routes the number to match.

const sdk = @import("sdk");
const _interrupt = @import("_interrupt.zig");

const ExecBase = @import("../exec.zig").ExecBase;
const Interrupt = sdk.exec.Interrupt;

/// Installs the one handler of an interrupt number.
///
/// SYNOPSIS:
/// ```zig
/// fn SetIntVector(base: *ExecBase, int_number: u32,
///     interrupt: ?*Interrupt) ?*Interrupt
/// ```
///
/// SINCE: 1.0. LVO -128.
///
/// INPUTS:
/// - `int_number` - a source from `sdk.hardware.intbits`. Out of range is
///   fatal.
/// - `interrupt` - an `Interrupt` whose `code` is an `IntHandlerFn`, called
///   with its `data` and the number; or null, which removes the handler.
///
/// RESULT:
/// The handler that was there, or null if there was none.
///
/// BEHAVIOR:
/// A number with a handler gets a CPU line of its own, because a handler is
/// not required to say whether its hardware raised the interrupt. So
/// installing one may take the last free line, and finding none is fatal -
/// there is no useful way to carry on with an interrupt that cannot be
/// delivered.
///
/// Adding the first handler or server routes the number; removing the last
/// releases it; gaining or losing a handler routes it again, because that
/// is what changes whether it may share.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: safe. It takes Disable, which an interrupt may.
/// - Forbid: not needed. Disable is what guards the vectors, since they are
///   what interrupts themselves touch.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated. The `Interrupt` stays the caller's and must
/// outlive its place in the vector - and must stay reachable with the
/// caches in whatever state an interrupt finds them.
///
/// NOTES:
/// A handler's state belongs in internal memory. `MEMF_ANY` takes PSRAM
/// first on this machine, and an interrupt reading its own state out of
/// memory that two DMA channels are working is measurably slower - 262 late
/// refills in 62 idle seconds, against 0 for the same code in internal
/// memory.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AddIntServer`, `RemIntServer`, `IntVector`, `Cause`
///
/// EXAMPLES:
/// ```zig
/// const old = sys.SetIntVector(intbits.INTB_UART0, &my_handler);
/// ```
pub fn SetIntVector(base: *ExecBase, int_number: u32, interrupt: ?*Interrupt) ?*Interrupt {
    const sys = base.iface();
    sys.Disable();
    defer sys.Enable();
    const int_vector = _interrupt.vector(base, int_number);
    const was_in_use = _interrupt.inUse(int_vector);
    const was_shareable = int_vector.handler == null;
    const old = int_vector.handler;
    int_vector.handler = interrupt;
    _interrupt.route(int_vector, int_number, was_in_use, was_shareable);
    return old;
}
