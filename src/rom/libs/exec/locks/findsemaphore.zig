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
/// As with `FindPort`, the semaphore may go away as soon as Forbid is let
/// go, so the caller holds Forbid from before this until it has obtained
/// it. Obtaining breaks that Forbid, but by then the semaphore is held and
/// cannot be removed from under the caller.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no. It takes Forbid.
/// - Forbid: taken here for the search, and needed by the caller across
///   this and the obtain.
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
/// sys.Forbid();
/// const sem = sys.FindSemaphore("my.lock");
/// if (sem) |x| sys.ObtainSemaphore(x);
/// sys.Permit();
/// ```
pub fn FindSemaphore(base: *ExecBase, name: [*:0]const u8) ?*SignalSemaphore {
    const sys = base.iface();
    sys.Forbid();
    defer sys.Permit();
    const node = sys.FindName(&base.sem_list, name) orelse return null;
    return _locks.semaphoreOf(node);
}
