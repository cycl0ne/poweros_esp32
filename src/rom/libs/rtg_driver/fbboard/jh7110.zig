// SPDX-License-Identifier: MPL-2.0
//! The JH7110's way to its HDMI port (CHIP_JH7110_DC8200): the VOUT power
//! domain, its clocks and resets, Innosilicon's HDMI transmitter and its
//! PHY, and Verisilicon's DC8200 display controller, which reads the
//! picture out of RAM. One mode - 1920x1080 at 60 Hz, 32 bits a pixel -
//! as the board's own firmware sets it up: the transmitter's PLL is set
//! for that pixel clock, and nothing reads the monitor's EDID.
//!
//! The steps and the values are U-Boot's (StarFive's sf_vop.c and
//! sf_hdmi.c), which takes all of it down again before it starts the
//! kernel, the power domain included. The controller's registers are
//! written as U-Boot writes them, a list of values with no names behind
//! most of them; the ones that matter here are named: where the picture
//! is (FRAMEBUFFER_ADDRESS), how far apart its rows are, and what starts
//! the display.
//!
//! Nothing here is read before its domain is on: a register of a block
//! that is off does not answer, and the bus waits for it.

const sdk = @import("sdk");
const reg = sdk.hardware.mmio.reg;

/// The power management unit: a domain is switched by writing its bit to
/// the switch register and the "encourage" sequence after it.
const PMU: usize = 0x1703_0000;
const PMU_SW_TURN_ON = PMU + 0x0C;
const PMU_SW_ENCOURAGE = PMU + 0x44;
const PMU_CURR_POWER_MODE = PMU + 0x80;
const DOMAIN_VOUT: u32 = 1 << 4;
const ENCOURAGE = [_]u32{ 0xFF, 0x05, 0x50 };

/// The system clock and reset generator: a clock's register is its
/// number times four, bit 31 lets it through; a reset is held while its
/// bit is set in ASSERT and is out once it is set in STATUS.
const SYS_CRG: usize = 0x1302_0000;
const SYSCLK_VOUT_SRC = SYS_CRG + 58 * 4;
const SYSCLK_NOC_BUS_DISP_AXI = SYS_CRG + 60 * 4;
const SYSCLK_VOUT_TOP_AHB = SYS_CRG + 61 * 4;
const SYSCLK_VOUT_TOP_AXI = SYS_CRG + 62 * 4;
const SYSCLK_VOUT_TOP_HDMITX0_MCLK = SYS_CRG + 63 * 4;
const SYS_RESET_ASSERT0 = SYS_CRG + 0x2F8;
const SYS_RESET_ASSERT1 = SYS_CRG + 0x2FC;
const SYS_RESET_STATUS0 = SYS_CRG + 0x308;
const SYS_RESET_STATUS1 = SYS_CRG + 0x30C;
const SYSRST_NOC_BUS_DISP_AXI: u32 = 1 << 26;
const SYSRST_VOUT_TOP_SRC: u32 = 1 << (43 - 32);
const CLK_ENABLE: u32 = 1 << 31;

/// The VOUT domain's own clock and reset generator, laid out the same
/// way. The controller's pixel clock is the VOUT source (PLL2, 1188 MHz)
/// divided by 8: 148.5 MHz.
const VOUT_CRG: usize = 0x295C_0000;
const VOUTCLK_DC8200_PIX = VOUT_CRG + 1 * 4;
const VOUTCLK_DC8200_AXI = VOUT_CRG + 4 * 4;
const VOUTCLK_DC8200_CORE = VOUT_CRG + 5 * 4;
const VOUTCLK_DC8200_AHB = VOUT_CRG + 6 * 4;
const VOUTCLK_DC8200_PIX0 = VOUT_CRG + 7 * 4;
const VOUTCLK_DC8200_PIX1 = VOUT_CRG + 8 * 4;
const VOUTCLK_HDMI_TX_MCLK = VOUT_CRG + 15 * 4;
const VOUTCLK_HDMI_TX_BCLK = VOUT_CRG + 16 * 4;
const VOUTCLK_HDMI_TX_SYS = VOUT_CRG + 17 * 4;
const VOUT_RESET_ASSERT = VOUT_CRG + 0x48;
const VOUT_RESET_STATUS = VOUT_CRG + 0x4C;
const VOUTRST_DC8200: u32 = 1 << 0 | 1 << 1 | 1 << 2;
const VOUTRST_HDMI_TX: u32 = 1 << 9;
const PIXEL_DIVIDER: u32 = 8;

/// The HDMI transmitter: register n is at n times four.
const HDMI: usize = 0x2959_0000;
const HDMI_STATUS = 0xC8;
const STATUS_HOTPLUG: u32 = 1 << 7;
const PLL_PRE = 0x1A0;
const PLL_PRE_LOCKED = 0x1A9;
const PLL_POST = 0x1AA;
const PLL_POST_LOCKED = 0x1AF;
const PLL_OFF: u32 = 1 << 0;

/// The transmitter's PLLs set for 148.5 MHz from its 24 MHz reference:
/// U-Boot's table for 1080p at 60 Hz.
const pll_1080p60 = [_][2]u32{
    .{ 0x1A0, 0x01 }, .{ 0x1AA, 0x0F }, .{ 0x1A1, 0x01 }, .{ 0x1A2, 0xF0 },
    .{ 0x1A3, 0x63 }, .{ 0x1A4, 0x15 }, .{ 0x1A5, 0x41 }, .{ 0x1A6, 0x42 },
    .{ 0x1AB, 0x01 }, .{ 0x1AC, 0x14 }, .{ 0x1AD, 0x01 }, .{ 0x1AA, 0x0E },
    .{ 0x1A0, 0x00 },
};
/// CEA-861's number for 1920x1080p at 60 Hz, which the transmitter sends.
const VIC_1080P60: u32 = 16;

/// The display controller.
const DC: usize = 0x2940_0000;
/// Its interrupts: reading ACKNOWLEDGE says which came since it was last
/// read, and clears them; ENABLE says which may come, and `start` lets
/// them, as U-Boot does.
const INTERRUPT_ACKNOWLEDGE = 0x0010;
const INTERRUPT_ENABLE = 0x0014;
const FRAMEBUFFER_ADDRESS = 0x1400;
const FRAMEBUFFER_STRIDE = 0x1408;
const PANEL_START = 0x1CCC;
/// The primary plane's extra configuration, with its shadow bit, and the
/// panel's, whose bit 0 holds the shadow registers while it is set: what
/// is written meanwhile is taken together once both are let go.
const FRAMEBUFFER_CONFIG_EX = 0x1CC0;
const FRAMEBUFFER_SHADOW: u32 = 1 << 12;
const PANEL_CONFIG_EX = 0x2518;
const PANEL_HOLD: u32 = 1 << 0;
/// The cursor plane: an ARGB8888 image 32 or 64 pixels square, laid over
/// the picture by the controller with its hot spot at LOCATION. Format 0
/// is no cursor; VALID stays set either way, as U-Boot and Linux leave it.
const CURSOR_CONFIG = 0x1468;
const CURSOR_ADDRESS = 0x146C;
const CURSOR_LOCATION = 0x1470;
const CURSOR_ARGB8888: u32 = 2;
const CURSOR_VALID: u32 = 1 << 2;
const CURSOR_UPDATE: u32 = 1 << 3;
const CURSOR_SIZE_64: u32 = 1 << 5;

/// One mode.
pub const width = 1920;
pub const height = 1080;
pub const pixel_clock_hz = 148_500_000;
pub const refresh_mhz = 60_000;

/// How many times a wait reads its register before it gives up.
const patience: u32 = 1_000_000;

/// Why the display did not come up.
pub const Failure = enum { none, power, pll };

fn hdmi(index: usize) *volatile u32 {
    return reg(HDMI + index * 4);
}

fn dc(offset: usize) *volatile u32 {
    return reg(DC + offset);
}

fn on(clock: usize) void {
    reg(clock).* |= CLK_ENABLE;
}

/// Resets `bits` of ASSERT let go, and waited for in STATUS.
fn release(assert: usize, status: usize, bits: u32) void {
    reg(assert).* &= ~bits;
    var tries: u32 = 0;
    while (reg(status).* & bits != bits and tries < patience) : (tries += 1) {}
}

/// Whether `index` came to have bit 0 set.
fn locked(index: usize) bool {
    var tries: u32 = 0;
    while (tries < patience) : (tries += 1) {
        if (hdmi(index).* & 1 != 0) return true;
    }
    return false;
}

/// The VOUT domain switched on, if it is off.
fn powerOn() bool {
    if (reg(PMU_CURR_POWER_MODE).* & DOMAIN_VOUT != 0) return true;
    reg(PMU_SW_TURN_ON).* = DOMAIN_VOUT;
    for (ENCOURAGE) |value| reg(PMU_SW_ENCOURAGE).* = value;
    var tries: u32 = 0;
    while (tries < patience) : (tries += 1) {
        if (reg(PMU_CURR_POWER_MODE).* & DOMAIN_VOUT != 0) return true;
    }
    return false;
}

/// Whether a monitor is on the port: the transmitter's hot-plug line.
/// Only once `start` has the transmitter out of reset.
pub fn monitor() bool {
    return hdmi(HDMI_STATUS).* & STATUS_HOTPLUG != 0;
}

/// The display brought up, showing the picture at `address` - 1920x1080,
/// 32 bits a pixel, rows `pitch` bytes apart, below 4 GiB and out of the
/// caches. `waiter.wait(micros)` waits that long.
pub fn start(address: usize, pitch: u32, waiter: anytype) Failure {
    if (!powerOn()) return .power;
    waiter.wait(50_000);

    // The bus to the domain and the domain's own clocks, as U-Boot's
    // vout_probe_resources_jh7110 has them.
    on(SYSCLK_NOC_BUS_DISP_AXI);
    release(SYS_RESET_ASSERT0, SYS_RESET_STATUS0, SYSRST_NOC_BUS_DISP_AXI);
    on(SYSCLK_VOUT_SRC);
    on(SYSCLK_VOUT_TOP_AXI);
    on(SYSCLK_VOUT_TOP_AHB);
    release(SYS_RESET_ASSERT1, SYS_RESET_STATUS1, SYSRST_VOUT_TOP_SRC);
    // The pixel clock from the divider, not the transmitter's PLL.
    reg(VOUTCLK_DC8200_PIX).* = PIXEL_DIVIDER;
    reg(VOUTCLK_DC8200_PIX0).* = CLK_ENABLE;
    reg(VOUTCLK_DC8200_PIX1).* = CLK_ENABLE;
    on(VOUTCLK_DC8200_AXI);
    on(VOUTCLK_DC8200_CORE);
    on(VOUTCLK_DC8200_AHB);
    release(VOUT_RESET_ASSERT, VOUT_RESET_STATUS, VOUTRST_DC8200);

    // The transmitter: its clocks, out of reset (inno_hdmi_probe).
    on(SYSCLK_VOUT_TOP_HDMITX0_MCLK);
    on(VOUTCLK_HDMI_TX_SYS);
    on(VOUTCLK_HDMI_TX_MCLK);
    on(VOUTCLK_HDMI_TX_BCLK);
    release(VOUT_RESET_ASSERT, VOUT_RESET_STATUS, VOUTRST_HDMI_TX);

    // Its PHY (inno_hdmi_enable): the PLLs on and locked, the LDO and the
    // serializer on; powered down while the PLLs are set for the mode and
    // the mode is set, up again with its drivers on.
    hdmi(0x1B0).* |= 0x4;
    hdmi(0x1CC).* = 0xF;
    hdmi(PLL_PRE).* &= ~PLL_OFF;
    hdmi(PLL_POST).* &= ~PLL_OFF;
    if (!locked(PLL_PRE_LOCKED) or !locked(PLL_POST_LOCKED)) return .pll;
    hdmi(0x1B4).* = 0x7;
    hdmi(0x1BE).* = 0x70;
    hdmi(0x00).* = 0x63;
    for (pll_1080p60) |pair| hdmi(pair[0]).* = pair[1];
    hdmi(0x9F).* = 0x06;
    hdmi(0xA0).* = 0x82;
    hdmi(0xA2).* = 0x0D;
    hdmi(0xA3).* = 0x00;
    hdmi(0xA4).* = 0x00;
    hdmi(0xA5).* = 0x08;
    hdmi(0xA6).* = 0x70;
    hdmi(0xA7).* = VIC_1080P60;
    hdmi(0xC9).* = 0x10;
    hdmi(0x00).* = 0x61;
    hdmi(0x1B2).* = 0x8F;
    waiter.wait(50_000);
    hdmi(0xCE).* = 0x00;
    hdmi(0xCE).* = 0x01;

    // The controller: 1920x1080 at 60 Hz from the picture at `address`,
    // to the transmitter (sf_display_init).
    dc(INTERRUPT_ENABLE).* = 0xC000_1FFF;
    dc(0x1CC0).* = 0x0000_2000;
    dc(0x1800).* = 0x0000_0000;
    dc(0x24D8).* = 0x0000_0000;
    dc(0x24E0).* = 0x021C_0780;
    dc(0x1810).* = 0x021C_0780;
    dc(FRAMEBUFFER_ADDRESS).* = @truncate(address);
    dc(FRAMEBUFFER_STRIDE).* = pitch;
    dc(0x1CE8).* = 0x0000_0F61;
    dc(0x2510).* = 0x0000_2042;
    dc(0x2508).* = 0x808A_3156;
    dc(0x2500).* = 0x8008_E1B2;
    dc(0x1518).* = 0x1800_0000;
    dc(0x1CC0).* = 0x0000_3000;
    dc(0x1540).* = 0x0006_0000;
    dc(0x2540).* = 0x0000_0001;
    dc(0x1540).* = 0x8006_0000;
    dc(0x1544).* = 0x0006_0000;
    dc(0x2544).* = 0x0000_0002;
    dc(0x1544).* = 0x8006_0000;
    dc(0x1548).* = 0x0006_0000;
    dc(0x2548).* = 0x0000_000C;
    dc(0x1548).* = 0x8006_0000;
    dc(0x154C).* = 0x0006_0000;
    dc(0x254C).* = 0x0000_000D;
    dc(0x154C).* = 0x8006_0000;
    dc(0x2518).* = 0x0000_0001;
    dc(0x1A28).* = 0x0000_0000;
    dc(0x1430).* = 0x0898_0780;
    dc(0x1438).* = 0x4402_07D8;
    dc(0x1440).* = 0x0465_0438;
    dc(0x1448).* = 0x4220_843C;
    dc(0x14B0).* = 0x0000_0000;
    dc(0x1CD0).* = 0x0000_00D2;
    dc(0x14B8).* = 0x0000_0005;
    dc(0x14D0).* = 0x0000_0052;
    dc(0x1528).* = 0xDEAD_BEEF;
    dc(0x1418).* = 0x0000_1111;
    dc(0x1410).* = 0x0000_0000;
    dc(0x2518).* = 0x0000_0000;
    dc(0x1468).* = 0x0020_0024;
    dc(0x1484).* = 0x0000_0000;
    dc(0x1468).* = 0x0020_0024;
    dc(0x24E8).* = 0x0000_0C24;
    dc(0x24FC).* = 0x0000_0000;
    dc(0x24E8).* = 0x0000_0C24;
    dc(PANEL_START).* = 0x0000_0001;
    return .none;
}

/// The shadow registers held, for writes that are to be taken together
/// (`let go`), as Linux's driver writes a plane.
fn hold() void {
    dc(PANEL_CONFIG_EX).* |= PANEL_HOLD;
    dc(FRAMEBUFFER_CONFIG_EX).* &= ~FRAMEBUFFER_SHADOW;
}

fn letGo() void {
    dc(FRAMEBUFFER_CONFIG_EX).* |= FRAMEBUFFER_SHADOW;
    dc(PANEL_CONFIG_EX).* &= ~PANEL_HOLD;
}

/// What the controller raised since this was last asked, cleared: 0 when
/// the interrupt was not its.
pub fn takeInterrupts() u32 {
    return dc(INTERRUPT_ACKNOWLEDGE).*;
}

/// The picture at `address` shown from now on.
pub fn show(address: usize) void {
    hold();
    dc(FRAMEBUFFER_ADDRESS).* = @truncate(address);
    letGo();
}

/// The largest cursor image, each way.
pub const cursor_side = 64;

/// The cursor plane, all of it at once as Linux's driver writes it: the
/// image at `address` (`cursor_side` square, or half that when `small`),
/// its hot spot at (x, y) on the picture, shown or not. A new place alone
/// is not taken: the controller fetches it with the configuration, whose
/// UPDATE is written after it.
pub fn cursor(address: usize, small: bool, hot_x: u32, hot_y: u32, x: u32, y: u32, shown: bool) void {
    hold();
    dc(CURSOR_ADDRESS).* = @truncate(address);
    dc(CURSOR_LOCATION).* = (x & 0x3FFF) | (y & 0x3FFF) << 16;
    const config = (hot_x & 0xFF) << 16 | (hot_y & 0xFF) << 8 | (if (small) 0 else CURSOR_SIZE_64) | CURSOR_UPDATE | CURSOR_VALID;
    dc(CURSOR_CONFIG).* = if (shown) config | CURSOR_ARGB8888 else config;
    letGo();
}
