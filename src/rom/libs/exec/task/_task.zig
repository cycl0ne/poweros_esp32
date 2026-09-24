// SPDX-License-Identifier: MPL-2.0
//! Tasks: preemptive scheduling by priority, round robin with a time slice
//! among equal priorities.
//!
//! A task is a stack, a context and a place on one of three lists: running
//! (one of them), ready, or waiting. The scheduler gives the processor to
//! the highest-priority ready task.
//!
//! **exec decides, the kernel switches.** The kernel calls `interruptEnter`
//! and `interruptExit` around every exception, and `interruptExit` answers
//! the context to resume - another task's when exec rescheduled. From task
//! level exec asks for a switch through `task_hardware.switch_now`, which
//! is a syscall, so a switch always happens at an exception exit and never
//! in the middle of compiled code.
//!
//! A switch is never cancelled, only postponed. `SFF_SAR` says one is due;
//! Forbid and Disable make `reschedule` leave it set, and the matching
//! `Permit` or `Enable` takes it.
//!
//! `reschedule` and `switchIfPending` do not go through the jump table and
//! must not: the scheduler cannot run on a vector something has replaced.
//!
//! Signals: Signal/Wait, SetSignal, AllocSignal/FreeSignal, and task
//! exceptions (SetExcept), which run a task's exception code when one of
//! its chosen signals arrives.
//!
//! A task has 32 signal bits. The low 16 are the system's, with fixed
//! meanings; `AllocSignal` hands out the rest, from 31 down.
//!
//! A signal is a flag and not a count: setting one that is already set
//! changes nothing, so two arrivals may be read as one. That is why a
//! signal only ever means "there is something to look at", and what is
//! looked at is a port, a list or a request.
//!
//! The task and signal calls are a file each in this folder; this file is
//! everything else.
//!
//! The scheduler - `interruptEnter`/`interruptExit` around every exception,
//! `tickQuantum` from the tick, `switchIfPending` from `Permit` and
//! `Enable`, and the dispatcher `reschedule` behind them; making the boot
//! and idle tasks at init and giving them back; laying a task out in one
//! block and freeing it; running a task's code; and raising a task's
//! exception on its way back into the processor.
//!
//! **The scheduler does not go through the jump table and must not**
//! (codex rule 1): it runs at the outermost exception exit on a
//! half-switched machine, so it cannot call a vector something may have
//! replaced. For the same reason it reads the running task from
//! `base.this_task` rather than asking `FindTask`.
//!
//! `taskEntry` and `exceptionEntry` are where the CPU starts a task and an
//! exception; they are handed no base, and take the kernel's `SysBase`.

const sdk = @import("sdk");
const exec = @import("../exec.zig");
const _interrupt = @import("../interrupt/_interrupt.zig");

const ExecBase = exec.ExecBase;
const vec = sdk.exec.vec;
const Task = sdk.exec.Task;
const Enqueue = @import("../list/enqueue.zig").Enqueue;
const RemHead = @import("../list/remhead.zig").RemHead;

/// SysFlags: scheduling attention required (a switch may be due).
pub const SFF_SAR: u16 = 1 << 15;
/// SysFlags: the running task's time slice is used up.
pub const SFF_TQE: u16 = 1 << 14;

/// The time slice, in ticks: how long a task keeps the processor before
/// one of equal priority gets a turn.
pub const default_quantum = 4;
/// The stack `CreateTask` gives a task that asks for none.
pub const default_stack_size = 8192;
/// The smallest stack a task or `NewStackRun` is given.
pub const min_stack_size = 1024;
const idle_stack_size = 4096;

/// What exec needs from the CPU to run tasks.
pub const TaskHardware = struct {
    /// Build a task's first context: resuming it calls `entry(arg)` on a
    /// stack that ends at `stack_upper`. Returns the context (tc_SPReg).
    init_context: *const fn (stack_upper: usize, entry: *const anyopaque, arg: *anyopaque) *anyopaque,
    /// From task level: enter the kernel so interruptExit can switch.
    switch_now: *const fn () void,
    /// Sleep until the next interrupt (the idle task).
    idle: *const fn () void,
    /// A context on the same stack, below `context`: resuming it calls
    /// `entry(context)`. How a task is made to run its exception code.
    push_exception: *const fn (context: *anyopaque, entry: *const anyopaque) *anyopaque,
    /// From task level: drop the running context and resume `context`.
    leave_exception: *const fn (context: *anyopaque) noreturn,
    /// `code(arg)` (a StackFn) on the stack that ends at `stack_upper`, and
    /// its answer: NewStackRun's part.
    call_on_stack: *const fn (stack_upper: usize, code: *const anyopaque, arg: ?*anyopaque) i32,
};

/// Where exec reaches the CPU to switch tasks. The kernel writes it before
/// the bootstrap; host tests put their own stub here. It is the kernel's
/// state rather than a module's, like `SysBase`.
pub var task_hardware: TaskHardware = no_task_hardware;

/// No CPU at all: a task's context is the task itself, nothing ever
/// switches, and an exception runs where it stands. It is what the host
/// tests run against, and what exec starts with until the kernel puts the
/// real one in.
pub const no_task_hardware: TaskHardware = .{
    .init_context = taskAsContext,
    .switch_now = noSwitch,
    .idle = noIdle,
    .push_exception = noException,
    .leave_exception = noLeave,
    .call_on_stack = callHere,
};

fn taskAsContext(_: usize, _: *const anyopaque, arg: *anyopaque) *anyopaque {
    return arg;
}
fn noSwitch() void {}
fn noIdle() void {}
fn noException(context: *anyopaque, _: *const anyopaque) *anyopaque {
    return context;
}
fn noLeave(_: *anyopaque) noreturn {
    @panic("no task hardware");
}
/// `no_task_hardware`'s call_on_stack: with no CPU to move a stack
/// pointer, the code runs on the caller's own stack. `stack_upper` is
/// ignored, which is safe here because nothing measures it.
fn callHere(_: usize, code: *const anyopaque, arg: ?*anyopaque) i32 {
    const stack_code: sdk.exec.StackFn = @ptrCast(@alignCast(code));
    return stack_code(arg);
}

/// `value` rounded up to a multiple of `alignment`, a power of two.
///
/// INPUTS:
/// - `value` - the size to round.
/// - `alignment` - a power of two.
pub fn alignUp(value: usize, alignment: usize) usize {
    return (value + (alignment - 1)) & ~(alignment - 1);
}

// --- the boot and idle tasks ------------------------------------------------

/// The task the boot code became, and the one that runs when nothing else
/// is ready. They are the kernel's own state, like `SysBase`; the host
/// tests need them by name to give the memory back in `deinitTasks`.
var boot_task: ?*Task = null;
var idle_task: ?*Task = null;

/// Makes the machine able to run tasks: the code running now becomes the
/// first task, "kernel", and an idle task is created under everything else.
///
/// The boot task gets no stack of its own - it already has the one it is
/// running on - which is what `newTask` with a size of 0 means. The idle
/// task is why the scheduler never has to ask whether there is a next
/// task: at priority -128 it is always ready or running.
///
/// INPUTS:
/// - `base` - exec: its task lists, and the jump table the calls go
///   through.
///
/// RESULT:
/// `error.OutOfMemory` if either task cannot be allocated, which the caller
/// turns into a failed init.
pub fn initTasks(base: *ExecBase) error{OutOfMemory}!void {
    base.task_ready.init(.task);
    base.task_wait.init(.task);
    base.quantum = default_quantum;
    base.elapsed = default_quantum;
    const boot = newTask(base, "kernel", 0, 0) orelse return error.OutOfMemory;
    boot.state = .run;
    base.this_task = boot;
    boot_task = boot;
    idle_task = base.iface().CreateTask("idle", -128, &idleLoop, idle_stack_size) orelse
        return error.OutOfMemory;
}

/// Gives the boot and idle tasks' memory back, so that a host test ends
/// with nothing outstanding. Only the tests call it: on the machine these
/// two live as long as it is running.
///
/// INPUTS:
/// - `base` - exec: the jump table the calls go through.
pub fn deinitTasks(base: *ExecBase) void {
    for ([_]?*Task{ idle_task, boot_task }) |maybe| {
        const task = maybe orelse continue;
        if (task.state == .ready or task.state == .wait) base.iface().Remove(&task.node);
        freeTaskMemory(base, task);
    }
    idle_task = null;
    boot_task = null;
}

/// The idle task: count a round and sleep until the next interrupt. It
/// never returns, and never waits on a signal - a task that waits is off
/// the ready list, and this one has to stay on it.
///
/// INPUTS:
/// - `sys` - exec, as every task's code is handed it; the idle count is in
///   its base.
fn idleLoop(sys: *sdk.exec.ExecBase) callconv(.c) void {
    const base: *ExecBase = @ptrCast(@alignCast(sys));
    while (true) {
        base.idle_count +%= 1;
        task_hardware.idle();
    }
}

// --- a task's memory and code -----------------------------------------------

/// One allocation holding the Task, a copy of its name and - unless
/// `stack_size` is 0 - its stack, so that `RemTask` frees all of it in one
/// call.
///
/// INPUTS:
/// - `base` - exec: the jump table `AllocMem` goes through.
/// - `name` - copied into the block.
/// - `pri` - the task's priority.
/// - `stack_size` - 0 for no stack at all, which is only right for the
///   boot task; anything smaller than the minimum is raised to it.
///
/// RESULT:
/// The task, not yet on any list, or null if there was no memory.
pub fn newTask(base: *ExecBase, name: [:0]const u8, pri: i8, stack_size: usize) ?*Task {
    const header = alignUp(@sizeOf(Task) + name.len + 1, 16);
    const stack = if (stack_size == 0) 0 else alignUp(@max(stack_size, min_stack_size), 16);
    const total = header + stack;
    const block = base.iface().AllocMem(total, sdk.exec.MEMF_CLEAR) orelse return null;
    const bytes: [*]u8 = @ptrCast(block);
    const name_copy = bytes + @sizeOf(Task);
    @memcpy(name_copy[0..name.len], name);
    name_copy[name.len] = 0;
    const task: *Task = @ptrCast(@alignCast(block));
    task.* = .{
        .node = .{ .type = .task, .pri = pri, .name = @ptrCast(name_copy) },
        .sp_lower = @intFromPtr(bytes + header),
        .sp_upper = @intFromPtr(bytes + total),
        .mem_block = block,
        .mem_size = total,
    };
    return task;
}

/// Gives back what `newTask` allocated, and clears the pointer so that a
/// second call does nothing. A task the caller laid out has no such block
/// and is left alone.
///
/// INPUTS:
/// - `base` - exec: the jump table `FreeMem` goes through.
/// - `task` - the task, off every list and not running.
pub fn freeTaskMemory(base: *ExecBase, task: *Task) void {
    const block = task.mem_block orelse return;
    task.mem_block = null;
    base.iface().FreeMem(block, task.mem_size);
}

/// Where every task really starts. It runs the task's code and then
/// removes the task, so a task that simply returns from its function ends
/// tidily instead of returning to nowhere.
///
/// INPUTS:
/// - `task` - the one being started. The CPU hands over nothing else, so
///   exec is the kernel's `SysBase`.
pub fn taskEntry(task: *Task) callconv(.c) noreturn {
    const base = exec.SysBase;
    runCode(base, task);
    base.iface().RemTask(null);
    unreachable;
}

/// A task's own code: its init function, then its final function if it has
/// one. Both are handed the SDK's `ExecBase`, which is how a task reaches
/// the system - the base is opaque and there is no global to read it from.
/// It is separate from `taskEntry` so that the host tests can run a task's
/// code without the removal.
///
/// INPUTS:
/// - `base` - exec, handed to the code.
/// - `task` - the task whose code is run.
pub fn runCode(base: *ExecBase, task: *Task) void {
    const sys = base.iface();
    task.init_pc.?(sys);
    if (task.final_pc) |final_pc| final_pc(sys);
}

/// Puts a task - the running one - on the wait list and asks for a switch,
/// so the next exception exit takes the processor away from it. This is
/// Wait's first half; the tests use it directly to block a task without
/// the rest of Wait.
///
/// INPUTS:
/// - `base` - exec: its wait list, and the jump table `AddTail` goes
///   through.
/// - `task` - the running task.
/// - `signal_set` - what it waits for, kept in `sig_wait` so that `Signal`
///   knows whether to wake it.
pub fn blockCurrent(base: *ExecBase, task: *Task, signal_set: u32) void {
    task.sig_wait = signal_set;
    task.state = .wait;
    base.iface().AddTail(&base.task_wait, &task.node);
    base.sys_flags |= SFF_SAR;
}

/// The highest-priority ready task, without taking it off the list, or
/// null if the ready list is empty - which on the running machine it never
/// is, since the idle task is always on it.
///
/// INPUTS:
/// - `base` - exec: its ready list.
pub fn firstReady(base: *ExecBase) ?*Task {
    const node = base.task_ready.first() orelse return null;
    return @fieldParentPtr("node", node);
}

// --- the scheduler ----------------------------------------------------------

/// Counts an exception entry. The kernel calls it at the start of every
/// exception - interrupt, syscall or trap - and `interruptExit` at the end.
/// The depth is what makes the scheduler run only at the **outermost**
/// exit: an interrupt that arrives inside another must not switch tasks.
///
/// INPUTS:
/// - `base` - exec: its exception depth.
pub fn interruptEnter(base: *ExecBase) void {
    base.int_depth += 1;
}

/// Counts an exception exit and answers the context to resume: the one
/// that was interrupted, or another task's when exec rescheduled. The
/// scheduler runs only at the outermost exit and only when a switch is
/// due, so an interrupt inside an interrupt always resumes exactly what it
/// interrupted.
///
/// INPUTS:
/// - `base` - exec: its exception depth and scheduling flags.
/// - `context` - what the kernel saved on entry.
pub fn interruptExit(base: *ExecBase, context: *anyopaque) *anyopaque {
    defer base.int_depth -= 1;
    if (base.int_depth == 1 and base.sys_flags & SFF_SAR != 0) return reschedule(base, context);
    return context;
}

/// Counts one tick off the running task's time slice, and asks for a
/// switch when it is spent and something of the same priority is waiting
/// its turn. The tick interrupt calls it.
///
/// A task of *lower* priority does not get a turn when the slice runs out.
/// The slice is what shares the processor between equals, not what takes it
/// away from a task that has earned it.
///
/// INPUTS:
/// - `base` - exec: the slice, the ready list and the running task.
pub fn tickQuantum(base: *ExecBase) void {
    if (base.elapsed > 0) base.elapsed -= 1;
    if (base.elapsed != 0) return;
    base.sys_flags |= SFF_TQE;
    if (firstReady(base)) |best| {
        if (best.node.pri >= base.this_task.node.pri) base.sys_flags |= SFF_SAR;
    }
}

/// Takes a switch that is due, if it is allowed now: at task level, with
/// no Forbid and no Disable outstanding. `Permit` and `Enable` call it,
/// which is what makes each of them a point where the caller may lose the
/// processor.
///
/// INPUTS:
/// - `base` - exec: its scheduling flags and nesting counts.
pub fn switchIfPending(base: *ExecBase) void {
    if (base.sys_flags & SFF_SAR == 0) return;
    if (base.int_depth != 0 or base.tdn_nest_cnt >= 0 or base.id_nest_cnt >= 0) return;
    task_hardware.switch_now();
}

/// The dispatcher: decides who runs next and answers that task's context.
/// It runs at the outermost exception exit and nowhere else.
///
/// The running task keeps the processor unless it waited, was removed, a
/// ready task has a higher priority, or one of equal priority is waiting
/// and the time slice is up. Forbid and Disable make it keep the processor
/// whatever else is true, and `SFF_SAR` is left set so that the matching
/// `Permit` or `Enable` comes back here.
///
/// The task that loses the processor has its switch function called once
/// its context is saved, and the task that gets it has its launch function
/// called before it runs. A task that removed itself is gone and gets
/// neither - and its memory is freed here, which is the first moment
/// nothing is running on its stack.
///
/// INPUTS:
/// - `base` - exec: the task lists, the running task and the flags.
/// - `context` - the running task's saved context.
///
/// RESULT:
/// What the kernel resumes.
fn reschedule(base: *ExecBase, context: *anyopaque) *anyopaque {
    const current = base.this_task;
    if (current.state == .run) {
        if (base.tdn_nest_cnt >= 0 or base.id_nest_cnt >= 0) return context;
        const best = firstReady(base) orelse {
            base.sys_flags &= ~SFF_SAR;
            return raiseException(base, current, context);
        };
        const time_up = base.sys_flags & SFF_TQE != 0;
        if (best.node.pri < current.node.pri or (best.node.pri == current.node.pri and !time_up)) {
            base.sys_flags &= ~SFF_SAR;
            return raiseException(base, current, context);
        }
        current.state = .ready;
        // Direct, not through the table: the dispatcher runs at the
        // outermost exception exit on a half-switched machine, so it
        // cannot call a vector something may have replaced (codex rule 1).
        Enqueue(base, &base.task_ready, &current.node);
    }
    base.sys_flags &= ~(SFF_SAR | SFF_TQE);

    if (current.state == .removed) {
        freeTaskMemory(base, current); // nothing will run on its stack again
    } else {
        current.sp_reg = context;
        current.td_nest_cnt = base.tdn_nest_cnt;
        current.id_nest_cnt = base.id_nest_cnt;
        current.id_saved = base.id_saved;
        if (current.flags & sdk.exec.TF_SWITCH != 0) {
            if (current.switch_code) |switch_code| switch_code(current, base.iface());
        }
    }

    // The idle task is always ready or running, so there is a next one.
    // Direct, for the same reason as the Enqueue above.
    const next: *Task = @fieldParentPtr("node", RemHead(base, &base.task_ready).?);
    next.state = .run;
    base.this_task = next;
    base.elapsed = base.quantum;
    base.disp_count +%= 1;
    base.tdn_nest_cnt = next.td_nest_cnt;
    base.id_nest_cnt = next.id_nest_cnt;
    base.id_saved = next.id_saved;
    if (next.flags & sdk.exec.TF_LAUNCH != 0) {
        if (next.launch_code) |launch_code| launch_code(next, base.iface());
    }
    return raiseException(base, next, next.sp_reg.?);
}

// --- task exceptions --------------------------------------------------------

/// Whether a task has an exception to run: exception code, and one of its
/// exception signals received.
///
/// INPUTS:
/// - `task` - the task to ask about.
pub fn exceptionPending(task: *const Task) bool {
    return task.except_code != null and task.sig_recvd & task.sig_except != 0;
}

/// Runs a task's exception code for every exception signal that has
/// arrived, and repeats while more are pending.
///
/// The caller holds Disable. The signals are taken out of both the received
/// and the exception sets before the code runs, so it cannot be re-entered
/// for the same signal; the code runs with interrupts on whatever the
/// Disable nesting was, since it is the task's own code and may do the
/// things a task does; and the bits it answers are put back into the
/// exception set, which is how it says which signals it still wants.
///
/// INPUTS:
/// - `base` - exec: the Disable nesting it steps out of.
/// - `task` - the running task.
pub fn runExceptions(base: *ExecBase, task: *Task) void {
    while (exceptionPending(task)) {
        const signals = task.sig_recvd & task.sig_except;
        task.sig_recvd &= ~signals;
        task.sig_except &= ~signals;
        const nest = base.id_nest_cnt;
        base.id_nest_cnt = -1;
        _interrupt.interrupt_hardware.restore(base.id_saved);
        const enable = task.except_code.?(signals, task.except_data);
        base.id_saved = _interrupt.interrupt_hardware.disable();
        base.id_nest_cnt = nest;
        task.sig_except |= enable;
    }
}

/// What a raised exception runs, in the task on its own stack.
///
/// INPUTS:
/// - `context` - where the task was. The CPU hands over nothing else, so
///   exec is the kernel's `SysBase`.
fn exceptionEntry(context: *anyopaque) callconv(.c) noreturn {
    exceptionBody(exec.SysBase);
    task_hardware.leave_exception(context);
}

/// `exceptionEntry` without the way back, for the host tests.
///
/// INPUTS:
/// - `base` - exec: the jump table Disable, Enable and `FindTask` go
///   through.
pub fn exceptionBody(base: *ExecBase) void {
    const sys = base.iface();
    sys.Disable();
    runExceptions(base, sys.FindTask(null).?);
    sys.Enable();
}

/// The dispatcher, on the way into `task`: if an exception is pending and
/// the task is neither in Forbid nor in Disable, the exception code runs
/// first. Tasks blocked in Wait are in Disable; Wait runs it itself.
///
/// INPUTS:
/// - `base` - exec: the Forbid and Disable nesting.
/// - `task` - the task about to run.
/// - `context` - where it resumes.
///
/// RESULT:
/// The context to resume: `context`, or one that runs the exception first.
pub fn raiseException(base: *ExecBase, task: *Task, context: *anyopaque) *anyopaque {
    if (!exceptionPending(task) or base.tdn_nest_cnt >= 0 or base.id_nest_cnt >= 0) return context;
    return task_hardware.push_exception(context, vec(exceptionEntry));
}

// --- tests (host: ./zig build test) -----------------------------------------

const testing = @import("std").testing;

test "alignUp rounds to the power of two" {
    try testing.expectEqual(@as(usize, 16), alignUp(1, 16));
    try testing.expectEqual(@as(usize, 16), alignUp(16, 16));
    try testing.expectEqual(@as(usize, 0), alignUp(0, 16));
}
