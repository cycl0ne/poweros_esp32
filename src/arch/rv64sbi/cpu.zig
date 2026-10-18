// SPDX-License-Identifier: MPL-2.0
//! The hart's supervisor registers and the instructions exec's hardware
//! needs of it: which core this is, its interrupts on and off, its sleep
//! until the next one, and the trap registers (CSRs) the trap code reads.
//!
//! A core is exec's numbering, 0 up; a hart the machine's, which the SBI
//! calls take. The boot hart is core 0 whatever its hart id - on the
//! JH7110 the firmware picks one of the U74s, 1 to 4 - and each core
//! keeps its number in `tp`, which start.S sets and the trap exit never
//! reloads: a task that moves to another core finds that core's number
//! there.
//!
//! A core's interrupts are its sstatus.SIE: masking it holds every
//! interrupt off on this core, which is what Disable and the trap entry
//! want - sie keeps the software, timer and external interrupts on from
//! the boot.

const exec_base = @import("../../rom/libs/exec/exec_base.zig");

pub const ccount = @import("sdk").hardware.cpu.ccount;

/// sstatus: the interrupts on, the interrupt state a trap saves and sret
/// puts back, the privilege sret returns to, and the FPU's state.
pub const SSTATUS_SIE: u64 = 1 << 1;
pub const SSTATUS_SPIE: u64 = 1 << 5;
pub const SSTATUS_SPP_S: u64 = 1 << 8;
pub const SSTATUS_FS_INITIAL: u64 = 1 << 13;

/// scause: an interrupt rather than an exception, and the code - the
/// exception's, or the interrupt's.
pub const SCAUSE_INTERRUPT: u64 = 1 << 63;
pub const SCAUSE_CODE: u64 = ~SCAUSE_INTERRUPT;

/// sie and sip: the software interrupt (exec's Cause and the cross-core
/// interrupt, both through the SBI's IPIs or the hart's own sip), the
/// timer's, and the PLIC's.
pub const SIE_SSIE: u64 = 1 << 1;
pub const SIE_STIE: u64 = 1 << 5;
pub const SIE_SEIE: u64 = 1 << 9;

/// The interrupt codes in scause.
pub const IRQ_SOFTWARE = 1;
pub const IRQ_TIMER = 5;
pub const IRQ_EXTERNAL = 9;

/// Each core's hart, as the firmware numbers it; start.S's a0.
pub var hartids: [exec_base.max_cores]usize = @splat(0);

/// The core this runs on: 0 up.
pub inline fn coreId() u32 {
    return @truncate(asm volatile ("mv %[r], tp"
        : [r] "=r" (-> u64),
    ));
}

/// The hart this runs on.
pub inline fn hartId() usize {
    return hartids[coreId()];
}

/// This core's interrupts masked; answers sstatus as it was, for
/// `restoreInterrupts`.
pub inline fn disableInterrupts() u32 {
    return @truncate(asm volatile ("csrrci %[r], sstatus, 2"
        : [r] "=r" (-> u64),
        :
        : .{ .memory = true }));
}

/// The interrupts as `disableInterrupts` found them: on again only if they
/// were on.
pub inline fn restoreInterrupts(saved: u32) void {
    if (saved & SSTATUS_SIE != 0) asm volatile ("csrsi sstatus, 2" ::: .{ .memory = true });
}

pub inline fn enableInterrupts() void {
    asm volatile ("csrsi sstatus, 2" ::: .{ .memory = true });
}

/// Whether this core takes interrupts now.
pub inline fn interruptsOn() bool {
    const status = asm volatile ("csrr %[r], sstatus"
        : [r] "=r" (-> u64),
    );
    return status & SSTATUS_SIE != 0;
}

/// The interrupts sie lets through set.
pub inline fn enableInterruptKinds(bits: u64) void {
    asm volatile ("csrs sie, %[b]"
        :
        : [b] "r" (bits),
        : .{ .memory = true });
}

/// The software interrupt pending on this hart: what a Cause raises.
pub inline fn raiseSoftware() void {
    asm volatile ("csrsi sip, 2" ::: .{ .memory = true });
}

/// The software interrupt taken: lowered before it is served.
pub inline fn clearSoftware() void {
    asm volatile ("csrci sip, 2" ::: .{ .memory = true });
}

/// Sleep until the next interrupt.
pub inline fn waitForInterrupt() void {
    asm volatile ("wfi" ::: .{ .memory = true });
}

pub inline fn stackPointer() usize {
    return asm volatile ("mv %[r], sp"
        : [r] "=r" (-> usize),
    );
}

/// stvec: where a trap goes, with its mode in the low two bits (direct).
pub inline fn trapVector() usize {
    return asm volatile ("csrr %[r], stvec"
        : [r] "=r" (-> usize),
    );
}

/// The trap vector's base: stvec without the mode.
pub inline fn vecbase() usize {
    return trapVector() & ~@as(usize, 3);
}

/// The core's id as platform.resource reports it: the hart's.
pub inline fn prid() u32 {
    return @intCast(hartId());
}

/// The core stopped for good: interrupts masked, asleep.
pub fn halt() noreturn {
    _ = disableInterrupts();
    while (true) asm volatile ("wfi");
}
