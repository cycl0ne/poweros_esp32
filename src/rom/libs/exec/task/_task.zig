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
//! **Every core has ready and waiting lists of its own.** Each core has
//! its running task, its slice and its flags, and its two lists
//! (`CpuState`), and its own dispatcher, which takes the first task of
//! its own ready list it may run. A task is on the lists of the core
//! that owns it - the core it last ran on (`Task.owner`) - and those
//! lists, the states and signals of the tasks on them, and that core's
//! running task are kept under **that core's lock** (`tasks_lock`,
//! `takeTasks` below). So a signal to a task waits only for the core
//! that owns it, and two cores signalling tasks of their own wait for
//! nothing at all.
//!
//! It is not the interrupt lock: a core deciding what to run next waits
//! for no handler on another core, and a signal sent waits for no
//! exception. **A core holds one core's lists at a time** - its own or
//! another's - which is what keeps two cores from waiting on each other;
//! a core that wants another's lets its own go first.
//!
//! **The cores spread the work by taking it.** A core whose own list has
//! nothing worth running takes the highest-priority task it may run from
//! another core's list (`stealReady`) and owns it from then on, so the
//! highest priority ready in the machine is the one that runs, whichever
//! core it was made ready on. What each core has ready is read from one
//! word of its own (`ready_pri`), never from a list the reader does not
//! hold. A task made ready outranking what runs on its core has that
//! core asked to look - this one's dispatcher through its flags, another
//! through its cross-core interrupt. A core writes only its own flags:
//! the others are poked, never written.
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
const _waitable = @import("../waitable/_waitable.zig");
const _memory = @import("../memory/_memory.zig");

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
/// A wide guard's words: a task started while memory debugging is on, with
/// a stack of `wide_guard_stack` or more, has one.
pub const wide_guard_words = 64;
pub const wide_guard_stack = 4096;
const guard_pattern: u32 = 0x5354_4B21; // "STK!"

/// The guard written at the bottom of `task`'s stack, and the task marked
/// as having one; a task without a stack of its own (`sp_lower` 0) has
/// none. TF_WIDEGUARD makes it a wide one.
pub fn guardStack(task: *Task) void {
    if (task.sp_lower == 0) return;
    writeGuard(task.sp_lower, guardWords(task));
    task.flags |= sdk.exec.TF_GUARDED;
}

/// How many words `task`'s guard is.
pub fn guardWords(task: *const Task) usize {
    return if (task.flags & sdk.exec.TF_WIDEGUARD != 0) wide_guard_words else guard_words;
}

/// The guard of `words` words written at the bottom of the stack starting
/// at `lower`.
pub fn writeGuard(lower: usize, words: usize) void {
    const at: [*]volatile u32 = @ptrFromInt(lower);
    for (0..words) |i| at[i] = guard_pattern;
}

/// Whether the stack starting at `lower` still has its guard of `words`
/// words.
pub fn guardIntact(lower: usize, words: usize) bool {
    if (lower == 0) return true;
    const at: [*]const volatile u32 = @ptrFromInt(lower);
    for (0..words) |i| {
        if (at[i] != guard_pattern) return false;
    }
    return true;
}

/// A task's stack checked as the dispatcher switches away from it: its
/// guard intact and, on the chip, its saved context inside its bounds. A
/// stack that ran over is a dead end - what it wrote over is no longer
/// what its owners think it is.
fn checkStack(task: *const Task, context: *anyopaque) void {
    if (task.flags & sdk.exec.TF_GUARDED == 0) return;
    var over = !guardIntact(task.sp_lower, guardWords(task));
    // The host tests hand the dispatcher contexts that are not addresses.
    if (@import("builtin").os.tag == .freestanding) {
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
    /// core may resume the task. As many as the chip's own code has cores
    /// for; none where nothing switches.
    leaving: ?[]usize = null,
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

/// `word`, a space and `number`, NUL-ended, into `buffer`: the name of a
/// task there is one of per core, built where it is wanted since there are
/// as many as the machine has cores. `newTask` copies it, so the buffer
/// may be the caller's own. It wants room for the word, eleven digits and
/// the NUL.
pub fn numberedName(buffer: []u8, word: []const u8, number: u32) [*:0]const u8 {
    @memcpy(buffer[0..word.len], word);
    var at = word.len;
    buffer[at] = ' ';
    at += 1;
    var digits: [10]u8 = undefined;
    var count: usize = 0;
    var rest = number;
    while (true) {
        digits[count] = '0' + @as(u8, @intCast(rest % 10));
        count += 1;
        rest /= 10;
        if (rest == 0) break;
    }
    while (count > 0) {
        count -= 1;
        buffer[at] = digits[count];
        at += 1;
    }
    buffer[at] = 0;
    return @ptrCast(buffer.ptr);
}

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
    // Every core's state, not only this one's: a task pinned to a core
    // goes on that core's lists as soon as it is added, which is before
    // the core is started (`prepareCore`), and the memory the states
    // were cut from holds whatever was there.
    for (base.cpus_at[0..base.cores_state]) |*state| {
        state.* = .{};
        state.tasks.ready.init(.task);
        state.tasks.wait.init(.task);
    }
    base.quantum = default_quantum;
    base.cpu().elapsed = default_quantum;
    const boot = newTask(base, "kernel", 0, 0) orelse return error.OutOfMemory;
    boot.state = .run;
    boot.core = 0;
    boot.owner = 0;
    base.cpu().this_task = boot;
    base.cpu().running_pri = boot.node.pri;
    base.cpu().time_mark = cycles();
    base.boot_task = boot;
    const idle = base.iface().CreateTask("idle", -128, &idleLoop, idle_stack_size) orelse
        return error.OutOfMemory;
    makeSystemTask(idle);
    // Pinned once it is on the ready list: no other core runs yet.
    idle.core = 0;
    idle.owner = 0;
    base.cpu().idle_task = idle;
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
    // Only a core exec has state for: the kernel said how many when it
    // built exec, from what the machine answered.
    if (core >= base.cores_state) return false;
    var name: [32]u8 = undefined;
    const task = newTask(base, numberedName(&name, "idle", core), -128, 0) orelse return false;
    task.sp_lower = stack_lower;
    task.sp_upper = stack_upper;
    task.core = core;
    task.owner = core;
    task.sig_alloc |= sdk.exec.tasks.system_signals;
    task.state = .run;
    guardStack(task);
    // The state was made ready for every core at exec's own start
    // (`initTasks`), and tasks pinned to this one are on its lists
    // already: only what the core itself needs is written here.
    base.cpus_at[core].this_task = task;
    base.cpus_at[core].running_pri = task.node.pri;
    base.cpus_at[core].elapsed = base.quantum;
    base.cpus_at[core].idle_task = task;
    return true;
}

/// The core this runs on, prepared by `prepareCore`, taking tasks from
/// here on. It calls this itself, with its interrupts masked, and then
/// `idleHere`.
///
/// INPUTS:
/// - `base` - exec: how many cores take tasks, which the dispatchers read
///   under the task lists' lock.
pub fn coreStarted(base: *ExecBase) void {
    base.cpu().time_mark = cycles();
    takeTaskLists(base, @returnAddress());
    base.cores_running = exec_base.coreId() + 1;
    dropTaskLists(base);
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
    for ([_]?*Task{ base.cpus_at[0].idle_task, base.boot_task }) |maybe| {
        const task = maybe orelse continue;
        if (task.state == .ready or task.state == .wait) {
            base.iface().Remove(&task.node);
            noteReady(&base.cpus_at[task.owner]);
        }
        freeTaskMemory(base, task);
    }
    base.cpus_at[0].idle_task = null;
    base.boot_task = null;
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

/// Counts `missed` cycles more to the core's idle task: for a CPU whose
/// cycle counter stops while it sleeps (the U74's in `wfi`), its idle hook
/// times the sleep on another clock and says what the counter missed. From
/// the idle task, its interrupts masked, before it takes the interrupt that
/// woke it: the next exception entry counts them with the rest.
///
/// INPUTS:
/// - `base` - exec: this core's times.
/// - `missed` - the cycles the sleep took that the counter did not count.
pub fn idleSlept(base: *ExecBase, missed: u32) void {
    const cpu = base.cpu();
    if (cpu.this_task == cpu.idle_task) cpu.time_mark -%= missed;
}

// --- a task's memory and code -----------------------------------------------

/// One allocation holding the Task, a copy of its name and - unless
/// `stack_size` is 0 - its stack, so that `RemTask` frees all of it in one
/// call. The stack is at the bottom and the Task above it: a stack that
/// runs past its end writes below the block, not over the Task the system
/// keeps the task by.
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
    const above = bytes + stack;
    const name_copy = above + @sizeOf(Task);
    @memcpy(name_copy[0..name_len], name[0..name_len]);
    name_copy[name_len] = 0;
    const task: *Task = @ptrCast(@alignCast(above));
    task.* = .{
        .node = .{ .type = .task, .pri = pri, .name = @ptrCast(name_copy) },
        // No stack at all (the boot task's): both bounds at the block's end.
        .sp_lower = if (stack == 0) @intFromPtr(bytes + total) else @intFromPtr(bytes),
        .sp_upper = if (stack == 0) @intFromPtr(bytes + total) else @intFromPtr(above),
        .mem_block = block,
        .mem_size = total,
    };
    return task;
}

/// The next task number (`Task.id`): never 0, which is the system's. Under
/// Disable, which is what keeps two cores from handing out the same one.
///
/// INPUTS:
/// - `base` - exec: the last number given.
pub fn nextTaskId(base: *ExecBase) u32 {
    base.task_ids +%= 1;
    if (base.task_ids == sdk.exec.MEMOWNER_SYSTEM) base.task_ids +%= 1;
    return base.task_ids;
}

/// One of exec's own tasks - the boot task's fellows, the idle tasks, the
/// exec task - made the system's: its number is MEMOWNER_SYSTEM, so what it
/// allocates is the system's, and so is its own block. Before it runs.
///
/// INPUTS:
/// - `task` - the task, added and not yet run.
pub fn makeSystemTask(task: *Task) void {
    task.id = sdk.exec.MEMOWNER_SYSTEM;
    if (task.mem_block) |block| _memory.setOwner(block, sdk.exec.MEMOWNER_SYSTEM);
}

/// A task's end hooks made an empty list, the first time one is put on: a
/// TCB laid out by hand has the list zeroed, which is not an empty list.
/// Under Disable, which the hook lists are kept under: a few nodes, and
/// the task they belong to may be ending on the other core.
pub fn endHooks(task: *Task) void {
    if (task.end_hooks.head == null) task.end_hooks.init();
}

/// Every end hook of `task` run, in the order they were put on, each taken
/// off under the task lists' lock before it runs and nothing held while
/// it does.
pub fn runEndHooks(base: *ExecBase, task: *Task) void {
    const sys = base.iface();
    while (true) {
        lockTaskLists(base);
        if (task.end_hooks.head == null) {
            unlockTaskLists(base);
            return;
        }
        const node = sys.RemHead(@ptrCast(&task.end_hooks)) orelse {
            unlockTaskLists(base);
            return;
        };
        const hook: *sdk.exec.TaskEndHook = @ptrCast(node);
        hook.task = null;
        unlockTaskLists(base);
        hook.code(sys, task, hook);
    }
}

// --- what a task's end gives back ---------------------------------------------
//
// A task that ends - its code returned, RemTask, or Kill - gives back what
// it still holds of exec's: the semaphores, before its end hooks run, so
// that neither they nor anyone queued behind it waits for a holder that is
// gone; and its private memory after them, since a hook may still use it.
// Each is a line on the log when there was anything: a task that ends
// holding a lock or a private block has a bug, and the line names it.

/// The semaphores `task` still holds let go, and a line on the log naming
/// how many and the first of them.
///
/// INPUTS:
/// - `base` - exec.
/// - `task` - the ending task, which does not run on holding them.
pub fn releaseSemaphores(base: *ExecBase, task: *Task) void {
    var released: _locks.Released = .{};
    _locks.releaseHolds(base, task, &released);
    if (released.count != 0) {
        const first = released.first[0].?;
        const named = first.link.name;
        exec.kprintf("exec: task \"%.32s\" #%u ended holding %u semaphore%s - released: %08x%s%.24s%s%s\n", .{
            task.name().ptr,
            task.id,
            released.count,
            plural(released.count),
            @as(u32, @truncate(@intFromPtr(first))),
            if (named != null) " \"" else "",
            named orelse "",
            if (named != null) "\"" else "",
            if (released.count > 1) " ..." else "",
        });
    }
    if (released.lost != 0) {
        exec.kprintf("exec: task \"%.32s\" #%u ended holding %u more holds its table had no room for - still held\n", .{
            task.name().ptr,
            task.id,
            @as(u32, released.lost),
        });
    }
}

/// How many private blocks one look of `freePrivateMemory` takes.
pub const private_batch = 32;

/// The private memory `task` left freed, and a line on the log saying how
/// much: every block with its number and MEMF_PRIVATE
/// (`_memory.privateBlocks`), through FreeMem, a batch at a time until a
/// look finds no more - or finds the same block first again, which only a
/// FreeMem that refused it leaves. Only for a task that ever allocated
/// any (`Task.private_memory`), and never for the system's number, whose
/// blocks are no task's.
///
/// INPUTS:
/// - `base` - exec: the jump table FreeMem goes through.
/// - `task` - the ending task: its end hooks have run.
/// - `running` - it is the caller, still on its stack: a private block
///   that holds the stack it runs on is left.
pub fn freePrivateMemory(base: *ExecBase, task: *Task, running: bool) void {
    if (!task.private_memory or task.id == sdk.exec.MEMOWNER_SYSTEM) return;
    const sys = base.iface();
    const keep_lower = if (running) task.sp_lower else 0;
    const keep_upper = if (running) task.sp_upper else 0;
    var found: [private_batch]usize = undefined;
    var first_before: usize = 0;
    var blocks: u32 = 0;
    var bytes: usize = 0;
    while (true) {
        const count = _memory.privateBlocks(base, task.id, keep_lower, keep_upper, &found);
        if (count == 0 or found[0] == first_before) break;
        first_before = found[0];
        for (found[0..count]) |block| {
            const size = sdk.exec.MemBlock.of(@ptrFromInt(block)).bytes();
            bytes += size;
            sys.FreeMem(@ptrFromInt(block), size);
        }
        blocks += @intCast(count);
        if (count < found.len) break;
    }
    if (blocks == 0) return;
    exec.kprintf("exec: task \"%.32s\" #%u ended with %u private block%s, %ld bytes - freed\n", .{
        task.name().ptr,
        task.id,
        blocks,
        plural(blocks),
        @as(u64, bytes),
    });
}

/// "s" for a count that is not 1.
fn plural(count: u32) [*:0]const u8 {
    return if (count == 1) "" else "s";
}

// --- Kill ----------------------------------------------------------------------

/// Kill: `task` made to end - the Software Failure requester's choice, and
/// `s3> kill`'s. It is taken from wherever it is - held by the requester,
/// waiting, ready, or running on the other core, which stops it first -
/// and started again in `killEntry`, on its own stack from the top: what
/// it was doing is dropped, frames and all. On the task itself, its end
/// then goes as if its code had returned (`killEntry`), and its Task stays
/// (`Task.killed`). A task killed already whose end has not finished - it
/// failed again on the way - is removed as it is, with no code of its own
/// run.
///
/// INPUTS:
/// - `base` - exec: the task lists, the jump table the calls go through.
/// - `task` - not the caller, and not exec's own: a task with the
///   system's number is refused.
///
/// RESULT:
/// False when the task cannot be killed: the caller itself, one of exec's
/// own, or one that has ended.
pub fn killTask(base: *ExecBase, task: *Task) bool {
    const sys = base.iface();
    if (task == sys.FindTask(null).? or task.id == sdk.exec.MEMOWNER_SYSTEM) return false;
    if (task.state == .removed or task.state == .invalid) return false;
    if (task.killed) {
        sys.RemTask(task);
        return true;
    }
    stopElsewhere(base, task);
    _locks.withdraw(base, task);
    _waitable.withdraw(base, task);
    // The lists of the core that owns it: it is taken off them and put
    // back on that core's ready list, started again from the top.
    const owner = lockOwner(base, task);
    defer unlockTaskLists(base);
    if (task.state == .ready or task.state == .wait) {
        sys.Remove(&task.node);
        noteReady(&base.cpus_at[owner]);
    }
    // Its own stack, if NewStackRun had it on another.
    if (task.home_upper != 0) {
        task.sp_lower = task.home_lower;
        task.sp_upper = task.home_upper;
        task.home_lower = 0;
        task.home_upper = 0;
    }
    task.flags &= ~(sdk.exec.TF_GUARDED | sdk.exec.TF_WIDEGUARD);
    if (base.mem_debug.on and task.sp_upper - task.sp_lower >= wide_guard_stack) task.flags |= sdk.exec.TF_WIDEGUARD;
    guardStack(task);
    task.killed = true;
    // A fresh start: waiting for nothing, no exception code run in its
    // end, outside Disable.
    task.sig_wait = 0;
    task.sig_except = 0;
    task.id_nest_cnt = -1;
    task.id_saved = 0;
    task.sp_reg = task_hardware.init_context(task.sp_upper, vec(killEntry), task);
    task.state = .ready;
    sys.Enqueue(&base.cpus_at[owner].tasks.ready, &task.node);
    noteReady(&base.cpus_at[owner]);
    wakeFor(base, task);
    return true;
}

/// Where a killed task starts again, on its own stack: the semaphores it
/// held let go first - its final code may need what others wait for - then
/// its final code (a process's is dos's, which closes its streams and
/// lets go of its directories), and RemTask, which runs its end hooks and
/// frees its private memory.
///
/// INPUTS:
/// - `task` - the killed task. The CPU hands over nothing else, so exec
///   is the kernel's `SysBase`.
fn killEntry(task: *Task) callconv(.c) noreturn {
    const base = exec.SysBase;
    releaseSemaphores(base, task);
    if (task.final_pc) |final_pc| final_pc(base.iface());
    base.iface().RemTask(null);
    unreachable;
}

/// The task with number `id`, running, ready or waiting; null when there is
/// none. Under Disable, which keeps the lists still: the task may end as
/// soon as it is let go.
///
/// INPUTS:
/// - `base` - exec: the running tasks and the lists.
/// - `id` - a task's number (`Task.id`).
pub fn findById(base: *ExecBase, id: u32) ?*Task {
    for (base.cpus_at[0..base.cores_running]) |*cpu| {
        if (cpu.this_task.id == id) return cpu.this_task;
    }
    for (0..base.cores_running) |number| {
        const core: u32 = @intCast(number);
        takeTasks(base, core, @returnAddress());
        defer dropTaskLists(base);
        for ([_]*sdk.exec.List{ &base.cpus_at[core].tasks.ready, &base.cpus_at[core].tasks.wait }) |list| {
            var it = list.iterator();
            while (it.next()) |node| {
                const task: *Task = @fieldParentPtr("node", node);
                if (task.id == id) return task;
            }
        }
    }
    return null;
}

/// Gives back what `newTask` allocated, and clears the pointer so that a
/// second call does nothing. A task the caller laid out has no such block
/// and is left alone. A killed task's block keeps the Task and what is
/// above it (`keptFrom`): only its stack is given back.
///
/// INPUTS:
/// - `base` - exec: the jump table `FreeMem` goes through.
/// - `task` - the task, off every list and not running.
pub fn freeTaskMemory(base: *ExecBase, task: *Task) void {
    const block = task.mem_block orelse return;
    task.mem_block = null;
    const sys = base.iface();
    if (keptFrom(task, block)) |keep| {
        sys.AcquireLock(&base.lock_memory);
        defer sys.ReleaseLock(&base.lock_memory);
        const header = sdk.exec.MemBlock.of(block);
        const region = _memory.regionOf(base, @intFromPtr(header)) orelse return;
        const cut = _memory.splitFront(header, keep);
        sys.Deallocate(region, header, cut);
        if (base.mem_debug.on) _memory.debugFreed(region, @intFromPtr(header), cut);
        return;
    }
    sys.FreeMem(block, task.mem_size);
}

/// Where a killed task's block is kept from: its Task, when the Task is in
/// the block above the stack, as `newTask` and dos's `CreateNewProc` lay
/// it out - a port in it, its name, a Process's fields may still be named
/// by someone, and a message or a signal sent to them must find them. Null
/// for a task that ended by itself, and for a block laid out otherwise,
/// which goes whole.
///
/// INPUTS:
/// - `task` - the task.
/// - `block` - its `mem_block`.
fn keptFrom(task: *const Task, block: *anyopaque) ?usize {
    if (!task.killed) return null;
    const start = @intFromPtr(block);
    const at = @intFromPtr(task);
    const bytes = sdk.exec.MemBlock.of(block).bytes();
    if (at < start + sdk.exec.MEM_BLOCKSIZE or at >= start + bytes) return null;
    if ((at - start) % sdk.exec.MEM_BLOCKSIZE != 0) return null;
    return at;
}

/// `freeTaskMemory` for an exception exit, which frees a removed task's
/// memory once nothing will run on its stack again. That is interrupt
/// context, where the memory lock - a plain one, so that allocating never
/// masks interrupts - is not taken through AcquireLock. It is tried here
/// directly, once: its holder - a task on this core the exception
/// interrupted, or one on another core, which may itself be waiting for
/// one of this core's locks - cannot be waited for. A lock held is
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
/// interrupt lock as well (a LOCKF_INTERRUPT lock is taken inside
/// Disable) - which the exit takes around this - so the list is changed
/// here without the port lock, and directly, as everything in the
/// dispatcher is. A port that signals has its task woken; one that causes
/// a software interrupt is not served from here.
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
    // The block with its MemBlock and its wall, as FreeMem gives one back
    // - the wall unchecked: there is no one to tell from here.
    const header = sdk.exec.MemBlock.of(block);
    const region = _memory.regionOf(base, @intFromPtr(header)) orelse return true;
    // A killed task's: its stack only (`keptFrom`).
    if (keptFrom(task, block)) |keep| {
        const cut = _memory.splitFront(header, keep);
        Deallocate(base, region, header, cut);
        if (base.mem_debug.on) _memory.debugFreed(region, @intFromPtr(header), cut);
        return true;
    }
    const whole = header.extent() + sdk.exec.MEM_BLOCKSIZE;
    header.size = 0;
    Deallocate(base, region, header, whole);
    if (base.mem_debug.on) _memory.debugFreed(region, @intFromPtr(header), whole);
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

/// A task left behind for the core's next exception exit - an ended one
/// to free, a stopped one whose taker is told - and that exit brought at
/// once: the core's own cross-core interrupt, taken as soon as the switch
/// is done. Without it a core with nothing else to run sleeps in its idle
/// task until the next tick, and the end of a task is heard up to a tick
/// late (2.8-4.1 ms measured on the VF2, at 100 Hz).
fn leftBehind(core: u32) void {
    pokeCore(core);
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
    // The task is whichever core's owns it, and this one holds its own
    // lists here (the exit's reap). A core holds one core's at a time, so
    // its own go and are taken again around the owner's.
    const cpu = base.cpu();
    const held = cpu.tasks_depth == 1;
    const here = cpu.tasks_which;
    if (held) dropTaskLists(base);
    const owner = takeOwner(base, task, 2);
    task.sig_recvd |= signals;
    if (task.state == .wait and task.sig_recvd & task.sig_wait != 0) {
        Remove(base, &task.node);
        task.state = .ready;
        Enqueue(base, &base.cpus_at[owner].tasks.ready, &task.node);
        noteReady(&base.cpus_at[owner]);
        wakeFor(base, task);
    }
    dropTaskLists(base);
    if (held) takeTasks(base, here, 2);
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
    // The task stays this core's while it waits: the core it last ran on
    // is the one whose lock covers it, and whose list its signal puts it
    // back on.
    base.iface().AddTail(&base.cpu().tasks.wait, &task.node);
    base.cpu().sys_flags |= SFF_SAR;
}

// --- a core's task lists and their lock -------------------------------------

/// Whether this core holds a core's task lists - its own or another's.
/// Its own count says so, and not a lock word every core writes: asking
/// is a load of a line no other core touches.
///
/// INPUTS:
/// - `base` - exec: this core's state.
pub inline fn taskListsHeld(base: *ExecBase) bool {
    return base.cpu().tasks_depth != 0;
}

/// Core `which`'s task lists taken by this core: spun for while another
/// core has them, answering a hold as it goes round. **This core's
/// interrupts are masked already** - a core that held them with its
/// interrupts on would have its own handler wait for itself. The longest
/// wait and the code that waited are kept in the core's state.
///
/// Taking the same core's again counts a nesting, as an exception taken
/// while the core's task holds them does, which is also what tells the
/// dispatcher to leave that task where it is (`reschedule`).
///
/// **A core holds one core's lists at a time.** Nothing asks for a second
/// core's while it holds one - that is what keeps two cores from waiting
/// on each other - so a core that wants another's lets its own go first
/// (`stealReady`), and a caller that must reach a task of another core's
/// goes through `takeOwner`.
///
/// INPUTS:
/// - `base` - exec: the cores' states.
/// - `which` - whose lists.
/// - `where` - the code taking them, or 1 for the dispatcher, 2 for what
///   a switch left behind, 3 for the time slice, 4 for a core taking work
///   from this one.
pub fn takeTasks(base: *ExecBase, which: u32, where: usize) void {
    const cpu = base.cpu();
    if (cpu.tasks_depth != 0) {
        cpu.tasks_depth += 1;
        return;
    }
    const me = exec_base.coreId() + 1;
    const lock = &base.cpus_at[which].tasks_lock;
    const before = cycles();
    while (@cmpxchgWeak(u32, lock, 0, me, .acquire, .monotonic) != null) {
        _interrupt.interrupt_hardware.park_if_asked();
    }
    const now = cycles();
    const waited = now -% before;
    if (waited > cpu.lists_wait_max) {
        cpu.lists_wait_max = waited;
        cpu.lists_wait_where = where;
    }
    cpu.lists_taken_at = now;
    cpu.lists_taker = where;
    cpu.tasks_depth = 1;
    cpu.tasks_which = which;
}

/// This core's own task lists taken, which is what the dispatcher, the
/// time slice and a task blocking itself want.
///
/// INPUTS:
/// - `base` - exec: the cores' states.
/// - `where` - the code taking them.
pub fn takeTaskLists(base: *ExecBase, where: usize) void {
    takeTasks(base, exec_base.coreId(), where);
}

/// The lists of the core that owns `task` taken, and `task` still that
/// core's once they are: another core may take it over between the read
/// and the lock, and then the lock is let go again and the new owner's
/// taken. **This core's interrupts are masked already**, and it holds no
/// other core's lists.
///
/// INPUTS:
/// - `base` - exec: the cores' states.
/// - `task` - the task to reach.
/// - `where` - the code taking them.
///
/// RESULT:
/// The core whose lists are now held.
pub fn takeOwner(base: *ExecBase, task: *Task, where: usize) u32 {
    while (true) {
        const owner = @atomicLoad(u32, &task.owner, .acquire);
        takeTasks(base, owner, where);
        if (@atomicLoad(u32, &task.owner, .acquire) == owner) return owner;
        dropTaskLists(base);
    }
}

/// The task lists this core holds let go, everything written under them
/// seen first; the longest hold and the code that took them kept in the
/// core's state. A nested take is counted back instead, and a core that
/// holds none lets nothing go.
///
/// INPUTS:
/// - `base` - exec: the cores' states.
pub fn dropTaskLists(base: *ExecBase) void {
    const cpu = base.cpu();
    if (cpu.tasks_depth == 0) return;
    if (cpu.tasks_depth > 1) {
        cpu.tasks_depth -= 1;
        return;
    }
    const held = cycles() -% cpu.lists_taken_at;
    if (held > cpu.lists_held_max) {
        cpu.lists_held_max = held;
        cpu.lists_held_where = cpu.lists_taker;
    }
    cpu.tasks_depth = 0;
    @atomicStore(u32, &base.cpus_at[cpu.tasks_which].tasks_lock, 0, .release);
}

/// The highest priority ready on `cpu`, kept as its list is changed so
/// that another core can see what is waiting here without reading a list
/// it does not hold - a node it read could be a task already freed. Below
/// every priority when nothing is ready.
pub const nothing_ready: i32 = -129;

/// `cpu`'s summary of what is ready on it written again: its own core
/// does this under its lists, each time they change.
pub fn noteReady(cpu: *exec_base.CpuState) void {
    const head = cpu.tasks.ready.first();
    const pri: i32 = if (head) |node| node.pri else nothing_ready;
    @atomicStore(i32, &cpu.ready_pri, pri, .release);
}

/// This core's own task lists held from task level: its interrupts masked
/// - so the caller keeps its core and nothing it half-changed is seen by
/// an interrupt here - and the lists taken. What `Disable` is for the
/// interrupt side, this is for the lists.
///
/// INPUTS:
/// - `base` - exec: the cores' states.
pub fn lockTaskLists(base: *ExecBase) void {
    const state = _interrupt.mask();
    // Masked, the caller stays on this core.
    if (taskListsHeld(base)) {
        base.cpu().tasks_depth += 1;
        return;
    }
    base.cpu().lists_saved = state;
    takeTaskLists(base, @returnAddress());
}

/// Core `which`'s task lists held from task level, the same way as this
/// core's own: for a caller that knows whose they are.
///
/// INPUTS:
/// - `base` - exec: the cores' states.
/// - `which` - whose lists.
pub fn lockTasksOf(base: *ExecBase, which: u32) void {
    const state = _interrupt.mask();
    if (taskListsHeld(base)) {
        base.cpu().tasks_depth += 1;
        return;
    }
    base.cpu().lists_saved = state;
    takeTasks(base, which, @returnAddress());
}

/// The lists of the core that owns `task` held from task level, the same
/// way: the answer is that core, which `unlockTaskLists` lets go again.
///
/// INPUTS:
/// - `base` - exec: the cores' states.
/// - `task` - the task to reach.
pub fn lockOwner(base: *ExecBase, task: *Task) u32 {
    const state = _interrupt.mask();
    if (taskListsHeld(base)) {
        base.cpu().tasks_depth += 1;
        return base.cpu().tasks_which;
    }
    base.cpu().lists_saved = state;
    return takeOwner(base, task, @returnAddress());
}

/// The lists let go again, the interrupts put back as they were, and a
/// switch that fell due while they were held taken - so this is a point
/// at which the caller may lose the processor, as `Enable` is.
///
/// INPUTS:
/// - `base` - exec: the cores' states.
pub fn unlockTaskLists(base: *ExecBase) void {
    const cpu = base.cpu();
    if (cpu.tasks_depth > 1) {
        cpu.tasks_depth -= 1;
        return;
    }
    const state = cpu.lists_saved;
    dropTaskLists(base);
    // A Signal of its own, or an AddTask, may have asked for a switch.
    const due = switchDue(base);
    _interrupt.unmask(state);
    if (due) task_hardware.switch_now();
}

// --- the scheduler ----------------------------------------------------------

/// Counts an exception entry. The kernel calls it at the start of every
/// exception - interrupt, syscall or trap - and `interruptExit` at the end.
/// The depth is what makes the scheduler run only at the **outermost**
/// exit: an interrupt that arrives inside another must not switch tasks.
///
/// **It takes no lock.** What a core does going into and out of an
/// exception - the depth, the times, the registers the kernel saved - is
/// its own, and what the exception goes on to do takes the lock it needs:
/// the interrupt one for a handler's chain (`dispatchInterrupt`), the
/// task lists' for the dispatcher.
///
/// INPUTS:
/// - `base` - exec: this core's exception depth and times.
pub fn interruptEnter(base: *ExecBase) void {
    const cpu = base.cpu();
    // The time since the last exit was the task's it resumed - or idle -
    // and that task's own.
    if (cpu.int_depth == 0) {
        const now = cycles();
        const spent = now -% cpu.time_mark;
        if (cpu.this_task == cpu.idle_task) cpu.time_idle +%= spent else cpu.time_tasks +%= spent;
        const task = cpu.this_task;
        const low = task.time_run_low +% spent;
        if (low < task.time_run_low) task.time_run_high +%= 1;
        task.time_run_low = low;
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
/// left behind (`reap`).
///
/// **What it takes.** The dispatcher runs under the task lists' lock, and
/// nothing else - a core deciding what to run next waits for no handler
/// on another core. What a switch left behind is given back under the
/// interrupt lock as well, since a task's end message goes on a port's
/// list, which only Disable's holders touch.
///
/// A task switched out inside Disable loses the interrupt lock here: it
/// is let go once the core no longer runs it, and the task's Enable finds
/// nothing to let go. That is what `Disable` says of a wait - what it
/// guards is not guarded across one.
///
/// INPUTS:
/// - `base` - exec: this core's exception depth, scheduling flags and
///   both locks.
/// - `context` - what the kernel saved on entry.
pub fn interruptExit(base: *ExecBase, context: *anyopaque) *anyopaque {
    const cpu = base.cpu();
    var resumed = context;
    if (cpu.int_depth == 1) {
        // Not while the interrupted code holds the task lists itself:
        // this takes the interrupt lock, which comes before them - so it
        // waits for the next exit, which is what a reap does anyway.
        if ((cpu.reap != null or cpu.stopped != null) and !taskListsHeld(base)) {
            _interrupt.takeSystemInterrupts(base, 3);
            takeTaskLists(base, 2);
            reap(base);
            dropTaskLists(base);
            _interrupt.dropSystemInterrupts(base);
        }
        // A slice spent with nothing to take over: no switch, but the
        // task's stack checked as a switch would check it - a task alone
        // on its core would otherwise run off its stack unseen.
        if (cpu.sys_flags & (SFF_SAR | SFF_TQE) == SFF_TQE) checkStack(cpu.this_task, context);
        if (cpu.sys_flags & SFF_SAR != 0) {
            takeTaskLists(base, 1);
            resumed = reschedule(base, context);
            dropTaskLists(base);
        }
    }
    cpu.int_depth -= 1;
    if (cpu.int_depth == 0) {
        const now = cycles();
        cpu.time_interrupts +%= now -% cpu.time_mark;
        cpu.time_mark = now;
        // Held for a task this core no longer runs: let go here.
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
    const cpu = &base.cpus_at[core];
    if (cpu.elapsed > 0) cpu.elapsed -= 1;
    if (cpu.elapsed != 0) return;
    cpu.sys_flags |= SFF_TQE;
    // The ready list read under its own lock; the core's own slice and
    // flags need none.
    takeTaskLists(base, 3);
    defer dropTaskLists(base);
    const here: i32 = cpu.this_task.node.pri;
    if (bestReady(base, core)) |best| {
        if (best.node.pri >= here) {
            cpu.sys_flags |= SFF_SAR;
            return;
        }
    }
    // Nothing of its own worth a switch: what the other cores have is
    // looked at too, which is how a core with an empty list comes for
    // work instead of waiting to be poked.
    if (othersHaveMore(base, core, here)) cpu.sys_flags |= SFF_SAR;
}

/// Whether a switch is due on the core and allowed now: at task level,
/// with no Disable, no spinlock and not the task lists outstanding.
/// `Enable`, `ReleaseLock` and `unlockTaskLists` ask it with their
/// interrupts masked and take the switch once they are back, which is
/// what makes each of them a point where the caller may lose the
/// processor.
///
/// INPUTS:
/// - `base` - exec: this core's state, and the task lists' lock.
pub fn switchDue(base: *ExecBase) bool {
    const cpu = base.cpu();
    return cpu.sys_flags & SFF_SAR != 0 and cpu.int_depth == 0 and
        cpu.id_nest_cnt < 0 and cpu.hold_count == 0 and !taskListsHeld(base);
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
    const due = switchDue(base);
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
    const cpu = &base.cpus_at[core];
    const current = cpu.this_task;
    const started = @atomicLoad(u32, &base.multitasking, .acquire) != 0;
    // A depth above the dispatcher's own take means the interrupted code
    // holds task lists itself: switching away from it would leave the
    // lock with no owner, as a spinlock would (`hold_count`).
    const held = !started or cpu.id_nest_cnt >= 0 or cpu.hold_count != 0 or cpu.tasks_depth > 1;
    const stopping = cpu.stopping == current;
    if (current.state == .run and held) return context;
    if (current.state == .run and !stopping) {
        const time_up = cpu.sys_flags & SFF_TQE != 0;
        var stays = runnableOn(base, current, core);
        if (stays) {
            if (bestReady(base, core)) |best| {
                stays = best.node.pri < current.node.pri or (best.node.pri == current.node.pri and !time_up);
            }
            // What the other cores have counts as well: a core whose own
            // list holds nothing better than what it runs still looks at
            // theirs, which is how it comes for work instead of waiting
            // to be given some. The dispatcher below decides what it may
            // actually take, and takes this task back when that is
            // nothing.
            if (stays and othersHaveMore(base, core, current.node.pri)) stays = false;
        }
        if (stays) {
            cpu.sys_flags &= ~SFF_SAR;
            return raiseException(base, current, context);
        }
        current.state = .ready;
        // Marked as leaving before it goes on a list any other core can
        // reach: a core looking for work leaves it alone until this one
        // is off its stack (`leavingNow`). The kernel clears the word at
        // this exception's exit, whether the task was switched away or
        // not.
        markLeaving(core, current);
        // Direct, not through the table: the dispatcher runs at the
        // outermost exception exit on a half-switched machine, so it
        // cannot call a vector something may have replaced (codex rule 1).
        Enqueue(base, &cpu.tasks.ready, &current.node);
        noteReady(cpu);
        offerOthers(base, current, core);
    }
    cpu.sys_flags &= ~(SFF_SAR | SFF_TQE);

    if (stopping) {
        // Taken away by another core: off the wait list if it went there,
        // and nothing saved - it never runs again as it was. On no list
        // from here, which is what `.added` says to the taker.
        if (current.state == .wait) Remove(base, &current.node);
        current.state = .added;
        cpu.stopping = null;
        cpu.stopped = current;
        leftBehind(core);
    } else if (current.state == .removed) {
        // Nothing will run on its stack again once this core is off it:
        // at once with one core, at the next exit with two, as the other
        // core could have the memory before this one has left it.
        // A task whose end someone waits to hear of is reaped at the next
        // exit as well, where the signal goes out as an interrupt's would.
        if (base.cores_running > 1 or current.end_msg != null or !freeRemovedTask(base, current)) {
            reapLater(cpu, current);
            leftBehind(core);
        }
    } else {
        checkStack(current, context);
        current.sp_reg = context;
        current.id_nest_cnt = cpu.id_nest_cnt;
        current.id_saved = cpu.id_saved;
        if (current.flags & sdk.exec.TF_SWITCH != 0) {
            if (current.switch_code) |switch_code| switch_code(current, base.iface());
        }
        // Marked before this core's lists are let go below: a task that
        // waited may be signalled and made ready while this core is
        // still on its stack, and a core that takes it then waits for
        // this one to be off it.
        markLeaving(core, current);
    }
    // The task that held the lists at task level does not keep them
    // across the switch: the lock is the core's, and the core is about to
    // run another task. The depth goes back to the dispatcher's own hold
    // before it looks - a core that takes work from another lets its own
    // lists go while it does - and the exit lets the lock go. What the
    // task comes back to is a hold it no longer has, which is what a wait
    // inside Disable comes back to as well.
    cpu.tasks_depth = 1;
    const next = takeReady(base, core);
    next.state = .run;
    @atomicStore(u32, &next.owner, core, .release);
    cpu.this_task = next;
    @atomicStore(i32, &cpu.running_pri, next.node.pri, .release);
    cpu.elapsed = base.quantum;
    cpu.disp_count +%= 1;
    cpu.id_nest_cnt = next.id_nest_cnt;
    cpu.id_saved = next.id_saved;
    if (next.flags & sdk.exec.TF_LAUNCH != 0) {
        if (next.launch_code) |launch_code| launch_code(next, base.iface());
    }
    return raiseException(base, next, next.sp_reg.?);
}

/// `task` marked as the one `core` is switching away from.
fn markLeaving(core: u32, task: *Task) void {
    const words = task_hardware.leaving orelse return;
    @atomicStore(usize, &words[core], @intFromPtr(task), .release);
}

/// Whether another core is still switching away from `task` - its
/// context not yet saved for good, however its state reads. A core that
/// takes work from another leaves such a task alone instead of waiting
/// for it: the core switching away may itself be waiting for this core's
/// lists, and two cores waiting on each other is a machine that stops.
fn leavingNow(task: *const Task, core: u32) bool {
    const words = task_hardware.leaving orelse return false;
    for (words, 0..) |*word, other| {
        if (other == core) continue;
        if (@atomicLoad(usize, word, .acquire) == @intFromPtr(task)) return true;
    }
    return false;
}

// --- the cores --------------------------------------------------------------

/// Whether `task` may run on `core`: the core it keeps to, or any - and
/// then on a core but 0 only once the cores share.
///
/// INPUTS:
/// - `base` - exec: whether the cores share.
/// - `task` - the task.
/// - `core` - the core.
pub fn runnableOn(base: *const ExecBase, task: *const Task, core: u32) bool {
    if (task.core != sdk.exec.ANY_CORE) return task.core == core;
    return core == 0 or base.share_cores != 0;
}

/// The highest-priority ready task `core`'s dispatcher would take,
/// without taking it: one that may run there. Null when there is none.
///
/// INPUTS:
/// - `base` - exec: its ready list.
/// - `core` - the core asking.
pub fn bestReady(base: *ExecBase, core: u32) ?*Task {
    var it = base.cpus_at[core].tasks.ready.iterator();
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
    const own = bestReady(base, core);
    // What another core has may outrank it: a core takes the best task it
    // can see, so that the highest priority ready in the machine is the
    // one that runs, whichever core it was made ready on.
    const above: i32 = if (own) |task| task.node.pri else nothing_ready;
    if (stealReady(base, core, above)) |stolen| return stolen;
    // The list read again rather than the task found above taken: this
    // core's lists were let go while another core's were held, and what
    // was first then may be that core's task now.
    var it = base.cpus_at[core].tasks.ready.iterator();
    while (it.next()) |node| {
        const task: *Task = @fieldParentPtr("node", node);
        if (!runnableOn(base, task, core)) continue;
        if (leavingNow(task, core)) continue;
        Remove(base, node);
        noteReady(&base.cpus_at[core]);
        return task;
    }
    // The core's idle task is pinned to it, and always ready or running.
    unreachable;
}

/// Whether another core has a task ready that outranks `here` - the
/// priority this core would otherwise run. One word of each core's is
/// read (`ready_pri`), never a list this core does not hold.
///
/// INPUTS:
/// - `base` - exec: the cores' states.
/// - `core` - this core.
/// - `here` - the priority to beat.
fn othersHaveMore(base: *ExecBase, core: u32, here: i32) bool {
    for (0..base.cores_running) |number| {
        const other: u32 = @intCast(number);
        if (other == core) continue;
        if (@atomicLoad(i32, &base.cpus_at[other].ready_pri, .monotonic) > here) return true;
    }
    return false;
}

/// A task taken from another core's ready list for `core` to run: of the
/// cores that have one above `above` this core may run, the one with the
/// highest, taken off its list and made this core's. Null when no other
/// core has work worth taking.
///
/// What each core has is read from its own summary word (`ready_pri`),
/// never from a list this core does not hold: a node read without its
/// lock could be a task already freed. The word may be a moment old,
/// which costs a round and never a wrong task - what is taken is taken
/// under the core's own lists and looked at again there.
///
/// **This core's lists are let go while another's are held** and taken
/// again before this returns, since a core holds one core's at a time.
/// The task it is switching away from is already marked as leaving
/// (`markLeaving`), so another core looking for work leaves that one
/// alone until this core is off its stack.
///
/// INPUTS:
/// - `base` - exec: the cores' states.
/// - `core` - this core.
/// - `above` - the priority to beat: what this core would run otherwise.
fn stealReady(base: *ExecBase, core: u32, above: i32) ?*Task {
    const running = base.cores_running;
    if (running < 2) return null;
    var found: ?u32 = null;
    var best = above;
    for (0..running) |number| {
        const other: u32 = @intCast(number);
        if (other == core) continue;
        const there = @atomicLoad(i32, &base.cpus_at[other].ready_pri, .monotonic);
        if (there > best) {
            best = there;
            found = other;
        }
    }
    const victim = found orelse return null;
    dropTaskLists(base);
    takeTasks(base, victim, 4);
    var taken: ?*Task = null;
    var it = base.cpus_at[victim].tasks.ready.iterator();
    while (it.next()) |node| {
        const task: *Task = @fieldParentPtr("node", node);
        if (task.node.pri <= above) break; // by priority: nothing below is better
        if (!runnableOn(base, task, core)) continue;
        if (leavingNow(task, core)) continue; // its own core has not let go of it
        Remove(base, node);
        @atomicStore(u32, &task.owner, core, .release);
        taken = task;
        break;
    }
    noteReady(&base.cpus_at[victim]);
    dropTaskLists(base);
    takeTaskLists(base, 5);
    return taken;
}

/// `task`, just made ready, brought to a core that should run it now:
/// of the other cores it may run on and outranks what runs there, the one
/// running the least poked, when that is less than what runs here or the
/// task may not run here; else this core's dispatcher asked to look when
/// it may run here and outranks what runs here. The caller holds the task
/// lists' lock, which keeps every core's running task where it is.
///
/// INPUTS:
/// - `base` - exec: the cores' running tasks and flags.
/// - `task` - the task made ready.
pub fn wakeFor(base: *ExecBase, task: *Task) void {
    const core = exec_base.coreId();
    const owner = @atomicLoad(u32, &task.owner, .monotonic);
    // Its own core runs it next if it outranks what runs there: this one
    // through its flags, another through its cross-core interrupt.
    if (task.node.pri > @atomicLoad(i32, &base.cpus_at[owner].running_pri, .monotonic)) {
        if (owner == core) {
            base.cpus_at[core].sys_flags |= SFF_SAR;
        } else {
            pokeCore(owner);
        }
        return;
    }
    // A task its own core may not run at all waits there until the core
    // it is pinned to comes for it: that core is asked, whatever it is
    // running.
    if (!runnableOn(base, task, owner)) {
        askCore(base, task.core);
        return;
    }
    // Its own core is busy with something higher. Another running less
    // may come and take it instead, which is what the offer is for.
    offerOthers(base, task, owner);
}

/// `task`, ready, offered to the cores that are not `core`: the one
/// `leastOutranked` names poked.
fn offerOthers(base: *ExecBase, task: *const Task, core: u32) void {
    if (leastOutranked(base, task, core)) |other| pokeCore(other);
}

/// Of the running cores but `core`, the one `task` may run on whose
/// running task is the least and below it - an idle one before a busy
/// one; null for none.
fn leastOutranked(base: *const ExecBase, task: *const Task, core: u32) ?u32 {
    var found: ?u32 = null;
    var least: i32 = task.node.pri;
    for (0..base.cores_running) |number| {
        const other: u32 = @intCast(number);
        if (other == core) continue;
        const there = @atomicLoad(i32, &base.cpus_at[other].running_pri, .monotonic);
        if (there < least and runnableOn(base, task, other)) {
            found = other;
            least = there;
        }
    }
    return found;
}

/// Core `core`'s dispatcher asked to look again: this core's through its
/// flags, another's through its cross-core interrupt. A core the machine
/// does not run is not asked.
///
/// INPUTS:
/// - `base` - exec: how many cores run.
/// - `core` - the core to ask.
pub fn askCore(base: *ExecBase, core: u32) void {
    if (core >= base.cores_running) return;
    if (core == exec_base.coreId()) {
        base.cpu().sys_flags |= SFF_SAR;
    } else {
        pokeCore(core);
    }
}

/// The dispatcher of the core running `task` asked to look again: this
/// core's through its flags, another's through its cross-core interrupt.
/// Nothing for a task that is not running. The caller holds the task's
/// own core's lists.
///
/// INPUTS:
/// - `base` - exec: the cores' running tasks.
/// - `task` - the task.
pub fn askCoreOf(base: *ExecBase, task: *const Task) void {
    const core = exec_base.coreId();
    if (base.cpus_at[core].this_task == task) {
        base.cpus_at[core].sys_flags |= SFF_SAR;
    } else if (runningOn(base, task)) |other| {
        pokeCore(other);
    }
}

/// The other core `task` is running on, if it is running on one. The
/// caller holds the task lists' lock.
pub fn runningOn(base: *ExecBase, task: *const Task) ?u32 {
    const core = exec_base.coreId();
    const owner = @atomicLoad(u32, &task.owner, .monotonic);
    if (owner == core or owner >= base.cores_running) return null;
    return if (base.cpus_at[owner].this_task == task) owner else null;
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
    // The caller's own word, on its stack: the lists are let go around
    // each wait, and the caller may come back on another core.
    const state = _interrupt.mask();
    defer _interrupt.unmask(state);
    // The task's own core's lists: what it runs, and the words that tell
    // it to stop, are that core's and are written under its lock.
    _ = takeOwner(base, task, @returnAddress());
    defer dropTaskLists(base);
    const core = runningOn(base, task) orelse return;
    const cpu = &base.cpus_at[core];
    cpu.stopping = task;
    cpu.stop_waiter = base.cpu().this_task;
    pokeCore(core);
    while (cpu.stopping == task or cpu.stopped == task) {
        dropTaskLists(base);
        _interrupt.unmask(state);
        _ = sys.Wait(sdk.exec.SIGF_SINGLE);
        _ = _interrupt.mask();
        takeTasks(base, core, @returnAddress());
    }
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
/// The caller holds the task lists once, at task level, and not nested.
/// The signals are taken out of both the received and the exception sets
/// before the code runs, so it cannot be re-entered for the same signal;
/// the code runs with the lists let go and the interrupts as `state` has
/// them, since it is the task's own code and may do the things a task
/// does; and the bits it answers are put back into the exception set,
/// which is how it says which signals it still wants.
///
/// INPUTS:
/// - `base` - exec: the lists lock it steps out of.
/// - `task` - the running task.
/// - `state` - the interrupts as the caller found them, which the task's
///   own code runs under. It is the caller's own word, on its stack, so
///   it is still the task's after a move to another core.
pub fn runExceptions(base: *ExecBase, task: *Task, state: u32) void {
    while (exceptionPending(task)) {
        const signals = task.sig_recvd & task.sig_except;
        task.sig_recvd &= ~signals;
        task.sig_except &= ~signals;
        dropTaskLists(base);
        _interrupt.unmask(state);
        const enable = task.except_code.?(signals, task.except_data);
        _ = _interrupt.mask();
        takeTaskLists(base, @returnAddress());
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
    const task = sys.FindTask(null).?;
    const state = _interrupt.mask();
    takeTaskLists(base, @returnAddress());
    runExceptions(base, task, state);
    dropTaskLists(base);
    _interrupt.unmask(state);
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
