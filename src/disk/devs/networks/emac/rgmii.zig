// SPDX-License-Identifier: MIT
//! The MACs' RGMII side on the JH7110, for emac.device: which of the
//! chip's MACs a part is wired to (its PART_BusUnit), and what that MAC
//! needs before its registers can be reached - RGMII chosen, its clocks
//! on, its resets let go.
//!
//! **What the firmware leaves.** U-Boot runs GMAC0 for its TFTP and stops
//! it before it boots the kernel, its resets asserted: every register
//! reads 0 and holds nothing. Its clocks' sources and dividers stay as the
//! firmware set them up. On the VisionFive 2 v1.3B the send clock comes
//! from the RGMII clock the PHY sends, which follows the link's speed by
//! itself, so nothing changes with the speed (`setSpeed`). The PHY keeps
//! what U-Boot told it; the device sets it up again anyway, from the
//! board's part.
//!
//! **Which MACs.** GMAC0, whose clocks are in the always-on domain. GMAC1
//! (0x1604_0000) is not here yet: a part on it is refused.
//!
//! The clock, reset and syscon registers are shared with other drivers,
//! so every change is a masked read-modify-write inside exec's Disable.

const sdk = @import("sdk");
const reg = sdk.hardware.mmio.reg;
const st = sdk.expansion.systemtags;
const TagItem = sdk.utility.TagItem;
const UtilityBase = sdk.interface.utility.UtilityBase;
const eqos = @import("eqos.zig");
const EmacBase = @import("_emac.zig").EmacBase;

/// The parts on this kind of bus.
pub const bus = st.BUS_RGMII;

const aon_crg: usize = 0x1700_0000;
const sys_crg: usize = 0x1302_0000;
const aon_syscon: usize = 0x1701_0000;

/// A clock's register: bit 31 turns it on.
const clock_on: u32 = 1 << 31;
/// The interface a MAC speaks, in its syscon field: RGMII.
const mode_rgmii: u32 = 1;
const mode_mask: u32 = 0x7;

/// One of the chip's MACs.
const Mac = struct {
    registers: usize,
    /// Its clocks: the bus's, the engine's, the send clock, and the
    /// gigabit and time-stamp clocks the system domain makes for it.
    clocks: []const usize,
    /// Where its resets are asserted, where they read as let go, and its
    /// bits in both.
    reset_assert: usize,
    reset_status: usize,
    resets: u32,
    /// The syscon register and the place in it of its interface field.
    mode: usize,
    mode_shift: u5,
};

const macs = [_]Mac{
    .{
        .registers = 0x1603_0000,
        .clocks = &.{
            aon_crg + 0x08, // GMAC0_AHB
            aon_crg + 0x0C, // GMAC0_AXI
            aon_crg + 0x14, // GMAC0_TX
            sys_crg + 0x1B0, // GMAC0_GTXCLK
            sys_crg + 0x1B4, // GMAC0_PTP
            sys_crg + 0x1BC, // GMAC0_GTXC
        },
        .reset_assert = aon_crg + 0x38,
        .reset_status = aon_crg + 0x3C,
        .resets = 0x3, // AXI, AHB
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

/// Bits `mask` of the register at `address` set to `value`.
fn update(address: usize, value: u32, mask: u32) void {
    const register = reg(address);
    register.* = register.* & ~mask | value;
}

/// The MAC ready for its own reset: RGMII chosen, its clocks on, its
/// resets held and let go. False if they never read as let go.
pub fn powerUp(port: *const Port, base: *EmacBase) bool {
    const mac = &macs[port.unit];
    const sys = base.sys_base;
    eqos.registers = mac.registers;
    sys.Disable();
    update(mac.mode, mode_rgmii << mac.mode_shift, mode_mask << mac.mode_shift);
    for (mac.clocks) |clock| update(clock, clock_on, clock_on);
    update(mac.reset_assert, mac.resets, mac.resets);
    sys.Enable();
    base.delay(reset_us);
    sys.Disable();
    update(mac.reset_assert, 0, mac.resets);
    sys.Enable();
    const until = sdk.hardware.systimer.uptimeUs() + reset_wait_us;
    while (reg(mac.reset_status).* & mac.resets != mac.resets) {
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
