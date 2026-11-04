// SPDX-License-Identifier: MPL-2.0
//! The descriptor tables the core reads: the task segment, which is what
//! holds the stacks an exception may be switched to, and the interrupt
//! descriptor table, which says where each of the 256 vectors goes.
//!
//! start.S loads a global descriptor table of the kernel's own before
//! anything else - the firmware's is in memory that is about to be handed
//! out - with a null entry, one code segment, one data segment and room
//! for a task segment per core. The rest is here, because it wants
//! addresses that are not known until the kernel runs: each core's task
//! segment is filled and its descriptor written into that table, and the
//! interrupt descriptor table is built from the stubs start.S laid out at
//! a fixed stride.
//!
//! **What the task segment is for.** Nothing here changes privilege level,
//! so the stacks a task segment names for that are never used; what it is
//! wanted for is the interrupt stack table. A core pushes an exception's
//! first words at the stack pointer it had, whatever that was - so an
//! exception on a stack that has run out faults again as it is taken, and
//! again on that, which is a double fault. The three exceptions that mean
//! the machine is in no state to be trusted with its own stack - the
//! double fault, the non-maskable interrupt and the machine check - are
//! given a stack of the core's own through that table, so there is always
//! one place a Guru can be written from.

const std = @import("std");
const cpu = @import("cpu.zig");
const exec_base = @import("../../rom/libs/exec/exec_base.zig");
const trap = @import("trap.zig");

const max_cores = exec_base.max_cores;

/// The selectors start.S set up.
pub const GDT_CODE: u16 = 0x08;
pub const GDT_DATA: u16 = 0x10;
/// Where the task segments' descriptors start in that table, and how far
/// apart they are: each is two entries, since a system descriptor holds a
/// 64-bit address.
const gdt_tss_first: usize = 3;

/// How far apart the vectors' stubs are (start.S STUB_STRIDE).
const stub_stride: usize = 16;

/// The stacks start.S set aside, one per core, for an exception taken with
/// no room on the stack it came on (start.S FAULT_STACK_SIZE).
const fault_stack_size: usize = 4096;

extern var x64_gdt: [gdt_tss_first + 2 * max_cores]u64;
extern const x64_isr_stubs: [256 * stub_stride]u8;
extern var x64_fault_stacks: [max_cores * fault_stack_size]u8;

/// A task segment as the architecture reads it: the stacks for a change of
/// privilege level, which nothing here makes, then the seven of the
/// interrupt stack table. None of its fields is on its natural boundary,
/// which is why each says its own alignment.
pub const TaskSegment = extern struct {
    reserved0: u32 = 0,
    /// The stacks for privilege levels 0 to 2.
    rsp: [3]u64 align(4) = @splat(0),
    reserved1: u64 align(4) = 0,
    /// The interrupt stack table, 1 to 7 as the vectors name them.
    ist: [7]u64 align(4) = @splat(0),
    reserved2: u64 align(4) = 0,
    reserved3: u16 = 0,
    /// Where the I/O permission map is, past the end of the segment: none.
    io_map_base: u16 = @sizeOf(TaskSegment),
};

comptime {
    std.debug.assert(@sizeOf(TaskSegment) == 104);
    std.debug.assert(@offsetOf(TaskSegment, "rsp") == 4);
    std.debug.assert(@offsetOf(TaskSegment, "ist") == 36);
    std.debug.assert(@offsetOf(TaskSegment, "io_map_base") == 102);
}

/// Each core's. Only core 0's is used until the other cores start.
pub var segments: [max_cores]TaskSegment = @splat(.{});

/// One of the 256 vectors: where it goes, with which code segment, and
/// which stack of the interrupt stack table it is taken on.
pub const Gate = extern struct {
    offset_low: u16 = 0,
    selector: u16 = 0,
    /// The interrupt stack table's entry, 1 to 7; 0 for the stack it came
    /// on.
    ist: u8 = 0,
    /// Present, this privilege level, a 64-bit interrupt gate.
    flags: u8 = 0,
    offset_middle: u16 = 0,
    offset_high: u32 = 0,
    reserved: u32 = 0,
};

comptime {
    std.debug.assert(@sizeOf(Gate) == 16);
}

/// Present, privilege level 0, type 14: an interrupt gate, which is taken
/// with this core's interrupts masked. Everything here is taken that way -
/// the exception entry wants them masked, and so does the syscall.
const GATE_INTERRUPT: u8 = 0x8E;

/// The stack of the interrupt stack table an exception is taken on: the
/// core's own for the three that mean its stack cannot be trusted, and the
/// stack it came on for everything else.
const IST_FAULT: u8 = 1;

pub var idt: [256]Gate = @splat(.{});

/// The pointer `lidt` and `lgdt` read: a limit and a base, with the base
/// two bytes in and so on no boundary of its own.
const TablePointer = extern struct {
    limit: u16,
    base: u64 align(2),
};

comptime {
    std.debug.assert(@sizeOf(TablePointer) == 10);
}

var idt_pointer: TablePointer = .{ .limit = 0, .base = 0 };

/// Where the stub of `vector` is: start.S laid them out at a fixed stride
/// so that this is arithmetic and not a table of 256 addresses.
fn stubOf(vector: usize) usize {
    return @intFromPtr(&x64_isr_stubs) + stub_stride * vector;
}

/// The core's task segment filled and its descriptor written, the segment
/// loaded, and the interrupt descriptor table built and loaded. Called on
/// each core as it starts, before its interrupts are let in; the table
/// itself is built once, by core 0, and every core loads the same one.
pub fn setUp() void {
    const core = cpu.coreId();
    const fault_top = @intFromPtr(&x64_fault_stacks) + (core + 1) * fault_stack_size;
    segments[core] = .{};
    // The stack the three worst exceptions are taken on. It is the same
    // one start.S switches to for an exception that came with no room on
    // its own stack: both of them end in a Guru and a machine that stops,
    // so neither has to leave the other's anything.
    segments[core].ist[IST_FAULT - 1] = fault_top & ~@as(u64, 15);
    writeSegmentDescriptor(core);
    const selector: u16 = @intCast(8 * (gdt_tss_first + 2 * core));
    asm volatile ("ltr %[selector]"
        :
        : [selector] "r" (selector),
        : .{ .memory = true });

    if (core == 0) {
        for (&idt, 0..) |*gate, vector| {
            const at = stubOf(vector);
            gate.* = .{
                .offset_low = @truncate(at),
                .selector = GDT_CODE,
                .ist = switch (vector) {
                    @intFromEnum(trap.Class.nmi),
                    @intFromEnum(trap.Class.double_fault),
                    @intFromEnum(trap.Class.machine_check),
                    => IST_FAULT,
                    else => 0,
                },
                .flags = GATE_INTERRUPT,
                .offset_middle = @truncate(at >> 16),
                .offset_high = @truncate(at >> 32),
            };
        }
        idt_pointer = .{ .limit = @sizeOf(@TypeOf(idt)) - 1, .base = @intFromPtr(&idt) };
    }
    asm volatile ("lidt %[pointer]"
        :
        : [pointer] "*p" (&idt_pointer),
        : .{ .memory = true });
}

/// Core `core`'s task segment descriptor into the table start.S loaded:
/// present, an available 64-bit task segment, the segment's address split
/// across the two entries the architecture splits it across.
fn writeSegmentDescriptor(core: u32) void {
    const base = @intFromPtr(&segments[core]);
    const limit: u64 = @sizeOf(TaskSegment) - 1;
    const access: u64 = 0x89; // present, type 9: an available 64-bit task segment
    x64_gdt[gdt_tss_first + 2 * core] =
        (limit & 0xFFFF) |
        ((base & 0xFFFF) << 16) |
        (((base >> 16) & 0xFF) << 32) |
        (access << 40) |
        (((limit >> 16) & 0xF) << 48) |
        (((base >> 24) & 0xFF) << 56);
    x64_gdt[gdt_tss_first + 2 * core + 1] = base >> 32;
}
