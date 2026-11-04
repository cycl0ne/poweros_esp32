// SPDX-License-Identifier: MPL-2.0
//! The core's own registers and the instructions exec's hardware needs of
//! it: which core this is, its interrupts on and off, its sleep until the
//! next one, the control registers the map and the FPU are switched with,
//! and what the descriptor tables are set to.
//!
//! **Which core this is, is kept in GS.** The architecture has no register
//! that answers it: a core's identity is its local interrupt controller's
//! id, which is a load from a device and a search through a table. So each
//! core is given a block of its own as it starts (`core_blocks`) and GS's
//! base is set to it, and the core's number is the first word in it - one
//! load, `%gs:0`, which is what exec asks for on every lock it takes. GS
//! is free on this machine: nothing else here uses it, there is no code
//! outside the kernel's own privilege level, and the exception exit never
//! reloads it, so a task that moves to another core finds that core's
//! number there.
//!
//! A core's interrupts are RFLAGS.IF: clearing it holds every interrupt
//! off on this core, which is what Disable and the exception entry want.
//! The entry clears it by the gate it comes through, and the `iretq` that
//! leaves puts back what the resumed frame holds.

const exec_base = @import("../../rom/libs/exec/exec_base.zig");
const hardware = @import("sdk").hardware;

pub const ccount = hardware.cpu.ccount;
pub const cycles = hardware.cpu.cycles;
pub const relax = hardware.cpu.relax;
pub const readMsr = hardware.cpu.readMsr;
pub const writeMsr = hardware.cpu.writeMsr;
pub const leaf = hardware.cpu.leaf;
pub const FLAGS_IF = hardware.cpu.FLAGS_IF;

/// GS's base, which the core sets to its own block as it starts.
pub const MSR_GS_BASE: u32 = 0xC000_0101;

/// What a core keeps of its own, reached through GS. Its number is first
/// because that is what is read; the rest is here so that a core's block
/// is one place and not several.
pub const CoreBlock = extern struct {
    /// The core's number, 0 up: `%gs:0`.
    core: u64 = 0,
    /// Its local interrupt controller's id, as the machine numbers it.
    lapic_id: u64 = 0,
};

/// Each core's block. Core 0's is set up by `takeCore` before anything
/// reads it, and the entry points GS at the array before that: it is
/// exported because the entry takes its address (start.S).
pub export var core_blocks: [exec_base.max_cores]CoreBlock = @splat(.{});

/// Each core's local controller id, as the firmware's tables name them;
/// core 0's is read from its own controller.
pub var lapic_ids: [exec_base.max_cores]u32 = @splat(0);

/// This core made core `core`: its block filled and GS pointed at it, so
/// `coreId` answers from here on. Nothing may read the core's number
/// before this.
pub fn takeCore(core: u32, lapic_id: u32) void {
    core_blocks[core] = .{ .core = core, .lapic_id = lapic_id };
    lapic_ids[core] = lapic_id;
    writeMsr(MSR_GS_BASE, @intFromPtr(&core_blocks[core]));
}

/// The core this runs on: 0 up.
pub inline fn coreId() u32 {
    return @truncate(asm volatile ("movq %%gs:0, %[r]"
        : [r] "=r" (-> u64),
    ));
}

/// This core's interrupts masked; answers RFLAGS as it was, for
/// `restoreInterrupts`. Read and cleared in one instruction stream, so
/// nothing comes between.
pub inline fn disableInterrupts() u32 {
    return @truncate(asm volatile (
        \\pushfq
        \\popq %[r]
        \\cli
        : [r] "=r" (-> u64),
        :
        : .{ .memory = true }));
}

/// The interrupts as `disableInterrupts` found them: on again only if they
/// were on.
pub inline fn restoreInterrupts(saved: u32) void {
    if (saved & FLAGS_IF != 0) asm volatile ("sti" ::: .{ .memory = true });
}

pub inline fn enableInterrupts() void {
    asm volatile ("sti" ::: .{ .memory = true });
}

/// Whether this core takes interrupts now.
pub inline fn interruptsOn() bool {
    const flags = asm volatile (
        \\pushfq
        \\popq %[r]
        : [r] "=r" (-> u64),
        :
        : .{ .memory = true });
    return flags & FLAGS_IF != 0;
}

/// Sleep until the next interrupt, and come back with the interrupts
/// masked again. `sti` lets them in only after the instruction that
/// follows it, which is the `hlt`: so an interrupt that arrives between
/// the two is taken after the core is asleep and not before, and the core
/// cannot sleep through one that was already pending. `hlt` with the
/// interrupts masked would never end.
pub inline fn waitForInterrupt() void {
    asm volatile (
        \\sti
        \\hlt
        \\cli
        ::: .{ .memory = true });
}

pub inline fn stackPointer() usize {
    return asm volatile ("movq %%rsp, %[r]"
        : [r] "=r" (-> usize),
    );
}

/// Where the interrupt descriptor table is (IDTR), which is this
/// machine's answer to a vector base.
pub fn vecbase() usize {
    var area: [10]u8 align(2) = @splat(0);
    asm volatile ("sidt %[at]"
        : [at] "=m" (area),
    );
    var base: u64 = 0;
    for (0..8) |byte| base |= @as(u64, area[2 + byte]) << @intCast(8 * byte);
    return @intCast(base);
}

/// The core's id as platform.resource reports it: its local controller's.
pub inline fn prid() u32 {
    return @truncate(core_blocks[coreId()].lapic_id);
}

/// The data cache's line, in bytes: leaf 1's CLFLUSH line size, in
/// eight-byte units. 0 where the core does not say, which none this runs
/// on does.
pub fn dcacheLine() u32 {
    if (hardware.cpu.highestLeaf() < 1) return 0;
    return ((leaf(1, 0).ebx >> 8) & 0xFF) * 8;
}

// --- the control registers ---------------------------------------------------------

/// CR0: the FPU's state (EM, MP, NE) and whether a read-only page is
/// read-only to this privilege level too (WP).
pub const CR0_MP: u64 = 1 << 1;
pub const CR0_EM: u64 = 1 << 2;
pub const CR0_NE: u64 = 1 << 5;
pub const CR0_WP: u64 = 1 << 16;

/// CR4: the SSE registers saved and restored by FXSAVE (OSFXSR) and their
/// exceptions taken as exceptions of their own (OSXMMEXCPT).
pub const CR4_OSFXSR: u64 = 1 << 9;
pub const CR4_OSXMMEXCPT: u64 = 1 << 10;

pub inline fn readCr0() u64 {
    return asm volatile ("movq %%cr0, %[r]"
        : [r] "=r" (-> u64),
    );
}

pub inline fn writeCr0(value: u64) void {
    asm volatile ("movq %[v], %%cr0"
        :
        : [v] "r" (value),
        : .{ .memory = true });
}

pub inline fn readCr3() u64 {
    return asm volatile ("movq %%cr3, %[r]"
        : [r] "=r" (-> u64),
    );
}

/// The map changed: every translation this core holds is dropped by the
/// write itself.
pub inline fn writeCr3(value: u64) void {
    asm volatile ("movq %[v], %%cr3"
        :
        : [v] "r" (value),
        : .{ .memory = true });
}

pub inline fn readCr4() u64 {
    return asm volatile ("movq %%cr4, %[r]"
        : [r] "=r" (-> u64),
    );
}

pub inline fn writeCr4(value: u64) void {
    asm volatile ("movq %[v], %%cr4"
        :
        : [v] "r" (value),
        : .{ .memory = true });
}

/// The address a page fault named (CR2).
pub inline fn faultAddress() usize {
    return asm volatile ("movq %%cr2, %[r]"
        : [r] "=r" (-> usize),
    );
}

/// The SSE registers in use, and a read-only page read-only to the kernel
/// as well: what the compiler's code and the kernel's map need of the
/// core. Set on every core as it starts.
pub fn setUpState() void {
    var cr0 = readCr0();
    cr0 &= ~CR0_EM; // the FPU is there: no emulation
    cr0 |= CR0_MP | CR0_NE | CR0_WP;
    writeCr0(cr0);
    writeCr4(readCr4() | CR4_OSFXSR | CR4_OSXMMEXCPT);
}

/// The core stopped for good: interrupts masked, asleep.
pub fn halt() noreturn {
    _ = disableInterrupts();
    while (true) asm volatile ("hlt");
}
