// SPDX-License-Identifier: MPL-2.0
//! AddIntServer: puts a server on an interrupt number's chain by priority,
//! and routes the number to match.

const sdk = @import("sdk");
const _interrupt = @import("_interrupt.zig");

const ExecBase = @import("../exec.zig").ExecBase;
const Interrupt = sdk.exec.Interrupt;

/// Adds a server to an interrupt number's chain.
///
/// SYNOPSIS:
/// ```zig
/// fn AddIntServer(base: *ExecBase, int_number: u32,
///     interrupt: *Interrupt) void
/// ```
///
/// SINCE: 1.0. LVO -132.
///
/// INPUTS:
/// - `int_number` - a source from `sdk.hardware.intbits`.
/// - `interrupt` - an `Interrupt` whose `code` is an `IntServerFn` and
///   whose `pri` decides its place in the chain.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// Servers are kept in priority order and run in that order when the number
/// fires, **until one answers non-zero**, which means "this was mine and it
/// is dealt with" and ends the chain. A server that did not cause the
/// interrupt must answer 0 and let the next one look.
///
/// That is also why a server's source may share a CPU line: every chain on
/// the line runs, and each server decides for itself whether its hardware
/// raised it. A server that answers non-zero without checking will swallow
/// another peripheral's interrupt.
///
/// CONTEXT:
/// - Waits: no. **The server itself must not wait**, allocate, or call
///   anything that reaches a handler process.
/// - Interrupts: safe. It takes Disable.
/// - Forbid: not needed; Disable is what guards the chains.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated. The `Interrupt` stays the caller's and must
/// outlive its place on the chain.
///
/// NOTES:
/// Work that cannot be done in an interrupt is passed on from one: `Signal`
/// a task, or `Cause` a software interrupt, and do it there.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `RemIntServer`, `SetIntVector`, `Cause`, `Signal`
///
/// EXAMPLES:
/// ```zig
/// var server: exec.Interrupt = .{
///     .node = .{ .pri = 0, .name = "my device" },
///     .code = @ptrCast(&myServer),
///     .data = self,
/// };
/// sys.AddIntServer(intbits.INTB_GPIO, &server);
/// ```
pub fn AddIntServer(base: *ExecBase, int_number: u32, interrupt: *Interrupt) void {
    const sys = base.iface();
    sys.Disable();
    defer sys.Enable();
    const int_vector = _interrupt.vector(base, int_number);
    const was_in_use = _interrupt.inUse(int_vector);
    const was_shareable = int_vector.handler == null;
    sys.Enqueue(&int_vector.servers, &interrupt.node);
    _interrupt.route(int_vector, int_number, was_in_use, was_shareable);
}
