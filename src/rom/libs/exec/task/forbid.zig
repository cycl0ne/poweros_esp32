// SPDX-License-Identifier: MPL-2.0
//! Forbid: holds task switching, nesting. While it is held the running
//! task keeps the processor until it gives it up; a switch that comes due
//! meanwhile waits for the `Permit` that lets the count go negative again.
//! The outermost Forbid takes the machine's Forbid lock, so two Forbid
//! sections never run at once on the two cores. It does not hold
//! interrupts off - only for as long as it takes to count, which is not the
//! same thing.

const _interrupt = @import("../interrupt/_interrupt.zig");
const _task = @import("_task.zig");

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
/// **Both cores.** The outermost Forbid takes the machine's Forbid lock,
/// held by the core whose task is inside Forbid, so two Forbid sections
/// never run at once. A task that asks while the other core holds it
/// waits for it - asleep, and switched out if something better becomes
/// ready, since it holds nothing yet.
///
/// The other core keeps the task it is running, but switches to no other
/// until the Permit - only to its idle task, should its own wait or end.
/// So a task made ready inside a Forbid section runs after the Permit, as
/// on one core: a task that signals the one waiting for it inside Forbid
/// and ends is gone before that one runs. What Forbid does not do is stop
/// the task already running on the other core: it guards what every task
/// touches only inside Forbid, which the lists above are, and not what
/// relies on no other task running at all.
///
/// Inside `Disable`, a Forbid that has to wait for the other core lets
/// the system's interrupt lock go meanwhile - that core's Forbid section
/// may need it to end - with this core's interrupts still masked; the
/// Disable is split there, as a `Wait` inside it splits it.
///
/// CONTEXT:
/// - Waits: only for the lock, while the other core holds it. Never `Wait`
///   while holding it: a Wait lets the lock go until the task runs again,
///   so nothing it guards stays guarded across the Wait.
/// - Interrupts: pointless rather than unsafe. An interrupt cannot be
///   switched away from, so it is already as forbidden as it can be; it
///   only counts, and takes no lock.
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
    // hold it. So the core's interrupts are masked for it, which also
    // keeps the caller on this core while it takes the lock. The
    // interrupt lock is not needed: the count is this core's alone.
    const hardware = _interrupt.interrupt_hardware;
    while (true) {
        const state = hardware.disable();
        const cpu = base.cpu();
        if (cpu.tdn_nest_cnt >= 0 or cpu.int_depth != 0 or _task.takeForbid(base)) {
            cpu.tdn_nest_cnt += 1;
            hardware.restore(state);
            return;
        }
        if (cpu.id_nest_cnt >= 0) {
            _task.waitForForbidInDisable(base);
            hardware.restore(state);
            continue;
        }
        hardware.restore(state);
        _task.waitForForbid(base);
    }
}
