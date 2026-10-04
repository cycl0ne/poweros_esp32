// SPDX-License-Identifier: MPL-2.0
//! The clock: one task, one timer.device request, and the list of what is
//! due - for every animation and timer the library runs.
//!
//! **What runs on it** is a `Clocked`: when it next wants to run, and the
//! function that runs it. That function does its step and says whether it
//! wants to run again, having set its next time; an animation and a timer
//! are each a `Clocked` with more after it.
//!
//! **The task** is made the first time something is due (`schedule`), at a
//! priority above programs and below input.device and intuition's input
//! task: a step that comes late stutters, but a step ahead of the input
//! would make the pointer stutter instead. It sleeps on two signals - its
//! request coming back, and another task telling it something new is due -
//! and on either one runs everything due (`advance`) and sends its request
//! out again for the earliest of what is left. While nothing is due no
//! request is out and the task costs nothing.
//!
//! **Time** is timer.device's, in microseconds since the system started
//! (`GetSysTime`). Without timer.device - the host tests - it is
//! `MotionBase.hand_time`, set by whoever drives the clock, and no task is
//! made: the tests call `advance` themselves.
//!
//! **Its owner.** Everything on the clock belongs to a task (`adopt`), and
//! the library keeps an `Owner` for each task that holds something, with
//! an end hook on that task (`AddTaskEndHook`). A task that ends without
//! giving back what it held has it taken off the clock and let go
//! (`Clocked.gone`) as it ends, so no step is left calling into code that
//! is gone.
//!
//! The lists are guarded by a semaphore; a step runs holding it, so a step
//! may schedule or unschedule (a semaphore is its holder's to take again)
//! but must not wait for anything another task holds.

const sdk = @import("sdk");
const exec = sdk.exec;
const timer = sdk.devices.timer;
const ExecBase = sdk.interface.exec.ExecBase;
const TimerBase = sdk.interface.timer.TimerBase;
const MotionBase = @import("../motion_base.zig").MotionBase;

/// Something that runs on the clock.
pub const Clocked = extern struct {
    node: exec.MinNode = .{},
    /// When it next wants to run, in microseconds of the clock.
    due: u64 align(4) = 0,
    /// Its step, run at or after `due` with the time it is run at. True
    /// when it wants to run again, its `due` set to when; false takes it
    /// off the list.
    step: *const fn (mb: *MotionBase, clocked: *Clocked, now: u64) callconv(.c) bool,
    /// Whether it is on the list.
    queued: u32 = 0,
    /// The task it belongs to, and its place on that owner's list.
    owner: ?*Owner = null,
    owned: exec.MinNode = .{},
    /// Run when its owner's task ends with it still held: off the clock
    /// already, and to be freed. Null for one with nothing to free.
    gone: ?*const fn (mb: *MotionBase, clocked: *Clocked) callconv(.c) void = null,
};

/// A task that holds something on the clock: its end hook, and what it
/// holds.
pub const Owner = extern struct {
    node: exec.MinNode = .{},
    hook: exec.TaskEndHook,
    mb: *MotionBase,
    task: *exec.Task,
    /// Its `Clocked`s, by their `owned` node.
    held: exec.MinList = .{},
};

/// The clock task's priority: above programs, below input.device and
/// intuition's input task (20).
const task_pri = 10;
const stack_size = 8192;

/// `clocked` made `task`'s (null: the caller's), and let go when that task
/// ends. False when there was no memory for the task's `Owner`.
pub fn adopt(mb: *MotionBase, clocked: *Clocked, task: ?*exec.Task) bool {
    const sys = mb.sys_base;
    const holder = task orelse sys.FindTask(null).?;
    sys.ObtainSemaphore(&mb.lock);
    defer sys.ReleaseSemaphore(&mb.lock);
    if (clocked.owner != null) return true;
    var owner: ?*Owner = null;
    var walk: ?*exec.MinNode = mb.owners.head;
    while (walk) |node| : (walk = node.succ) {
        if (node.succ == null) break;
        const each: *Owner = @ptrCast(node);
        if (each.task == holder) owner = each;
    }
    if (owner == null) {
        const memory = sys.AllocVec(@sizeOf(Owner), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return false;
        const made: *Owner = @ptrCast(@alignCast(memory));
        made.* = .{ .hook = .{ .code = &ended, .data = made }, .mb = mb, .task = holder };
        made.held.init();
        sys.AddTail(@ptrCast(&mb.owners), @ptrCast(&made.node));
        sys.AddTaskEndHook(holder, &made.hook);
        owner = made;
    }
    sys.AddTail(@ptrCast(&owner.?.held), @ptrCast(&clocked.owned));
    clocked.owner = owner;
    return true;
}

/// `clocked` given back by its task: no longer its, and the task's
/// `Owner` gone with its hook when it was the last thing the task held.
pub fn release(mb: *MotionBase, clocked: *Clocked) void {
    const sys = mb.sys_base;
    sys.ObtainSemaphore(&mb.lock);
    defer sys.ReleaseSemaphore(&mb.lock);
    const owner = clocked.owner orelse return;
    sys.Remove(@ptrCast(&clocked.owned));
    clocked.owner = null;
    if (owner.held.head.?.succ != null) return;
    sys.RemTaskEndHook(&owner.hook);
    sys.Remove(@ptrCast(&owner.node));
    sys.FreeVec(owner);
}

/// A task's end hook: everything it still held taken off the clock and let
/// go, then its `Owner`. Runs on the task that ended it, before it goes.
fn ended(sys: *ExecBase, _: *exec.Task, hook: *exec.TaskEndHook) callconv(.c) void {
    const owner: *Owner = @ptrCast(@alignCast(hook.data.?));
    const mb = owner.mb;
    sys.ObtainSemaphore(&mb.lock);
    defer sys.ReleaseSemaphore(&mb.lock);
    while (sys.RemHead(@ptrCast(&owner.held))) |node| {
        const clocked: *Clocked = @fieldParentPtr("owned", @as(*exec.MinNode, @ptrCast(node)));
        clocked.owner = null;
        if (clocked.queued != 0) {
            sys.Remove(@ptrCast(&clocked.node));
            clocked.queued = 0;
        }
        if (clocked.gone) |gone| gone(mb, clocked);
    }
    sys.Remove(@ptrCast(&owner.node));
    sys.FreeVec(owner);
}

/// The time now, in microseconds.
pub fn now(mb: *MotionBase) u64 {
    const device = mb.tick.node.device orelse return mb.hand_time;
    const tb: *TimerBase = @ptrCast(device);
    var time: timer.TimeVal = .{};
    tb.GetSysTime(&time);
    return @as(u64, time.secs) * 1_000_000 + time.micro;
}

/// `clocked` put on the list, to run when its `due` comes - at once if it
/// has come already - and the clock told. The task is made the first time.
pub fn schedule(mb: *MotionBase, clocked: *Clocked) void {
    const sys = mb.sys_base;
    sys.ObtainSemaphore(&mb.lock);
    if (clocked.queued == 0) {
        sys.AddTail(@ptrCast(&mb.running), @ptrCast(&clocked.node));
        clocked.queued = 1;
    }
    sys.ReleaseSemaphore(&mb.lock);
    if (mb.started == 0) start(mb);
    if (mb.started == 1) sys.Signal(&mb.task, mb.wake_mask);
}

/// `clocked` taken off the list; nothing when it is not on it. Once this
/// returns its step is not running and will not run.
pub fn unschedule(mb: *MotionBase, clocked: *Clocked) void {
    const sys = mb.sys_base;
    sys.ObtainSemaphore(&mb.lock);
    if (clocked.queued != 0) {
        sys.Remove(@ptrCast(&clocked.node));
        clocked.queued = 0;
    }
    sys.ReleaseSemaphore(&mb.lock);
}

/// Every step that is due at `time` run, and the ones that are done taken
/// off; the earliest `due` of what is left, or null when nothing is.
pub fn advance(mb: *MotionBase, time: u64) ?u64 {
    const sys = mb.sys_base;
    sys.ObtainSemaphore(&mb.lock);
    defer sys.ReleaseSemaphore(&mb.lock);
    var next: ?*exec.MinNode = mb.running.head;
    while (next) |node| {
        // The tail sentinel is the node with no successor; the successor is
        // taken first, as a step may take itself off.
        const after = node.succ orelse break;
        const clocked: *Clocked = @ptrCast(node);
        if (clocked.due <= time and !clocked.step(mb, clocked, time)) {
            if (clocked.queued != 0) {
                sys.Remove(@ptrCast(node));
                clocked.queued = 0;
            }
        }
        next = after;
    }
    var earliest: ?u64 = null;
    var walk: ?*exec.MinNode = mb.running.head;
    while (walk) |node| : (walk = node.succ) {
        if (node.succ == null) break;
        const due = @as(*Clocked, @ptrCast(node)).due;
        if (earliest == null or due < earliest.?) earliest = due;
    }
    return earliest;
}

/// The request out for `due`, after taking back one that is out already;
/// nothing out when `due` is null.
fn arm(mb: *MotionBase, due: ?u64) void {
    const sys = mb.sys_base;
    if (mb.out != 0) {
        _ = sys.AbortIO(&mb.tick.node);
        _ = sys.WaitIO(&mb.tick.node);
        mb.out = 0;
    }
    // An aborted request leaves its signal set; the next Wait would come
    // back at once for nothing.
    _ = sys.SetSignal(0, mb.port.sigMask());
    const when = due orelse return;
    const at = now(mb);
    const wait: u64 = if (when > at) when - at else 1;
    mb.tick.node.command = timer.TR_ADDREQUEST;
    mb.tick.time = timer.TimeVal.fromMicros(wait);
    sys.SendIO(&mb.tick.node);
    mb.out = 1;
}

/// The clock task: woken by its request or by `schedule`, it runs what is
/// due and sends its request out again for the earliest of what is left.
fn clockTask(sys: *ExecBase) callconv(.c) void {
    const task = sys.FindTask(null).?;
    const mb: *MotionBase = @alignCast(@fieldParentPtr("task", task));
    const tick_signal = sys.AllocSignal(-1);
    const wake_signal = sys.AllocSignal(-1);
    if (tick_signal >= 0 and wake_signal >= 0) {
        mb.port.sig_bit = @intCast(tick_signal);
        mb.port.sig_task = task;
        mb.port.flags = exec.PA_SIGNAL;
        mb.wake_mask = @as(u32, 1) << @intCast(wake_signal);
    }
    if (mb.starter) |starter| {
        mb.starter = null;
        sys.Signal(starter, @as(u32, 1) << @intCast(mb.start_signal));
    }
    if (mb.wake_mask == 0) return;
    const tick_mask = mb.port.sigMask();
    while (true) {
        const got = sys.Wait(tick_mask | mb.wake_mask);
        if (got & tick_mask != 0 and mb.out != 0 and sys.CheckIO(&mb.tick.node) != null) {
            _ = sys.WaitIO(&mb.tick.node);
            mb.out = 0;
        }
        arm(mb, advance(mb, now(mb)));
    }
}

/// The clock task made and running. Without timer.device there is no
/// clock to run it on, and none is made.
fn start(mb: *MotionBase) void {
    const sys = mb.sys_base;
    // Claimed under the library's lock: two tasks scheduling at once make
    // one clock task.
    sys.ObtainSemaphore(&mb.lock);
    if (mb.started != 0) {
        sys.ReleaseSemaphore(&mb.lock);
        return;
    }
    mb.started = 2;
    sys.ReleaseSemaphore(&mb.lock);
    if (mb.tick.node.device == null) return;
    const stack = sys.AllocMem(stack_size, exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return;
    const signal = sys.AllocSignal(-1);
    if (signal < 0) {
        sys.FreeMem(stack, stack_size);
        return;
    }
    defer sys.FreeSignal(signal);
    mb.stack = stack;
    mb.task = .{
        .node = .{ .type = .task, .pri = task_pri, .name = "motion.library" },
        .sp_lower = @intFromPtr(stack),
        .sp_upper = @intFromPtr(stack) + stack_size,
    };
    mb.starter = sys.FindTask(null);
    mb.start_signal = signal;
    _ = sys.AddTask(&mb.task, &clockTask, null);
    _ = sys.Wait(@as(u32, 1) << @intCast(signal));
    if (mb.wake_mask != 0) mb.started = 1;
}
