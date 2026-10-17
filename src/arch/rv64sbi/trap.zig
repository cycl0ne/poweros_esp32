// SPDX-License-Identifier: MPL-2.0
//! Exception and interrupt dispatch. start.S saves the interrupted context
//! into a `Frame` and calls `riscv_exception` for every trap: an
//! exception, one of supervisor mode's three interrupts (the code in
//! scause), or the kernel's syscall.
//!
//! **The syscall is an ebreak.** ecall from supervisor mode is the SBI
//! firmware's, so the kernel enters itself with a breakpoint, which the
//! firmware hands to supervisor mode (medeleg): a four-byte `ebreak` with
//! `syscall_magic` in a7. Any other breakpoint is a breakpoint. A
//! software interrupt the hart raises on itself would not do: it waits
//! while the hart's interrupts are masked, and the syscall must not.
//!
//! **The interrupts.** A "line" here is the interrupt's code in scause:
//! the software interrupt (1), which carries exec's Cause and the
//! cross-core interrupt both, each with a flag of its own per core
//! (plic.zig); the timer's (5), the tick; and the external one (9), the
//! PLIC's, behind which every device's source is.

const std = @import("std");
const cpu = @import("cpu.zig");
const sdk = @import("sdk");
const exec = @import("../../rom/libs/exec/exec.zig");
const exec_base = @import("../../rom/libs/exec/exec_base.zig");
const exec_cache = @import("../../rom/libs/exec/cache/_cache.zig");

const max_cores = exec_base.max_cores;

/// Layout shared with start.S: the integer registers (x[0] unused, x[2] the
/// interrupted stack pointer), the trap's CSRs, and the FPU's registers
/// when `fpu_saved` says they are here.
pub const Frame = extern struct {
    x: [32]u64,
    sepc: u64,
    sstatus: u64,
    scause: u64,
    stval: u64,
    fpu_saved: u64,
    fcsr: u64,
    f: [32]u64,
};

comptime {
    std.debug.assert(@sizeOf(Frame) == 560);
    std.debug.assert(@sizeOf(Frame) % 16 == 0);
    std.debug.assert(@offsetOf(Frame, "sepc") == 256);
    std.debug.assert(@offsetOf(Frame, "fpu_saved") == 288);
    std.debug.assert(@offsetOf(Frame, "f") == 304);
}

/// The frame sits this far below the interrupted stack pointer (start.S
/// FRAME_SIZE).
pub const frame_offset = @sizeOf(Frame);

/// The interrupts by their code in scause, each core's own.
pub const software_line: u6 = cpu.IRQ_SOFTWARE;
pub const tick_line: u6 = cpu.IRQ_TIMER;
pub const external_line: u6 = cpu.IRQ_EXTERNAL;
pub const line_count = 16;

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
    ecall_supervisor = 9,
    instruction_page_fault = 12,
    load_page_fault = 13,
    store_page_fault = 15,
    _,
};

/// Gets the interrupt that came.
pub const Handler = *const fn (line: u6) void;
/// Each core's own.
var handlers: [max_cores][line_count]?Handler = @splat(@splat(null));

/// `handler` for interrupt `line` of the core this runs on.
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

/// What a7 holds at the syscall's ebreak: "PowerOS" in ASCII.
pub const syscall_magic: u64 = 0x0053_4F72_6577_6F50;
/// The low half of a four-byte ebreak; a two-byte one (c.ebreak) is
/// 0x9002.
const ebreak_low: u16 = 0x0073;

/// Set by the leave_exception syscall, each core's own.
var resume_frame: [max_cores]?*Frame = @splat(null);

/// Trap into the kernel with `syscall`; the result comes back in a0.
pub fn syscall(nr: u32, arg: usize) usize {
    return asm volatile (
        \\.option push
        \\.option norvc
        \\ebreak
        \\.option pop
        : [ret] "={a0}" (-> usize),
        : [nr] "{a0}" (@as(usize, nr)),
          [arg] "{a1}" (arg),
          [magic] "{a7}" (syscall_magic),
        : .{ .memory = true });
}

/// The longest trap each core has taken, in cycles, its cause (scause's
/// code, bit 31 set for an interrupt) and the interrupt it served (bit n
/// for code n), and the longest each interrupt's handler ran; the shell's
/// `cores` shows them.
pub var longest: [max_cores]u32 = @splat(0);
pub var longest_cause: [max_cores]u32 = @splat(0);
pub var longest_lines: [max_cores]u32 = @splat(0);
pub var line_longest: [max_cores][line_count]u32 = @splat(@splat(0));

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
        longest_cause[core] = @as(u32, @truncate(frame.scause & 0xFFF)) | if (frame.scause & cpu.SCAUSE_INTERRUPT != 0) @as(u32, 1) << 31 else 0;
        const line = frame.scause & 0x3F;
        longest_lines[core] = if (frame.scause & cpu.SCAUSE_INTERRUPT != 0 and line < 32) @as(u32, 1) << @intCast(line) else 0;
    }
    // Code another core has loaded since this one last fenced its
    // instruction fetch: fenced before anything is resumed.
    exec_cache.syncFetch(core);
    return resumed;
}

fn handle(frame: *Frame) void {
    if (frame.scause & cpu.SCAUSE_INTERRUPT != 0) {
        dispatchLine(@truncate(frame.scause & 0x3F));
        return;
    }
    const code: u32 = @truncate(frame.scause & cpu.SCAUSE_CODE);
    if (code == @intFromEnum(Cause.breakpoint) and isSyscall(frame)) {
        frame.x[10] = handleSyscall(@enumFromInt(@as(u32, @truncate(frame.x[10]))), frame.x[11]);
        frame.sepc += 4; // past the ebreak
        return;
    }
    // Before exec is up there is nobody to ask.
    if (!exec.initialized) fatal(frame);
    var info: exec.TrapInfo = .{
        .number = code,
        .pc = frame.sepc,
        .address = frame.stval,
        .frame = frame,
    };
    exec.dispatchTrap(exec.SysBase, &info); // returns if the trap code handled it, or the task was held
    frame.sepc = info.pc;
}

/// Whether the breakpoint is the kernel's syscall: the magic in a7, at a
/// four-byte ebreak. The instruction is read a half at a time, since code
/// with the C extension is aligned to two bytes only.
fn isSyscall(frame: *const Frame) bool {
    if (frame.x[17] != syscall_magic) return false;
    return @as(*const volatile u16, @ptrFromInt(frame.sepc)).* == ebreak_low;
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
    asm volatile ("csrc sie, %[bit]"
        :
        : [bit] "r" (@as(u64, 1) << line),
        : .{ .memory = true });
    exec.kprintf("\n[trap] spurious interrupt %d on core %d, disabled\n", .{ @as(u32, line), cpu.coreId() });
}

fn handleSyscall(nr: Syscall, arg: usize) usize {
    return switch (nr) {
        .ping => arg +% 1,
        .reschedule => 0,
        .leave_exception => blk: {
            resume_frame[cpu.coreId()] = @ptrFromInt(arg);
            break :blk 0;
        },
        _ => std.math.maxInt(usize),
    };
}

/// The name of an exception's cause (scause's code).
pub fn causeName(code: u32) [:0]const u8 {
    return std.enums.tagName(Cause, @enumFromInt(code)) orelse "unknown";
}

/// A trap that came on a stack with no room for its frame, from start.S on
/// the core's fault stack: what it had of where it was - the stack
/// pointer, pc, cause, address, return address and frame pointer - and a
/// dead end. The task's registers are gone.
export fn riscv_stack_fault(sp: u64, pc: u64, scause: u64, stval: u64, ra: u64, fp: u64) callconv(.c) noreturn {
    exec.kprintf("\n*** trap on a stack with no room: sp 0x%016lx, pc 0x%016lx, cause 0x%016lx, address 0x%016lx, ra 0x%016lx, fp 0x%016lx\n", .{ sp, pc, scause, stval, ra, fp });
    var info: exec.TrapInfo = .{
        .number = @truncate(scause & cpu.SCAUSE_CODE),
        .pc = pc,
        .address = stval,
        .frame = null,
    };
    exec.alert_hook.*(sdk.exec.AT_DeadEnd | sdk.exec.AN_StackProbe, pc, &info, "a trap on a stack with no room");
    cpu.halt();
}

/// An exception before exec is up: the frame, and the machine stops.
fn fatal(frame: *const Frame) noreturn {
    _ = cpu.disableInterrupts();
    const code: u32 = @truncate(frame.scause & cpu.SCAUSE_CODE);
    exec.kprintf("\n*** FATAL EXCEPTION %d (%s)\n", .{ code, causeName(code).ptr });
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
    printLine(put, data, "  PC   0x%016lx  SSTATUS 0x%016lx\n  CAUSE 0x%016lx STVAL 0x%016lx\n", .{ frame.sepc, frame.sstatus, frame.scause, frame.stval });
    for (0..8) |row| {
        printLine(put, data, " ", .{});
        for (0..4) |col| {
            const index = row * 4 + col;
            printLine(put, data, " %-4s %016lx", .{ register_names[index].ptr, frame.x[index] });
        }
        printLine(put, data, "\n", .{});
    }
}

fn printLine(put: sdk.exec.PutChProc, data: ?*anyopaque, comptime format: [:0]const u8, args: anytype) void {
    const stream = sdk.exec.fmtStream(args);
    _ = exec.format(format, &stream, put, data);
}
