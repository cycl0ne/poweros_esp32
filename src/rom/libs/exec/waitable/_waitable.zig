// SPDX-License-Identifier: MPL-2.0
//! Waitables (sdk/libs/exec/waitables.zig): SignalWaitable, ResetWaitable
//! and WaitForAny are a file each in this folder; this file is what they
//! share.
//!
//! A task in WaitForAny is on exec's list of waiters (`ExecBase.waiting`)
//! by a record on its own stack: the waitables it waits for, and when its
//! time runs out. SignalWaitable walks the list and wakes every task that
//! waits for the waitable it signalled; core 0's tick walks it for the
//! times that ran out. Either wakes a task with SIGF_SINGLE, the signal a
//! task waits on for exec, as it does for a semaphore. All of it is done
//! under Disable, which holds off every core's interrupts as well.
//!
//! The time is the system's uptime in microseconds, and the tick looks at
//! it: a time limit is kept to within a tick (`tickWaitables`).

const sdk = @import("sdk");
const systimer = sdk.hardware.systimer;
const Task = sdk.exec.Task;
const Waitable = sdk.exec.Waitable;

const ExecBase = @import("../exec.zig").ExecBase;

/// A task in WaitForAny.
pub const Record = struct {
    next: ?*Record = null,
    task: *Task,
    waitables: [*]const *Waitable,
    count: u32,
    /// The uptime, in microseconds, at which the time runs out;
    /// WAIT_FOREVER for never.
    deadline: u64,
    /// Set by the tick when it has.
    timed_out: bool = false,
};

/// Where the first of `count` waitables that is signalled is in the list,
/// or null.
///
/// INPUTS:
/// - `waitables` - the list.
/// - `count` - how many.
pub fn firstSignalled(waitables: [*]const *Waitable, count: u32) ?u32 {
    for (waitables[0..count], 0..) |waitable, i| {
        if (@atomicLoad(u32, &waitable.signalled, .acquire) != 0) return @intCast(i);
    }
    return null;
}

/// `record` on the list of waiters. The caller has Disable.
///
/// INPUTS:
/// - `base` - exec: the list.
/// - `record` - the waiting task's record.
pub fn enlist(base: *ExecBase, record: *Record) void {
    record.next = base.waiting;
    base.waiting = record;
}

/// `record` off the list, if it is on it. The caller has Disable.
///
/// INPUTS:
/// - `base` - exec: the list.
/// - `record` - the record.
pub fn delist(base: *ExecBase, record: *Record) void {
    var link: *?*Record = &base.waiting;
    while (link.*) |at| : (link = &at.next) {
        if (at != record) continue;
        link.* = at.next;
        return;
    }
}

/// Every task that waits for `waitable` woken. The caller has Disable.
///
/// INPUTS:
/// - `base` - exec: the list, and the jump table `Signal` goes through.
/// - `waitable` - the waitable signalled.
pub fn wake(base: *ExecBase, waitable: *const Waitable) void {
    var at = base.waiting;
    while (at) |record| : (at = record.next) {
        for (record.waitables[0..record.count]) |one| {
            if (one != waitable) continue;
            base.iface().Signal(record.task, sdk.exec.tasks.SIGF_SINGLE);
            break;
        }
    }
}

/// The waiters whose time has run out by `now` told so, and woken.
/// The caller has Disable, or is the tick.
///
/// INPUTS:
/// - `base` - exec: the list, and the jump table `Signal` goes through.
/// - `now` - the uptime, in microseconds.
pub fn expire(base: *ExecBase, now: u64) void {
    var at = base.waiting;
    while (at) |record| : (at = record.next) {
        if (record.timed_out or now < record.deadline) continue;
        @atomicStore(bool, &record.timed_out, true, .release);
        base.iface().Signal(record.task, sdk.exec.tasks.SIGF_SINGLE);
    }
}

/// From the tick, on core 0 only: the waiters whose time has run out
/// woken. Nothing is read with nobody waiting.
///
/// INPUTS:
/// - `base` - exec: the list.
pub fn tickWaitables(base: *ExecBase) void {
    if (base.waiting == null) return;
    expire(base, systimer.uptimeUs());
}

/// A task removed while it waits taken off the list: its record is on
/// its stack, which goes with it.
///
/// INPUTS:
/// - `base` - exec: the list.
/// - `task` - the task, which does not run.
pub fn withdraw(base: *ExecBase, task: *Task) void {
    const sys = base.iface();
    sys.Disable();
    defer sys.Enable();
    var link: *?*Record = &base.waiting;
    while (link.*) |at| {
        if (at.task == task) {
            link.* = at.next;
        } else {
            link = &at.next;
        }
    }
}
