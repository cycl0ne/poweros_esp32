// SPDX-License-Identifier: MPL-2.0
//! FindSemaphore: a public semaphore by name.

const sdk = @import("sdk");
const _locks = @import("_locks.zig");

const ExecBase = @import("../exec.zig").ExecBase;
const SignalSemaphore = sdk.exec.SignalSemaphore;

/// Finds a public semaphore by name.
///
/// SYNOPSIS:
/// ```zig
/// fn FindSemaphore(base: *ExecBase, name: [*:0]const u8) ?*SignalSemaphore
/// ```
///
/// SINCE: 1.0. LVO -264.
///
/// INPUTS:
/// - `name` - the semaphore's name, matched exactly.
///
/// RESULT:
/// The semaphore, or null if there is none of that name.
///
/// BEHAVIOR:
/// As with `FindPort`, the semaphore may go away as soon as the search is
/// over: what keeps it there until the caller has obtained it is the
/// protocol of the program that made it - one that removes it only once
/// it holds it itself, and nobody waits for it any more.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no. It takes exec's semaphore lock for the search.
/// - Locks: takes exec's semaphore lock for the search. The semaphore may be
///   removed the moment it is let go: the protocol of the program that made it
///   is what keeps it there until the caller has obtained it.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated, and nothing is obtained.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AddSemaphore`, `ObtainSemaphore`, `FindPort`
///
/// EXAMPLES:
/// ```zig
/// // The program that made "my.lock" keeps it there while it runs.
/// const sem = sys.FindSemaphore("my.lock") orelse return;
/// sys.ObtainSemaphore(sem);
/// defer sys.ReleaseSemaphore(sem);
/// ```
pub fn FindSemaphore(base: *ExecBase, name: [*:0]const u8) ?*SignalSemaphore {
    const sys = base.iface();
    sys.AcquireLock(&base.lock_semaphores);
    defer sys.ReleaseLock(&base.lock_semaphores);
    const node = sys.FindName(&base.sem_list, name) orelse return null;
    return _locks.semaphoreOf(node);
}
