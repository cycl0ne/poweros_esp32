// SPDX-License-Identifier: MIT
//! The peripherals' bus clocks and resets, which the SYSTEM block keeps
//! for all of them in two pairs of registers: a clock-enable word and a
//! reset word, each pair split across two registers by peripheral.
//!
//! **Every change is a read-modify-write of a register other drivers
//! share**, so each one is done with the CPU's interrupts masked: a task
//! switch between the read and the write would put back a word without
//! the bit another driver had set meanwhile. Masking at the CPU rather
//! than through exec's Disable lets the same helpers serve exec's own
//! early output and the boot code, which run before exec does.
//!
//! **Two cores** share the registers too, and masking holds off only the
//! caller's own. So a driver - once the system runs - makes its changes
//! inside exec's Disable, which keeps the other core's Disables out as
//! well: every change made that way is made alone.
//!
//! All `inline`: nothing here is a call into flash, so code in internal RAM
//! may use it.

const mmio = @import("mmio.zig");
const map = @import("map.zig");

/// Core 1's clock, stall and reset.
pub const CORE_1_CONTROL_0: usize = map.SYSTEM + 0x00;
/// Core 1 stalled.
pub const CORE_1_RUNSTALL: u32 = 1 << 0;
/// Core 1's clock on.
pub const CORE_1_CLKGATE_EN: u32 = 1 << 1;
/// Core 1 held in reset while set.
pub const CORE_1_RESETING: u32 = 1 << 2;
/// Where core 1 goes from the ROM's reset code, 0 while it is to wait:
/// the ROM's `ets_set_appcpu_boot_addr` writes it.
pub const CORE_1_CONTROL_1: usize = map.SYSTEM + 0x04;

/// Core 1 put back as the chip starts it - held in reset, then its clock
/// off, and no address to go to - right before a system reset, so the
/// boot after lets it go afresh whatever the reset leaves of these
/// registers: Espressif's QEMU keeps the address, and a core 1 that found
/// it would run before core 0 had set anything up. Reset first: a core
/// stopped inside an S32C1I would keep its memory locked to it.
pub inline fn core1Off() void {
    const control = mmio.reg(CORE_1_CONTROL_0);
    control.* |= CORE_1_RESETING;
    control.* &= ~CORE_1_CLKGATE_EN;
    mmio.reg(CORE_1_CONTROL_1).* = 0;
}

/// The four cross-core interrupts, a word each: writing 1 raises source
/// `INTB_FROM_CPU_INTR0 + n`, writing 0 lowers it.
pub const CPU_INTR_FROM_CPU_0: usize = map.SYSTEM + 0x30;

pub const PERIP_CLK_EN0: usize = map.SYSTEM + 0x18;
pub const PERIP_CLK_EN1: usize = map.SYSTEM + 0x1C;
pub const PERIP_RST_EN0: usize = map.SYSTEM + 0x20;
pub const PERIP_RST_EN1: usize = map.SYSTEM + 0x24;

/// A peripheral with a bus clock and a reset of its own.
pub const Peripheral = enum {
    uart0,
    uart1,
    uart2,
    /// The FIFO memory the three UARTs share.
    uart_mem,
    spi2,
    spi3,
    i2c0,
    i2c1,
    i2s0,
    gdma,
    lcd_cam,
    sdio_host,
    /// The SAR ADCs' digital controller.
    apb_saradc,
    /// The crypto engines. The SHA engine stays in reset while the
    /// digital signature and HMAC engines are, so its user lets those
    /// out of reset as well.
    crypto_aes,
    crypto_sha,
    crypto_rsa,
    crypto_ds,
    crypto_hmac,
};

/// Which register pair holds a peripheral's bit, and the bit.
const Slot = struct { second: bool, bit: u32 };

inline fn slotOf(comptime peripheral: Peripheral) Slot {
    return switch (peripheral) {
        .uart0 => .{ .second = false, .bit = 1 << 2 },
        .i2s0 => .{ .second = false, .bit = 1 << 4 },
        .uart1 => .{ .second = false, .bit = 1 << 5 },
        .spi2 => .{ .second = false, .bit = 1 << 6 },
        .spi3 => .{ .second = false, .bit = 1 << 16 },
        .i2c0 => .{ .second = false, .bit = 1 << 7 },
        .i2c1 => .{ .second = false, .bit = 1 << 18 },
        .uart_mem => .{ .second = false, .bit = 1 << 24 },
        .apb_saradc => .{ .second = false, .bit = 1 << 28 },
        .gdma => .{ .second = true, .bit = 1 << 6 },
        .sdio_host => .{ .second = true, .bit = 1 << 7 },
        .crypto_aes => .{ .second = true, .bit = 1 << 1 },
        .crypto_sha => .{ .second = true, .bit = 1 << 2 },
        .crypto_rsa => .{ .second = true, .bit = 1 << 3 },
        .crypto_ds => .{ .second = true, .bit = 1 << 4 },
        .crypto_hmac => .{ .second = true, .bit = 1 << 5 },
        .lcd_cam => .{ .second = true, .bit = 1 << 8 },
        .uart2 => .{ .second = true, .bit = 1 << 9 },
    };
}

inline fn clockRegister(comptime peripheral: Peripheral) usize {
    return if (slotOf(peripheral).second) PERIP_CLK_EN1 else PERIP_CLK_EN0;
}

inline fn resetRegister(comptime peripheral: Peripheral) usize {
    return if (slotOf(peripheral).second) PERIP_RST_EN1 else PERIP_RST_EN0;
}

/// `set` and `clear` applied to the register at `addr` with interrupts
/// masked at the CPU, so nothing runs between the read and the write.
inline fn update(addr: usize, set: u32, clear: u32) void {
    const saved = asm volatile ("rsil %[r], 15"
        : [r] "=r" (-> u32),
        :
        : .{ .memory = true });
    const register = mmio.reg(addr);
    register.* = (register.* & ~clear) | set;
    asm volatile (
        \\wsr %[v], ps
        \\rsync
        :
        : [v] "r" (saved),
        : .{ .memory = true });
}

/// The peripheral's bus clock on.
pub inline fn clockOn(comptime peripheral: Peripheral) void {
    update(clockRegister(peripheral), slotOf(peripheral).bit, 0);
}

/// The peripheral's bus clock off.
pub inline fn clockOff(comptime peripheral: Peripheral) void {
    update(clockRegister(peripheral), 0, slotOf(peripheral).bit);
}

/// Whether the peripheral's bus clock is on.
pub inline fn clockIsOn(comptime peripheral: Peripheral) bool {
    return mmio.reg(clockRegister(peripheral)).* & slotOf(peripheral).bit != 0;
}

/// The peripheral held in reset.
pub inline fn holdInReset(comptime peripheral: Peripheral) void {
    update(resetRegister(peripheral), slotOf(peripheral).bit, 0);
}

/// The peripheral let out of reset.
pub inline fn releaseReset(comptime peripheral: Peripheral) void {
    update(resetRegister(peripheral), 0, slotOf(peripheral).bit);
}

/// What almost every driver does first: the bus clock on and the
/// peripheral through a reset, so it starts from its power-on state. A
/// peripheral held in reset reads as zeroes, so nothing may be read or
/// written before this.
pub inline fn enable(comptime peripheral: Peripheral) void {
    clockOn(peripheral);
    holdInReset(peripheral);
    releaseReset(peripheral);
}
