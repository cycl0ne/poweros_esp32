// SPDX-License-Identifier: MPL-2.0
//! Exception and interrupt dispatch. start.S saves the interrupted context
//! into a `Frame` and calls `riscv_exception` for every trap: an
//! exception, an interrupt from one of the interrupt controller's lines
//! (the number in mcause), an `ecall` - the kernel's syscall - or a
//! breakpoint exception, which is the ROM debugger's (debugexc.zig).

const std = @import("std");
const cpu = @import("cpu.zig");
const sdk = @import("sdk");
const exec = @import("../../rom/libs/exec/exec.zig");

/// Layout shared with start.S: the integer registers (x[0] unused, x[2] the
/// interrupted stack pointer), the trap's CSRs, and the FPU's registers
/// when `fpu_saved` says they are here.
pub const Frame = extern struct {
    x: [32]u32,
    mepc: u32,
    mstatus: u32,
    mcause: u32,
    mtval: u32,
    fpu_saved: u32,
    fcsr: u32,
    f: [32]u32,
    pad: [2]u32,
};

comptime {
    std.debug.assert(@sizeOf(Frame) == 288);
    std.debug.assert(@offsetOf(Frame, "mepc") == 128);
    std.debug.assert(@offsetOf(Frame, "fpu_saved") == 144);
    std.debug.assert(@offsetOf(Frame, "f") == 152);
}

/// The frame sits this far below the interrupted stack pointer (start.S
/// FRAME_SIZE).
pub const frame_offset = @sizeOf(Frame);

/// The interrupt controller's lines this kernel uses, each core's own: the
/// software interrupt (exec's Cause), which is the lowest so that it runs
/// after every device interrupt pending with it; the cross-core interrupt;
/// the tick; and the lines for the devices' sources.
pub const software_line: u6 = 16;
pub const cross_core_line: u6 = 17;
pub const tick_line: u6 = 18;
pub const first_device_line: u6 = 19;
pub const line_count = 48;

const Cause = enum(u32) {
    instruction_misaligned = 0,
    instruction_access_fault = 1,
    illegal_instruction = 2,
    breakpoint = 3,
    load_misaligned = 4,
    load_access_fault = 5,
    store_misaligned = 6,
    store_access_fault = 7,
    ecall_user = 8,
    ecall_machine = 11,
    _,
};

/// Gets the interrupt line that fired.
pub const Handler = *const fn (line: u6) void;
/// Each core's own: its lines are its own.
var handlers: [2][line_count]?Handler = @splat(@splat(null));

/// `handler` for line `line` of the core this runs on.
pub fn setHandler(line: u6, handler: Handler) void {
    handlers[cpu.coreId()][line] = handler;
}

pub const Syscall = enum(u32) {
    ping = 0,
    /// Enter the kernel so exec can switch tasks on the way out.
    reschedule = 3,
    /// End a task exception: resume the frame in `arg` instead.
    leave_exception = 4,
    _,
};

/// Set by the leave_exception syscall, each core's own.
var resume_frame: [2]?*Frame = @splat(null);

/// Trap into the kernel with `syscall`; the result comes back in a0.
pub fn syscall(nr: u32, arg: u32) u32 {
    return asm volatile ("ecall"
        : [ret] "={a0}" (-> u32),
        : [nr] "{a0}" (nr),
          [arg] "{a1}" (arg),
        : .{ .memory = true });
}

/// The longest trap each core has taken, in cycles, its mcause and the
/// line it served (bit n for line 16 + n), and the longest each line's
/// handler ran; the shell's `cores` shows them.
pub var longest: [2]u32 = @splat(0);
pub var longest_cause: [2]u32 = @splat(0);
pub var longest_lines: [2]u32 = @splat(0);
pub var line_longest: [2][line_count]u32 = @splat(@splat(0));

/// Called by start.S for every trap. Returns the frame to resume: `frame`
/// itself, or another task's when exec switched tasks.
export fn riscv_exception(frame: *Frame) callconv(.c) *Frame {
    if (!exec.initialized) {
        handle(frame);
        return frame;
    }
    const began = cpu.ccount();
    exec.interruptEnter(exec.SysBase);
    handle(frame);
    const core = cpu.coreId();
    const current = resume_frame[core] orelse frame;
    resume_frame[core] = null;
    const resumed: *Frame = @ptrCast(@alignCast(exec.interruptExit(exec.SysBase, current)));
    const took = cpu.ccount() -% began;
    if (took > longest[core]) {
        longest[core] = took;
        longest_cause[core] = frame.mcause;
        const line = frame.mcause & 0x3F;
        longest_lines[core] = if (frame.mcause & cpu.MCAUSE_INTERRUPT != 0 and line >= 16) @as(u32, 1) << @intCast(line - 16) else 0;
    }
    return resumed;
}

fn handle(frame: *Frame) void {
    if (frame.mcause & cpu.MCAUSE_INTERRUPT != 0) {
        dispatchLine(@intCast(frame.mcause & 0x3F));
        return;
    }
    switch (@as(Cause, @enumFromInt(frame.mcause & cpu.MCAUSE_CODE))) {
        .ecall_machine => {
            frame.x[10] = handleSyscall(@enumFromInt(frame.x[10]), frame.x[11]);
            frame.mepc += 4; // past the ecall
        },
        .breakpoint => @import("debugexc.zig").onBreakpoint(frame),
        else => {
            // Before exec is up there is nobody to ask.
            if (!exec.initialized) fatal(frame);
            var info: exec.TrapInfo = .{
                .number = frame.mcause & cpu.MCAUSE_CODE,
                .pc = frame.mepc,
                .address = frame.mtval,
                .frame = frame,
            };
            exec.dispatchTrap(exec.SysBase, &info); // returns if the trap code handled it, or the task was held
            frame.mepc = @intCast(info.pc);
        },
    }
}

fn dispatchLine(line: u6) void {
    if (line < line_count) {
        if (handlers[cpu.coreId()][line]) |handler| {
            const began = cpu.ccount();
            handler(line);
            const core = cpu.coreId();
            line_longest[core][line] = @max(line_longest[core][line], cpu.ccount() -% began);
            return;
        }
    }
    @import("intmatrix.zig").disableLine(line);
    exec.kprintf("\n[trap] spurious interrupt %d on core %d, disabled\n", .{ line, cpu.coreId() });
}

fn handleSyscall(nr: Syscall, arg: u32) u32 {
    return switch (nr) {
        .ping => arg +% 1,
        .reschedule => 0,
        .leave_exception => blk: {
            resume_frame[cpu.coreId()] = @ptrFromInt(arg);
            break :blk 0;
        },
        _ => 0xFFFF_FFFF,
    };
}

/// The name of an exception's cause (mcause's code).
pub fn causeName(code: u32) [:0]const u8 {
    return std.enums.tagName(Cause, @enumFromInt(code)) orelse "unknown";
}

/// A trap that came on a stack with no room for its frame, from start.S on
/// the core's fault stack: what it had of where it was - the stack
/// pointer, pc, cause, address, return address and frame pointer - and a
/// dead end. The task's registers are gone; the call chain is followed
/// from its frame pointer as far as it leads through memory.
export fn riscv_stack_fault(sp: u32, pc: u32, mcause: u32, mtval: u32, ra: u32, fp: u32) callconv(.c) noreturn {
    exec.kprintf("\n*** trap on a stack with no room: sp 0x%08x, pc 0x%08x, cause 0x%08x, address 0x%08x, ra 0x%08x, fp 0x%08x\n", .{ sp, pc, mcause, mtval, ra, fp });
    var info: exec.TrapInfo = .{
        .number = mcause & cpu.MCAUSE_CODE,
        .pc = pc,
        .address = mtval,
        .frame = null,
    };
    exec.alert_hook.*(sdk.exec.AT_DeadEnd | sdk.exec.AN_StackProbe, pc, &info, "a trap on a stack with no room");
    cpu.halt();
}

/// An exception before exec is up: the frame, and the machine stops.
fn fatal(frame: *const Frame) noreturn {
    _ = cpu.disableInterrupts();
    exec.kprintf("\n*** FATAL EXCEPTION %d (%s)\n", .{ frame.mcause & cpu.MCAUSE_CODE, causeName(frame.mcause & cpu.MCAUSE_CODE).ptr });
    dumpFrame(frame);
    exec.kprintf("*** system halted\n", .{});
    cpu.halt();
}

/// The frame on the raw port, which is where a Guru is read from.
pub fn dumpFrame(frame: *const Frame) void {
    dumpFrameTo(frame, &kprintfSink, null);
}

fn kprintfSink(character: u8, _: ?*anyopaque) callconv(.c) void {
    exec.kprintf("%c", .{character});
}

/// The ABI's names of the integer registers.
const register_names = [32][:0]const u8{
    "zero", "ra", "sp",  "gp",  "tp", "t0", "t1", "t2",
    "s0",   "s1", "a0",  "a1",  "a2", "a3", "a4", "a5",
    "a6",   "a7", "s2",  "s3",  "s4", "s5", "s6", "s7",
    "s8",   "s9", "s10", "s11", "t3", "t4", "t5", "t6",
};

/// The frame written a character at a time through `put`, so that
/// whoever asked decides where it goes.
pub fn dumpFrameTo(frame: *const Frame, put: sdk.exec.PutChProc, data: ?*anyopaque) void {
    printLine(put, data, "  PC       0x%08x  MSTATUS 0x%08x  MCAUSE 0x%08x  MTVAL 0x%08x\n", .{ frame.mepc, frame.mstatus, frame.mcause, frame.mtval });
    for (0..8) |row| {
        printLine(put, data, " ", .{});
        for (0..4) |col| {
            const index = row * 4 + col;
            printLine(put, data, " %-4s 0x%08x", .{ register_names[index].ptr, frame.x[index] });
        }
        printLine(put, data, "\n", .{});
    }
}

fn printLine(put: sdk.exec.PutChProc, data: ?*anyopaque, comptime format: [:0]const u8, args: anytype) void {
    const stream = sdk.exec.fmtStream(args);
    _ = exec.format(format, &stream, put, data);
}
