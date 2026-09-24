// SPDX-License-Identifier: MPL-2.0
//! ReleaseSemaphore: gives up one hold on a semaphore. The last one frees
//! it, and it goes straight to the next waiter.

const sdk = @import("sdk");
const _locks = @import("_locks.zig");

const ExecBase = @import("../exec.zig").ExecBase;
const SignalSemaphore = sdk.exec.SignalSemaphore;

/// Gives back one obtain, and hands the semaphore on when it was the last.
///
/// SYNOPSIS:
/// ```zig
/// fn ReleaseSemaphore(base: *ExecBase, sem: *SignalSemaphore) void
/// ```
///
/// SINCE: 1.0. LVO -248.
///
/// INPUTS:
/// - `sem` - a semaphore this task holds.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// The last release gives it to the next waiter: **an exclusive waiter
/// alone, or every shared waiter at the head of the queue together.** The
/// semaphore is never let go for whoever asks next, so the order of the
/// queue is the order it is granted in.
///
/// Releasing one this task does not hold raises `AN_SemCorrupt`. It is an
/// alert rather than an ignored mistake because the alternative is a
/// semaphore whose count no longer means anything, which fails later and
/// somewhere else.
///
/// CONTEXT:
/// - Waits: no, but handing the semaphore on signals a task, which may
///   switch.
/// - Interrupts: no. It takes Forbid and may signal.
/// - Forbid: taken here.
/// - Process: a Task will do, and it must be **the task that obtained
///   it**.
///
/// OWNERSHIP:
/// One obtain is given back. Whatever the semaphore guarded must not be
/// touched after the last release.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ObtainSemaphore`, `ReleaseSemaphoreList`, `Vacate`
///
/// EXAMPLES:
/// ```zig
/// defer sys.ReleaseSemaphore(&self.lock);
/// ```
pub fn ReleaseSemaphore(base: *ExecBase, sem: *SignalSemaphore) void {
    const sys = base.iface();
    sys.Forbid();
    defer sys.Permit();
    _locks.leave(base, sem, sys.FindTask(null).?);
}
