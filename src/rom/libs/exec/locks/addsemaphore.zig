// SPDX-License-Identifier: MPL-2.0
//! AddSemaphore: makes a semaphore public - initialised, and on exec's
//! semaphore list by priority, where `FindSemaphore` finds it by name.

const sdk = @import("sdk");

const ExecBase = @import("../exec.zig").ExecBase;
const SignalSemaphore = sdk.exec.SignalSemaphore;

/// Makes a semaphore public, so that anything can find it by name.
///
/// SYNOPSIS:
/// ```zig
/// fn AddSemaphore(base: *ExecBase, sem: *SignalSemaphore) void
/// ```
///
/// SINCE: 1.0. LVO -268.
///
/// INPUTS:
/// - `sem` - the semaphore, with its name and priority set. It is
///   **initialised here**, so it must not already be held.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// It is enqueued by priority, so a higher-priority semaphore of the same
/// name is the one `FindSemaphore` answers.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no. It takes exec's semaphore lock, around the list.
/// - Forbid: may be held. It is taken here as well, around the change:
///   a program walks the semaphore list under Forbid, which must keep it
///   still on both cores.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated. The semaphore stays the caller's and must outlive
/// every holder.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `RemSemaphore`, `FindSemaphore`, `InitSemaphore`
///
/// EXAMPLES:
/// ```zig
/// sem.link.name = "my.lock";
/// sys.AddSemaphore(&sem);
/// ```
pub fn AddSemaphore(base: *ExecBase, sem: *SignalSemaphore) void {
    const sys = base.iface();
    sys.InitSemaphore(sem);
    sys.Forbid();
    defer sys.Permit();
    sys.AcquireLock(&base.lock_semaphores);
    defer sys.ReleaseLock(&base.lock_semaphores);
    sys.Enqueue(&base.sem_list, &sem.link);
}
