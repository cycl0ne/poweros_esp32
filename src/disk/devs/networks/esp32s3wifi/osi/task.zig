// SPDX-License-Identifier: MIT
//! The adapter's tasks: the libraries ask for a task with a stack size in
//! bytes and a priority from 0 to 25, and get an exec task running their
//! function on a stack in internal memory.
//!
//! **Priorities.** exec's priority is theirs less 5, so their own task
//! (23 of 25) runs at 18: above the network stack (5) and every process,
//! below input.device (20). The core they name is ignored; there is one.
//!
//! **The stack** is the size asked for and `stack_margin` more: their
//! sizes were measured on another system, whose interrupts do not use the
//! task's stack.
//!
//! **A task that ends** - by deleting itself, or by returning - cannot
//! free the stack it runs on. It goes on the adapter's `ended` list and
//! is removed; the next task made frees what is on the list.

const sdk = @import("sdk");
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const _osi = @import("_osi.zig");

/// configMAX_PRIORITIES - 1.
pub const max_priority: i32 = 25;
const stack_margin: u32 = 2048;

/// A task's block: the Task, then its Thread, then its stack.
const Made = struct {
    task: exec.Task,
    name: [16:0]u8,
    thread: _osi.Thread,
};

pub fn priority(freertos: u32) i8 {
    const wanted: i32 = @as(i32, @intCast(@min(freertos, 127))) - 5;
    return @intCast(@max(wanted, -128));
}

/// What ended tasks left, freed.
fn reap() void {
    const sys = _osi.get().sys;
    sys.Disable();
    while (sys.RemHead(&_osi.get().ended)) |node| {
        sys.Enable();
        const thread: *_osi.Thread = @alignCast(@fieldParentPtr("node", node));
        const made: *Made = @fieldParentPtr("thread", thread);
        sys.FreeVec(thread.stack);
        sys.FreeVec(made);
        sys.Disable();
    }
    sys.Enable();
}

/// The first code a made task runs: its thread's timer and signal, then
/// the libraries' function. If that returns, the task ends.
fn start(sys: *ExecBase) callconv(.c) void {
    const task = sys.FindTask(null).?;
    const made: *Made = @fieldParentPtr("task", task);
    finish(sys, made, setUp(made));
}

fn setUp(made: *Made) bool {
    const own = _osi.adopt(&made.task) orelse return false;
    // adopt made a thread of its own; the made task keeps its stack and
    // entry in the one inside its block.
    made.thread.task = own.task;
    made.thread.wake = own.wake;
    made.thread.timer_port = own.timer_port;
    made.thread.timer_io = own.timer_io;
    made.task.user_data = &made.thread;
    _osi.get().sys.FreeVec(own);
    made.thread.entry.?(made.thread.param);
    return true;
}

fn finish(sys: *ExecBase, made: *Made, adopted: bool) void {
    if (adopted) {
        sys.CloseDevice(&made.thread.timer_io.node);
        sys.DeleteIORequest(&made.thread.timer_io.node);
        sys.DeleteMsgPort(made.thread.timer_port);
    }
    sys.Disable();
    sys.AddTail(&_osi.get().ended, &made.thread.node);
    sys.RemTask(null);
}

pub fn taskCreatePinnedToCore(entry: ?*anyopaque, name: ?[*:0]const u8, stack_bytes: u32, param: ?*anyopaque, prio: u32, handle: ?*anyopaque, _: u32) callconv(.c) i32 {
    return taskCreate(entry, name, stack_bytes, param, prio, handle);
}

pub fn taskCreate(entry: ?*anyopaque, name: ?[*:0]const u8, stack_bytes: u32, param: ?*anyopaque, prio: u32, handle: ?*anyopaque) callconv(.c) i32 {
    _osi.trace("task_create");
    reap();
    const sys = _osi.get().sys;
    const memory = sys.AllocVec(@sizeOf(Made), exec.MEMF_INTERNAL | exec.MEMF_CLEAR) orelse return _osi.no;
    const made: *Made = @ptrCast(@alignCast(memory));
    const size = (stack_bytes + stack_margin + 15) & ~@as(u32, 15);
    const stack = sys.AllocVec(size, exec.MEMF_INTERNAL | exec.MEMF_CLEAR) orelse {
        sys.FreeVec(memory);
        return _osi.no;
    };
    if (name) |text| {
        var i: usize = 0;
        while (i < made.name.len and text[i] != 0) : (i += 1) made.name[i] = text[i];
    }
    made.thread = .{
        .task = &made.task,
        .wake = 0,
        .timer_port = undefined,
        .timer_io = undefined,
        .stack = stack,
        .entry = @ptrCast(@alignCast(entry.?)),
        .param = param,
    };
    // On core 0, as everything that runs the vendor code: it was written
    // for one core, and its interrupts are core 0's.
    made.task = .{
        .node = .{ .type = .task, .pri = priority(prio), .name = &made.name },
        .flags = exec.TF_CORE0,
        .sp_lower = @intFromPtr(stack),
        .sp_upper = @intFromPtr(stack) + size,
    };
    if (handle) |out| @as(*?*anyopaque, @ptrCast(@alignCast(out))).* = &made.task;
    _ = sys.AddTask(&made.task, &start, null);
    return _osi.yes;
}

/// The task given (null: the caller) ended. A task the libraries made
/// goes on the `ended` list; the device's own tasks are never handed here.
pub fn taskDelete(handle: ?*anyopaque) callconv(.c) void {
    _osi.trace("task_delete");
    const sys = _osi.get().sys;
    const self = sys.FindTask(null).?;
    const task: *exec.Task = if (handle) |h| @ptrCast(@alignCast(h)) else self;
    const made: *Made = @fieldParentPtr("task", task);
    if (task == self) return finish(sys, made, true);
    sys.RemTask(task);
    sys.Disable();
    sys.AddTail(&_osi.get().ended, &made.thread.node);
    sys.Enable();
}

/// Nothing wakes a delay early: the wake signal is cleared first, and a
/// task that delays is on no object's list.
pub fn taskDelay(ticks: u32) callconv(.c) void {
    _osi.trace2("task_delay", ticks, 0);
    const thread = _osi.current();
    const until = _osi.deadline(ticks);
    _ = _osi.get().sys.SetSignal(0, thread.wake);
    while (until == null or _osi.now() < until.?) _ = _osi.sleep(thread, until);
}

pub fn taskMsToTick(ms: u32) callconv(.c) i32 {
    return @intCast(@as(u64, ms) * 1000 / _osi.tick_us);
}

pub fn taskGetCurrentTask() callconv(.c) ?*anyopaque {
    return _osi.get().sys.FindTask(null);
}

pub fn taskGetMaxPriority() callconv(.c) i32 {
    return max_priority;
}

pub fn taskYieldFromIsr() callconv(.c) void {}
