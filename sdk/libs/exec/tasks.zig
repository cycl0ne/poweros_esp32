// SPDX-License-Identifier: MIT
//! Tasks (exec/tasks.h): struct Task, its states, the signals, and what a
//! task's exception and trap code look like.

const std = @import("std");
const Node = @import("nodes.zig").Node;
const ExecBase = @import("../../interface/exec.zig").ExecBase;

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

/// tc_Switch and tc_Launch. They get the task and SysBase (A3 and A6 in the
/// ROM). exec calls them from its dispatcher, at the exception exit with
/// interrupts masked, so they must be short and must not wait, switch, or
/// call exec functions that might.
pub const TaskSwitchFn = *const fn (task: *Task, sys_base: *ExecBase) callconv(.c) void;

/// struct Task.
pub const Task = extern struct {
    /// tc_Node: ln_Type NT_TASK, ln_Pri, ln_Name.
    node: Node = .{ .type = .task },
    /// tc_Flags: TF_SWITCH, TF_LAUNCH.
    flags: u8 = 0,
    /// tc_State
    state: TaskState = .invalid,
    /// tc_IDNestCnt, tc_TDNestCnt: the task's Disable/Forbid nesting,
    /// kept here while it is switched out.
    id_nest_cnt: i8 = -1,
    td_nest_cnt: i8 = -1,
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

    pub fn name(task: *const Task) [:0]const u8 {
        return std.mem.span(task.node.name orelse return "");
    }
};
