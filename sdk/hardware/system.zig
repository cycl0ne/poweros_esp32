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
//! early output and the boot code, which run before exec does, as well as
//! a driver loaded off the disk while other tasks run.
//!
//! All `inline`: nothing here is a call into flash, so code in internal RAM
//! may use it.

const mmio = @import("mmio.zig");
const map = @import("map.zig");

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
    i2c0,
    i2c1,
    i2s0,
    gdma,
    lcd_cam,
    sdio_host,
};

/// Which register pair holds a peripheral's bit, and the bit.
const Slot = struct { second: bool, bit: u32 };

inline fn slotOf(comptime peripheral: Peripheral) Slot {
    return switch (peripheral) {
        .uart0 => .{ .second = false, .bit = 1 << 2 },
        .i2s0 => .{ .second = false, .bit = 1 << 4 },
        .uart1 => .{ .second = false, .bit = 1 << 5 },
        .spi2 => .{ .second = false, .bit = 1 << 6 },
        .i2c0 => .{ .second = false, .bit = 1 << 7 },
        .i2c1 => .{ .second = false, .bit = 1 << 18 },
        .uart_mem => .{ .second = false, .bit = 1 << 24 },
        .gdma => .{ .second = true, .bit = 1 << 6 },
        .sdio_host => .{ .second = true, .bit = 1 << 7 },
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
