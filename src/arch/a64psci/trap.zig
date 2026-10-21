// SPDX-License-Identifier: MPL-2.0
//! Exception and interrupt dispatch. start.S saves the interrupted context
//! into a `Frame` and calls `a64_exception` for every exception the
//! kernel takes: a synchronous one (by its class in ESR_EL1), an IRQ, an
//! FIQ or an SError.
//!
//! **The syscall is an `svc #0`**, the number in x0 and its argument in
//! x1, the answer in x0. From EL1 it is taken at EL1, as a synchronous
//! exception of its own class, and ELR_EL1 already points past it. It is
//! taken whether or not the core's interrupts are masked, which the
//! syscall needs.
//!
//! **The interrupts** are the GIC's (gic.zig): an IRQ is taken by
//! acknowledging the highest pending interrupt, and each core has a
//! handler per SGI and PPI - the software-generated interrupts that carry
//! exec's Cause and the cross-core interrupt, and the timer's - its
//! "lines" here, as the interrupt codes are under SBI.

const std = @import("std");
const cpu = @import("cpu.zig");
const sdk = @import("sdk");
const exec = @import("../../rom/libs/exec/exec.zig");
const exec_base = @import("../../rom/libs/exec/exec_base.zig");
const exec_cache = @import("../../rom/libs/exec/cache/_cache.zig");

const max_cores = exec_base.max_cores;

/// Layout shared with start.S: x0 to x30 and the interrupted stack
/// pointer (x[31]), the exception's registers, the FPU's control and
/// status, and the 32 vector registers.
pub const Frame = extern struct {
    x: [32]u64,
    elr: u64,
    spsr: u64,
    esr: u64,
    far: u64,
    fpcr: u64,
    fpsr: u64,
    q: [32]u128 align(16),
};

comptime {
    std.debug.assert(@sizeOf(Frame) == 816);
    std.debug.assert(@sizeOf(Frame) % 16 == 0);
    std.debug.assert(@offsetOf(Frame, "elr") == 256);
    std.debug.assert(@offsetOf(Frame, "esr") == 272);
    std.debug.assert(@offsetOf(Frame, "fpcr") == 288);
    std.debug.assert(@offsetOf(Frame, "q") == 304);
}

/// The frame sits this far below the interrupted stack pointer (start.S
/// FRAME_SIZE).
pub const frame_offset = @sizeOf(Frame);

/// What came, as start.S says: its vectors' order.
pub const Kind = enum(u64) {
    sync = 0,
    irq = 1,
    fiq = 2,
    serror = 3,
    _,
};

/// The interrupts a core has of its own, by their IDs - the SGIs and the
/// PPIs - each core's handlers.
pub const line_count = 32;
pub const Handler = *const fn (line: u6) void;
var handlers: [max_cores][line_count]?Handler = @splat(@splat(null));

/// `handler` for interrupt `line` (an SGI or PPI) of the core this runs on.
pub fn setHandler(line: u6, handler: Handler) void {
    handlers[cpu.coreId()][line] = handler;
}

/// The core's own interrupt `line` served, if it has a handler; whether it
/// did.
pub fn dispatchLine(line: u6) bool {
    if (line >= line_count) return false;
    const handler = handlers[cpu.coreId()][line] orelse return false;
    const began = cpu.ccount();
    handler(line);
    const core = cpu.coreId();
    line_longest[core][line] = @max(line_longest[core][line], cpu.ccount() -% began);
    return true;
}

/// The IRQ's own handler: the GIC's (gic.zig), set as the kernel starts.
pub var irq_handler: *const fn () void = &noIrq;

fn noIrq() void {}

/// The exception classes (ESR_EL1.EC) the kernel tells apart.
pub const Class = enum(u32) {
    unknown = 0x00,
    wfi_wfe = 0x01,
    fp_access = 0x07,
    illegal_state = 0x0E,
    svc = 0x15,
    hvc = 0x16,
    smc = 0x17,
    msr_mrs = 0x18,
    sve_access = 0x19,
    pointer_auth = 0x1C,
    instruction_abort_lower = 0x20,
    instruction_abort = 0x21,
    pc_alignment = 0x22,
    data_abort_lower = 0x24,
    data_abort = 0x25,
    sp_alignment = 0x26,
    fp_exception = 0x2C,
    serror = 0x2F,
    breakpoint_lower = 0x30,
    breakpoint = 0x31,
    step_lower = 0x32,
    step = 0x33,
    watchpoint_lower = 0x34,
    watchpoint = 0x35,
    brk = 0x3C,
    _,
};

pub const Syscall = enum(u32) {
    ping = 0,
    /// Enter the kernel so exec can switch tasks on the way out.
    reschedule = 3,
    /// End a task exception: resume the frame in `arg` instead.
    leave_exception = 4,
    _,
};

/// Set by the leave_exception syscall, each core's own.
var resume_frame: [max_cores]?*Frame = @splat(null);

/// Trap into the kernel with `syscall`; the result comes back in x0.
pub fn syscall(nr: u32, arg: usize) usize {
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> usize),
        : [nr] "{x0}" (@as(usize, nr)),
          [arg] "{x1}" (arg),
        : .{ .memory = true });
}

/// The longest exception each core has taken, in cycles, its cause (the
/// class, bit 31 set for an interrupt) and the interrupt it served (bit
/// n for SGI or PPI n), and the longest each of those ran; the shell's
/// `cores` shows them.
pub var longest: [max_cores]u32 = @splat(0);
pub var longest_cause: [max_cores]u32 = @splat(0);
pub var longest_lines: [max_cores]u32 = @splat(0);
pub var line_longest: [max_cores][line_count]u32 = @splat(@splat(0));
/// The SGI or PPI the last IRQ on each core was, for `longest_lines`.
pub var last_line: [max_cores]u32 = @splat(0);

/// Called by start.S for every exception. Returns the frame to resume:
/// `frame` itself, or another task's when exec switched tasks.
export fn a64_exception(frame: *Frame, kind: Kind) callconv(.c) *Frame {
    if (!exec.initialized) {
        handle(frame, kind);
        return frame;
    }
    const began = cpu.ccount();
    exec.interruptEnter(exec.SysBase);
    handle(frame, kind);
    const core = cpu.coreId();
    const current = resume_frame[core] orelse frame;
    resume_frame[core] = null;
    const resumed: *Frame = @ptrCast(@alignCast(exec.interruptExit(exec.SysBase, current)));
    const took = cpu.ccount() -% began;
    if (took > longest[core]) {
        longest[core] = took;
        const interrupt = kind != .sync;
        longest_cause[core] = if (interrupt) @as(u32, @truncate(@intFromEnum(kind))) | @as(u32, 1) << 31 else classOf(frame.esr);
        longest_lines[core] = if (interrupt) last_line[core] else 0;
    }
    // Code another core has loaded since this one last synchronised its
    // instruction fetch: synchronised before anything is resumed.
    exec_cache.syncFetch(core);
    return resumed;
}

/// The class of an exception, from its syndrome.
pub fn classOf(esr: u64) u32 {
    return @truncate((esr >> cpu.ESR_EC_SHIFT) & cpu.ESR_EC_MASK);
}

fn handle(frame: *Frame, kind: Kind) void {
    switch (kind) {
        .irq, .fiq => {
            irq_handler();
            return;
        },
        .serror => {
            // Asynchronous: what caused it ran some time before, and ELR is
            // only where the core was when it came.
            if (!exec.initialized) fatal(frame, "SError");
            var info: exec.TrapInfo = .{
                .number = @intFromEnum(Class.serror),
                .pc = frame.elr,
                .address = frame.esr,
                .frame = frame,
            };
            exec.dispatchTrap(exec.SysBase, &info);
            frame.elr = info.pc;
            return;
        },
        .sync => {},
        _ => fatal(frame, "an exception from no vector"),
    }
    const class = classOf(frame.esr);
    if (class == @intFromEnum(Class.svc)) {
        // ELR is past the svc already.
        frame.x[0] = handleSyscall(@enumFromInt(@as(u32, @truncate(frame.x[0]))), frame.x[1]);
        return;
    }
    // A breakpoint, a watchpoint, the step or a `brk`: the ROM debugger's.
    switch (@as(Class, @enumFromInt(class))) {
        .breakpoint, .step, .watchpoint, .brk => return @import("debugexc.zig").onDebug(frame, @enumFromInt(class)),
        else => {},
    }
    // Before exec is up there is nobody to ask.
    if (!exec.initialized) fatal(frame, "an exception before exec");
    var info: exec.TrapInfo = .{
        .number = class,
        .pc = frame.elr,
        .address = frame.far,
        .frame = frame,
    };
    exec.dispatchTrap(exec.SysBase, &info); // returns if the trap code handled it, or the task was held
    frame.elr = info.pc;
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

/// The name of an exception's class (ESR_EL1.EC).
pub fn causeName(code: u32) [:0]const u8 {
    return switch (@as(Class, @enumFromInt(code))) {
        .unknown => "undefined instruction",
        .wfi_wfe => "wfi or wfe trapped",
        .fp_access => "FPU access trapped",
        .illegal_state => "illegal execution state",
        .svc => "svc",
        .hvc => "hvc",
        .smc => "smc",
        .msr_mrs => "system register access",
        .sve_access => "SVE access trapped",
        .pointer_auth => "pointer authentication",
        .instruction_abort_lower, .instruction_abort => "instruction abort",
        .pc_alignment => "pc misaligned",
        .data_abort_lower, .data_abort => "data abort",
        .sp_alignment => "sp misaligned",
        .fp_exception => "floating-point exception",
        .serror => "SError",
        .breakpoint_lower, .breakpoint => "breakpoint",
        .step_lower, .step => "software step",
        .watchpoint_lower, .watchpoint => "watchpoint",
        .brk => "brk",
        _ => "unknown",
    };
}

/// An exception that came on a stack with no room for its frame, from
/// start.S on the core's fault stack: what it had of where it was - the
/// stack pointer, pc, syndrome, address, link register and frame pointer
/// - and a dead end. The task's registers are gone.
export fn a64_stack_fault(sp: u64, pc: u64, esr: u64, far: u64, lr: u64, fp: u64) callconv(.c) noreturn {
    exec.kprintf("\n*** exception on a stack with no room: sp 0x%016lx, pc 0x%016lx, syndrome 0x%016lx, address 0x%016lx, lr 0x%016lx, fp 0x%016lx\n", .{ sp, pc, esr, far, lr, fp });
    if (!exec.initialized) cpu.halt();
    var info: exec.TrapInfo = .{
        .number = classOf(esr),
        .pc = pc,
        .address = far,
        .frame = null,
    };
    exec.alert_hook.*(sdk.exec.AT_DeadEnd | sdk.exec.AN_StackProbe, pc, &info, "an exception on a stack with no room");
    cpu.halt();
}

/// A vector that is never taken - from SP_EL0, or from a lower level -
/// from start.S on the core's fault stack, and the machine stops.
export fn a64_unexpected(sp: u64, pc: u64, esr: u64, far: u64, lr: u64, fp: u64, vector: u64) callconv(.c) noreturn {
    _ = cpu.disableInterrupts();
    exec.kprintf("\n*** FATAL: vector %ld taken: sp 0x%016lx, pc 0x%016lx, syndrome 0x%016lx, address 0x%016lx, lr 0x%016lx, fp 0x%016lx\n*** system halted\n", .{ vector, sp, pc, esr, far, lr, fp });
    cpu.halt();
}

/// An exception before exec is up: the frame, and the machine stops.
fn fatal(frame: *const Frame, what: [*:0]const u8) noreturn {
    _ = cpu.disableInterrupts();
    const class = classOf(frame.esr);
    exec.kprintf("\n*** FATAL EXCEPTION: %s, class 0x%02x (%s)\n", .{ what, class, causeName(class).ptr });
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

/// The frame written a character at a time through `put`, so that
/// whoever asked decides where it goes.
pub fn dumpFrameTo(frame: *const Frame, put: sdk.exec.PutChProc, data: ?*anyopaque) void {
    printLine(put, data, "  PC  0x%016lx  SPSR 0x%016lx  SP 0x%016lx\n  ESR 0x%016lx  FAR  0x%016lx\n", .{ frame.elr, frame.spsr, frame.x[31], frame.esr, frame.far });
    var row: usize = 0;
    while (row < 8) : (row += 1) {
        printLine(put, data, " ", .{});
        for (0..4) |col| {
            const index = row * 4 + col;
            if (index == 31) break;
            if (index == 29) {
                printLine(put, data, "  fp %016lx", .{frame.x[index]});
            } else if (index == 30) {
                printLine(put, data, "  lr %016lx", .{frame.x[index]});
            } else {
                printLine(put, data, " x%-2ld %016lx", .{ @as(u64, index), frame.x[index] });
            }
        }
        printLine(put, data, "\n", .{});
    }
}

fn printLine(put: sdk.exec.PutChProc, data: ?*anyopaque, comptime format: [:0]const u8, args: anytype) void {
    const stream = sdk.exec.fmtStream(args);
    _ = exec.format(format, &stream, put, data);
}
