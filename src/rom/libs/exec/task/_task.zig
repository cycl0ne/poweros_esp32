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
//! Disable and a spinlock make `reschedule` leave it set, and the matching
//! `Enable` or `ReleaseLock` takes it.
//!
//! `reschedule` does not go through the jump table and must not: the
//! scheduler cannot run on a vector something has replaced.
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
//! `tickQuantum` from the tick, `switchDue` for `Enable` and
//! `ReleaseLock`, and the dispatcher `reschedule` behind them; making the boot
//! and idle tasks at init and giving them back; laying a task out in one
//! block and freeing it; running a task's code; and raising a task's
//! exception on its way back into the processor.
//!
//! **The scheduler does not go through the jump table and must not**
//! (codex rule 1): it runs at the outermost exception exit on a
//! half-switched machine, so it cannot call a vector something may have
//! replaced. For the same reason it reads the running task from
//! `base.cpu().this_task` rather than asking `FindTask`.
//!
//! `taskEntry` and `exceptionEntry` are where the CPU starts a task and an
//! exception; they are handed no base, and take the kernel's `SysBase`.
//!
//! **Two cores share one ready list.** Each core has its running task, its
//! slice and its flags (`CpuState`), and its own dispatcher, which takes
//! the best ready task that may run there: one pinned to it or to no
//! core. The lists and every core's flags are kept under the system's interrupt
//! lock, which a core holds in every exception and while its task is
//! inside Disable. A task made ready goes to the core it should run on
//! now - this one's dispatcher asked to look, or the other core poked
//! with its cross-core interrupt, whose exit runs its dispatcher. A core
//! writes only its own flags: the other is poked, never written.
//!
//! **What keeps a task on its core**: Disable, and a spinlock held
//! (`hold_count`) - each for its own core only. Nothing stops the machine:
//! what code must keep to itself is under a lock of its own. Until the
//! kernel lets multitasking start (`startMultitasking`) no core switches
//! away from the task it runs, unless that task waits. A task's own
//! memory is freed by the core it ran on, at the exception exit after its
//! last one: until then that core still writes its windows to its stack.

const sdk = @import("sdk");
const exec = @import("../exec.zig");
const exec_base = @import("../exec_base.zig");
const _interrupt = @import("../interrupt/_interrupt.zig");

const ExecBase = exec.ExecBase;
const vec = sdk.exec.vec;
const Task = sdk.exec.Task;
const Enqueue = @import("../list/enqueue.zig").Enqueue;
const RemHead = @import("../list/remhead.zig").RemHead;
const Remove = @import("../list/remove.zig").Remove;
const AddTail = @import("../list/addtail.zig").AddTail;
const Deallocate = @import("../memory/deallocate.zig").Deallocate;
const _locks = @import("../locks/_locks.zig");

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

// --- stack guards -----------------------------------------------------------
//
// The bottom words of every stack hold a pattern no frame writes on purpose:
// a stack that grows down past its end writes over them before it writes
// over anything else's memory. The dispatcher looks at the running task's
// guard each time it switches away from it, and `NewStackRun` before it
// gives its stack back, so a stack that ran over stops the machine with a
// Guru naming the task - not three programs later, in whatever memory the
// overflow happened to land on.

/// How many words at the bottom of a stack are its guard.
pub const guard_words = 4;
const guard_pattern: u32 = 0x5354_4B21; // "STK!"

/// The guard written at the bottom of `task`'s stack, and the task marked
/// as having one; a task without a stack of its own (`sp_lower` 0) has
/// none.
pub fn guardStack(task: *Task) void {
    if (task.sp_lower == 0) return;
    const words: [*]volatile u32 = @ptrFromInt(task.sp_lower);
    for (0..guard_words) |i| words[i] = guard_pattern;
    task.flags |= sdk.exec.TF_GUARDED;
}

/// Whether the stack starting at `lower` still has its guard.
pub fn guardIntact(lower: usize) bool {
    if (lower == 0) return true;
    const words: [*]const volatile u32 = @ptrFromInt(lower);
    for (0..guard_words) |i| {
        if (words[i] != guard_pattern) return false;
    }
    return true;
}

/// A task's stack checked as the dispatcher switches away from it: its
/// guard intact and, on the chip, its saved context inside its bounds. A
/// stack that ran over is a dead end - what it wrote over is no longer
/// what its owners think it is.
fn checkStack(task: *const Task, context: *anyopaque) void {
    if (task.flags & sdk.exec.TF_GUARDED == 0) return;
    var over = !guardIntact(task.sp_lower);
    // The host tests hand the dispatcher contexts that are not addresses.
    if (@import("builtin").cpu.arch == .xtensa) {
        const at = @intFromPtr(context);
        if (at < task.sp_lower or at > task.sp_upper) over = true;
    }
    if (over) stackOverrun(@intFromPtr(context));
}

/// The dead end for a stack that ran over; `where` is the stack or the
/// context the check found it at.
pub fn stackOverrun(where: usize) void {
    _interrupt.alertAt(sdk.exec.AT_DeadEnd | sdk.exec.AN_StackProbe, where, "a task's stack ran past its end");
}
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
    /// A word per core: the task the core's dispatcher has just switched
    /// away from, which the CPU sets back to 0 once the switch is done and
    /// the core is off that task's stack - its windows written there, and
    /// the exception's own frames below them left. Until then no other
    /// core may resume the task. None where nothing switches.
    leaving: ?*[exec_base.max_cores]usize = null,
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

/// The task the boot code became, and the ones that run when nothing else
/// is ready, one pinned to each core. They are the kernel's own state,
/// like `SysBase`; the host tests need them by name to give the memory
/// back in `deinitTasks`.
var boot_task: ?*Task = null;
var idle_tasks: [exec_base.max_cores]?*Task = @splat(null);
const idle_names = [exec_base.max_cores][:0]const u8{ "idle", "idle 1" };

/// Makes the machine able to run tasks: the code running now becomes the
/// first task, "kernel", and an idle task is created under everything else.
/// Both stay on core 0.
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
    base.cpu().elapsed = default_quantum;
    const boot = newTask(base, "kernel", 0, 0) orelse return error.OutOfMemory;
    boot.state = .run;
    boot.flags |= sdk.exec.TF_CORE0;
    base.cpu().this_task = boot;
    base.cpu().time_mark = cycles();
    boot_task = boot;
    const idle = base.iface().CreateTask(idle_names[0], -128, &idleLoop, idle_stack_size) orelse
        return error.OutOfMemory;
    // Pinned once it is on the ready list: no other core runs yet.
    idle.flags |= sdk.exec.TF_CORE0;
    idle_tasks[0] = idle;
}

/// Core `core`'s idle task, made by core 0 before it lets that core go:
/// the code the core starts in becomes it, on the stack it starts on, as
/// the boot code became "kernel" on core 0. It is pinned to the core,
/// below everything else, and running there from the start.
///
/// INPUTS:
/// - `base` - exec: the core's state, and the jump table `AllocMem` goes
///   through.
/// - `core` - the core, not running yet.
/// - `stack_lower`, `stack_upper` - the stack it starts on; its bottom
///   gets the guard.
///
/// RESULT:
/// False when there was no memory for the task.
pub fn prepareCore(base: *ExecBase, core: u32, stack_lower: usize, stack_upper: usize) bool {
    const task = newTask(base, idle_names[core].ptr, -128, 0) orelse return false;
    task.sp_lower = stack_lower;
    task.sp_upper = stack_upper;
    task.flags |= if (core == 0) sdk.exec.TF_CORE0 else sdk.exec.TF_CORE1;
    task.sig_alloc |= sdk.exec.tasks.system_signals;
    task.state = .run;
    guardStack(task);
    base.cpus[core] = .{};
    base.cpus[core].this_task = task;
    base.cpus[core].elapsed = base.quantum;
    idle_tasks[core] = task;
    return true;
}

/// The core this runs on, prepared by `prepareCore`, taking tasks from
/// here on. It calls this itself, with its interrupts masked, and then
/// `idleHere`.
///
/// INPUTS:
/// - `base` - exec: how many cores take tasks.
pub fn coreStarted(base: *ExecBase) void {
    base.cpu().time_mark = cycles();
    _interrupt.takeSystemInterrupts(base, @returnAddress());
    base.cores_running = exec_base.coreId() + 1;
    _interrupt.dropSystemInterrupts(base);
}

/// The idle task's loop, for the code of a core that became its idle
/// task (`prepareCore`); never returns.
///
/// INPUTS:
/// - `base` - exec: the idle count.
pub fn idleHere(base: *ExecBase) noreturn {
    while (true) idleRound(base);
}

/// Gives the boot and idle tasks' memory back, so that a host test ends
/// with nothing outstanding. Only the tests call it: on the machine these
/// two live as long as it is running.
///
/// INPUTS:
/// - `base` - exec: the jump table the calls go through.
pub fn deinitTasks(base: *ExecBase) void {
    for ([_]?*Task{ idle_tasks[0], boot_task }) |maybe| {
        const task = maybe orelse continue;
        if (task.state == .ready or task.state == .wait) base.iface().Remove(&task.node);
        freeTaskMemory(base, task);
    }
    idle_tasks[0] = null;
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
    while (true) idleRound(base);
}

/// One round of an idle task: counted, and asleep until the next
/// interrupt. An idle task is pinned to its core, so it reads the core's
/// state as it stands.
fn idleRound(base: *ExecBase) void {
    base.cpu().idle_count +%= 1;
    task_hardware.idle();
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
pub fn newTask(base: *ExecBase, name: [*:0]const u8, pri: i8, stack_size: usize) ?*Task {
    var name_len: usize = 0;
    while (name[name_len] != 0) name_len += 1;
    const header = alignUp(@sizeOf(Task) + name_len + 1, 16);
    const stack = if (stack_size == 0) 0 else alignUp(@max(stack_size, min_stack_size), 16);
    const total = header + stack;
    const block = base.iface().AllocMem(total, sdk.exec.MEMF_CLEAR) orelse return null;
    const bytes: [*]u8 = @ptrCast(block);
    const name_copy = bytes + @sizeOf(Task);
    @memcpy(name_copy[0..name_len], name[0..name_len]);
    name_copy[name_len] = 0;
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

/// A task's end hooks made an empty list, the first time one is put on: a
/// TCB laid out by hand has the list zeroed, which is not an empty list.
/// Under Disable, which the hook lists are kept under: a few nodes, and
/// the task they belong to may be ending on the other core.
pub fn endHooks(task: *Task) void {
    if (task.end_hooks.head == null) task.end_hooks.init();
}

/// Every end hook of `task` run, in the order they were put on, each taken
/// off under Disable before it runs and nothing held while it does.
pub fn runEndHooks(base: *ExecBase, task: *Task) void {
    const sys = base.iface();
    while (true) {
        sys.Disable();
        if (task.end_hooks.head == null) {
            sys.Enable();
            return;
        }
        const node = sys.RemHead(@ptrCast(&task.end_hooks)) orelse {
            sys.Enable();
            return;
        };
        const hook: *sdk.exec.TaskEndHook = @ptrCast(node);
        hook.task = null;
        sys.Enable();
        hook.code(sys, task, hook);
    }
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

/// `freeTaskMemory` for an exception exit, which frees a removed task's
/// memory once nothing will run on its stack again. That is interrupt
/// context, where the memory lock - a plain one, so that allocating never
/// masks interrupts - is not taken through AcquireLock. It is tried here
/// directly, once: its holder - a task on this core the exception
/// interrupted, or one on the other core, which may itself be waiting for
/// this core's interrupt lock - cannot be waited for. A lock held is
/// false, and the task is tried again at a later exit. And directly, not
/// through the table, as everything here: the dispatcher runs on a
/// half-switched machine (codex rule 1).
///
/// Once it is, the message whoever asked to be told left (`SetTaskEndMsg`)
/// is replied - read before the memory goes, replied after: the task is
/// not read again.
///
/// RESULT:
/// True once the memory is given back (or there was none to give).
fn freeRemovedTask(base: *ExecBase, task: *Task) bool {
    const ended = task.end_msg;
    if (!giveBackTaskMemory(base, task)) return false;
    if (ended) |msg| replyEnded(base, msg);
    return true;
}

/// A task's end message replied, from an exception exit. The port's list
/// is exec's port lock's, and every holder of that lock holds the system's
/// interrupt lock as well - which the exception holds - so the list is
/// changed here without it, and directly, as everything in the dispatcher
/// is. A port that signals has its task woken; one that causes a software
/// interrupt is not served from here.
fn replyEnded(base: *ExecBase, msg: *sdk.exec.Message) void {
    const port = msg.reply_port orelse return;
    msg.node.type = .replymsg;
    AddTail(base, &port.msg_list, &msg.node);
    if (port.flags & sdk.exec.PF_ACTION != sdk.exec.PA_SIGNAL) return;
    const owner = port.sig_task orelse return;
    wake(base, @ptrCast(@alignCast(owner)), port.sigMask());
}

/// The memory part of `freeRemovedTask`: false while the memory lock is
/// held elsewhere.
fn giveBackTaskMemory(base: *ExecBase, task: *Task) bool {
    const block = task.mem_block orelse return true;
    const here = _locks.heldHere(base);
    if (!_locks.compareAndSet(base, &base.lock_memory.state, 0, here)) return false;
    defer @atomicStore(u32, &base.lock_memory.state, 0, .release);
    task.mem_block = null;
    const address = @intFromPtr(block);
    var it = base.mem_list.iterator();
    while (it.next()) |node| {
        const region: *sdk.exec.MemHeader = @fieldParentPtr("node", node);
        if (address >= @intFromPtr(region.lower) and address < @intFromPtr(region.upper)) {
            Deallocate(base, region, block, task.mem_size);
            return true;
        }
    }
    return true;
}

/// What the core's last switches left behind, dealt with at its next
/// exception exit - on another task's stack now: ended tasks' memory
/// freed, as far as the memory lock lets it be, and the taker of a
/// stopped task told.
///
/// INPUTS:
/// - `base` - exec: this core's state.
fn reap(base: *ExecBase) void {
    const cpu = base.cpu();
    if (cpu.stopped) |_| {
        cpu.stopped = null;
        const waiter = cpu.stop_waiter;
        cpu.stop_waiter = null;
        if (waiter) |task| wake(base, task, sdk.exec.SIGF_SINGLE);
    }
    var left: ?*Task = null;
    while (cpu.reap) |task| {
        cpu.reap = nextReaped(task);
        if (freeRemovedTask(base, task)) continue;
        task.node.succ = if (left) |kept| &kept.node else null;
        left = task;
    }
    cpu.reap = left;
}

/// `task` put on this core's chain of tasks to free at its next exit.
fn reapLater(cpu: *exec_base.CpuState, task: *Task) void {
    task.node.succ = if (cpu.reap) |kept| &kept.node else null;
    cpu.reap = task;
}

fn nextReaped(task: *Task) ?*Task {
    const node = task.node.succ orelse return null;
    return @fieldParentPtr("node", node);
}

/// Signal's part for the dispatcher: `signals` for `task`, and the task
/// made ready if it waits for one of them. Directly, not through the
/// table (codex rule 1); the caller is in an exception.
fn wake(base: *ExecBase, task: *Task, signals: u32) void {
    task.sig_recvd |= signals;
    if (task.state != .wait or task.sig_recvd & task.sig_wait == 0) return;
    Remove(base, &task.node);
    task.state = .ready;
    Enqueue(base, &base.task_ready, &task.node);
    wakeFor(base, task);
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
    base.cpu().sys_flags |= SFF_SAR;
}

// --- the scheduler ----------------------------------------------------------

/// Counts an exception entry. The kernel calls it at the start of every
/// exception - interrupt, syscall or trap - and `interruptExit` at the end.
/// The depth is what makes the scheduler run only at the **outermost**
/// exit: an interrupt that arrives inside another must not switch tasks.
/// The outermost entry takes the system's interrupt lock, unless the core
/// holds it already for a task inside Disable: what an exception does is
/// kept from a Disable on the other core, as it is from one on this.
///
/// INPUTS:
/// - `base` - exec: this core's exception depth, and the lock.
pub fn interruptEnter(base: *ExecBase) void {
    const cpu = base.cpu();
    if (cpu.int_depth == 0 and cpu.id_nest_cnt < 0) _interrupt.takeSystemInterrupts(base, 1);
    // The time since the last exit was the task's it resumed - or idle.
    if (cpu.int_depth == 0) {
        const now = cycles();
        const spent = now -% cpu.time_mark;
        if (cpu.this_task == idle_tasks[exec_base.coreId()]) cpu.time_idle +%= spent else cpu.time_tasks +%= spent;
        cpu.time_mark = now;
    }
    cpu.int_depth += 1;
}

/// The core's clock, in cycles: what its times are counted in. None on
/// the host.
pub fn cycles() u32 {
    return exec_base.cycles();
}

/// Counts an exception exit and answers the context to resume: the one
/// that was interrupted, or another task's when exec rescheduled. The
/// scheduler runs only at the outermost exit and only when a switch is
/// due, so an interrupt inside an interrupt always resumes exactly what it
/// interrupted. The outermost exit first deals with what earlier switches
/// left behind (`reap`), and lets the interrupt lock go unless the task
/// it resumes is inside Disable.
///
/// INPUTS:
/// - `base` - exec: this core's exception depth and scheduling flags.
/// - `context` - what the kernel saved on entry.
pub fn interruptExit(base: *ExecBase, context: *anyopaque) *anyopaque {
    const cpu = base.cpu();
    var resumed = context;
    if (cpu.int_depth == 1) {
        if (cpu.reap != null or cpu.stopped != null) reap(base);
        if (cpu.sys_flags & SFF_SAR != 0) resumed = reschedule(base, context);
    }
    cpu.int_depth -= 1;
    if (cpu.int_depth == 0) {
        const now = cycles();
        cpu.time_interrupts +%= now -% cpu.time_mark;
        cpu.time_mark = now;
        if (cpu.id_nest_cnt < 0) _interrupt.dropSystemInterrupts(base);
    }
    return resumed;
}

/// Counts one tick off the running task's time slice, and asks for a
/// switch when it is spent and something of the same priority is waiting
/// its turn. Each core's tick interrupt calls it for its own slice.
///
/// A task of *lower* priority does not get a turn when the slice runs out.
/// The slice is what shares the processor between equals, not what takes it
/// away from a task that has earned it.
///
/// INPUTS:
/// - `base` - exec: the slice, the ready list and the running task.
pub fn tickQuantum(base: *ExecBase) void {
    const core = exec_base.coreId();
    const cpu = &base.cpus[core];
    if (cpu.elapsed > 0) cpu.elapsed -= 1;
    if (cpu.elapsed != 0) return;
    cpu.sys_flags |= SFF_TQE;
    if (bestReady(base, core)) |best| {
        if (best.node.pri >= cpu.this_task.node.pri) cpu.sys_flags |= SFF_SAR;
    }
}

/// Whether a switch is due on the core and allowed now: at task level, with
/// no Disable and no spinlock outstanding. `Enable` and `ReleaseLock` ask
/// it with their interrupts masked and take the switch once they are back,
/// which is what makes each of them a point where the caller may lose the
/// processor.
///
/// INPUTS:
/// - `cpu` - this core's state.
pub fn switchDue(cpu: *const exec_base.CpuState) bool {
    return cpu.sys_flags & SFF_SAR != 0 and cpu.int_depth == 0 and
        cpu.id_nest_cnt < 0 and cpu.hold_count == 0;
}

/// Multitasking started: from here on a core switches away from a running
/// task as its priority and its slice say. The kernel's, once, when the
/// system is up - before, the boot runs on as the one task that matters,
/// and the exec task it made waits for this. A switch that came due
/// meanwhile is taken here.
///
/// INPUTS:
/// - `base` - exec: the flag, and this core's state.
pub fn startMultitasking(base: *ExecBase) void {
    const hardware = _interrupt.interrupt_hardware;
    const state = hardware.disable();
    @atomicStore(u32, &base.multitasking, 1, .release);
    const due = switchDue(base.cpu());
    hardware.restore(state);
    if (due) task_hardware.switch_now();
}

/// The dispatcher: decides who runs next on this core and answers that
/// task's context. It runs at the outermost exception exit and nowhere
/// else.
///
/// The running task keeps the processor unless it waited, was removed, a
/// ready task that may run here has a higher priority, or one of equal
/// priority is waiting and the time slice is up. Disable and a spinlock
/// make it keep the processor whatever else is true - as does the boot,
/// until multitasking starts - and `SFF_SAR` is left set so that the
/// matching `Enable` or `ReleaseLock` comes back here. A task that gives up
/// the processor still able to run is offered to the other core.
///
/// The task that loses the processor has its switch function called once
/// its context is saved, and the task that gets it has its launch function
/// called before it runs. A task that removed itself is gone and gets
/// neither - and its memory is freed once nothing runs on its stack: here
/// with one core, at the next exit with two. A task another core's
/// RemTask is taking away (`stopping`) is switched out at its first switch
/// point and goes nowhere; the next exit tells the taker.
///
/// INPUTS:
/// - `base` - exec: the task lists, the running task and the flags.
/// - `context` - the running task's saved context.
///
/// RESULT:
/// What the kernel resumes.
fn reschedule(base: *ExecBase, context: *anyopaque) *anyopaque {
    const core = exec_base.coreId();
    const cpu = &base.cpus[core];
    const current = cpu.this_task;
    const started = @atomicLoad(u32, &base.multitasking, .acquire) != 0;
    const held = !started or cpu.id_nest_cnt >= 0 or cpu.hold_count != 0;
    const stopping = cpu.stopping == current;
    if (current.state == .run and held) return context;
    if (current.state == .run and !stopping) {
        const time_up = cpu.sys_flags & SFF_TQE != 0;
        var stays = runnableOn(base, current, core);
        if (stays) {
            if (bestReady(base, core)) |best| {
                stays = best.node.pri < current.node.pri or (best.node.pri == current.node.pri and !time_up);
            }
        }
        if (stays) {
            cpu.sys_flags &= ~SFF_SAR;
            return raiseException(base, current, context);
        }
        current.state = .ready;
        // Direct, not through the table: the dispatcher runs at the
        // outermost exception exit on a half-switched machine, so it
        // cannot call a vector something may have replaced (codex rule 1).
        Enqueue(base, &base.task_ready, &current.node);
        offerOther(base, current, core);
    }
    cpu.sys_flags &= ~(SFF_SAR | SFF_TQE);

    if (stopping) {
        // Taken away by another core: off the wait list if it went there,
        // and nothing saved - it never runs again.
        if (current.state == .wait) Remove(base, &current.node);
        cpu.stopping = null;
        cpu.stopped = current;
    } else if (current.state == .removed) {
        // Nothing will run on its stack again once this core is off it:
        // at once with one core, at the next exit with two, as the other
        // core could have the memory before this one has left it.
        // A task whose end someone waits to hear of is reaped at the next
        // exit as well, where the signal goes out as an interrupt's would.
        if (base.cores_running > 1 or current.end_msg != null or !freeRemovedTask(base, current)) reapLater(cpu, current);
    } else {
        checkStack(current, context);
        current.sp_reg = context;
        current.id_nest_cnt = cpu.id_nest_cnt;
        current.id_saved = cpu.id_saved;
        if (current.flags & sdk.exec.TF_SWITCH != 0) {
            if (current.switch_code) |switch_code| switch_code(current, base.iface());
        }
    }
    const next = takeReady(base, core);
    // The task left stays this core's until the switch is done: the CPU
    // still writes to its stack on the way out.
    if (next != current and current.state != .removed and !stopping) markLeaving(core, current);
    next.state = .run;
    cpu.this_task = next;
    cpu.elapsed = base.quantum;
    cpu.disp_count +%= 1;
    cpu.id_nest_cnt = next.id_nest_cnt;
    cpu.id_saved = next.id_saved;
    if (next.flags & sdk.exec.TF_LAUNCH != 0) {
        if (next.launch_code) |launch_code| launch_code(next, base.iface());
    }
    // What is left ready may be the other core's to run.
    if (base.cores_running > 1) {
        const other = 1 - core;
        if (bestReady(base, other)) |waiting| offerOther(base, waiting, core);
    }
    return raiseException(base, next, next.sp_reg.?);
}

/// `task` marked as the one `core` is switching away from.
fn markLeaving(core: u32, task: *Task) void {
    const words = task_hardware.leaving orelse return;
    @atomicStore(usize, &words[core], @intFromPtr(task), .release);
}

/// Until no other core is still switching away from `task`: a few hundred
/// cycles at most, as that core is on its way out of an exception with
/// its interrupts masked. A hold asked meanwhile is answered.
fn waitLeft(task: *const Task, core: u32) void {
    const words = task_hardware.leaving orelse return;
    for (words, 0..) |*word, other| {
        if (other == core) continue;
        while (@atomicLoad(usize, word, .acquire) == @intFromPtr(task)) {
            _interrupt.interrupt_hardware.park_if_asked();
        }
    }
}

// --- the cores --------------------------------------------------------------

/// Whether `task` may run on `core`: pinned to it, or to neither core (or
/// both) - and then on core 1 only once the cores share.
///
/// INPUTS:
/// - `base` - exec: whether the cores share.
/// - `task` - the task.
/// - `core` - the core.
pub fn runnableOn(base: *const ExecBase, task: *const Task, core: u32) bool {
    const both = sdk.exec.TF_CORE0 | sdk.exec.TF_CORE1;
    const pins = task.flags & both;
    const own: u8 = if (core == 0) sdk.exec.TF_CORE0 else sdk.exec.TF_CORE1;
    if (pins == own) return true;
    if (pins != 0 and pins != both) return false;
    return core == 0 or base.share_cores != 0;
}

/// The highest-priority ready task `core`'s dispatcher would take,
/// without taking it: one that may run there. Null when there is none.
///
/// INPUTS:
/// - `base` - exec: its ready list.
/// - `core` - the core asking.
pub fn bestReady(base: *ExecBase, core: u32) ?*Task {
    var it = base.task_ready.iterator();
    while (it.next()) |node| {
        const task: *Task = @fieldParentPtr("node", node);
        if (runnableOn(base, task, core)) return task;
    }
    return null;
}

/// The task `core`'s dispatcher runs next, off the ready list: the first
/// that may run there.
///
/// INPUTS:
/// - `base` - exec: the ready list.
/// - `core` - this core.
fn takeReady(base: *ExecBase, core: u32) *Task {
    var it = base.task_ready.iterator();
    while (it.next()) |node| {
        const task: *Task = @fieldParentPtr("node", node);
        if (!runnableOn(base, task, core)) continue;
        waitLeft(task, core);
        Remove(base, node);
        return task;
    }
    // The core's idle task is pinned to it, and always ready or running.
    unreachable;
}

/// `task`, just made ready, brought to a core that should run it now:
/// the other core poked when it may run there, outranks what runs there,
/// and that is less than what runs here; else this core's dispatcher
/// asked to look when it may run here and outranks what runs here. The
/// caller holds the interrupt lock, which keeps every core's running task
/// where it is.
///
/// INPUTS:
/// - `base` - exec: the cores' running tasks and flags.
/// - `task` - the task made ready.
pub fn wakeFor(base: *ExecBase, task: *Task) void {
    const core = exec_base.coreId();
    const here = base.cpus[core].this_task.node.pri;
    const may_here = runnableOn(base, task, core);
    if (base.cores_running > 1) {
        const other = 1 - core;
        const there = base.cpus[other].this_task.node.pri;
        if (runnableOn(base, task, other) and task.node.pri > there and (!may_here or there < here)) {
            pokeCore(other);
            return;
        }
    }
    if (may_here and task.node.pri > here) base.cpus[core].sys_flags |= SFF_SAR;
}

/// `task`, ready, offered to the core that is not `core`: poked when the
/// task may run there and outranks what runs there.
fn offerOther(base: *ExecBase, task: *const Task, core: u32) void {
    if (base.cores_running < 2) return;
    const other = 1 - core;
    if (!runnableOn(base, task, other)) return;
    if (task.node.pri > base.cpus[other].this_task.node.pri) pokeCore(other);
}

/// The dispatcher of the core running `task` asked to look again: this
/// core's through its flags, another's through its cross-core interrupt.
/// Nothing for a task that is not running. The caller holds the
/// interrupt lock.
///
/// INPUTS:
/// - `base` - exec: the cores' running tasks.
/// - `task` - the task.
pub fn askCoreOf(base: *ExecBase, task: *const Task) void {
    const core = exec_base.coreId();
    if (base.cpus[core].this_task == task) {
        base.cpus[core].sys_flags |= SFF_SAR;
    } else if (runningOn(base, task)) |other| {
        pokeCore(other);
    }
}

/// The other core `task` is running on, if it is running on one. The
/// caller holds the interrupt lock.
pub fn runningOn(base: *ExecBase, task: *const Task) ?u32 {
    const core = exec_base.coreId();
    for (0..base.cores_running) |other| {
        if (other != core and base.cpus[other].this_task == task) return @intCast(other);
    }
    return null;
}

/// Core `core` asked to run its dispatcher: its cross-core interrupt.
fn pokeCore(core: u32) void {
    _interrupt.interrupt_hardware.poke_core(core);
}

/// The cross-core interrupt's part: this core's dispatcher runs at its
/// exit and looks at what is ready. The kernel calls it from the
/// interrupt.
///
/// INPUTS:
/// - `base` - exec: this core's flags.
pub fn crossCorePoke(base: *ExecBase) void {
    base.cpu().sys_flags |= SFF_SAR;
}

/// A task running on another core brought to its next switch point there
/// and switched out for good, before `RemTask` takes it away; nothing for
/// a task that is not running. The caller waits for it with Wait, and goes
/// on once the other core has left the task's stack.
///
/// INPUTS:
/// - `base` - exec: the cores' running tasks, and the jump table the calls
///   go through.
/// - `task` - the task, not the caller.
pub fn stopElsewhere(base: *ExecBase, task: *Task) void {
    const sys = base.iface();
    _ = sys.SetSignal(0, sdk.exec.SIGF_SINGLE);
    sys.Disable();
    defer sys.Enable();
    const core = runningOn(base, task) orelse return;
    const cpu = &base.cpus[core];
    cpu.stopping = task;
    cpu.stop_waiter = base.cpu().this_task;
    pokeCore(core);
    while (cpu.stopping == task or cpu.stopped == task) _ = sys.Wait(sdk.exec.SIGF_SINGLE);
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
/// The caller holds Disable, at task level. The signals are taken out of
/// both the received and the exception sets before the code runs, so it
/// cannot be re-entered for the same signal; the code runs with interrupts
/// on and the interrupt lock let go whatever the Disable nesting was,
/// since it is the task's own code and may do the things a task does; and
/// the bits it answers are put back into the exception set, which is how
/// it says which signals it still wants.
///
/// INPUTS:
/// - `base` - exec: the Disable nesting it steps out of.
/// - `task` - the running task.
pub fn runExceptions(base: *ExecBase, task: *Task) void {
    while (exceptionPending(task)) {
        const signals = task.sig_recvd & task.sig_except;
        task.sig_recvd &= ~signals;
        task.sig_except &= ~signals;
        const cpu = base.cpu();
        const nest = cpu.id_nest_cnt;
        cpu.id_nest_cnt = -1;
        _interrupt.dropSystemInterrupts(base);
        _interrupt.interrupt_hardware.restore(cpu.id_saved);
        const enable = task.except_code.?(signals, task.except_data);
        const saved = _interrupt.interrupt_hardware.disable();
        // The task may have moved to the other core while its code ran.
        const now = base.cpu();
        now.id_saved = saved;
        now.id_nest_cnt = nest;
        _interrupt.takeSystemInterrupts(base, @returnAddress());
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
/// the task is neither in Disable nor holding a spinlock, the exception
/// code runs first. Tasks blocked in Wait are in Disable; Wait runs it
/// itself.
///
/// INPUTS:
/// - `base` - exec: the Disable nesting and the spinlocks held.
/// - `task` - the task about to run.
/// - `context` - where it resumes.
///
/// RESULT:
/// The context to resume: `context`, or one that runs the exception first.
pub fn raiseException(base: *ExecBase, task: *Task, context: *anyopaque) *anyopaque {
    if (!exceptionPending(task) or base.cpu().id_nest_cnt >= 0 or base.cpu().hold_count != 0) return context;
    return task_hardware.push_exception(context, vec(exceptionEntry));
}

// --- tests (host: ./zig build test) -----------------------------------------

const testing = @import("std").testing;

test "alignUp rounds to the power of two" {
    try testing.expectEqual(@as(usize, 16), alignUp(1, 16));
    try testing.expectEqual(@as(usize, 16), alignUp(16, 16));
    try testing.expectEqual(@as(usize, 0), alignUp(0, 16));
}
