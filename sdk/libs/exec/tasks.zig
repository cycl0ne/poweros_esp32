// SPDX-License-Identifier: MIT
//! Tasks (exec/tasks.h): struct Task, its states, the signals, and what a
//! task's exception and trap code look like.

const std = @import("std");
const Node = @import("nodes.zig").Node;
const MinNode = @import("nodes.zig").MinNode;
const MinList = @import("lists.zig").MinList;
const ExecBase = @import("../../interface/exec.zig").ExecBase;
const Message = @import("ports.zig").Message;

/// tc_State
pub const TaskState = enum(u8) {
    invalid = 0,
    added = 1,
    run = 2,
    ready = 3,
    wait = 4,
    except = 5,
    removed = 6,
    _,
};

// System signals (0-15); AllocSignal hands out 16-31.
pub const SIGB_ABORT = 0;
pub const SIGB_CHILD = 1;
pub const SIGB_BLIT = 4;
pub const SIGB_SINGLE = 4;
pub const SIGB_INTUITION = 5;
pub const SIGB_NET = 7;
pub const SIGB_DOS = 8;
pub const SIGF_ABORT: u32 = 1 << SIGB_ABORT;
pub const SIGF_CHILD: u32 = 1 << SIGB_CHILD;
pub const SIGF_BLIT: u32 = 1 << SIGB_BLIT;
pub const SIGF_SINGLE: u32 = 1 << SIGB_SINGLE;
pub const SIGF_INTUITION: u32 = 1 << SIGB_INTUITION;
pub const SIGF_NET: u32 = 1 << SIGB_NET;
pub const SIGF_DOS: u32 = 1 << SIGB_DOS;
pub const SIGBREAKB_CTRL_C = 12;
pub const SIGBREAKB_CTRL_D = 13;
pub const SIGBREAKB_CTRL_E = 14;
pub const SIGBREAKB_CTRL_F = 15;
pub const SIGBREAKF_CTRL_C: u32 = 1 << SIGBREAKB_CTRL_C;
pub const SIGBREAKF_CTRL_D: u32 = 1 << SIGBREAKB_CTRL_D;
pub const SIGBREAKF_CTRL_E: u32 = 1 << SIGBREAKB_CTRL_E;
pub const SIGBREAKF_CTRL_F: u32 = 1 << SIGBREAKB_CTRL_F;
/// Signals reserved for the system in every task's tc_SigAlloc.
pub const system_signals: u32 = 0xFFFF;

/// A task's code: initialPC and finalPC. It gets SysBase, as init routines
/// do, rather than reading it from a fixed address.
pub const TaskFn = *const fn (sys_base: *ExecBase) callconv(.c) void;

/// NewStackRun's code: gets its argument, answers a number.
pub const StackFn = *const fn (arg: ?*anyopaque) callconv(.c) i32;

/// tc_ExceptCode: gets the signals that raised the exception and
/// tc_ExceptData; returns the signals to enable again in tc_SigExcept.
pub const ExceptFn = *const fn (signals: u32, data: ?*anyopaque) callconv(.c) u32;

/// What the trap code gets about a CPU exception.
pub const TrapInfo = extern struct {
    /// Exception number (EXCCAUSE).
    number: u32,
    /// Where it happened. Trap code that handles the exception may change
    /// it; execution continues there.
    pc: usize,
    /// The faulting address, for memory exceptions (EXCVADDR).
    address: usize,
    /// The CPU state saved by the kernel.
    frame: ?*anyopaque,
};

/// tc_TrapCode. Return non-zero if the exception was handled (execution
/// continues at info.pc), 0 to hand it on to the default Alert.
pub const TrapFn = *const fn (info: *TrapInfo, trap_data: ?*anyopaque) callconv(.c) i32;

/// tc_Flags: call tc_Switch when the task loses the CPU, tc_Launch when it
/// gets it.
pub const TB_SWITCH = 6;
pub const TB_LAUNCH = 7;
pub const TF_SWITCH: u8 = 1 << TB_SWITCH;
pub const TF_LAUNCH: u8 = 1 << TB_LAUNCH;
/// exec's own: the stack from `sp_lower` has a guard at its bottom
/// (`AddTask`, `NewStackRun`), which the dispatcher checks.
pub const TB_GUARDED = 0;
pub const TF_GUARDED: u8 = 1 << TB_GUARDED;
/// The cores a task runs on: TF_CORE0 alone keeps it on core 0, TF_CORE1
/// alone on core 1; neither (or both) lets it run on whichever core is
/// free.
pub const TB_CORE0 = 1;
pub const TB_CORE1 = 2;
pub const TF_CORE0: u8 = 1 << TB_CORE0;
pub const TF_CORE1: u8 = 1 << TB_CORE1;

/// How a core has spent its time since it started, in cycles of its own
/// clock (`ReadCoreTimes`): running tasks, in its idle task, and in
/// interrupts and exceptions. The sum is all of it; what a program makes
/// of them is the ratios, between two readings.
pub const CoreTimes = extern struct {
    tasks: u64 align(4) = 0,
    idle: u64 align(4) = 0,
    interrupts: u64 align(4) = 0,
};

/// tc_Switch and tc_Launch. They get the task and SysBase (A3 and A6 in the
/// ROM). exec calls them from its dispatcher, at the exception exit with
/// interrupts masked, so they must be short and must not wait, switch, or
/// call exec functions that might.
pub const TaskSwitchFn = *const fn (task: *Task, sys_base: *ExecBase) callconv(.c) void;

/// struct Task.
/// What `RemTask` runs for a hook when the task it is on ends: on the task
/// that called `RemTask` - the ending one itself, when it ends itself -
/// before the task is taken away, with nothing held. `hook` is already off
/// the task's list.
pub const TaskEndFn = *const fn (sys_base: *ExecBase, task: *Task, hook: *TaskEndHook) callconv(.c) void;

/// Something a library holds for a task, to be let go when the task ends
/// (`AddTaskEndHook`). Lives in the caller's memory.
pub const TaskEndHook = extern struct {
    node: MinNode = .{},
    code: TaskEndFn,
    /// The caller's, handed back through `hook`.
    data: ?*anyopaque = null,
    /// The task it is on, while it is on one; null once it has run or was
    /// taken off.
    task: ?*Task = null,
};

pub const Task = extern struct {
    /// tc_Node: ln_Type NT_TASK, ln_Pri, ln_Name.
    node: Node = .{ .type = .task },
    /// tc_Flags: TF_SWITCH, TF_LAUNCH, TF_CORE0, TF_CORE1.
    flags: u8 = 0,
    /// tc_State
    state: TaskState = .invalid,
    /// tc_IDNestCnt: the task's Disable nesting, kept here while it is
    /// switched out.
    id_nest_cnt: i8 = -1,
    /// tc_SigAlloc: allocated signals.
    sig_alloc: u32 = system_signals,
    /// tc_SigWait: signals the task waits for.
    sig_wait: u32 = 0,
    /// tc_SigRecvd: signals received.
    sig_recvd: u32 = 0,
    /// tc_SigExcept: signals that raise the task's exception (SetExcept).
    sig_except: u32 = 0,
    /// tc_ExceptData, tc_ExceptCode: the task's exception code.
    except_data: ?*anyopaque = null,
    except_code: ?ExceptFn = null,
    /// tc_TrapData, tc_TrapCode: CPU exceptions of this task.
    trap_data: ?*anyopaque = null,
    trap_code: ?TrapFn = null,
    /// tc_SPReg: the saved context while switched out.
    sp_reg: ?*anyopaque = null,
    /// tc_SPLower, tc_SPUpper: the stack.
    sp_lower: usize = 0,
    sp_upper: usize = 0,
    /// tc_Switch: called when the task loses the CPU, if TF_SWITCH is set,
    /// after its context is saved.
    switch_code: ?TaskSwitchFn = null,
    /// tc_Launch: called when the task gets the CPU, if TF_LAUNCH is set,
    /// before it runs again.
    launch_code: ?TaskSwitchFn = null,
    /// tc_UserData
    user_data: ?*anyopaque = null,
    // The system's own fields:
    /// Disable state to restore at the task's outermost Enable.
    id_saved: u32 = 0,
    init_pc: ?TaskFn = null,
    final_pc: ?TaskFn = null,
    /// Memory CreateTask allocated for the task (freed by RemTask).
    mem_block: ?*anyopaque = null,
    mem_size: usize = 0,
    /// What is to be run when the task ends: a `TaskEndHook` each, put on
    /// with `AddTaskEndHook` and run by `RemTask`. Made empty the first
    /// time a hook is put on.
    end_hooks: MinList = .{},
    /// What is replied to its reply port once the task has ended and
    /// nothing runs on its stack any more (`SetTaskEndMsg`). Set before the
    /// task may end: in the Task handed to AddTask, or with the call.
    end_msg: ?*Message = null,

    pub fn name(task: *const Task) [:0]const u8 {
        return std.mem.span(task.node.name orelse return "");
    }
};
