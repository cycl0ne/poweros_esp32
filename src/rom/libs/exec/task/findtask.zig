// SPDX-License-Identifier: MPL-2.0
//! FindTask: the running task, or a task by name. The running task is
//! the official way to ask "who am I" - and this is where that answer is
//! read, so it alone reads `this_task` from the base.

const sdk = @import("sdk");
const _interrupt = @import("../interrupt/_interrupt.zig");
const _task = @import("_task.zig");

const ExecBase = @import("../exec.zig").ExecBase;
const Task = sdk.exec.Task;

/// Finds a task by name, or answers the calling task.
///
/// SYNOPSIS:
/// ```zig
/// fn FindTask(base: *ExecBase, name: ?[*:0]const u8) ?*Task
/// ```
///
/// SINCE: 1.0. LVO -168.
///
/// INPUTS:
/// - `name` - the task's name, matched exactly; or **null, which answers
///   the running task** without searching anything.
///
/// RESULT:
/// The task, or null if no task of that name exists.
///
/// BEHAVIOR:
/// The running task is checked first, then the ready and waiting lists -
/// which is what makes the null case free and the named case a search of
/// every task there is. A named search looks at what runs on the other
/// core too.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: the null case only, and even then the answer is whichever
///   task was interrupted. A named search takes the task lists' lock.
/// - Locks: takes the task lists' lock, since a search walks them.
/// - Process: a Task will do. `FindTask(null)` is also how code finds out
///   whether it is a task or a process, from the node's type.
///
/// OWNERSHIP:
/// Nothing is allocated. The pointer is only good while the task exists,
/// and nothing here stops it ending the moment the lock is let go - which
/// is why a task is usually found in order to `Signal` it immediately.
///
/// NOTES:
/// Two tasks may share a name, and then which one is answered is not worth
/// relying on. dos gives each shell process a number in its name for that
/// reason, and finds its own with `FindCliProc` rather than by name.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AddTask`, `Signal`, `FindPort`
///
/// EXAMPLES:
/// ```zig
/// const me = sys.FindTask(null).?;
/// if (sys.FindTask("timer.device")) |t| sys.Signal(t, 1 << sig);
/// ```
pub fn FindTask(base: *ExecBase, name: ?[*:0]const u8) ?*Task {
    const wanted = name orelse return running(base);
    const sys = base.iface();
    // The caller's interrupts masked for the whole walk - it keeps its
    // core, and the core it is on cannot take an exception in the middle
    // - and each core's lists taken in turn: there is no one list of the
    // machine's tasks, and a core holds one core's lists at a time.
    const state = _interrupt.mask();
    defer _interrupt.unmask(state);
    const own = base.cpu().this_task;
    if (own.node.name) |own_name| {
        if (sameName(own_name, wanted)) return own;
    }
    for (0..base.cores_running) |number| {
        const core: u32 = @intCast(number);
        _task.takeTasks(base, core, @returnAddress());
        defer _task.dropTaskLists(base);
        const there = base.cpus_at[core].this_task;
        if (there != own) {
            if (there.node.name) |other_name| {
                if (sameName(other_name, wanted)) return there;
            }
        }
        for ([_]*sdk.exec.List{ &base.cpus_at[core].tasks.ready, &base.cpus_at[core].tasks.wait }) |list| {
            if (sys.FindName(list, wanted)) |node| return @fieldParentPtr("node", node);
        }
    }
    return null;
}

/// The caller: this core's running task, read with the core's interrupts
/// masked so that the caller cannot be moved to the other core between
/// asking which core it is on and reading.
fn running(base: *ExecBase) *Task {
    const state = _interrupt.mask();
    defer _interrupt.unmask(state);
    return base.cpu().this_task;
}

/// Whether two NUL-terminated names are the same, byte for byte. A leaf of
/// exec's own: exec runs before utility.library exists and cannot call it
/// (codex rule 3).
///
/// INPUTS:
/// - `left`, `right` - the names to compare.
fn sameName(left: [*:0]const u8, right: [*:0]const u8) bool {
    var index: usize = 0;
    while (left[index] == right[index]) : (index += 1) {
        if (left[index] == 0) return true;
    }
    return false;
}
