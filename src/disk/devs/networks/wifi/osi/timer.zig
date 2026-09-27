// SPDX-License-Identifier: MIT
//! The adapter's timers: the libraries' ETSTimers, run by one task of the
//! adapter's own.
//!
//! **An ETSTimer is the libraries' memory**, five words they declare and
//! pass around. `_timer_setfn` marks it (`timer_expire` holds `marker`)
//! and hangs a `Record` of the adapter's own on it (`timer_arg`): the
//! function, its argument, the deadline and the period. `_timer_done`
//! takes the record away again. The libraries touch no field themselves.
//!
//! **One task runs them all**, at the priority of the libraries' own
//! timer task (22, so exec's 17). It sleeps until the nearest deadline or
//! until a timer is armed, and calls each timer that is due on its own
//! stack, outside Disable. Arming and disarming only change the record
//! and wake the task, so both work from the interrupt handler.
//!
//! `nextDue` is the choice of what runs, without exec, for the host
//! tests.

const sdk = @import("sdk");
const exec = sdk.exec;
const timer = sdk.devices.timer;
const ExecBase = sdk.interface.exec.ExecBase;
const _osi = @import("_osi.zig");
const task_file = @import("task.zig");

/// struct _ETSTIMER_.
pub const EtsTimer = extern struct {
    next: ?*EtsTimer,
    expire: u32,
    period: u32,
    func: ?*anyopaque,
    arg: ?*anyopaque,
};

comptime {
    if (@sizeOf(usize) == 4 and @sizeOf(EtsTimer) != 20) @compileError("an ETSTimer is five words");
}

/// What `timer_expire` holds on a timer that has a record.
pub const marker: u32 = 0x1212_1212;

pub const Func = *const fn (?*anyopaque) callconv(.c) void;

pub const Record = struct {
    node: exec.Node = .{},
    func: ?Func = null,
    arg: ?*anyopaque = null,
    /// When it is next due, in microseconds, and 0 when it is not armed.
    due: u64 = 0,
    /// Its period, 0 for once.
    period: u64 = 0,
};

/// The timer task's stack.
const stack_size = 4096;
const timer_task_priority = 22;

fn recordOf(ets: *EtsTimer) ?*Record {
    if (ets.expire != marker) return null;
    return @ptrCast(@alignCast(ets.arg));
}

pub fn timerSetfn(handle: ?*anyopaque, func: ?*anyopaque, arg: ?*anyopaque) callconv(.c) void {
    _osi.trace("timer_setfn");
    const ets: *EtsTimer = @ptrCast(@alignCast(handle.?));
    const sys = _osi.get().sys;
    if (recordOf(ets) == null) {
        ets.* = .{ .next = null, .expire = 0, .period = 0, .func = null, .arg = null };
        const memory = _osi.alloc(@sizeOf(Record), true, false) orelse return;
        const record: *Record = @ptrCast(@alignCast(memory));
        record.* = .{};
        sys.Disable();
        sys.AddTail(&_osi.get().timers, &record.node);
        sys.Enable();
        ets.arg = record;
        ets.expire = marker;
    }
    const record = recordOf(ets).?;
    sys.Disable();
    record.func = @ptrCast(@alignCast(func));
    record.arg = arg;
    sys.Enable();
}

fn arm(handle: ?*anyopaque, us: u64, repeat: bool) void {
    _osi.trace2("timer_arm", @intFromPtr(handle), @intCast(us | (@as(u64, @intFromBool(repeat)) << 31)));
    const ets: *EtsTimer = @ptrCast(@alignCast(handle.?));
    const record = recordOf(ets) orelse return;
    const state = _osi.get();
    const sys = state.sys;
    const due = _osi.now() + @max(us, 1);
    sys.Disable();
    record.due = due;
    record.period = if (repeat) @max(us, 1) else 0;
    if (state.timer_task) |task| sys.Signal(task, state.timer_wake);
    sys.Enable();
}

pub fn timerArm(handle: ?*anyopaque, ms: u32, repeat: bool) callconv(.c) void {
    arm(handle, @as(u64, ms) * 1000, repeat);
}

pub fn timerArmUs(handle: ?*anyopaque, us: u32, repeat: bool) callconv(.c) void {
    arm(handle, us, repeat);
}

pub fn timerDisarm(handle: ?*anyopaque) callconv(.c) void {
    const ets: *EtsTimer = @ptrCast(@alignCast(handle.?));
    const record = recordOf(ets) orelse return;
    const sys = _osi.get().sys;
    sys.Disable();
    record.due = 0;
    sys.Enable();
}

pub fn timerDone(handle: ?*anyopaque) callconv(.c) void {
    _osi.trace("timer_done");
    const ets: *EtsTimer = @ptrCast(@alignCast(handle.?));
    const record = recordOf(ets) orelse return;
    const sys = _osi.get().sys;
    sys.Disable();
    sys.Remove(&record.node);
    sys.Enable();
    ets.expire = 0;
    ets.arg = null;
    _osi.free(record);
}

/// The first record on `timers` due at `time`, or null; and in `nearest`
/// the soonest deadline of the rest (0: none armed).
pub fn nextDue(timers: *exec.List, time: u64, nearest: *u64) ?*Record {
    nearest.* = 0;
    var it = timers.iterator();
    while (it.next()) |node| {
        const record: *Record = @alignCast(@fieldParentPtr("node", node));
        if (record.due == 0) continue;
        if (record.due <= time) return record;
        if (nearest.* == 0 or record.due < nearest.*) nearest.* = record.due;
    }
    return null;
}

/// The timer task: every due timer run, then a sleep until the next one
/// or until one is armed.
fn run(sys: *ExecBase) callconv(.c) void {
    const state = _osi.get();
    const thread = _osi.adopt(sys.FindTask(null).?) orelse return;
    // The signal arming raises is the thread's own wake.
    sys.Disable();
    state.timer_wake = thread.wake;
    state.timer_task = thread.task;
    sys.Enable();
    while (true) {
        var nearest: u64 = 0;
        sys.Disable();
        const due = nextDue(&state.timers, _osi.now(), &nearest);
        var func: ?Func = null;
        var arg: ?*anyopaque = null;
        if (due) |record| {
            func = record.func;
            arg = record.arg;
            record.due = if (record.period != 0) record.due + record.period else 0;
        }
        sys.Enable();
        if (func) |call| {
            _osi.trace2("timer_fire", @intFromPtr(call), @intFromPtr(arg));
            call(arg);
            continue;
        }
        if (due != null) continue;
        _ = _osi.sleep(thread, if (nearest == 0) null else nearest);
    }
}

/// The timer task started. Its block is never freed: the device keeps
/// the radio for as long as it is loaded.
pub fn startTask() bool {
    const sys = _osi.get().sys;
    _osi.get().timers.init(.unknown);
    const memory = sys.AllocVec(@sizeOf(exec.Task) + 16 + stack_size, exec.MEMF_INTERNAL | exec.MEMF_CLEAR) orelse return false;
    const task: *exec.Task = @ptrCast(@alignCast(memory));
    const stack = (@intFromPtr(memory) + @sizeOf(exec.Task) + 15) & ~@as(usize, 15);
    task.* = .{
        .node = .{ .type = .task, .pri = task_file.priority(timer_task_priority), .name = "wifi timers" },
        .sp_lower = stack,
        .sp_upper = stack + stack_size,
    };
    _ = sys.AddTask(task, &run, null);
    return true;
}
