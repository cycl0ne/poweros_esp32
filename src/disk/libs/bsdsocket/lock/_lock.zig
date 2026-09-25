// SPDX-License-Identifier: MIT
//! The stack's lock: one semaphore over all protocol state. Whoever has
//! something to do takes it - a program in a socket call, on its own
//! task - does it, and lets go; nothing waits while holding it.
//!
//! exec's semaphores lend no priority, so a program of low priority that
//! held the lock would keep everyone else out for as long as it is not
//! scheduled. Taking the lock therefore raises the caller to the stack's
//! priority first, and letting go puts it back.

const sdk = @import("sdk");
const exec = sdk.exec;
const _base = @import("../bsdsocket_base.zig");
const StackBase = _base.StackBase;

/// What letting go needs to know: whose priority was raised, and from
/// what.
pub const Held = struct {
    task: ?*exec.Task,
    pri: i8,
};

pub fn take(stack: *StackBase) Held {
    const sys = stack.sys_base;
    const task = sys.FindTask(null);
    var held: Held = .{ .task = null, .pri = 0 };
    if (task) |me| {
        if (me.node.pri < _base.stack_pri) {
            held = .{ .task = me, .pri = sys.SetTaskPri(me, _base.stack_pri) };
        }
    }
    sys.ObtainSemaphore(&stack.lock);
    return held;
}

pub fn give(stack: *StackBase, held: Held) void {
    const sys = stack.sys_base;
    sys.ReleaseSemaphore(&stack.lock);
    if (held.task) |me| _ = sys.SetTaskPri(me, held.pri);
}
