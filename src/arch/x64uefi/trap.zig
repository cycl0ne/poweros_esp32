// SPDX-License-Identifier: MPL-2.0
//! Exception and interrupt dispatch. start.S has a stub for each of the
//! architecture's 256 interrupt vectors; every one of them saves the
//! interrupted context into a `Frame` and calls `x64_exception`, which
//! sorts out what came by the vector it came on: one of the core's
//! exceptions (the first 32), the kernel's own interrupts above them, or a
//! device's.
//!
//! **The syscall is a software interrupt**, `int $35`, the number in RAX
//! and its argument in RDX, the answer in RAX. It is a vector of the
//! kernel's own, which no firmware and no device shares - the `syscall`
//! instruction would do as well and would want a model register set up per
//! core for no gain, since this is not a path anything takes often.
//!
//! **The vectors.** The first 32 are the architecture's: a core's
//! exceptions, and they are not ours to choose. Above them the kernel
//! keeps sixteen of its own - the tick, exec's Cause, the poke to another
//! core, the syscall, and the one the local controller sends when it has
//! nothing - and above those it hands one to each interrupt source a
//! driver asks for, so that a vector says which source it is
//! (`apic.vectorOf`). What exec and the drivers deal in is the source, as
//! on every other chip; the vectors are this kernel's own business.
//!
//! **The frame** is the whole interrupted context: the five words the core
//! pushes itself, the vector and the error code the stub adds, every
//! general register, and the SSE state. All of it each time - there is no
//! telling whether the interrupted code used any of it - and the SSE state
//! because the compiler's code copies memory with the vector registers.

const std = @import("std");
const cpu = @import("cpu.zig");
const sdk = @import("sdk");
const exec = @import("../../rom/libs/exec/exec.zig");
const exec_base = @import("../../rom/libs/exec/exec_base.zig");
const exec_cache = @import("../../rom/libs/exec/cache/_cache.zig");

const max_cores = cpu.max_cores;

/// Layout shared with start.S: the SSE state lowest, then the general
/// registers in the order they are pushed, the vector and its error code,
/// and the five words the core pushed itself.
pub const Frame = extern struct {
    /// FXSAVE's area: the x87 and SSE state. 16-byte aligned, which is
    /// what the instruction wants.
    fx: [512]u8 align(16),
    r15: u64,
    r14: u64,
    r13: u64,
    r12: u64,
    r11: u64,
    r10: u64,
    r9: u64,
    r8: u64,
    rbp: u64,
    rdi: u64,
    rsi: u64,
    rdx: u64,
    rcx: u64,
    rbx: u64,
    rax: u64,
    /// Which vector it came on, pushed by that vector's stub.
    vector: u64,
    /// The error code the core pushes for the exceptions that have one,
    /// and 0 where the stub pushed it instead.
    error_code: u64,
    /// Where it goes on, and with what: the core's own five words.
    rip: u64,
    cs: u64,
    rflags: u64,
    rsp: u64,
    ss: u64,
};

comptime {
    std.debug.assert(@sizeOf(Frame) == 688);
    std.debug.assert(@sizeOf(Frame) % 16 == 0);
    std.debug.assert(@offsetOf(Frame, "r15") == 512);
    std.debug.assert(@offsetOf(Frame, "rax") == 624);
    std.debug.assert(@offsetOf(Frame, "vector") == 632);
    std.debug.assert(@offsetOf(Frame, "rip") == 648);
    std.debug.assert(@offsetOf(Frame, "ss") == 680);
}

/// The frame sits this far below the interrupted stack pointer (start.S
/// FRAME_SIZE).
pub const frame_offset = @sizeOf(Frame);

/// The exceptions, by their vector. The ones with no name of their own
/// are reserved by the architecture and are never taken.
pub const Class = enum(u32) {
    divide = 0,
    debug = 1,
    nmi = 2,
    breakpoint = 3,
    overflow = 4,
    bound_range = 5,
    invalid_opcode = 6,
    no_fpu = 7,
    double_fault = 8,
    invalid_tss = 10,
    segment_absent = 11,
    stack_segment = 12,
    protection = 13,
    page_fault = 14,
    fpu_error = 16,
    alignment = 17,
    machine_check = 18,
    sse_error = 19,
    virtualisation = 20,
    control_protection = 21,
    _,
};

/// One past the highest vector that is an exception of the core's.
pub const exception_count = 32;

/// The kernel's own interrupt vectors, after the exceptions. `line_count`
/// of them, so that a vector is line `vector - own_first`.
pub const own_first = exception_count;
pub const line_count = 16;

pub const Handler = *const fn (line: u6) void;
var handlers: [max_cores][line_count]?Handler = @splat(@splat(null));

/// `handler` for the kernel's own interrupt `line` on the core this runs
/// on: the tick's, exec's Cause, the poke from another core.
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

/// What a device's interrupt goes to: the controller's (apic.zig), set as
/// the kernel starts.
pub var source_handler: *const fn (vector: u32) void = &noSource;

fn noSource(_: u32) void {}

/// What the controller is told when an interrupt has been served, which
/// the exception exit does for every vector but its own spurious one:
/// the controller's (apic.zig).
pub var end_of_interrupt: *const fn () void = &noEnd;

fn noEnd() void {}

/// The vector the controller sends when it has nothing to send, which has
/// no end of its own: the controller sets it (apic.zig).
pub var spurious_vector: u32 = 0xFF;

pub const Syscall = enum(u32) {
    ping = 0,
    /// Enter the kernel so exec can switch tasks on the way out.
    reschedule = 3,
    /// End a task exception: resume the frame in `arg` instead.
    leave_exception = 4,
    _,
};

/// The vector the syscall is taken on: one of the kernel's own.
pub const syscall_vector = own_first + 3;

/// Set by the leave_exception syscall, each core's own.
var resume_frame: [max_cores]?*Frame = @splat(null);

/// Trap into the kernel with `syscall`; the result comes back in RAX. It
/// is taken whether or not the core's interrupts are masked, which the
/// syscall needs.
pub fn syscall(nr: u32, arg: usize) usize {
    return asm volatile (std.fmt.comptimePrint("int ${d}", .{syscall_vector})
        : [ret] "={rax}" (-> usize),
        : [nr] "{rax}" (@as(usize, nr)),
          [arg] "{rdx}" (arg),
        : .{ .memory = true });
}

/// The longest exception each core has taken, in cycles, its cause (the
/// vector, bit 31 set for an interrupt) and which of the kernel's own
/// interrupts it served (bit n for line n), and the longest each of those
/// ran; the shell's `cores` shows them. A device's interrupt is counted
/// per source instead (`apic.source_longest`).
pub var longest: [max_cores]u32 = @splat(0);
pub var longest_cause: [max_cores]u32 = @splat(0);
pub var longest_lines: [max_cores]u32 = @splat(0);
pub var line_longest: [max_cores][line_count]u32 = @splat(@splat(0));
/// Which of the kernel's own interrupts the last one on each core was,
/// for `longest_lines`.
pub var last_line: [max_cores]u32 = @splat(0);

/// Called by start.S for every exception and every interrupt. Returns the
/// frame to resume: `frame` itself, or another task's when exec switched
/// tasks.
export fn x64_exception(frame: *Frame) callconv(.c) *Frame {
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
        const interrupt = frame.vector >= own_first;
        longest_cause[core] = @as(u32, @truncate(frame.vector)) | if (interrupt) @as(u32, 1) << 31 else 0;
        longest_lines[core] = if (interrupt) last_line[core] else 0;
    }
    // Code another core has loaded since this one last synchronised its
    // instruction fetch: synchronised before anything is resumed, which
    // on this machine the `iretq` below already is.
    exec_cache.syncFetch(core);
    return resumed;
}

fn handle(frame: *Frame) void {
    const vector: u32 = @truncate(frame.vector);
    // The one vector that is not an interrupt the controller sent: it has
    // no end, and nothing asked for it.
    if (vector == spurious_vector) return;
    // The syscall is a software interrupt: nothing is in service at the
    // controller, so it gets no end of interrupt - one sent here would
    // end whatever interrupt the syscall came in the middle of.
    if (vector == syscall_vector) {
        frame.rax = handleSyscall(@enumFromInt(@as(u32, @truncate(frame.rax))), frame.rdx);
        return;
    }
    if (vector >= own_first) {
        // After the handler, not before: a line a device still holds down
        // comes again as soon as the controller is told, so it is told
        // once the device has been quieted.
        defer end_of_interrupt();
        if (vector < own_first + line_count) {
            const core = cpu.coreId();
            const line: u6 = @intCast(vector - own_first);
            last_line[core] = @as(u32, 1) << @intCast(line);
            if (!dispatchLine(line)) {
                exec.kprintf("\n[trap] nothing on the kernel's vector %d on core %d\n", .{ vector, core });
            }
            return;
        }
        source_handler(vector);
        return;
    }
    // Before exec is up there is nobody to ask.
    if (!exec.initialized) fatal(frame, "an exception before exec");
    var info: exec.TrapInfo = .{
        .number = vector,
        .pc = frame.rip,
        .address = if (vector == @intFromEnum(Class.page_fault)) cpu.faultAddress() else frame.error_code,
        .frame = frame,
    };
    exec.dispatchTrap(exec.SysBase, &info); // returns if the trap code handled it, or the task was held
    frame.rip = info.pc;
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

/// The name of an exception's vector.
pub fn causeName(code: u32) [:0]const u8 {
    return switch (@as(Class, @enumFromInt(code))) {
        .divide => "divide by zero",
        .debug => "debug exception",
        .nmi => "non-maskable interrupt",
        .breakpoint => "breakpoint",
        .overflow => "overflow",
        .bound_range => "bound range exceeded",
        .invalid_opcode => "illegal instruction",
        .no_fpu => "FPU not available",
        .double_fault => "double fault",
        .invalid_tss => "invalid task segment",
        .segment_absent => "segment not present",
        .stack_segment => "stack segment fault",
        .protection => "general protection fault",
        .page_fault => "page fault",
        .fpu_error => "floating-point exception",
        .alignment => "misaligned access",
        .machine_check => "machine check",
        .sse_error => "SSE exception",
        .virtualisation => "virtualisation exception",
        .control_protection => "control protection fault",
        _ => "unknown",
    };
}

/// An exception that came on a stack with no room for its frame, from
/// start.S on the core's fault stack: what it had of where it was - the
/// stack pointer, pc, the vector, its error code and the frame pointer -
/// and a dead end. The task's registers are gone.
export fn x64_stack_fault(sp: u64, pc: u64, vector: u64, error_code: u64, fp: u64) callconv(.c) noreturn {
    exec.kprintf("\n*** exception on a stack with no room: sp 0x%016lx, pc 0x%016lx, vector %ld, error 0x%lx, fp 0x%016lx\n", .{ sp, pc, vector, error_code, fp });
    if (!exec.initialized) cpu.halt();
    var info: exec.TrapInfo = .{
        .number = @truncate(vector),
        .pc = pc,
        .address = error_code,
        .frame = null,
    };
    exec.alert_hook.*(sdk.exec.AT_DeadEnd | sdk.exec.AN_StackProbe, pc, &info, "an exception on a stack with no room");
    cpu.halt();
}

/// An exception before exec is up: the frame, and the machine stops.
fn fatal(frame: *const Frame, what: [*:0]const u8) noreturn {
    _ = cpu.disableInterrupts();
    const vector: u32 = @truncate(frame.vector);
    exec.kprintf("\n*** FATAL EXCEPTION: %s, vector %d (%s)\n", .{ what, vector, causeName(vector).ptr });
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

/// The registers of the frame, in the order they are written about.
const names = [_][:0]const u8{ "rax", "rbx", "rcx", "rdx", "rsi", "rdi", "rbp", "rsp", "r8 ", "r9 ", "r10", "r11", "r12", "r13", "r14", "r15" };

fn registerOf(frame: *const Frame, index: usize) u64 {
    return switch (index) {
        0 => frame.rax,
        1 => frame.rbx,
        2 => frame.rcx,
        3 => frame.rdx,
        4 => frame.rsi,
        5 => frame.rdi,
        6 => frame.rbp,
        7 => frame.rsp,
        8 => frame.r8,
        9 => frame.r9,
        10 => frame.r10,
        11 => frame.r11,
        12 => frame.r12,
        13 => frame.r13,
        14 => frame.r14,
        else => frame.r15,
    };
}

/// The frame written a character at a time through `put`, so that
/// whoever asked decides where it goes.
pub fn dumpFrameTo(frame: *const Frame, put: sdk.exec.PutChProc, data: ?*anyopaque) void {
    printLine(put, data, "  RIP 0x%016lx  RFLAGS 0x%016lx  CS 0x%04lx  SS 0x%04lx\n  vector %ld (%s), error 0x%lx\n", .{
        frame.rip,
        frame.rflags,
        frame.cs,
        frame.ss,
        frame.vector,
        causeName(@truncate(frame.vector)).ptr,
        frame.error_code,
    });
    var row: usize = 0;
    while (row < 4) : (row += 1) {
        printLine(put, data, " ", .{});
        for (0..4) |column| {
            const index = row * 4 + column;
            printLine(put, data, "  %s %016lx", .{ names[index].ptr, registerOf(frame, index) });
        }
        printLine(put, data, "\n", .{});
    }
}

fn printLine(put: sdk.exec.PutChProc, data: ?*anyopaque, comptime format: [:0]const u8, args: anytype) void {
    const stream = sdk.exec.fmtStream(args);
    _ = exec.format(format, &stream, put, data);
}
