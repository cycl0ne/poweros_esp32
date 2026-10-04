// SPDX-License-Identifier: MPL-2.0
//! SetTaskAffinity: the cores a task may run on, in its flags, and the
//! task moved when it is somewhere it may no longer be.

const sdk = @import("sdk");
const _task = @import("_task.zig");

const ExecBase = @import("../exec.zig").ExecBase;
const Task = sdk.exec.Task;

/// Sets the cores a task may run on.
///
/// SYNOPSIS:
/// ```zig
/// fn SetTaskAffinity(base: *ExecBase, task: ?*Task, cores: u32) u32
/// ```
///
/// SINCE: 1.4. LVO -516.
///
/// INPUTS:
/// - `task` - the task; null for the caller.
/// - `cores` - `TF_CORE0` to keep it on core 0, `TF_CORE1` on core 1;
///   0 (or both) for whichever core is free. Other bits are ignored.
///
/// RESULT:
/// The cores it was set to before: `TF_CORE0`, `TF_CORE1`, both or 0.
///
/// BEHAVIOR:
/// The cores are the task's `TF_CORE0` and `TF_CORE1` flags. Every
/// dispatcher looks at them each time it picks a task, so the change holds
/// from the next pick on: a ready task is offered to a core it may run on
/// now, and a running one on a core it may no longer use is switched out
/// at that core's next switch point and taken up by the other.
///
/// The idle tasks are pinned, one to each core, and so is the code that
/// must keep to one core - the Wi-Fi vendor code to core 0.
///
/// With one core running, a task pinned to core 1 never runs.
///
/// CONTEXT:
/// - Waits: no, but the caller may switch - to the other core, when it
///   pinned itself away from this one.
/// - Interrupts: no. It takes Disable.
/// - Forbid: not needed. Inside it the move waits for the Permit, as every
///   switch does.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated.
///
/// NOTES:
/// A task that is to be pinned from its first instruction is made inside
/// Forbid and pinned before the Permit: while one core holds Forbid
/// neither switches to a new task. dos's `NP_Affinity` does it for a
/// process.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `SetTaskPri`, `CreateTask`, `Forbid`
///
/// EXAMPLES:
/// ```zig
/// sys.Forbid();
/// const task = sys.CreateTask("radio", 5, &radioCode, 8192) orelse return error.NoMemory;
/// _ = sys.SetTaskAffinity(task, sdk.exec.TF_CORE0);
/// sys.Permit();
/// ```
pub fn SetTaskAffinity(base: *ExecBase, task: ?*Task, cores: u32) u32 {
    const sys = base.iface();
    const pins: u8 = sdk.exec.TF_CORE0 | sdk.exec.TF_CORE1;
    sys.Disable();
    defer sys.Enable(); // where a move of the caller is taken
    const target = task orelse base.cpu().this_task;
    const old = target.flags & pins;
    target.flags = (target.flags & ~pins) | (@as(u8, @truncate(cores)) & pins);
    switch (target.state) {
        .ready => _task.wakeFor(base, target),
        .run => _task.askCoreOf(base, target),
        else => {},
    }
    return old;
}
