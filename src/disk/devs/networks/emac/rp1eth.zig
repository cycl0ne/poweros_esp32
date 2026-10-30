// SPDX-License-Identifier: MIT
//! The RP1's Ethernet port, for emac.device: its one MAC (gem.zig) and what
//! that needs from the rest of the chip.
//!
//! **What the bootloader leaves**, read on a CM5 started over USB: the
//! MAC's clocks running - clk_sys for its bus, clk_eth at 125 MHz from
//! pll_sys_sec for the line, which the MAC divides itself for the slower
//! speeds, so nothing changes with the speed (`setSpeed`). Not left: the
//! PHY, whose reset line is GPIO32, active low (Raspberry Pi's device tree,
//! phy-reset-gpios): undriven, the pin's pull-down holds it in reset.
//!
//! The pin's bank of the RP1's GPIO is shared with others, GPIO28 among
//! them, so its output and enable go through their set and clear aliases:
//! nothing is read and written back.

const sdk = @import("sdk");
const st = sdk.expansion.systemtags;
const reg = sdk.hardware.mmio.reg;
const TagItem = sdk.utility.TagItem;
const UtilityBase = sdk.interface.utility.UtilityBase;
const gem = @import("gem.zig");
const EmacBase = @import("_emac.zig").EmacBase;

/// The parts on this kind of bus.
pub const bus = st.BUS_RGMII;

/// The RP1's peripherals, where the bootloader's window puts them, and the
/// MAC's registers.
const peripherals: usize = 0x1C_0000_0000;
const mac_registers: usize = peripherals + 0x10_0000;

/// clk_eth's control register, what it should hold - on, from pll_sys_sec
/// - and its divider after it.
const CLK_ETH_CTRL: usize = peripherals + 0x1_8064;
const CLK_ETH_DIV_INT: usize = peripherals + 0x1_8068;
const CLK_ENABLE: u32 = 1 << 11;
const CLK_AUXSRC_MASK: u32 = 0x1F << 5;

/// GPIO32, the fifth of the RP1's second bank: its control, its pad and its
/// bank's output (RIO), which has aliases to set and clear. The control's
/// function that gives the pin to RIO.
const PIN_CTRL: usize = peripherals + 0xD_4024;
const PIN_PAD: usize = peripherals + 0xF_4014;
const RIO: usize = peripherals + 0xE_4000;
const RIO_SET: usize = 0x2000;
const RIO_CLR: usize = 0x3000;
const RIO_OUT: usize = 0x0;
const RIO_OE: usize = 0x4;
const pin_bit: u32 = 1 << (32 - 28);
const CTRL_FUNCSEL_MASK: u32 = 0x1F;
const CTRL_OVERRIDES_MASK: u32 = 0xF << 12;
const FUNCSEL_RIO: u32 = 5;
const PAD_IN_ENABLE: u32 = 1 << 6;
const PAD_OUT_DISABLE: u32 = 1 << 7;

/// How long the PHY is held in reset (the device tree's
/// phy-reset-duration), and how long it is given afterwards.
const phy_reset_us = 5_000;
const phy_settle_us = 20_000;

/// The port. The RP1 has one MAC.
pub const Port = extern struct {
    unit: u32 = 0,
};

/// The part's MAC, or null if it names one the RP1 does not have.
pub fn portOf(utility: *UtilityBase, tags: ?[*]const TagItem) ?Port {
    if (utility.GetTagData(st.PART_BusUnit, 0, tags) != 0) return null;
    return .{};
}

/// The MAC ready for its own reset and its PHY out of reset: clk_eth on, if
/// the bootloader left it off, and the PHY's reset line held low and let
/// go.
pub fn powerUp(port: *const Port, base: *EmacBase) bool {
    _ = port;
    const sys = base.sys_base;
    gem.registers = mac_registers;
    const clock = reg(CLK_ETH_CTRL);
    if (clock.* & CLK_ENABLE == 0) {
        reg(CLK_ETH_DIV_INT).* = 1;
        clock.* = (clock.* & ~CLK_AUXSRC_MASK) | CLK_ENABLE;
    }

    sys.Disable();
    reg(RIO + RIO_CLR + RIO_OUT).* = pin_bit;
    reg(RIO + RIO_SET + RIO_OE).* = pin_bit;
    const pad = reg(PIN_PAD);
    pad.* = (pad.* & ~PAD_OUT_DISABLE) | PAD_IN_ENABLE;
    const control = reg(PIN_CTRL);
    control.* = (control.* & ~(CTRL_FUNCSEL_MASK | CTRL_OVERRIDES_MASK)) | FUNCSEL_RIO;
    sys.Enable();
    base.delay(phy_reset_us);
    reg(RIO + RIO_SET + RIO_OUT).* = pin_bit;
    base.delay(phy_settle_us);
    return true;
}

/// Nothing to change for the line's speed: the MAC makes the send clock
/// from clk_eth itself (Linux's MACB_CAPS_CLK_HW_CHG).
pub fn setSpeed(port: *const Port, mbits: u32) void {
    _ = port;
    _ = mbits;
}

/// The RP1 keeps no station address of its own: the board gives it
/// (PART_StationAddress), from what the firmware put in the device tree.
pub fn factoryAddress(port: *const Port) ?[6]u8 {
    _ = port;
    return null;
}
