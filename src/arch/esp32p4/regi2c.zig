// SPDX-License-Identifier: MPL-2.0
//! The analog blocks' registers - the PLLs', the SAR ADC's, the bias's -
//! which sit behind the chip's internal analog I2C bus rather than on the
//! system bus. The LP block's master (LP_I2C_ANA_MST) reaches them: the
//! block is selected in ANA_CONF2, then one control word starts a read or
//! a write of one 8-bit register, and BUSY says when it is done.
//!
//! As ESP-IDF v6.1's esp_hal_regi2c/esp32p4/regi2c_impl.c drives it.

const hardware = @import("sdk").hardware;
const reg = hardware.mmio.reg;

/// The blocks, by their bus address, and the bit in ANA_CONF2 that
/// selects each.
pub const Block = enum(u8) {
    /// The MSPI PLL (MPLL), PSRAM's clock.
    mpll = 0x63,
    cpu_pll = 0x67,
    sar_adc = 0x69,
    bias = 0x6A,
    dig_reg = 0x6D,

    fn selectBit(block: Block) u32 {
        return switch (block) {
            .mpll => 1 << 9,
            .cpu_pll => 1 << 11,
            .sar_adc => 1 << 7,
            .bias => 1 << 12,
            .dig_reg => 1 << 10,
        };
    }
};

const master = hardware.map.LP_I2C_ANA_MST;
/// I2C0_CTRL: the block (bits 0-7), the register (8-15), the data (16-23),
/// write rather than read (24), busy (25).
const control = master + 0x00;
const ana_conf1 = master + 0x1C;
const ana_conf2 = master + 0x20;
const busy: u32 = 1 << 25;
const write_bit: u32 = 1 << 24;
/// LPPERI_CLK_EN: the master's clock (on from reset).
const lpperi_clk_en = hardware.map.LPPERI + 0x000;
const master_clock: u32 = 1 << 27;

fn select(block: Block) void {
    reg(lpperi_clk_en).* |= master_clock;
    reg(ana_conf2).* &= ~@as(u32, 0xFF_FFFF);
    reg(ana_conf1).* &= ~@as(u32, 0xFF_FFFF);
    reg(ana_conf2).* |= block.selectBit();
}

fn idle() void {
    while (reg(control).* & busy != 0) {}
}

/// `register` of `block` set to `value`.
pub fn write(block: Block, register: u8, value: u8) void {
    select(block);
    idle();
    reg(control).* = @intFromEnum(block) | @as(u32, register) << 8 | @as(u32, value) << 16 | write_bit;
    idle();
}

/// What `register` of `block` holds.
pub fn read(block: Block, register: u8) u8 {
    select(block);
    idle();
    reg(control).* = @intFromEnum(block) | @as(u32, register) << 8;
    idle();
    return @truncate(reg(control).* >> 16);
}

/// Bits `lsb` to `msb` of `register` of `block` set to `value`, the others
/// kept.
pub fn writeMask(block: Block, register: u8, msb: u3, lsb: u3, value: u8) void {
    const width: u4 = @as(u4, msb) - lsb + 1;
    const field: u8 = @truncate((@as(u16, 1) << width) - 1);
    const kept = read(block, register) & ~(field << lsb);
    write(block, register, kept | ((value & field) << lsb));
}
