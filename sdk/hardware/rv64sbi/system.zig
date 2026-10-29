// SPDX-License-Identifier: MIT
//! The machine as a whole: its reset, which is the SBI firmware's; and on
//! the JH7110 the peripherals' clocks and resets, which four clock and
//! reset generators keep.
//!
//! **A generator** has a word per clock - clock n at n times four - and
//! words of reset bits. A clock's word lets it through with bit 31,
//! inverts it with bit 30, picks its source in bits 24 to 27 and divides
//! it by the bits below; each clock has the ones it has. Reset n is bit
//! n % 32 of word n / 32: held while it is set in ASSERT, out once it
//! reads set in STATUS. A reset comes off only while its clock runs.
//!
//! **What the firmware leaves is not counted on.** U-Boot holds most of
//! the chip in reset with its clocks off as it starts the kernel - the
//! STG domain's every block, the display, the sound, the Ethernet MAC -
//! and each driver turns on, sets and lets go what it uses. What the
//! firmware needs for itself it sets up before the kernel and leaves
//! running: the PLLs, the buses, UART0 and I2C5's pads. PLL0, the cores'
//! clock, the kernel sets again as it starts (`cpuclock.zig`).
//!
//! **Every change is a read-modify-write of a register other drivers
//! share** - a reset word, the pin controller's (`gpio.zig`), a syscon's
//! - so each one is done with the hart's interrupts masked (`update`): a
//! task switch between the read and the write would put back a word
//! without the bit another driver had set meanwhile. Masking at the hart
//! rather than through exec's Disable lets the kernel use the same
//! helpers before exec runs.
//!
//! **Four harts** share the registers too, and masking holds off only the
//! caller's own. So a driver - once the system runs - makes its changes
//! inside exec's Disable, which keeps the other harts' Disables out as
//! well: every change made that way is made alone. The wait for a reset to
//! come off (`waitOutOfReset`) is made after it.
//!
//! The clocks and resets are numbered as in Linux's binding
//! (dt-bindings/clock/starfive,jh7110-crg.h and its reset twin), and
//! named as there.

const sbi = @import("sbi.zig");
const mmio = @import("mmio.zig");

/// What the board does to the machine before the firmware resets it,
/// which the kernel sets from the board: the VisionFive 2 resets the chip
/// itself through its watchdog, which does not return, and should that
/// fail readies the I2C bus U-Boot left in reset, over which its firmware
/// resets it.
pub var before_reset: ?*const fn () void = null;

/// The whole machine restarted: a cold reboot through the firmware. If
/// the firmware refuses, the hart stops here.
pub fn resetChip() noreturn {
    if (before_reset) |prepare| prepare();
    _ = sbi.systemReset(sbi.RESET_COLD_REBOOT, sbi.REASON_NONE);
    while (true) asm volatile ("wfi");
}

// --- the JH7110's clock and reset generators -----------------------------------

/// The generators, by where they are: the system domain's, the STG
/// domain's (PCIe, the DMA controller, the security block), the always-on
/// domain's, and the VOUT domain's, which answers only while that domain
/// is powered.
pub const Generator = enum(usize) {
    sys = 0x1302_0000,
    stg = 0x1023_0000,
    aon = 0x1700_0000,
    vout = 0x295C_0000,
};

/// A clock's word: let through, inverted, its source, its divider.
pub const CLK_ENABLE: u32 = 1 << 31;
pub const CLK_INVERT: u32 = 1 << 30;
pub const CLK_MUX_SHIFT = 24;
pub const CLK_MUX: u32 = 0xF << CLK_MUX_SHIFT;
pub const CLK_DIVIDER: u32 = 0x00FF_FFFF;

/// The system generator's clocks.
pub const SYSCLK_CPU_ROOT = 0;
pub const SYSCLK_CPU_CORE = 1;
pub const SYSCLK_PERH_ROOT = 4;
pub const SYSCLK_PLL0_DIV2 = 13;
pub const SYSCLK_AUDIO_ROOT = 16;
pub const SYSCLK_MCLK = 18;
pub const SYSCLK_GCLK0 = 22;
pub const SYSCLK_VOUT_SRC = 58;
pub const SYSCLK_NOC_BUS_DISP_AXI = 60;
pub const SYSCLK_VOUT_TOP_AHB = 61;
pub const SYSCLK_VOUT_TOP_AXI = 62;
pub const SYSCLK_VOUT_TOP_HDMITX0_MCLK = 63;
pub const SYSCLK_CODAJ12_AXI = 66;
pub const SYSCLK_CODAJ12_CORE = 67;
pub const SYSCLK_CODAJ12_APB = 68;
pub const SYSCLK_WAVE511_AXI = 70;
pub const SYSCLK_WAVE511_BPU = 71;
pub const SYSCLK_WAVE511_VCE = 72;
pub const SYSCLK_WAVE511_APB = 73;
pub const SYSCLK_VDEC_JPG = 74;
pub const SYSCLK_VDEC_MAIN = 75;
pub const SYSCLK_NOC_BUS_VDEC_AXI = 76;
pub const SYSCLK_QSPI_REF_SRC = 89;
pub const SYSCLK_SDIO1_AHB = 92;
pub const SYSCLK_SDIO1_SDCARD = 94;
pub const SYSCLK_USB_125M = 95;
pub const SYSCLK_NOC_BUS_STG_AXI = 96;
pub const SYSCLK_GMAC_SRC = 99;
pub const SYSCLK_GMAC1_GTXCLK = 100;
pub const SYSCLK_GMAC0_GTXCLK = 108;
pub const SYSCLK_GMAC0_PTP = 109;
pub const SYSCLK_GMAC0_GTXC = 111;
pub const SYSCLK_WDT_APB = 122;
pub const SYSCLK_WDT_CORE = 123;
pub const SYSCLK_TEMP_APB = 129;
pub const SYSCLK_TEMP_CORE = 130;
pub const SYSCLK_I2C5_APB = 143;
pub const SYSCLK_PWMDAC_APB = 157;
pub const SYSCLK_PWMDAC_CORE = 158;
pub const SYSCLK_I2STX0_APB = 161;
pub const SYSCLK_I2STX0_BCLK_MST = 162;
pub const SYSCLK_I2STX0_LRCK_MST = 164;
pub const SYSCLK_I2STX0_BCLK = 165;
pub const SYSCLK_I2STX0_LRCK = 167;

/// The STG generator's: a PCIe port's three are its AXI master's, its
/// APB's and its transaction layer's, port 1's three after port 0's.
pub const STGCLK_PCIE0_AXI_MST0 = 8;
pub const STGCLK_SEC_AHB = 15;
pub const STGCLK_SEC_MISC_AHB = 16;
pub const STGCLK_DMA1P_AXI = 27;
pub const STGCLK_DMA1P_AHB = 28;

/// The always-on generator's.
pub const AONCLK_GMAC0_AHB = 2;
pub const AONCLK_GMAC0_AXI = 3;
pub const AONCLK_GMAC0_RMII_RTX = 4;
pub const AONCLK_GMAC0_TX = 5;
pub const AONCLK_RTC_APB = 10;

/// The VOUT generator's.
pub const VOUTCLK_DC8200_PIX = 1;
pub const VOUTCLK_DC8200_AXI = 4;
pub const VOUTCLK_DC8200_CORE = 5;
pub const VOUTCLK_DC8200_AHB = 6;
pub const VOUTCLK_DC8200_PIX0 = 7;
pub const VOUTCLK_DC8200_PIX1 = 8;
pub const VOUTCLK_HDMI_TX_MCLK = 15;
pub const VOUTCLK_HDMI_TX_BCLK = 16;
pub const VOUTCLK_HDMI_TX_SYS = 17;

/// The system generator's resets.
pub const SYSRST_NOC_BUS_DISP_AXI = 26;
pub const SYSRST_NOC_BUS_VDEC_AXI = 31;
pub const SYSRST_VOUT_TOP_SRC = 43;
pub const SYSRST_CODAJ12_AXI = 44;
pub const SYSRST_CODAJ12_CORE = 45;
pub const SYSRST_CODAJ12_APB = 46;
pub const SYSRST_WAVE511_AXI = 47;
pub const SYSRST_WAVE511_BPU = 48;
pub const SYSRST_WAVE511_VCE = 49;
pub const SYSRST_WAVE511_APB = 50;
pub const SYSRST_VDEC_JPG = 51;
pub const SYSRST_VDEC_MAIN = 52;
pub const SYSRST_AXIMEM0_AXI = 53;
pub const SYSRST_SDIO1_AHB = 65;
pub const SYSRST_I2C5_APB = 81;
pub const SYSRST_PWMDAC_APB = 96;
pub const SYSRST_I2STX0_APB = 101;
pub const SYSRST_I2STX0_BCLK = 102;
pub const SYSRST_WDT_APB = 109;
pub const SYSRST_WDT_CORE = 110;
pub const SYSRST_TEMP_APB = 123;
pub const SYSRST_TEMP_CORE = 124;

/// The STG generator's: a PCIe port's six are its AXI master's, its two
/// AXI slaves', its bridge's, its core's and its APB's, port 1's six
/// after port 0's.
pub const STGRST_SEC_AHB = 3;
pub const STGRST_DMA1P_AXI = 5;
pub const STGRST_DMA1P_AHB = 6;
pub const STGRST_PCIE0_AXI_MST0 = 11;

/// The always-on generator's.
pub const AONRST_GMAC0_AXI = 0;
pub const AONRST_GMAC0_AHB = 1;
pub const AONRST_RTC_APB = 5;
pub const AONRST_RTC_CAL = 6;
pub const AONRST_RTC_32K = 7;

/// The VOUT generator's.
pub const VOUTRST_DC8200_AXI = 0;
pub const VOUTRST_DC8200_AHB = 1;
pub const VOUTRST_DC8200_CORE = 2;
pub const VOUTRST_HDMI_TX_HDMI = 9;

/// sstatus.SIE: this hart's interrupts on.
const SSTATUS_SIE = 1 << 1;

/// How many times a wait reads its register before it gives up: far
/// longer than a reset takes to come off.
const patience: u32 = 1_000_000;

/// `set` and `clear` applied to the register at `addr` with the hart's
/// interrupts masked, so nothing on this hart runs between the read and
/// the write.
pub inline fn update(addr: usize, set: u32, clear: u32) void {
    const saved = asm volatile ("csrrci %[r], sstatus, 2"
        : [r] "=r" (-> usize),
        :
        : .{ .memory = true });
    const register = mmio.reg(addr);
    register.* = (register.* & ~clear) | set;
    if (saved & SSTATUS_SIE != 0) asm volatile ("csrsi sstatus, 2" ::: .{ .memory = true });
}

/// Clock `n`'s word.
pub inline fn clockRegister(comptime generator: Generator, n: u32) usize {
    return @intFromEnum(generator) + @as(usize, n) * 4;
}

/// Clock `n` let through.
pub inline fn clockOn(comptime generator: Generator, n: u32) void {
    update(clockRegister(generator, n), CLK_ENABLE, 0);
}

/// Clock `n` stopped.
pub inline fn clockOff(comptime generator: Generator, n: u32) void {
    update(clockRegister(generator, n), 0, CLK_ENABLE);
}

/// The bits `mask` of clock `n`'s word set to `value`: its source, its
/// divider, whether it runs.
pub inline fn setClock(comptime generator: Generator, n: u32, mask: u32, value: u32) void {
    update(clockRegister(generator, n), value & mask, mask);
}

fn resetAssert(comptime generator: Generator) usize {
    return @intFromEnum(generator) + switch (generator) {
        .sys => 0x2F8,
        .stg => 0x74,
        .aon => 0x38,
        .vout => 0x48,
    };
}

fn resetStatus(comptime generator: Generator) usize {
    return @intFromEnum(generator) + switch (generator) {
        .sys => 0x308,
        .stg => 0x78,
        .aon => 0x3C,
        .vout => 0x4C,
    };
}

inline fn resetWord(n: u32) usize {
    return @as(usize, n / 32) * 4;
}

inline fn resetBit(n: u32) u32 {
    return @as(u32, 1) << @intCast(n % 32);
}

/// Reset `n` held.
pub inline fn holdInReset(comptime generator: Generator, n: u32) void {
    update(resetAssert(generator) + resetWord(n), resetBit(n), 0);
}

/// Reset `n` let go. It is off once `outOfReset` says so, which takes
/// its clock running.
pub inline fn releaseReset(comptime generator: Generator, n: u32) void {
    update(resetAssert(generator) + resetWord(n), 0, resetBit(n));
}

/// Whether reset `n` is off.
pub inline fn outOfReset(comptime generator: Generator, n: u32) bool {
    return mmio.reg(resetStatus(generator) + resetWord(n)).* & resetBit(n) != 0;
}

/// Whether reset `n`, let go, came off in time. Outside Disable: a reset
/// whose clock does not run never comes off.
pub fn waitOutOfReset(comptime generator: Generator, n: u32) bool {
    var tries: u32 = 0;
    while (tries < patience) : (tries += 1) {
        if (outOfReset(generator, n)) return true;
    }
    return false;
}

// --- the JH7110's power domains ------------------------------------------------

/// The power management unit, in the always-on domain: a domain is
/// switched on by writing its bit to SW_TURN_ON and then the three words
/// that make the unit act on it, and is on once its bit reads set in
/// CURR_POWER_MODE. Numbered as in Linux's binding
/// (dt-bindings/power/starfive,jh7110-pmu.h).
const PMU: usize = 0x1703_0000;
const PMU_SW_TURN_ON = PMU + 0x0C;
const PMU_SW_ENCOURAGE = PMU + 0x44;
const PMU_CURR_POWER_MODE = PMU + 0x80;
const PMU_ENCOURAGE = [_]u32{ 0xFF, 0x05, 0x50 };

/// The video decoder's domain - the WAVE511 and the JPEG codec - and the
/// display's.
pub const PD_VDEC: u32 = 1 << 3;
pub const PD_VOUT: u32 = 1 << 4;

/// Whether the domains `mask` are on.
pub fn powered(mask: u32) bool {
    return mmio.reg(PMU_CURR_POWER_MODE).* & mask == mask;
}

/// The domains `mask` switched on, if they are off; whether they came on
/// in time. The other domains are left as they are. Outside Disable, as
/// `waitOutOfReset`.
pub fn powerOn(mask: u32) bool {
    if (powered(mask)) return true;
    mmio.reg(PMU_SW_TURN_ON).* = mask;
    for (PMU_ENCOURAGE) |value| mmio.reg(PMU_SW_ENCOURAGE).* = value;
    var tries: u32 = 0;
    while (tries < patience) : (tries += 1) {
        if (powered(mask)) return true;
    }
    return false;
}
