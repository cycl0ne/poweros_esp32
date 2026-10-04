// SPDX-License-Identifier: MPL-2.0
//! ReadCoreTimes: how a core has spent its time - in tasks, idle, in
//! interrupts - for a program that shows how busy the machine is.

const sdk = @import("sdk");
const exec_base = @import("../exec_base.zig");
const _task = @import("_task.zig");

const ExecBase = @import("../exec.zig").ExecBase;
const CoreTimes = sdk.exec.CoreTimes;

/// Reads how a core has spent its time since it started.
///
/// SYNOPSIS:
/// ```zig
/// fn ReadCoreTimes(base: *ExecBase, core: u32, times: *CoreTimes) bool
/// ```
///
/// SINCE: 1.5. LVO -524.
///
/// INPUTS:
/// - `core` - the core: 0 is the one the system starts on.
/// - `times` - filled in: the cycles of the core's clock spent running
///   tasks, in its idle task, and in interrupts and exceptions.
///
/// RESULT:
/// True; false for a core that is not running, which is every core from
/// the first false on. `times` is then left as it was.
///
/// BEHAVIOR:
/// Each core adds up its own time at the outermost entry and exit of
/// every exception, from its cycle counter: what ran between an exit and
/// the next entry was its idle task or another task, and what ran
/// between them was the exception. Every switch from one task to another
/// happens at an exception's exit, so nothing is missed and nothing is
/// guessed - a task that runs a moment after each tick is counted as
/// fully as one that runs all the time.
///
/// The figures run up for as long as the core runs. A program reads them
/// twice and divides the differences: tasks over the sum is how busy the
/// core was with tasks in between, interrupts over the sum how busy with
/// interrupts. The cycles are the core's own and only their ratios mean
/// anything.
///
/// The calling core's figures are as of this moment; another core's as
/// of its last exception, which is at most one of its ticks ago.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: yes.
/// - Forbid: not needed. It takes Disable to read a core's figures
///   whole.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// `times` is the caller's.
///
/// NOTES:
/// The cycles are 64 bits wide, and run for longer than any machine
/// stays on.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CoreTask`, `SetTaskAffinity`
///
/// EXAMPLES:
/// ```zig
/// var before: sdk.exec.CoreTimes = .{};
/// _ = sys.ReadCoreTimes(0, &before);
/// // ... a second later:
/// var after: sdk.exec.CoreTimes = .{};
/// _ = sys.ReadCoreTimes(0, &after);
/// const tasks = after.tasks - before.tasks;
/// const all = tasks + (after.idle - before.idle) + (after.interrupts - before.interrupts);
/// const busy_percent = if (all == 0) 0 else tasks * 100 / all;
/// ```
pub fn ReadCoreTimes(base: *ExecBase, core: u32, times: *CoreTimes) bool {
    const sys = base.iface();
    sys.Disable();
    defer sys.Enable();
    if (core >= base.cores_running) return false;
    const cpu = &base.cpus[core];
    times.* = .{ .tasks = cpu.time_tasks, .idle = cpu.time_idle, .interrupts = cpu.time_interrupts };
    // The caller's own core: since its last exception it has been running
    // the caller, a task.
    if (core == exec_base.coreId()) times.tasks +%= _task.cycles() -% cpu.time_mark;
    return true;
}
