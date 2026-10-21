// SPDX-License-Identifier: MPL-2.0
//! The core's EL1 registers and the instructions exec's hardware needs of
//! it: which core this is, its interrupts on and off, its sleep until the
//! next one, and the exception registers the trap code reads.
//!
//! A core is exec's numbering, 0 up; an MPIDR the machine's affinity,
//! which PSCI's calls take. The boot core is core 0 whatever its
//! affinity, and each core keeps its number in TPIDR_EL1, which start.S
//! sets and the exception exit never reloads: a task that moves to
//! another core finds that core's number there.
//!
//! A core's interrupts are its PSTATE.I (DAIF): masking it holds every
//! interrupt off on this core, which is what Disable and the exception
//! entry want. SErrors (PSTATE.A) are taken from the boot on.

const exec_base = @import("../../rom/libs/exec/exec_base.zig");

pub const ccount = @import("sdk").hardware.cpu.ccount;

/// DAIF.I: this core's IRQs masked.
pub const DAIF_I: u64 = 1 << 7;

/// SPSR_EL1 for a context at EL1 on SP_EL1 (EL1h) with every exception
/// taken: what a new task is resumed with.
pub const SPSR_EL1H: u64 = 0b0101;

/// ESR_EL1: the exception class, and the syndrome below it.
pub const ESR_EC_SHIFT: u6 = 26;
pub const ESR_EC_MASK: u64 = 0x3F;

/// MPIDR_EL1's affinity fields - Aff3 above, Aff2 to Aff0 below - as
/// PSCI takes them.
pub const MPIDR_AFFINITY: u64 = 0xFF_00FF_FFFF;

/// Each core's MPIDR affinity; start.S's for core 0.
pub var mpidrs: [exec_base.max_cores]u64 = @splat(0);

/// The core this runs on: 0 up.
pub inline fn coreId() u32 {
    return @truncate(asm volatile ("mrs %[r], tpidr_el1"
        : [r] "=r" (-> u64),
    ));
}

/// This core's MPIDR affinity.
pub inline fn mpidr() u64 {
    return asm volatile ("mrs %[r], mpidr_el1"
        : [r] "=r" (-> u64),
    ) & MPIDR_AFFINITY;
}

/// This core's interrupts masked; answers DAIF as it was, for
/// `restoreInterrupts`.
pub inline fn disableInterrupts() u32 {
    return @truncate(asm volatile ("mrs %[r], daif; msr daifset, #2"
        : [r] "=r" (-> u64),
        :
        : .{ .memory = true }));
}

/// The interrupts as `disableInterrupts` found them: on again only if they
/// were on.
pub inline fn restoreInterrupts(saved: u32) void {
    if (saved & DAIF_I == 0) asm volatile ("msr daifclr, #2" ::: .{ .memory = true });
}

pub inline fn enableInterrupts() void {
    asm volatile ("msr daifclr, #2" ::: .{ .memory = true });
}

/// Whether this core takes interrupts now.
pub inline fn interruptsOn() bool {
    const daif = asm volatile ("mrs %[r], daif"
        : [r] "=r" (-> u64),
    );
    return daif & DAIF_I == 0;
}

/// Sleep until the next interrupt. It wakes for one that is pending even
/// while they are masked.
pub inline fn waitForInterrupt() void {
    asm volatile ("dsb sy; wfi" ::: .{ .memory = true });
}

pub inline fn stackPointer() usize {
    return asm volatile ("mov %[r], sp"
        : [r] "=r" (-> usize),
    );
}

/// VBAR_EL1: where the vectors are.
pub inline fn vecbase() usize {
    return asm volatile ("mrs %[r], vbar_el1"
        : [r] "=r" (-> usize),
    );
}

/// The core's id as platform.resource reports it: its affinity.
pub inline fn prid() u32 {
    return @truncate(mpidrs[coreId()]);
}

/// The exception level the kernel runs at: 1.
pub inline fn currentEl() u32 {
    return @truncate(asm volatile ("mrs %[r], CurrentEL"
        : [r] "=r" (-> u64),
    ) >> 2);
}

/// The data cache's smallest line, in bytes (CTR_EL0.DminLine).
pub fn dcacheLine() u32 {
    const ctr = asm volatile ("mrs %[r], ctr_el0"
        : [r] "=r" (-> u64),
    );
    return @as(u32, 4) << @intCast((ctr >> 16) & 0xF);
}

/// Whether the instruction cache needs no clean of the data cache to the
/// point of unification before it sees new code (CTR_EL0.IDC).
pub fn idcCoherent() bool {
    const ctr = asm volatile ("mrs %[r], ctr_el0"
        : [r] "=r" (-> u64),
    );
    return ctr & (1 << 28) != 0;
}

/// The core stopped for good: interrupts masked, asleep.
pub fn halt() noreturn {
    _ = disableInterrupts();
    while (true) asm volatile ("wfi");
}
