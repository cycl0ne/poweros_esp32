// SPDX-License-Identifier: MIT
//! The PHY, for emac.device: the registers every PHY has (IEEE 802.3
//! clause 22), read and written over the MAC's management bus. The PHY is
//! reset, told to negotiate every speed it and the MAC offer - 1000
//! Mbit/s too where both do (`mac.gigabit`, and the PHY's extended
//! status) - and asked whether its link is up and what the two ends
//! agreed on.
//!
//! **One maker's part.** On RGMII the PHY delays the clocks against the
//! data and drives its lines as the board's wiring needs, which the
//! board's part says (`Wiring`); Motorcomm's YT8531 is told so through
//! its extended registers (`configure`), and sends its clock inverted at
//! the speeds the board asks once the link is up (`settle`). Any other
//! PHY keeps what it starts with.
//!
//! The PHY has no interrupt line here, so the device asks `link` every
//! so often.

const sdk = @import("sdk");
const st = sdk.expansion.systemtags;
const TagItem = sdk.utility.TagItem;
const UtilityBase = sdk.interface.utility.UtilityBase;
const mac = @import("_emac.zig").mac;

// The registers.
const bmcr = 0;
const bmsr = 1;
const id1 = 2;
const id2 = 3;
const anar = 4;
const anlpar = 5;
const gbcr = 9;
const gbsr = 10;

/// BMCR: reset, restart negotiation, negotiation on.
const bmcr_reset: u16 = 1 << 15;
const bmcr_autoneg: u16 = 1 << 12;
const bmcr_restart: u16 = 1 << 9;
/// BMSR: the extended status is there (1000 Mbit/s), negotiation
/// complete, link up (latched low: a link that went down reads down once
/// even if it is back).
const bmsr_extended: u16 = 1 << 8;
const bmsr_complete: u16 = 1 << 5;
const bmsr_link: u16 = 1 << 2;
/// ANAR and ANLPAR: the abilities one end offers (10 Mbit/s half duplex,
/// which every PHY has, is what is left without these).
const ability_100_full: u16 = 1 << 8;
const ability_100_half: u16 = 1 << 7;
const ability_10_full: u16 = 1 << 6;
/// GBCR: 1000 Mbit/s offered, full and half duplex. GBSR: what the other
/// end offers, the same two bits two places up.
const gbcr_1000_full: u16 = 1 << 9;
const gbcr_1000_half: u16 = 1 << 8;
const gbsr_shift = 2;

/// What the link is: down, or up at a speed and duplex.
pub const Link = struct {
    up: bool = false,
    mbits: u32 = 10,
    full_duplex: bool = false,
};

/// A wiring figure the board's part leaves out.
const unset: u32 = 0xFFFF_FFFF;

/// What the board's wiring asks of the PHY, from its part: the delays it
/// adds on RGMII, in picoseconds, the speeds it sends its clock inverted
/// at, and how hard it drives the lines it sends the MAC, in
/// microamperes. `unset` where the part says nothing.
pub const Wiring = extern struct {
    rx_delay: u32 = unset,
    tx_delay: u32 = unset,
    tx_inverted: u32 = 0,
    rx_clock_drive: u32 = unset,
    rx_data_drive: u32 = unset,
};

pub fn wiringOf(utility: *UtilityBase, tags: ?[*]const TagItem) Wiring {
    return .{
        .rx_delay = @truncate(utility.GetTagData(st.PART_RxDelay, unset, tags)),
        .tx_delay = @truncate(utility.GetTagData(st.PART_TxDelay, unset, tags)),
        .tx_inverted = @truncate(utility.GetTagData(st.PART_TxClockInverted, 0, tags)),
        .rx_clock_drive = @truncate(utility.GetTagData(st.PART_RxClockDrive, unset, tags)),
        .rx_data_drive = @truncate(utility.GetTagData(st.PART_RxDataDrive, unset, tags)),
    };
}

/// The PHY's identifier, both registers; null if none answers at
/// `address` - all zeroes or all ones is what a bus without one gives.
fn identify(address: u32) ?u32 {
    const high = mac.readPhy(address, id1) orelse return null;
    const low = mac.readPhy(address, id2) orelse return null;
    if (high == 0 or high == 0xFFFF) return null;
    return @as(u32, high) << 16 | low;
}

/// Whether a PHY answers at `address`.
pub fn present(address: u32) bool {
    return identify(address) != null;
}

/// The PHY's own reset started: it clears the bit when it is done
/// (`resetDone`).
pub fn startReset(address: u32) bool {
    return mac.writePhy(address, bmcr, bmcr_reset);
}

pub fn resetDone(address: u32) bool {
    const control = mac.readPhy(address, bmcr) orelse return false;
    return control & bmcr_reset == 0;
}

/// After its reset: the PHY set up as the board's wiring asks.
pub fn configure(address: u32, wiring: *const Wiring) void {
    if (identify(address) == yt8531_id) yt8531.configure(address, wiring);
}

/// Negotiation of every speed the PHY and the MAC offer, started.
pub fn negotiate(address: u32) bool {
    const status = mac.readPhy(address, bmsr) orelse return false;
    if (status & bmsr_extended != 0) {
        const offer: u16 = if (mac.gigabit) gbcr_1000_full | gbcr_1000_half else 0;
        const control = mac.readPhy(address, gbcr) orelse return false;
        if (!mac.writePhy(address, gbcr, control & ~(gbcr_1000_full | gbcr_1000_half) | offer)) return false;
    }
    return mac.writePhy(address, bmcr, bmcr_autoneg | bmcr_restart);
}

/// Whether the link is up, and at what: the best both ends offer, once
/// negotiation is done. Read twice for the link bit, which holds a drop
/// until it is read.
pub fn link(address: u32) Link {
    _ = mac.readPhy(address, bmsr);
    const status = mac.readPhy(address, bmsr) orelse return .{};
    if (status & bmsr_link == 0 or status & bmsr_complete == 0) return .{};
    if (mac.gigabit and status & bmsr_extended != 0) {
        const ours = mac.readPhy(address, gbcr) orelse return .{};
        const theirs = mac.readPhy(address, gbsr) orelse return .{};
        const both = ours & (theirs >> gbsr_shift);
        if (both & gbcr_1000_full != 0) return .{ .up = true, .mbits = 1000, .full_duplex = true };
        if (both & gbcr_1000_half != 0) return .{ .up = true, .mbits = 1000 };
    }
    const ours = mac.readPhy(address, anar) orelse return .{};
    const theirs = mac.readPhy(address, anlpar) orelse return .{};
    const both = ours & theirs;
    if (both & ability_100_full != 0) return .{ .up = true, .mbits = 100, .full_duplex = true };
    if (both & ability_100_half != 0) return .{ .up = true, .mbits = 100 };
    if (both & ability_10_full != 0) return .{ .up = true, .full_duplex = true };
    return .{ .up = true };
}

/// The link came up at `up`: the PHY told what the board's wiring needs
/// at that speed.
pub fn settle(address: u32, up: Link, wiring: *const Wiring) void {
    if (identify(address) == yt8531_id) yt8531.settle(address, up, wiring);
}

// --- Motorcomm's YT8531 ---------------------------------------------------

const yt8531_id: u32 = 0x4F51_E91B;

/// The YT8531's extended registers, reached through two of its own: the
/// one to reach written to 0x1E, its value then read or written at 0x1F.
const yt8531 = struct {
    const ext_address = 0x1E;
    const ext_data = 0x1F;

    /// Chip config: 1.9 ns more on the receive clock; the voltage of the
    /// RGMII pads (0: 3.3 V, 2: 1.8 V).
    const chip_config = 0xA001;
    const rxc_delay_on: u16 = 1 << 8;
    const ldo_shift = 4;
    const ldo_3v3 = 0;
    const ldo_1v8 = 2;
    /// RGMII config 1: the send clock inverted; the receive clock's delay
    /// and the gigabit send clock's, in steps of 150 ps.
    const rgmii_config1 = 0xA003;
    const tx_inverted: u16 = 1 << 14;
    const rx_delay_shift = 10;
    const tx_delay_shift = 0;
    const delay_mask: u16 = 0xF;
    const delay_step_ps = 150;
    /// What the receive clock's own delay adds when it is on.
    const rxc_delay_ps = 1900;
    /// Pad drive: the receive clock's strength, and the receive data's -
    /// its top bit apart from the other two.
    const pad_drive = 0xA010;
    const rxc_drive_shift = 13;
    const rxd_drive_low_shift = 4;
    const rxd_drive_high: u16 = 1 << 12;

    /// The strengths each of the eight drive settings gives, in
    /// microamperes, at 1.8 V and at 3.3 V.
    const drive_1v8 = [8]u32{ 1200, 2100, 2700, 2910, 3110, 3600, 3970, 4350 };
    const drive_3v3 = [8]u32{ 3070, 4080, 4370, 4680, 5020, 5450, 5740, 6140 };

    fn read(address: u32, register: u16) ?u16 {
        if (!mac.writePhy(address, ext_address, register)) return null;
        return mac.readPhy(address, ext_data);
    }

    /// Bits `mask` of extended register `register` set to `value`.
    fn update(address: u32, register: u16, value: u16, mask: u16) void {
        const old = read(address, register) orelse return;
        _ = mac.writePhy(address, ext_address, register);
        _ = mac.writePhy(address, ext_data, old & ~mask | value);
    }

    /// A delay in the register's steps, the nearest to `ps`.
    fn steps(ps: u32) u16 {
        return @intCast(@min((ps + delay_step_ps / 2) / delay_step_ps, delay_mask));
    }

    /// The drive setting nearest to `microamps` in `table`.
    fn driveOf(table: *const [8]u32, microamps: u32) u16 {
        var best: u16 = 0;
        for (table, 0..) |one, setting| {
            const distance = if (one > microamps) one - microamps else microamps - one;
            const best_distance = if (table[best] > microamps) table[best] - microamps else microamps - table[best];
            if (distance < best_distance) best = @intCast(setting);
        }
        return best;
    }

    fn configure(address: u32, wiring: *const Wiring) void {
        if (wiring.rx_delay != unset) {
            // The receive clock's own 1.9 ns, if the board wants that much,
            // and the rest in steps.
            const long = wiring.rx_delay >= rxc_delay_ps;
            update(address, chip_config, if (long) rxc_delay_on else 0, rxc_delay_on);
            const rest = if (long) wiring.rx_delay - rxc_delay_ps else wiring.rx_delay;
            update(address, rgmii_config1, steps(rest) << rx_delay_shift, delay_mask << rx_delay_shift);
        }
        if (wiring.tx_delay != unset) {
            update(address, rgmii_config1, steps(wiring.tx_delay) << tx_delay_shift, delay_mask << tx_delay_shift);
        }
        const config = read(address, chip_config) orelse return;
        const table: *const [8]u32 = switch ((config >> ldo_shift) & 0x3) {
            ldo_3v3 => &drive_3v3,
            ldo_1v8 => &drive_1v8,
            else => return,
        };
        if (wiring.rx_clock_drive != unset) {
            update(address, pad_drive, driveOf(table, wiring.rx_clock_drive) << rxc_drive_shift, 0x7 << rxc_drive_shift);
        }
        if (wiring.rx_data_drive != unset) {
            const setting = driveOf(table, wiring.rx_data_drive);
            const value = (setting & 0x3) << rxd_drive_low_shift | (if (setting & 0x4 != 0) rxd_drive_high else 0);
            update(address, pad_drive, value, 0x3 << rxd_drive_low_shift | rxd_drive_high);
        }
    }

    fn settle(address: u32, up: Link, wiring: *const Wiring) void {
        const speed: u32 = switch (up.mbits) {
            1000 => st.LINKSPEED_1000,
            100 => st.LINKSPEED_100,
            else => st.LINKSPEED_10,
        };
        update(address, rgmii_config1, if (wiring.tx_inverted & speed != 0) tx_inverted else 0, tx_inverted);
    }
};
