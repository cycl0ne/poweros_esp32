// SPDX-License-Identifier: MPL-2.0
//! InitSemaphore: makes a semaphore free, with nobody waiting.

const sdk = @import("sdk");

const ExecBase = @import("../exec.zig").ExecBase;
const SignalSemaphore = sdk.exec.SignalSemaphore;

/// Prepares a semaphore for use.
///
/// SYNOPSIS:
/// ```zig
/// fn InitSemaphore(_: *ExecBase, sem: *SignalSemaphore) void
/// ```
///
/// SINCE: 1.0. LVO -240.
///
/// INPUTS:
/// - `sem` - the semaphore to prepare. Whatever state it was in is
///   forgotten, so this must not be done to one that anything holds.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// It must be done before the first obtain. A zeroed semaphore is not an
/// initialised one: the count that says "free" is -1 rather than 0, and its
/// queue is a list that must be made empty before anything is added to it.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: safe in itself, though nothing else about a semaphore is.
/// - Forbid: not needed. Nothing can be holding a semaphore that does not
///   exist yet.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated. The semaphore lives in the caller's memory, which
/// must outlive every holder.
///
/// NOTES:
/// `AddSemaphore` does this itself, so a public semaphore is not
/// initialised twice.
///
/// A free semaphore has a queue count of -1: the count is one less than
/// the obtains outstanding, held or queued, so the first takes it to 0.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ObtainSemaphore`, `AddSemaphore`
///
/// EXAMPLES:
/// ```zig
/// sys.InitSemaphore(&self.lock);
/// ```
pub fn InitSemaphore(_: *ExecBase, sem: *SignalSemaphore) void {
    sem.link.type = .signalsem;
    sem.nest_count = 0;
    sem.owner = null;
    sem.queue_count = -1;
    sem.multiple_link = .{};
    sem.wait_queue.init(.unknown);
}
