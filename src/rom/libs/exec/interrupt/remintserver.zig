// SPDX-License-Identifier: MPL-2.0
//! RemIntServer: takes a server off an interrupt number's chain, and
//! releases the number when nothing listens to it any more.

const sdk = @import("sdk");
const _interrupt = @import("_interrupt.zig");

const ExecBase = @import("../exec.zig").ExecBase;
const Interrupt = sdk.exec.Interrupt;

/// Takes a server off an interrupt number's chain.
///
/// SYNOPSIS:
/// ```zig
/// fn RemIntServer(base: *ExecBase, int_number: u32,
///     interrupt: *Interrupt) void
/// ```
///
/// SINCE: 1.0. LVO -136.
///
/// INPUTS:
/// - `int_number` - the number the server is on.
/// - `interrupt` - the server to remove.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// Removing the last user of a number releases its CPU line, which is what
/// keeps the twelve from being spent on devices that are no longer open.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: safe. It takes Disable.
/// - Forbid: not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated. The `Interrupt` is the caller's again. It is safe
/// to free once this returns: Disable is held across the removal, so no
/// interrupt can be part-way through the chain.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AddIntServer`, `SetIntVector`
///
/// EXAMPLES:
/// ```zig
/// sys.RemIntServer(intbits.INTB_GPIO, &server);
/// ```
pub fn RemIntServer(base: *ExecBase, int_number: u32, interrupt: *Interrupt) void {
    const sys = base.iface();
    sys.Disable();
    defer sys.Enable();
    const int_vector = _interrupt.vector(base, int_number);
    const was_in_use = _interrupt.inUse(int_vector);
    const was_shareable = int_vector.handler == null;
    sys.Remove(&interrupt.node);
    _interrupt.route(int_vector, int_number, was_in_use, was_shareable);
}
