// SPDX-License-Identifier: MIT
//! The core's counters as supervisor mode reads them - `cycle` at the
//! CPU's clock and `time` at the platform's timebase, both of which the
//! SBI firmware lets through to supervisor mode - and a busy wait.
//!
//! On the JH7110's U74 `time` is not a register of the core: reading it
//! traps to the firmware, which answers from the CLINT. It is right, but
//! it costs a trap; `cycle` is the core's own.

/// The cycles counted since the core started, wrapping at 32 bits.
pub inline fn ccount() u32 {
    return @truncate(cycles());
}

/// The whole 64-bit cycle counter.
pub inline fn cycles() u64 {
    return asm volatile ("rdcycle %[r]"
        : [r] "=r" (-> u64),
    );
}

/// The platform's time, in its timebase's units.
pub inline fn time() u64 {
    return asm volatile ("rdtime %[r]"
        : [r] "=r" (-> u64),
    );
}

/// sstatus.SIE: this hart's interrupts on.
const SSTATUS_SIE = 1 << 1;

/// At least `count` cycles waited out, with this hart's interrupts masked
/// meanwhile.
pub inline fn spinCycles(count: u32) void {
    const saved = asm volatile ("csrrci %[r], sstatus, 2"
        : [r] "=r" (-> usize),
        :
        : .{ .memory = true });
    const since = ccount();
    while (ccount() -% since < count) {}
    if (saved & SSTATUS_SIE != 0) asm volatile ("csrsi sstatus, 2" ::: .{ .memory = true });
}
