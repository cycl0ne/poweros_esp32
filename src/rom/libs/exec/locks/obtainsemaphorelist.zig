// SPDX-License-Identifier: MPL-2.0
//! ObtainSemaphoreList: holds every semaphore of a list exclusively, or
//! waits until it can. A request is queued on all of them before any is
//! waited for, so two tasks after the same set cannot each end up holding
//! half of it.

const sdk = @import("sdk");
const _locks = @import("_locks.zig");

const ExecBase = @import("../exec.zig").ExecBase;
const List = sdk.exec.List;
const Task = sdk.exec.Task;

/// Takes every semaphore on a list, exclusively, all or nothing.
///
/// SYNOPSIS:
/// ```zig
/// fn ObtainSemaphoreList(base: *ExecBase, list: *List) void
/// ```
///
/// SINCE: 1.0. LVO -256.
///
/// INPUTS:
/// - `list` - a list of semaphores, linked through their own node.
///
/// RESULT:
/// Nothing. It returns when all of them are the caller's.
///
/// BEHAVIOR:
/// **Every request is queued before any is waited for**, which is the whole
/// reason this call exists: two tasks each taking the same semaphores one
/// at a time can end up each holding half and waiting for the other, and
/// queueing them all at once cannot.
///
/// Only one task at a time may do this over the same semaphores, because
/// each semaphore has one request built into it for the purpose. Two tasks
/// doing it at once want another semaphore between them to arbitrate.
///
/// CONTEXT:
/// - Waits: yes, until the last one is granted.
/// - Interrupts: no. It waits.
/// - Forbid: taken here and broken by the waiting, as with
///   `ObtainSemaphore`.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The caller holds them all until `ReleaseSemaphoreList`.
///
/// NOTES:
/// A semaphore created while a list is held has to be accounted for: it
/// joins a list that will be released as a list, so it must inherit the
/// hold rather than start free. Getting that wrong shows up as an alert
/// from the release rather than at the creation.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ReleaseSemaphoreList`, `ObtainSemaphore`
///
/// EXAMPLES:
/// ```zig
/// sys.ObtainSemaphoreList(&li.lock_list);
/// defer sys.ReleaseSemaphoreList(&li.lock_list);
/// ```
pub fn ObtainSemaphoreList(base: *ExecBase, list: *List) void {
    const sys = base.iface();
    sys.Forbid();
    defer sys.Permit();
    enterList(base, list, sys.FindTask(null).?);
    var it = list.iterator();
    while (it.next()) |node| _locks.waitGranted(base, &_locks.semaphoreOf(node).multiple_link);
}

/// The first half: queues a request on **every** semaphore of the list
/// before any of them is waited for, which is what makes the
/// all-or-nothing hold possible. The caller holds Forbid.
///
/// Each semaphore's own built-in request is used, which is why only one
/// task at a time may do this over the same semaphores.
///
/// INPUTS:
/// - `base` - exec, passed on to each enter.
/// - `list` - the semaphores.
/// - `task` - who wants them.
fn enterList(base: *ExecBase, list: *List, task: *Task) void {
    var it = list.iterator();
    while (it.next()) |node| {
        const sem = _locks.semaphoreOf(node);
        sem.multiple_link = .{ .waiter = task };
        _ = _locks.enter(base, sem, &sem.multiple_link);
    }
}
