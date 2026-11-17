// SPDX-License-Identifier: MIT
//! The BCM2711's Ethernet port, for emac.device: its one GENET
//! (genet.zig), on RGMII to the board's PHY.
//!
//! **What the firmware leaves**, read on a Compute Module 4 started over
//! USB: the GENET powered and clocked, and the PHY - the module's
//! BCM54213PE - out of reset; the device tree names no reset line for it.
//! The GENET makes the send clock for the line's speed itself, so nothing
//! changes with the speed (`setSpeed`).

const sdk = @import("sdk");
const st = sdk.expansion.systemtags;
const TagItem = sdk.utility.TagItem;
const UtilityBase = sdk.interface.utility.UtilityBase;
const genet = @import("genet.zig");
const EmacBase = @import("_emac.zig").EmacBase;

/// The parts on this kind of bus.
pub const bus = st.BUS_RGMII;

/// Where the GENET's registers are: the device tree's 0x7D58_0000 on the
/// VideoCore's bus, in the ARM's low peripheral window.
const registers: usize = 0xFD58_0000;

/// The port. The BCM2711 has one GENET.
pub const Port = extern struct {
    unit: u32 = 0,
};

/// The part's MAC, or null if it names one the BCM2711 does not have.
pub fn portOf(utility: *UtilityBase, tags: ?[*]const TagItem) ?Port {
    if (utility.GetTagData(st.PART_BusUnit, 0, tags) != 0) return null;
    return .{};
}

/// The GENET's registers placed; the firmware left the rest ready.
pub fn powerUp(port: *const Port, base: *EmacBase) bool {
    _ = port;
    genet.registers = registers;
    genet.exec_base = base.sys_base;
    return true;
}

/// Nothing to change for the line's speed: UniMAC sets its clock from the
/// speed in its command register (genet.setLine).
pub fn setSpeed(port: *const Port, mbits: u32) void {
    _ = port;
    _ = mbits;
}

/// The GENET keeps no station address of its own: the board gives it
/// (PART_StationAddress), from what the firmware put in the device tree.
pub fn factoryAddress(port: *const Port) ?[6]u8 {
    _ = port;
    return null;
}
