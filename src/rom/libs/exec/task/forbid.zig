// SPDX-License-Identifier: MPL-2.0
//! Forbid: holds task switching, nesting. While it is held the running
//! task keeps the processor until it gives it up; a switch that comes due
//! meanwhile waits for the `Permit` that lets the count go negative again.
//! It does not hold interrupts off - only for as long as it takes to
//! count, which is not the same thing.

const ExecBase = @import("../exec.zig").ExecBase;

/// Holds task switching until the matching `Permit`.
///
/// SYNOPSIS:
/// ```zig
/// fn Forbid(base: *ExecBase) void
/// ```
///
/// SINCE: 1.0. LVO -52.
///
/// INPUTS:
/// None.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// It raises a nesting count, so Forbid and Permit pair and may be nested.
/// While it is held the running task keeps the processor until it gives it
/// up, and a switch that comes due in the meantime is taken at the `Permit`
/// that lets the count go negative again.
///
/// **It does not disable interrupts.** What it guards is what only tasks
/// touch: the library list, the device list, the memory list and its
/// handlers, the port and semaphore lists. Interrupt code must not touch
/// any of those - no `AllocMem`, no `OpenLibrary` from an interrupt - and
/// what interrupts *do* touch, the interrupt vectors and the software
/// interrupt queues, is guarded by `Disable` instead.
///
/// CONTEXT:
/// - Waits: no. Never `Wait` while holding it: the task that would signal
///   you cannot run, so it is a machine that has stopped rather than a
///   deadlock that resolves.
/// - Interrupts: pointless rather than unsafe. An interrupt cannot be
///   switched away from, so it is already as forbidden as it can be.
/// - Forbid: this is it. Nesting is fine and is the normal case.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated. The caller owes a `Permit`, and an error path that
/// returns without one stops the machine - which is why every use in this
/// tree is `defer`red on the next line.
///
/// NOTES:
/// Anything that reaches a file system cannot run under Forbid, because a
/// handler is a process and a process cannot run while the scheduler is
/// held. That is why a listing copies its fields out under the lock and
/// prints them after letting it go.
///
/// The count starts at -1, so one Forbid brings it to 0 and "held" is
/// "not negative".
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `Permit`, `Disable`, `ObtainSemaphore`
///
/// EXAMPLES:
/// ```zig
/// sys.Forbid();
/// defer sys.Permit();
/// // ... walk a system list, copying out what is wanted ...
/// ```
pub fn Forbid(base: *ExecBase) void {
    // The count is read, added to and written back, and an interrupt
    // between the read and the write would be a Forbid that never
    // happened - the caller would believe it held the processor and not
    // hold it. On a machine whose add-to-memory was one instruction this
    // needed nothing; on this one it needs the interrupts off for the
    // three that it takes.
    const sys = base.iface();
    sys.Disable();
    base.tdn_nest_cnt += 1;
    sys.Enable();
}
