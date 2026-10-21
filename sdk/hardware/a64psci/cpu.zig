// SPDX-License-Identifier: MIT
//! The core's counters as EL1 reads them - the performance monitor's cycle
//! counter (PMCCNTR_EL0) at the CPU's clock, and the generic timer's
//! virtual count (CNTVCT_EL0) at the system counter's rate - and a busy
//! wait.
//!
//! The cycle counter counts once the kernel has switched it on
//! (`startCycleCounter`, on every core as it starts); before that it reads
//! 0. The virtual count is the physical one: the kernel sets the offset to
//! 0 where it comes in at EL2, and nothing else has a reason to set one.

/// The cycles counted since the core started, wrapping at 32 bits.
pub inline fn ccount() u32 {
    return @truncate(cycles());
}

/// The whole 64-bit cycle counter.
pub inline fn cycles() u64 {
    return asm volatile ("mrs %[r], pmccntr_el0"
        : [r] "=r" (-> u64),
    );
}

/// The system counter, in its own units (`CNTFRQ_EL0` a second).
pub inline fn time() u64 {
    return asm volatile ("isb; mrs %[r], cntvct_el0"
        : [r] "=r" (-> u64),
        :
        : .{ .memory = true });
}

/// What the firmware says the system counter counts at, in Hz.
pub inline fn counterFrequency() u64 {
    return asm volatile ("mrs %[r], cntfrq_el0"
        : [r] "=r" (-> u64),
    );
}

/// PMCR_EL0.E: the counters on; PMCR_EL0.LC: the cycle counter 64 bits
/// wide; PMCNTENSET_EL0.C: the cycle counter counts.
const PMCR_E: u64 = 1 << 0;
const PMCR_LC: u64 = 1 << 6;
const PMCNTEN_C: u64 = 1 << 31;

/// This core's cycle counter on, counting at EL1 (PMCCFILTR_EL0 0).
pub fn startCycleCounter() void {
    asm volatile (
        \\msr pmccfiltr_el0, xzr
        \\mrs x9, pmcr_el0
        \\orr x9, x9, %[e]
        \\msr pmcr_el0, x9
        \\msr pmcntenset_el0, %[c]
        \\isb
        :
        : [e] "r" (PMCR_E | PMCR_LC),
          [c] "r" (PMCNTEN_C),
        : .{ .x9 = true, .memory = true });
}

/// DAIF.I: this core's IRQs masked.
const DAIF_I: u64 = 1 << 7;

/// At least `count` cycles waited out, with this core's interrupts masked
/// meanwhile.
pub inline fn spinCycles(count: u32) void {
    const saved = asm volatile ("mrs %[r], daif; msr daifset, #2"
        : [r] "=r" (-> u64),
        :
        : .{ .memory = true });
    const since = ccount();
    while (ccount() -% since < count) {}
    if (saved & DAIF_I == 0) asm volatile ("msr daifclr, #2" ::: .{ .memory = true });
}
