// SPDX-License-Identifier: MIT
//! The JH7110's cores' clock: PLL0, which the four U74s run from - through
//! CPU_ROOT, which picks it or the 24 MHz oscillator, and CPU_CORE's
//! divider; their bus (CPU_BUS) has half of that - set to a speed the
//! chip has an operating point for, with the supply the point wants
//! (vdd_cpu), which is the board's to set.
//!
//! The points are what the VisionFive 2 runs at: 1000 MHz at 0.9 V, as
//! its firmware leaves it, and 1500 MHz at 1.04 V, which Linux's device
//! tree for it gives the cores (its cpu_opp table) and sets PLL0 to.
//!
//! **PLL0 feeds more than the cores**: the USB controller's 125 MHz, the
//! Ethernet MACs' transmit clocks and their source, the SPI flash's
//! reference, the video encoder, GCLK0 through PLL0_DIV2, and PERH_ROOT
//! when it picks PLL0. Each is kept at the rate the firmware gave it: its
//! divider set again for PLL0's new rate - raised before PLL0 speeds up,
//! lowered after it slows down - so none ever runs faster than it did.
//! PLL0_DIV2 divides by two at the most, so it follows PLL0, 750 MHz at
//! 1.5 GHz as under Linux; GCLK0 below it is kept.
//!
//! **While PLL0 changes**, the cores run from the oscillator, as Linux has
//! them (jh7110_pll0_clk_notifier_cb). The PLL has no lock flag to read,
//! and Linux takes the cores back at once; this waits a millisecond
//! first. The supply is raised before the clock, and lowered after it.
//!
//! Set once, as the kernel starts (`set`): on the one hart that runs,
//! with interrupts off, before exec, the drivers and the other harts, and
//! before the kernel measures the clock. PLL0's registers are the system
//! syscon's, whose words the PCIe host's code shares, so they change
//! through `system.update`.
//!
//! The PLL's registers and presets as Linux's driver has them
//! (clk-starfive-jh7110-pll.c), the clocks as its system generator's
//! (clk-starfive-jh7110-sys.c).

const mmio = @import("mmio.zig");
const system = @import("system.zig");
const systimer = @import("systimer.zig");

/// The oscillator the PLLs multiply, and CPU_ROOT's other source.
const OSC_HZ: u64 = 24_000_000;

/// PLL0's registers in the system syscon: its mode in the first - both
/// bits set for whole numbers, both clear for a fraction - its feedback
/// divider in the second, its fraction and its post divider (a power of
/// two) in the third, its pre-divider in the fourth, whose other bits are
/// PLL1's.
const SYS_SYSCON: usize = 0x1303_0000;
const PLL0_PD = SYS_SYSCON + 0x18;
const PLL0_FBDIV = SYS_SYSCON + 0x1C;
const PLL0_FRAC = SYS_SYSCON + 0x20;
const PLL0_PREDIV = SYS_SYSCON + 0x24;

const PD_DACPD: u32 = 1 << 24;
const PD_DSMPD: u32 = 1 << 25;
const PD_WHOLE = PD_DACPD | PD_DSMPD;
const FBDIV_MASK: u32 = 0xFFF;
const FRAC_MASK: u32 = 0xFF_FFFF;
const POSTDIV1_SHIFT = 28;
const POSTDIV1_MASK: u32 = 3 << POSTDIV1_SHIFT;
const PREDIV_MASK: u32 = 0x3F;

/// CPU_ROOT's sources.
const ROOT_OSC: u32 = 0 << system.CLK_MUX_SHIFT;
const ROOT_PLL0: u32 = 1 << system.CLK_MUX_SHIFT;

/// How long PLL0 is given to settle before the cores go back to it.
const lock_us = 1000;

/// A speed the cores run at: the supply it wants, and PLL0's feedback
/// divider and pre-divider for it - whole numbers, no post divider, the
/// cores' own divider at one.
const Point = struct {
    mhz: u32,
    microvolts: u32,
    fbdiv: u32,
    prediv: u32,
};

const points = [_]Point{
    .{ .mhz = 1000, .microvolts = 900_000, .fbdiv = 125, .prediv = 3 },
    .{ .mhz = 1500, .microvolts = 1_040_000, .fbdiv = 125, .prediv = 2 },
};

/// A clock PLL0 feeds, kept at its rate: its divider's largest value,
/// and for one with a choice of source, the one that is PLL0.
const Kept = struct {
    clock: u32,
    largest: u32,
    pll0_source: ?u32 = null,
};

const kept = [_]Kept{
    .{ .clock = system.SYSCLK_PERH_ROOT, .largest = 2, .pll0_source = 0 },
    .{ .clock = system.SYSCLK_GCLK0, .largest = 62 },
    .{ .clock = system.SYSCLK_WAVE511_VCE, .largest = 7 },
    .{ .clock = system.SYSCLK_QSPI_REF_SRC, .largest = 16 },
    .{ .clock = system.SYSCLK_USB_125M, .largest = 15 },
    .{ .clock = system.SYSCLK_GMAC_SRC, .largest = 7 },
    .{ .clock = system.SYSCLK_GMAC1_GTXCLK, .largest = 15 },
    .{ .clock = system.SYSCLK_GMAC0_GTXCLK, .largest = 15 },
};

pub const Error = error{
    /// The chip has no point at that speed.
    NoSuchSpeed,
    /// The board cannot set the cores' supply.
    NoSupply,
    /// PLL0 is in a mode not read here.
    PllUnknown,
    /// A clock PLL0 feeds could not be kept at its rate.
    ClockNotKept,
    /// The board's supply did not take the voltage.
    SupplyFailed,
};

/// The cores set to `mhz`, one of the chip's points, with `supply` - the
/// board's - setting the voltage the point wants: before the clock when
/// it rises, after it when it falls. Nothing is changed if a clock PLL0
/// feeds could not be kept, or the supply could not be raised.
/// Interrupts off, the other harts not started.
pub fn set(mhz: u32, supply: ?*const fn (microvolts: u32) bool) Error!void {
    const point = for (points) |candidate| {
        if (candidate.mhz == mhz) break candidate;
    } else return error.NoSuchSpeed;
    const setSupply = supply orelse return error.NoSupply;
    const old_hz = pll0Hz();
    if (old_hz == 0) return error.PllUnknown;
    const new_hz = OSC_HZ * point.fbdiv / point.prediv;
    if (old_hz == new_hz and coresHz() == new_hz) {
        if (!setSupply(point.microvolts)) return error.SupplyFailed;
        return;
    }
    var dividers: [kept.len]u32 = undefined;
    for (kept, &dividers) |clock, *divider| divider.* = try keptDivider(clock, old_hz, new_hz);

    const rising = new_hz > coresHz();
    if (rising and !setSupply(point.microvolts)) return error.SupplyFailed;
    for (kept, dividers) |clock, divider| {
        if (divider > dividerOf(clock.clock)) setDivider(clock.clock, divider);
    }
    system.setClock(.sys, system.SYSCLK_CPU_ROOT, system.CLK_MUX, ROOT_OSC);
    // In Linux's order: the mode, the pre-divider, the feedback divider,
    // the post divider.
    system.update(PLL0_PD, PD_WHOLE, PD_WHOLE);
    system.update(PLL0_PREDIV, point.prediv, PREDIV_MASK);
    system.update(PLL0_FBDIV, point.fbdiv, FBDIV_MASK);
    system.update(PLL0_FRAC, 0, POSTDIV1_MASK);
    systimer.spinUs(lock_us);
    setDivider(system.SYSCLK_CPU_CORE, 1);
    system.setClock(.sys, system.SYSCLK_CPU_ROOT, system.CLK_MUX, ROOT_PLL0);
    for (kept, dividers) |clock, divider| setDivider(clock.clock, divider);
    if (!rising and !setSupply(point.microvolts)) return error.SupplyFailed;
}

/// PLL0's rate, or 0 in a mode that is neither whole numbers nor a
/// fraction.
fn pll0Hz() u64 {
    const mode = mmio.reg(PLL0_PD).* & PD_WHOLE;
    const fbdiv: u64 = mmio.reg(PLL0_FBDIV).* & FBDIV_MASK;
    const third = mmio.reg(PLL0_FRAC).*;
    const prediv: u64 = mmio.reg(PLL0_PREDIV).* & PREDIV_MASK;
    const postdiv: u6 = @intCast((third & POSTDIV1_MASK) >> POSTDIV1_SHIFT);
    if (prediv == 0) return 0;
    const frac: u64 = switch (mode) {
        PD_WHOLE => 0,
        0 => third & FRAC_MASK,
        else => return 0,
    };
    return (OSC_HZ * fbdiv + (OSC_HZ * frac >> 24)) / (prediv << postdiv);
}

/// The cores' clock now.
fn coresHz() u64 {
    const root = mmio.reg(system.clockRegister(.sys, system.SYSCLK_CPU_ROOT)).* & system.CLK_MUX;
    const source = if (root == ROOT_PLL0) pll0Hz() else OSC_HZ;
    return source / @max(dividerOf(system.SYSCLK_CPU_CORE), 1);
}

fn dividerOf(clock: u32) u32 {
    return mmio.reg(system.clockRegister(.sys, clock)).* & system.CLK_DIVIDER;
}

fn setDivider(clock: u32, divider: u32) void {
    system.setClock(.sys, clock, system.CLK_DIVIDER, divider);
}

/// `clock`'s divider for PLL0 at `new_hz` rather than `old_hz`: the rate
/// it has now, or the nearest below. Its divider as it is if PLL0 does
/// not feed it, or the divider is unset.
fn keptDivider(clock: Kept, old_hz: u64, new_hz: u64) Error!u32 {
    const word = mmio.reg(system.clockRegister(.sys, clock.clock)).*;
    const now = word & system.CLK_DIVIDER;
    if (clock.pll0_source) |source| {
        if ((word & system.CLK_MUX) >> system.CLK_MUX_SHIFT != source) return now;
    }
    if (now == 0) return now;
    const divider = (new_hz * now + old_hz - 1) / old_hz;
    if (divider > clock.largest) return error.ClockNotKept;
    return @intCast(divider);
}
