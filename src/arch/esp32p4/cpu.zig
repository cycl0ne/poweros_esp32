// SPDX-License-Identifier: MPL-2.0
//! The HP core's control registers and the instructions exec's hardware
//! needs of it: which core this is, its interrupts on and off, its sleep
//! until the next one, and the trap registers (CSRs) the trap code reads.
//!
//! A core's interrupts are its mstatus.MIE: masking it holds every
//! interrupt off on this core, which is what Disable and the trap entry
//! want - the interrupt controller's level and threshold stay as they are
//! set at boot, all lines at one level.

pub const ccount = @import("sdk").hardware.cpu.ccount;

/// mstatus: the interrupts on, the interrupt state a trap saves and mret
/// puts back, the privilege mret returns to, and the FPU's state.
pub const MSTATUS_MIE: u32 = 1 << 3;
pub const MSTATUS_MPIE: u32 = 1 << 7;
pub const MSTATUS_MPP_M: u32 = 3 << 11;
pub const MSTATUS_FS_INITIAL: u32 = 1 << 13;

/// mcause in the interrupt controller's mode: an interrupt rather than an
/// exception, and the code - the exception's, or the interrupt's number.
pub const MCAUSE_INTERRUPT: u32 = 1 << 31;
pub const MCAUSE_CODE: u32 = 0xFFF;
/// The aliases of mstatus.MPP and mstatus.MPIE mcause carries, so a frame's
/// mcause written back before mret returns to machine mode with interrupts
/// on.
pub const MCAUSE_MPP_M: u32 = 3 << 28;
pub const MCAUSE_MPIE: u32 = 1 << 27;

/// The core this runs on: 0 or 1.
pub inline fn coreId() u32 {
    return asm volatile ("csrr %[r], mhartid"
        : [r] "=r" (-> u32),
    );
}

/// This core's interrupts masked; answers mstatus as it was, for
/// `restoreInterrupts`.
pub inline fn disableInterrupts() u32 {
    return asm volatile ("csrrci %[r], mstatus, 8"
        : [r] "=r" (-> u32),
        :
        : .{ .memory = true });
}

/// The interrupts as `disableInterrupts` found them: on again only if they
/// were on.
pub inline fn restoreInterrupts(saved: u32) void {
    if (saved & MSTATUS_MIE != 0) asm volatile ("csrsi mstatus, 8" ::: .{ .memory = true });
}

pub inline fn enableInterrupts() void {
    asm volatile ("csrsi mstatus, 8" ::: .{ .memory = true });
}

/// Whether this core takes interrupts now.
pub inline fn interruptsOn() bool {
    const status = asm volatile ("csrr %[r], mstatus"
        : [r] "=r" (-> u32),
    );
    return status & MSTATUS_MIE != 0;
}

/// Sleep until the next interrupt.
pub inline fn waitForInterrupt() void {
    asm volatile ("wfi" ::: .{ .memory = true });
}

pub inline fn stackPointer() u32 {
    return asm volatile ("mv %[r], sp"
        : [r] "=r" (-> u32),
    );
}

/// mtvec: where a trap goes, with the interrupt controller's mode in its
/// low two bits.
pub inline fn trapVector() u32 {
    return asm volatile ("csrr %[r], mtvec"
        : [r] "=r" (-> u32),
    );
}

/// The core stopped for good: interrupts masked, asleep.
pub fn halt() noreturn {
    _ = disableInterrupts();
    while (true) asm volatile ("wfi");
}
