// SPDX-License-Identifier: MIT
//! The chip as a whole: its reset, and the peripherals' clocks and resets,
//! which the HP_SYS_CLKRST block keeps for all of them.
//!
//! A peripheral has more than one clock here: its bus clock (SOC_CLK_CTRL),
//! and most have a function clock of their own as well (PERI_CLK_CTRL) -
//! whose source and divider are the driver's to choose - and a reset for
//! its core and for its bus side (HP_RST_EN). `clockOn` turns all of its
//! clocks on, `holdInReset` holds all of its resets, so a driver says what
//! it wants of the peripheral and not which registers that takes. The
//! function clock's source and dividers are here too, not in the
//! peripheral's own block: `setFunctionClock`.
//!
//! **Every change is a read-modify-write of a register other drivers
//! share**, so each one is done with this core's interrupts masked: a
//! task switch between the read and the write would put back a word
//! without the bit another driver had set meanwhile. Once the system runs,
//! a driver makes its changes inside exec's Disable, which keeps the other
//! core out as well.
//!
//! From ESP-IDF v6.1's soc/esp32p4/register/hw_ver1/soc/hp_sys_clkrst_reg.h.
//! All `inline`.

const mmio = @import("mmio.zig");
const map = @import("map.zig");

// The registers.
pub const SOC_CLK_CTRL1: usize = map.HP_SYS_CLKRST + 0x018;
pub const SOC_CLK_CTRL2: usize = map.HP_SYS_CLKRST + 0x01C;
pub const PERI_CLK_CTRL10: usize = map.HP_SYS_CLKRST + 0x040;
pub const PERI_CLK_CTRL11: usize = map.HP_SYS_CLKRST + 0x044;
pub const PERI_CLK_CTRL21: usize = map.HP_SYS_CLKRST + 0x098;
pub const PERI_CLK_CTRL110: usize = map.HP_SYS_CLKRST + 0x068;
pub const PERI_CLK_CTRL111: usize = map.HP_SYS_CLKRST + 0x06C;
pub const PERI_CLK_CTRL112: usize = map.HP_SYS_CLKRST + 0x070;
pub const PERI_CLK_CTRL113: usize = map.HP_SYS_CLKRST + 0x074;
pub const PERI_CLK_CTRL114: usize = map.HP_SYS_CLKRST + 0x078;
pub const PERI_CLK_CTRL115: usize = map.HP_SYS_CLKRST + 0x07C;
pub const PERI_CLK_CTRL116: usize = map.HP_SYS_CLKRST + 0x080;
pub const PERI_CLK_CTRL117: usize = map.HP_SYS_CLKRST + 0x084;
pub const HP_RST_EN1: usize = map.HP_SYS_CLKRST + 0x0C4;
pub const HP_RST_EN2: usize = map.HP_SYS_CLKRST + 0x0C8;

/// A peripheral with clocks and a reset of its own.
pub const Peripheral = enum {
    uart0,
    uart1,
    uart2,
    uart3,
    uart4,
    i2c0,
    i2c1,
    spi2,
    spi3,
    systimer,
    /// The two general DMA engines: AHB's and AXI's.
    ahb_dma,
    axi_dma,
    usb_serial_jtag,
};

/// One bit in one register.
const Bit = struct { register: usize, mask: u32 };

/// A peripheral's clock bits and reset bits.
const Parts = struct { clocks: []const Bit, resets: []const Bit };

fn bit(register: usize, comptime n: u5) Bit {
    return .{ .register = register, .mask = 1 << n };
}

inline fn partsOf(comptime peripheral: Peripheral) Parts {
    return comptime switch (peripheral) {
        .uart0 => .{
            .clocks = &.{ bit(SOC_CLK_CTRL1, 18), bit(SOC_CLK_CTRL2, 7), bit(PERI_CLK_CTRL110, 26) },
            .resets = &.{ bit(HP_RST_EN1, 8), bit(HP_RST_EN1, 13) },
        },
        .uart1 => .{
            .clocks = &.{ bit(SOC_CLK_CTRL1, 19), bit(SOC_CLK_CTRL2, 8), bit(PERI_CLK_CTRL111, 26) },
            .resets = &.{ bit(HP_RST_EN1, 9), bit(HP_RST_EN1, 14) },
        },
        .uart2 => .{
            .clocks = &.{ bit(SOC_CLK_CTRL1, 20), bit(SOC_CLK_CTRL2, 9), bit(PERI_CLK_CTRL112, 26) },
            .resets = &.{ bit(HP_RST_EN1, 10), bit(HP_RST_EN1, 15) },
        },
        .uart3 => .{
            .clocks = &.{ bit(SOC_CLK_CTRL1, 21), bit(SOC_CLK_CTRL2, 10), bit(PERI_CLK_CTRL113, 26) },
            .resets = &.{ bit(HP_RST_EN1, 11), bit(HP_RST_EN1, 16) },
        },
        .uart4 => .{
            .clocks = &.{ bit(SOC_CLK_CTRL1, 22), bit(SOC_CLK_CTRL2, 11), bit(PERI_CLK_CTRL114, 26) },
            .resets = &.{ bit(HP_RST_EN1, 12), bit(HP_RST_EN1, 17) },
        },
        .i2c0 => .{
            .clocks = &.{ bit(SOC_CLK_CTRL2, 12), bit(PERI_CLK_CTRL10, 1) },
            .resets = &.{bit(HP_RST_EN1, 22)},
        },
        .i2c1 => .{
            .clocks = &.{ bit(SOC_CLK_CTRL2, 13), bit(PERI_CLK_CTRL10, 27) },
            .resets = &.{bit(HP_RST_EN1, 21)},
        },
        .spi2 => .{
            .clocks = &.{ bit(SOC_CLK_CTRL1, 0), bit(SOC_CLK_CTRL2, 19), bit(PERI_CLK_CTRL116, 3), bit(PERI_CLK_CTRL116, 20) },
            .resets = &.{bit(HP_RST_EN2, 7)},
        },
        .spi3 => .{
            .clocks = &.{ bit(SOC_CLK_CTRL1, 1), bit(SOC_CLK_CTRL2, 20), bit(PERI_CLK_CTRL116, 24), bit(PERI_CLK_CTRL117, 16) },
            .resets = &.{bit(HP_RST_EN2, 8)},
        },
        .systimer => .{
            .clocks = &.{ bit(SOC_CLK_CTRL2, 23), bit(PERI_CLK_CTRL21, 30) },
            .resets = &.{bit(HP_RST_EN1, 5)},
        },
        .ahb_dma => .{
            .clocks = &.{bit(SOC_CLK_CTRL1, 3)},
            .resets = &.{bit(HP_RST_EN1, 1)},
        },
        .axi_dma => .{
            .clocks = &.{bit(SOC_CLK_CTRL1, 4)},
            .resets = &.{bit(HP_RST_EN1, 2)},
        },
        .usb_serial_jtag => .{
            .clocks = &.{bit(SOC_CLK_CTRL2, 29)},
            .resets = &.{},
        },
    };
}

/// `set` and `clear` applied to the register at `addr` with this core's
/// interrupts masked, so nothing runs between the read and the write.
inline fn update(addr: usize, set: u32, clear: u32) void {
    const saved = asm volatile ("csrrci %[r], mstatus, 8"
        : [r] "=r" (-> u32),
        :
        : .{ .memory = true });
    const register = mmio.reg(addr);
    register.* = (register.* & ~clear) | set;
    if (saved & 8 != 0) asm volatile ("csrsi mstatus, 8" ::: .{ .memory = true });
}

/// The peripheral's clocks on.
pub inline fn clockOn(comptime peripheral: Peripheral) void {
    inline for (partsOf(peripheral).clocks) |clock| update(clock.register, clock.mask, 0);
}

/// The peripheral's clocks off.
pub inline fn clockOff(comptime peripheral: Peripheral) void {
    inline for (partsOf(peripheral).clocks) |clock| update(clock.register, 0, clock.mask);
}

/// Whether all of the peripheral's clocks are on.
pub inline fn clockIsOn(comptime peripheral: Peripheral) bool {
    inline for (partsOf(peripheral).clocks) |clock| {
        if (mmio.reg(clock.register).* & clock.mask == 0) return false;
    }
    return true;
}

/// The peripheral held in reset.
pub inline fn holdInReset(comptime peripheral: Peripheral) void {
    inline for (partsOf(peripheral).resets) |reset| update(reset.register, reset.mask, 0);
}

/// The peripheral let out of reset.
pub inline fn releaseReset(comptime peripheral: Peripheral) void {
    inline for (partsOf(peripheral).resets) |reset| update(reset.register, 0, reset.mask);
}

/// What almost every driver does first: the clocks on and the peripheral
/// through a reset, so it starts from its power-on state.
pub inline fn enable(comptime peripheral: Peripheral) void {
    clockOn(peripheral);
    holdInReset(peripheral);
    releaseReset(peripheral);
}

/// A function clock: its source - the peripheral's own numbering, 0 the
/// crystal on all of them - and how far it is divided, 1 to 256.
/// `pre_divider` is SPI2's and SPI3's first stage (the "HS" clock, at most
/// 160 MHz) ahead of `divider` (at most 80 MHz); elsewhere it stays 1.
pub const FunctionClock = struct { source: u32 = 0, divider: u32 = 1, pre_divider: u32 = 1 };

/// A field: its register, its lowest bit, its width.
const Field = struct { register: usize, shift: u5, width: u5 };

fn field(register: usize, shift: u5, width: u5) Field {
    return .{ .register = register, .shift = shift, .width = width };
}

/// Where a peripheral's function clock is chosen: the source, the integer
/// divider (the fractional one beside it stays 0), the SPI's pre-divider.
const ClockFields = struct { source: Field, divider: Field, pre_divider: ?Field = null };

inline fn clockFieldsOf(comptime peripheral: Peripheral) ClockFields {
    return comptime switch (peripheral) {
        .uart0 => .{ .source = field(PERI_CLK_CTRL110, 24, 2), .divider = field(PERI_CLK_CTRL111, 0, 8) },
        .uart1 => .{ .source = field(PERI_CLK_CTRL111, 24, 2), .divider = field(PERI_CLK_CTRL112, 0, 8) },
        .uart2 => .{ .source = field(PERI_CLK_CTRL112, 24, 2), .divider = field(PERI_CLK_CTRL113, 0, 8) },
        .uart3 => .{ .source = field(PERI_CLK_CTRL113, 24, 2), .divider = field(PERI_CLK_CTRL114, 0, 8) },
        .uart4 => .{ .source = field(PERI_CLK_CTRL114, 24, 2), .divider = field(PERI_CLK_CTRL115, 0, 8) },
        .i2c0 => .{ .source = field(PERI_CLK_CTRL10, 0, 1), .divider = field(PERI_CLK_CTRL10, 2, 8) },
        .i2c1 => .{ .source = field(PERI_CLK_CTRL10, 26, 1), .divider = field(PERI_CLK_CTRL11, 0, 8) },
        .spi2 => .{
            .source = field(PERI_CLK_CTRL116, 0, 3),
            .divider = field(PERI_CLK_CTRL116, 12, 8),
            .pre_divider = field(PERI_CLK_CTRL116, 4, 8),
        },
        .spi3 => .{
            .source = field(PERI_CLK_CTRL116, 21, 3),
            .divider = field(PERI_CLK_CTRL117, 8, 8),
            .pre_divider = field(PERI_CLK_CTRL117, 0, 8),
        },
        else => @compileError("no function clock to choose: " ++ @tagName(peripheral)),
    };
}

inline fn setField(comptime at: Field, value: u32) void {
    const mask: u32 = ((@as(u32, 1) << at.width) - 1) << at.shift;
    update(at.register, (value << at.shift) & mask, mask);
}

/// The peripheral's function clock taken from `clock.source`, divided as
/// `clock` says. The clock is better off while it changes: the
/// peripheral's own state machine runs on it.
pub inline fn setFunctionClock(comptime peripheral: Peripheral, clock: FunctionClock) void {
    const fields = comptime clockFieldsOf(peripheral);
    setField(fields.source, clock.source);
    setField(fields.divider, clock.divider - 1);
    if (fields.pre_divider) |pre| setField(pre, clock.pre_divider - 1);
}

/// HP_SYSTEM's CPU_INT_FROM_CPU_0..3, a word each: writing 1 raises
/// source `INTB_FROM_CPU_INTR0 + n`, writing 0 lowers it.
pub const CPU_INTR_FROM_CPU_0: usize = map.HP_SYS + 0x10;

/// The ROM's software_reset, through the ROM's table of entry points,
/// which is at the same place in every revision's ROM.
const rom_software_reset: *const fn () callconv(.c) noreturn = @ptrFromInt(0x4FC0_0094);

/// The software system reset: the whole chip, both cores with it. It does
/// not come back.
pub fn resetChip() noreturn {
    rom_software_reset();
}
