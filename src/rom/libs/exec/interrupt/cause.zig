// SPDX-License-Identifier: MPL-2.0
//! Cause: queues a software interrupt and raises the software interrupt
//! line. One already queued is not queued twice.

const sdk = @import("sdk");
const _interrupt = @import("_interrupt.zig");

const ExecBase = @import("../exec.zig").ExecBase;
const Interrupt = sdk.exec.Interrupt;

/// Queues a software interrupt, to run when no hardware interrupt is being
/// handled.
///
/// SYNOPSIS:
/// ```zig
/// fn Cause(base: *ExecBase, interrupt: *Interrupt) void
/// ```
///
/// SINCE: 1.0. LVO -148.
///
/// INPUTS:
/// - `interrupt` - an `Interrupt` whose `code` is a `SoftIntFn`, called
///   with its `data` alone. Its `pri` is rounded down to one of -32, -16,
///   0, 16, 32, which are the five queues.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// It runs as soon as no hardware interrupt is being handled, highest
/// priority first, and still before any task - so it is where an interrupt
/// puts work that is too long for an interrupt but too urgent for a task.
///
/// **Causing one that is already queued does nothing**, which is what makes
/// it safe to call on every interrupt without counting: the flag is the
/// node's type, cleared the moment it is taken off the queue, so it may be
/// caused again from inside its own run.
///
/// CONTEXT:
/// - Waits: no. **The software interrupt itself must not wait** either: it
///   runs on no task's time and has no task to be suspended.
/// - Interrupts: safe, and this is its main caller.
/// - Forbid: not needed; it takes Disable.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated. The `Interrupt` must outlive its time on the
/// queue, so it cannot be freed between causing it and its running.
///
/// NOTES:
/// It may allocate nothing and reach no handler, exactly as a hardware
/// interrupt may not. What it usefully can do is `Signal` a task, which is
/// how a device's interrupt reaches the process waiting on it.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `Signal`, `AddIntServer`
///
/// EXAMPLES:
/// ```zig
/// sys.Cause(&self.soft_int);
/// ```
pub fn Cause(base: *ExecBase, interrupt: *Interrupt) void {
    const sys = base.iface();
    sys.Disable();
    defer sys.Enable();
    if (interrupt.node.type == .softint) return;
    interrupt.node.type = .softint;
    sys.AddTail(&base.soft_ints[softIntQueue(interrupt.node.pri)], &interrupt.node);
    _interrupt.interrupt_hardware.cause_softint();
}

/// Which of the five queues a priority belongs to. Anything outside
/// -32..32 is clamped, so every priority has a queue.
///
/// INPUTS:
/// - `pri` - the software interrupt's priority.
fn softIntQueue(pri: i8) usize {
    const clamped: i32 = @max(-32, @min(32, @as(i32, pri)));
    return @intCast(@divFloor(clamped + 32, 16));
}

// --- tests (host: ./zig build test) -----------------------------------------

const testing = @import("std").testing;

test "softIntQueue rounds down to one of the five, and clamps" {
    try testing.expectEqual(@as(usize, 0), softIntQueue(-128));
    try testing.expectEqual(@as(usize, 0), softIntQueue(-17));
    try testing.expectEqual(@as(usize, 1), softIntQueue(-16));
    try testing.expectEqual(@as(usize, 2), softIntQueue(0));
    try testing.expectEqual(@as(usize, 2), softIntQueue(15));
    try testing.expectEqual(@as(usize, 4), softIntQueue(32));
    try testing.expectEqual(@as(usize, 4), softIntQueue(127));
}
