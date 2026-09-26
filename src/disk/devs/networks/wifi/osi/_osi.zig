// SPDX-License-Identifier: MIT
//! The OS adapter's own state, and what every group of its calls shares:
//! the task a call runs on, waiting with a timeout, time, and memory.
//!
//! **The one global.** The radio's libraries call the adapter through a
//! table of plain C functions, and many of them carry no context at all -
//! `_malloc(size)`, `_rand()`, `_task_delay(ticks)` - so the adapter
//! reaches its state through `adapter`, set when the device starts the
//! radio and cleared when it stops. It is the only module global the
//! device has, and the codex's exception for wifi.device names it.
//!
//! **A thread.** Every task that calls into the libraries - the ones they
//! create and the device's own - has a `Thread`, found through its
//! `tc_UserData`: the signal a waiter is woken with, a timer request of
//! its own for timeouts, and the binary semaphore the libraries ask for
//! per thread. A task makes its own (`adopt`), since the signals and the
//! timer's reply port must be its own.
//!
//! **Waiting.** Every blocking call - a semaphore, a queue, an event
//! group, a mutex - is the same loop (`waitUntil`): under Disable, try;
//! if that fails and there is time left, go on the object's list of
//! waiters and sleep until woken or the deadline. Whoever changes the
//! object wakes every waiter on it, and each one tries again. Nothing is
//! handed over, so a waiter woken for nothing simply sleeps again, and a
//! give from an interrupt is only a Signal, which exec allows there.
//!
//! **Ticks.** The libraries count time in ticks of 10 ms (`tick_us`) and
//! ask the adapter to convert; the adapter's own clock is the E-clock, in
//! microseconds.

const sdk = @import("sdk");
const exec = sdk.exec;
const timer = sdk.devices.timer;
const ExecBase = sdk.interface.exec.ExecBase;
const TimerBase = sdk.interface.timer.TimerBase;
const phy_file = @import("../phy/phy.zig");
const events_file = @import("../events.zig");

/// A tick: 10 ms, as the libraries were built to expect.
pub const tick_us: u64 = 10_000;
/// A timeout of "forever".
pub const blocking: u32 = 0xFFFF_FFFF;

/// pdTRUE, pdFALSE, pdPASS: what the libraries' calls answer.
pub const yes: i32 = 1;
pub const no: i32 = 0;

/// The adapter, while the radio is started (see the file's header).
pub var adapter: ?*Adapter = null;

/// The adapter's state: in the internal block the device allocates, as
/// the interrupt reads it.
pub const Adapter = struct {
    sys: *ExecBase,
    /// timer.device's base, for the E-clock.
    timer_base: *TimerBase,
    /// The E-clock's rate, in ticks per second.
    eclock_hz: u32,
    /// Nonzero while the libraries' interrupt handler runs.
    in_isr: u32 = 0,
    /// The handler the libraries set on their CPU line, and its argument.
    isr: ?*const fn (?*anyopaque) callconv(.c) void = null,
    isr_arg: ?*anyopaque = null,
    /// The sources routed to that line (bit n: source n), and whether
    /// the servers are on them.
    sources: u32 = 0,
    hooked: u32 = 0,
    servers: [2]exec.Interrupt = @splat(.{}),
    /// The ETSTimers armed and not, and the task that runs them.
    timers: exec.List = .{},
    timer_task: ?*exec.Task = null,
    timer_wake: u32 = 0,
    /// Tasks that ended, whose stacks are freed by the next task made.
    ended: exec.List = .{},
    /// The MAC address from eFuse.
    mac: [6]u8 = @splat(0),
    /// The PHY's state.
    phy: phy_file.Phy = .{},
    /// The device's base, for the libraries' callbacks that carry no
    /// context (a received frame).
    device: ?*anyopaque = null,
    /// The events the libraries posted, for the device's task.
    events: events_file.Events = .{},
    /// Trace every call on the raw port.
    trace: bool = false,
};

pub fn get() *Adapter {
    return adapter.?;
}

// --- time -----------------------------------------------------------------

/// Microseconds since the E-clock started.
pub fn now() u64 {
    const state = get();
    var clock: timer.EClockVal = .{};
    _ = state.timer_base.ReadEClock(&clock);
    return clock.toTicks() * 1_000_000 / state.eclock_hz;
}

/// A deadline `ticks` from now, or null for forever.
pub fn deadline(ticks: u32) ?u64 {
    if (ticks == blocking) return null;
    return now() + @as(u64, ticks) * tick_us;
}

// --- threads --------------------------------------------------------------

/// A task's side of the adapter (see the file's header).
pub const Thread = struct {
    task: *exec.Task,
    /// The signal a waiter is woken with.
    wake: u32,
    /// Its own timer for timeouts, on a port of its own.
    timer_port: *exec.MsgPort,
    timer_io: *timer.TimeRequest,
    /// The per-thread binary semaphore, made the first time it is asked.
    semaphore: ?*anyopaque = null,
    /// For a task the libraries made: its stack and what it runs.
    stack: ?*anyopaque = null,
    entry: ?*const fn (?*anyopaque) callconv(.c) void = null,
    param: ?*anyopaque = null,
    node: exec.Node = .{},
};

/// The running task's thread, made on first use.
pub fn current() *Thread {
    const sys = get().sys;
    const task = sys.FindTask(null).?;
    if (task.user_data) |data| return @ptrCast(@alignCast(data));
    return adopt(task) orelse @panic("wifi.device: no signal or memory for a thread");
}

/// A thread for the running task: its wake signal, and a timer of its
/// own. Null when either cannot be had.
pub fn adopt(task: *exec.Task) ?*Thread {
    const sys = get().sys;
    const memory = sys.AllocVec(@sizeOf(Thread), exec.MEMF_INTERNAL | exec.MEMF_CLEAR) orelse return null;
    const thread: *Thread = @ptrCast(@alignCast(memory));
    const signal = sys.AllocSignal(-1);
    if (signal < 0) {
        sys.FreeVec(memory);
        return null;
    }
    const port = sys.CreateMsgPort() orelse {
        sys.FreeSignal(signal);
        sys.FreeVec(memory);
        return null;
    };
    const io: *timer.TimeRequest = @ptrCast(@alignCast(sys.CreateIORequest(port, @sizeOf(timer.TimeRequest)) orelse {
        sys.DeleteMsgPort(port);
        sys.FreeSignal(signal);
        sys.FreeVec(memory);
        return null;
    }));
    if (sys.OpenDevice(timer.TIMERNAME, timer.UNIT_MICROHZ, &io.node, 0) != 0) {
        sys.DeleteIORequest(&io.node);
        sys.DeleteMsgPort(port);
        sys.FreeSignal(signal);
        sys.FreeVec(memory);
        return null;
    }
    thread.* = .{
        .task = task,
        .wake = @as(u32, 1) << @intCast(signal),
        .timer_port = port,
        .timer_io = io,
    };
    task.user_data = thread;
    return thread;
}

/// What `adopt` made, given back by the task it belongs to.
pub fn release(thread: *Thread) void {
    const sys = get().sys;
    sys.CloseDevice(&thread.timer_io.node);
    sys.DeleteIORequest(&thread.timer_io.node);
    sys.DeleteMsgPort(thread.timer_port);
    thread.task.user_data = null;
    sys.FreeVec(thread);
}

/// Sleep until woken or `until` (null: forever). True if woken.
pub fn sleep(thread: *Thread, until: ?u64) bool {
    const sys = get().sys;
    const time = until orelse {
        _ = sys.Wait(thread.wake);
        return true;
    };
    const start = now();
    if (time <= start) return sys.SetSignal(0, thread.wake) & thread.wake != 0;
    const io = thread.timer_io;
    io.node.command = timer.TR_ADDREQUEST;
    io.time = timer.TimeVal.fromMicros(time - start);
    sys.SendIO(&io.node);
    const got = sys.Wait(thread.wake | thread.timer_port.sigMask());
    if (sys.CheckIO(&io.node) == null) _ = sys.AbortIO(&io.node);
    _ = sys.WaitIO(&io.node);
    return got & thread.wake != 0;
}

/// A waiter on an object's list.
const Waiter = struct {
    node: exec.Node = .{},
    thread: *Thread,
};

/// Try `attempt` under Disable until it succeeds or `until` passes (null:
/// forever), sleeping on `waiters` between tries. True if it succeeded.
/// With a deadline of now it tries once.
pub fn waitUntil(waiters: *exec.List, until: ?u64, context: anytype, comptime attempt: fn (@TypeOf(context)) bool) bool {
    const sys = get().sys;
    var waiter: Waiter = .{ .thread = undefined };
    var thread: ?*Thread = null;
    while (true) {
        sys.Disable();
        if (attempt(context)) {
            sys.Enable();
            return true;
        }
        if (until) |time| if (now() >= time) {
            sys.Enable();
            return false;
        };
        if (thread == null) {
            sys.Enable();
            thread = current();
            waiter.thread = thread.?;
            continue;
        }
        _ = sys.SetSignal(0, waiter.thread.wake);
        sys.AddTail(waiters, &waiter.node);
        sys.Enable();
        _ = sleep(waiter.thread, until);
        sys.Disable();
        if (waiter.node.succ != null) sys.Remove(&waiter.node);
        sys.Enable();
    }
}

/// Every waiter on `waiters` woken to try again. Under Disable, or from
/// an interrupt.
pub fn wakeAll(waiters: *exec.List) void {
    const sys = get().sys;
    while (sys.RemHead(waiters)) |node| {
        const waiter: *Waiter = @alignCast(@fieldParentPtr("node", node));
        node.succ = null;
        sys.Signal(waiter.thread.task, waiter.thread.wake);
    }
}

// --- memory ---------------------------------------------------------------

/// A block's size, kept before it: realloc needs it, and `free` is given
/// only the pointer.
const header_bytes = 8;

/// `size` bytes, cleared or not, from internal memory or any.
pub fn alloc(size: usize, internal: bool, clear: bool) ?*anyopaque {
    const sys = get().sys;
    var flags: u32 = if (internal) exec.MEMF_INTERNAL else exec.MEMF_ANY;
    if (clear) flags |= exec.MEMF_CLEAR;
    const block: [*]u8 = @ptrCast(sys.AllocVec(size + header_bytes, flags) orelse return null);
    @as(*usize, @ptrCast(@alignCast(block))).* = size;
    return block + header_bytes;
}

pub fn free(memory: ?*anyopaque) void {
    const block: [*]u8 = @ptrCast(memory orelse return);
    get().sys.FreeVec(block - header_bytes);
}

pub fn sizeOf(memory: *anyopaque) usize {
    const block: [*]u8 = @ptrCast(memory);
    return @as(*usize, @ptrCast(@alignCast(block - header_bytes))).*;
}

pub fn realloc(memory: ?*anyopaque, size: usize, internal: bool) ?*anyopaque {
    const old = memory orelse return alloc(size, internal, false);
    if (size == 0) {
        free(old);
        return null;
    }
    const new = alloc(size, internal, false) orelse return null;
    const kept = @min(sizeOf(old), size);
    const to: [*]u8 = @ptrCast(new);
    const from: [*]const u8 = @ptrCast(old);
    @memcpy(to[0..kept], from[0..kept]);
    free(old);
    return new;
}

// --- the trace ------------------------------------------------------------

/// A call's name on the raw port, when the adapter traces.
pub fn trace(comptime name: []const u8) void {
    const state = adapter orelse return;
    if (!state.trace) return;
    sdk.exec.kprintf(state.sys, "wifi: %s\n", .{@as([*:0]const u8, name ++ "")});
}
