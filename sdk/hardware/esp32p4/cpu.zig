// SPDX-License-Identifier: MIT
//! The core's cycle counter - the standard `cycle` register, counting at
//! the CPU's clock - and a busy wait on it.

/// The cycles counted since the core started, wrapping at 32 bits.
pub inline fn ccount() u32 {
    return asm volatile ("csrr %[r], cycle"
        : [r] "=r" (-> u32),
    );
}

/// At least `cycles` cycles waited out, with this core's interrupts
/// masked meanwhile.
pub inline fn spinCycles(cycles: u32) void {
    const saved = asm volatile ("csrrci %[r], mstatus, 8"
        : [r] "=r" (-> u32),
        :
        : .{ .memory = true });
    const since = ccount();
    while (ccount() -% since < cycles) {}
    if (saved & 8 != 0) asm volatile ("csrsi mstatus, 8" ::: .{ .memory = true });
}
