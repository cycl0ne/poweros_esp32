// SPDX-License-Identifier: MIT
//! The MACs' RGMII side on the JH7110, for emac.device: which of the
//! chip's MACs a part is wired to (its PART_BusUnit), and what that MAC
//! needs before its registers can be reached - RGMII chosen, its clocks
//! on, its resets let go.
//!
//! **What the firmware leaves** is not counted on. U-Boot runs GMAC0 for
//! its TFTP and stops it before it boots the kernel, its clocks off and
//! its resets asserted: every register reads 0 and holds nothing. The
//! send clock's source is set here: on the VisionFive 2 v1.3B the RGMII
//! clock the PHY sends (its device tree's assigned parent, which U-Boot
//! sets as it probes the MAC), which follows the link's speed by itself,
//! so nothing changes with the speed (`setSpeed`). The dividers are the
//! chip's own; neither U-Boot nor Linux sets them. The PHY keeps what
//! U-Boot told it; the device sets it up again anyway, from the board's
//! part.
//!
//! **Which MACs.** GMAC0, whose clocks are in the always-on domain. GMAC1
//! (0x1604_0000) is not here yet: a part on it is refused.
//!
//! The clocks and resets are `sdk.hardware.system`'s. The reset and
//! syscon registers are shared with other drivers, so every change is a
//! masked read-modify-write inside exec's Disable.

const sdk = @import("sdk");
const system = sdk.hardware.system;
const st = sdk.expansion.systemtags;
const TagItem = sdk.utility.TagItem;
const UtilityBase = sdk.interface.utility.UtilityBase;
const eqos = @import("eqos.zig");
const EmacBase = @import("_emac.zig").EmacBase;

/// The parts on this kind of bus.
pub const bus = st.BUS_RGMII;

const aon_syscon: usize = 0x1701_0000;

/// The interface a MAC speaks, in its syscon field: RGMII.
const mode_rgmii: u32 = 1;
const mode_mask: u32 = 0x7;

/// One of the chip's MACs. GMAC0's clocks and resets are the always-on
/// domain's, but for the gigabit and time-stamp clocks the system domain
/// makes for it.
const Mac = struct {
    registers: usize,
    /// Its clocks in the always-on generator - the bus's and the engine's
    /// - and in the system generator.
    aon_clocks: []const u32,
    sys_clocks: []const u32,
    /// The send clock, and its source: the RGMII clock the PHY sends.
    tx_clock: u32,
    tx_from_phy: u32,
    /// Its resets, in the always-on generator.
    resets: []const u32,
    /// The syscon register and the place in it of its interface field.
    mode: usize,
    mode_shift: u5,
};

const macs = [_]Mac{
    .{
        .registers = 0x1603_0000,
        .aon_clocks = &.{ system.AONCLK_GMAC0_AHB, system.AONCLK_GMAC0_AXI },
        .sys_clocks = &.{ system.SYSCLK_GMAC0_GTXCLK, system.SYSCLK_GMAC0_PTP, system.SYSCLK_GMAC0_GTXC },
        .tx_clock = system.AONCLK_GMAC0_TX,
        // Its sources: 0 the gigabit clock, 1 RMII_RTX - the PHY's.
        .tx_from_phy = 1,
        .resets = &.{ system.AONRST_GMAC0_AXI, system.AONRST_GMAC0_AHB },
        .mode = aon_syscon + 0x0C,
        .mode_shift = 18,
    },
};

/// How long the resets are held, and how long they may take to read as
/// let go.
const reset_us = 10;
const reset_wait_us = 10_000;

/// Which MAC the part is on.
pub const Port = extern struct {
    unit: u32 = 0,
};

/// The part's MAC, or null if it names one this does not drive.
pub fn portOf(utility: *UtilityBase, tags: ?[*]const TagItem) ?Port {
    const unit = utility.GetTagData(st.PART_BusUnit, 0, tags);
    if (unit >= macs.len) return null;
    return .{ .unit = @intCast(unit) };
}

/// Whether every one of the MAC's resets reads as let go.
fn outOfReset(mac: *const Mac) bool {
    for (mac.resets) |reset| {
        if (!system.outOfReset(.aon, reset)) return false;
    }
    return true;
}

/// The MAC ready for its own reset: RGMII chosen, its clocks on - the
/// send clock from the PHY's - its resets held and let go. False if they
/// never read as let go.
pub fn powerUp(port: *const Port, base: *EmacBase) bool {
    const mac = &macs[port.unit];
    const sys = base.sys_base;
    eqos.registers = mac.registers;
    sys.Disable();
    system.update(mac.mode, mode_rgmii << mac.mode_shift, mode_mask << mac.mode_shift);
    for (mac.aon_clocks) |clock| system.clockOn(.aon, clock);
    system.setClock(.aon, mac.tx_clock, system.CLK_ENABLE | system.CLK_MUX, system.CLK_ENABLE | mac.tx_from_phy << system.CLK_MUX_SHIFT);
    for (mac.sys_clocks) |clock| system.clockOn(.sys, clock);
    for (mac.resets) |reset| system.holdInReset(.aon, reset);
    sys.Enable();
    base.delay(reset_us);
    sys.Disable();
    for (mac.resets) |reset| system.releaseReset(.aon, reset);
    sys.Enable();
    const until = sdk.hardware.systimer.uptimeUs() + reset_wait_us;
    while (!outOfReset(mac)) {
        if (sdk.hardware.systimer.uptimeUs() > until) return false;
    }
    return true;
}

/// Nothing to change for the line's speed: the send clock follows the
/// PHY's RGMII clock.
pub fn setSpeed(port: *const Port, mbits: u32) void {
    _ = port;
    _ = mbits;
}

/// The chip keeps no station address of its own: the board gives it
/// (PART_StationAddress).
pub fn factoryAddress(port: *const Port) ?[6]u8 {
    _ = port;
    return null;
}
