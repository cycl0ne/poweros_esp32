// SPDX-License-Identifier: MIT
//! The MAC's RMII side on the ESP32-P4, for emac.device: its pads and its
//! clocks, as the board's part names the lines.
//!
//! **The pads.** RMII's lines change at 50 MHz and go through the
//! IO_MUX's fixed functions - function 3 on each pad wired for one -
//! rather than the GPIO matrix. Each line has two or three pads it can
//! be on (`lines`); a part that names another for it is refused. The
//! management bus (MDC, MDIO) is slow and crosses the matrix, so it may
//! be on any pads. The PHY's reset is a plain output.
//!
//! **The clocks.** The 50 MHz reference clock comes in from the PHY on
//! one of the pads wired for it, and the MAC's receive and send clocks
//! are it divided: by 2 at 100 Mbit/s, by 20 at 10 (`setSpeed`).
//!
//! The clock registers are shared - PERI_CLK_CTRL00 holds the flash's and
//! the PSRAM's clocks too - so every change is a masked read-modify-write
//! (`system.update`), made inside exec's Disable by the caller.

const sdk = @import("sdk");
const hardware = sdk.hardware;
const gpio = hardware.gpio;
const system = hardware.system;
const reg = hardware.mmio.reg;
const st = sdk.expansion.systemtags;
const boardpin = sdk.expansion.boardpin;
const BoardPin = boardpin.BoardPin;
const TagItem = sdk.utility.TagItem;
const UtilityBase = sdk.interface.utility.UtilityBase;

/// HP_SYSTEM's GMAC_CTRL0: the interface the MAC speaks, RMII being 4.
const gmac_ctrl0 = hardware.map.HP_SYS + 0x14C;
const phy_intf_mask: u32 = 0x7 << 2;
const phy_intf_rmii: u32 = 4 << 2;

/// PERI_CLK_CTRL00: the chip driving REF_CLK out itself; the RMII clock
/// on and from the pad (source 0); the receive clock on and from the
/// same pad (source 0).
const ref_clk_out: u32 = 1 << 24;
const rmii_clk_source: u32 = 0x3 << 25;
const rmii_clk_on: u32 = 1 << 27;
const receive_clk_source: u32 = 1 << 28;
const receive_clk_on: u32 = 1 << 29;
/// PERI_CLK_CTRL01: the receive clock's divider (less one), the send
/// clock's source (0, the same pad), the send clock on, its divider.
const receive_div_mask: u32 = 0xFF;
const send_clk_source: u32 = 1 << 8;
const send_clk_on: u32 = 1 << 9;
const send_div_shift = 10;
const send_div_mask: u32 = 0xFF << send_div_shift;
/// LP_CLKRST's HP_CLK_CTRL: which of the MAC's clock pads are taken in -
/// RMII's one, not MII's two.
const pad_send_clk: u32 = 1 << 13;
const pad_receive_clk: u32 = 1 << 14;
const pad_ref_clk: u32 = 1 << 15;

/// The receive and send clocks' dividers, less one: 50 MHz to 25 and to
/// 2.5.
const div_100: u32 = 2 - 1;
const div_10: u32 = 20 - 1;

/// The IO_MUX function every RMII line is on its pads.
const function_emac: u3 = 3;

/// The GPIO matrix's signals: the management bus's, and the inputs the
/// IO_MUX delivers straight, whose matrix select is turned off.
const signal_mdc: u32 = 108;
const signal_mdio_out: u32 = 109;
const signal_mdio_in: u32 = 107;
const signal_crs_dv: u32 = 109;
const signal_rxd0: u32 = 179;
const signal_rxd1: u32 = 180;

/// An RMII line: its tag, the pads it can be on, whether it comes in,
/// and the signal it delivers past the matrix if it has one.
const Line = struct {
    tag: u32,
    pads: []const u8,
    input: bool = false,
    signal: ?u32 = null,
};

const lines = [_]Line{
    .{ .tag = st.PART_PinRefClock, .pads = &.{ 32, 44, 50 }, .input = true },
    .{ .tag = st.PART_PinTxEnable, .pads = &.{ 33, 40, 49 } },
    .{ .tag = st.PART_PinTxd0, .pads = &.{ 34, 41 } },
    .{ .tag = st.PART_PinTxd1, .pads = &.{ 35, 42 } },
    .{ .tag = st.PART_PinCrsDv, .pads = &.{ 28, 45, 51 }, .input = true, .signal = signal_crs_dv },
    .{ .tag = st.PART_PinRxd0, .pads = &.{ 29, 46, 52 }, .input = true, .signal = signal_rxd0 },
    .{ .tag = st.PART_PinRxd1, .pads = &.{ 30, 47, 53 }, .input = true, .signal = signal_rxd1 },
};

/// Where the part's lines are.
pub const Pins = extern struct {
    /// The RMII lines' pads, in the order of `lines`.
    pads: [lines.len]u8 = @splat(0),
    mdc: u8 = 0,
    mdio: u8 = 0,
    /// The PHY's reset, if it has one the chip drives.
    reset: BoardPin = .{},
};

/// The part's lines, or null if one is missing, not a pad of the chip,
/// or on a pad that cannot carry it.
pub fn pinsOf(utility: *UtilityBase, tags: ?[*]const TagItem) ?Pins {
    var pins: Pins = .{};
    for (lines, &pins.pads) |line, *pad| {
        pad.* = padOf(utility, tags, line.tag) orelse return null;
        var allowed = false;
        for (line.pads) |one| allowed = allowed or one == pad.*;
        if (!allowed) return null;
    }
    pins.mdc = padOf(utility, tags, st.PART_PinMDC) orelse return null;
    pins.mdio = padOf(utility, tags, st.PART_PinMDIO) orelse return null;
    pins.reset = BoardPin.of(utility.GetTagData(st.PART_PinReset, 0, tags));
    if (pins.reset.wired() and pins.reset.kind != boardpin.BPIN_GPIO) pins.reset = .{};
    return pins;
}

fn padOf(utility: *UtilityBase, tags: ?[*]const TagItem, tag: u32) ?u8 {
    const pin = BoardPin.of(utility.GetTagData(tag, 0, tags));
    if (pin.kind != boardpin.BPIN_GPIO or pin.number > gpio.max_pin) return null;
    return pin.number;
}

/// The PHY's reset line asserted or let go, if the chip drives it.
pub fn holdPhy(pins: *const Pins, held: bool) void {
    const line = pins.reset;
    if (!line.wired()) return;
    gpio.toMatrix(line.number);
    gpio.connectOut(line.number, gpio.out_of_gpio, true);
    gpio.setLevel(line.number, held == (line.active_low == 0));
    gpio.outputEnable(line.number, true);
}

/// The RMII lines onto their pads, the management bus through the
/// matrix. No pull resistors: the PHY drives every line, and the
/// management bus has its own pull-ups.
pub fn connect(pins: *const Pins) void {
    for (lines, pins.pads) |line, pad| {
        gpio.noPull(pad);
        gpio.inputEnable(pad, line.input);
        if (line.signal) |signal| gpio.connectInDirect(signal);
        gpio.toFunction(pad, function_emac);
    }
    gpio.noPull(pins.mdc);
    gpio.toMatrix(pins.mdc);
    gpio.connectOut(pins.mdc, signal_mdc, false);
    gpio.noPull(pins.mdio);
    gpio.toMatrix(pins.mdio);
    gpio.inputEnable(pins.mdio, true);
    gpio.connectOut(pins.mdio, signal_mdio_out, false);
    gpio.connectIn(signal_mdio_in, pins.mdio);
}

/// The MAC's bus clock on and the MAC through a reset; RMII chosen, with
/// the reference clock coming in from the PHY, and the receive and send
/// clocks made from it for 100 Mbit/s.
pub fn clockOn() void {
    system.enable(.emac);
    system.update(gmac_ctrl0, phy_intf_rmii, phy_intf_mask);
    system.update(system.PERI_CLK_CTRL00, rmii_clk_on | receive_clk_on, ref_clk_out | rmii_clk_source | receive_clk_source);
    system.update(system.PERI_CLK_CTRL01, send_clk_on | div_100 << send_div_shift | div_100, send_clk_source | send_div_mask | receive_div_mask);
    system.update(system.LP_HP_CLK_CTRL, pad_ref_clk, pad_send_clk | pad_receive_clk);
}

/// The receive and send clocks for the line's speed.
pub fn setSpeed(fast: bool) void {
    const div = if (fast) div_100 else div_10;
    system.update(system.PERI_CLK_CTRL01, div << send_div_shift | div, send_div_mask | receive_div_mask);
}

/// The station address the factory burned into eFuse: the chip's base
/// address, which is the Ethernet port's. EFUSE_RD_MAC_SYS_0 holds its
/// last four bytes, the last lowest; _1's low half the first two.
pub fn factoryAddress() [6]u8 {
    const low = reg(hardware.map.EFUSE + 0x44).*;
    const high = reg(hardware.map.EFUSE + 0x48).*;
    return .{
        @truncate(high >> 8), @truncate(high),
        @truncate(low >> 24), @truncate(low >> 16),
        @truncate(low >> 8),  @truncate(low),
    };
}
