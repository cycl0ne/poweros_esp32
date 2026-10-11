// SPDX-License-Identifier: MIT
//! The PHY, for emac.device: the registers every 10/100 PHY has (IEEE
//! 802.3 clause 22), read and written over the MAC's management bus.
//! Nothing here is one maker's: the PHY is reset, told to negotiate
//! every speed it offers, and asked whether its link is up and what the
//! two ends agreed on.
//!
//! The PHY has no interrupt line here, so the device asks `link` every
//! so often.

const gmac = @import("gmac.zig");

// The registers.
const bmcr = 0;
const bmsr = 1;
const id1 = 2;
const anar = 4;
const anlpar = 5;

/// BMCR: reset, restart negotiation, negotiation on.
const bmcr_reset: u16 = 1 << 15;
const bmcr_autoneg: u16 = 1 << 12;
const bmcr_restart: u16 = 1 << 9;
/// BMSR: negotiation complete, link up (latched low: a link that went
/// down reads down once even if it is back).
const bmsr_complete: u16 = 1 << 5;
const bmsr_link: u16 = 1 << 2;
/// ANAR and ANLPAR: the abilities one end offers (10 Mbit/s half duplex,
/// which every PHY has, is what is left without these).
const ability_100_full: u16 = 1 << 8;
const ability_100_half: u16 = 1 << 7;
const ability_10_full: u16 = 1 << 6;

/// What the link is: down, or up at a speed and duplex.
pub const Link = struct {
    up: bool = false,
    fast: bool = false,
    full_duplex: bool = false,
};

/// Whether a PHY answers at `address`: its identifier reads as neither
/// all zeroes nor all ones, which is what a bus without one gives.
pub fn present(address: u32) bool {
    const id = gmac.readPhy(address, id1) orelse return false;
    return id != 0 and id != 0xFFFF;
}

/// The PHY's own reset started: it clears the bit when it is done
/// (`resetDone`).
pub fn startReset(address: u32) bool {
    return gmac.writePhy(address, bmcr, bmcr_reset);
}

pub fn resetDone(address: u32) bool {
    const control = gmac.readPhy(address, bmcr) orelse return false;
    return control & bmcr_reset == 0;
}

/// Negotiation of every speed the PHY offers, started.
pub fn negotiate(address: u32) bool {
    return gmac.writePhy(address, bmcr, bmcr_autoneg | bmcr_restart);
}

/// Whether the link is up, and at what: the best both ends offer, once
/// negotiation is done. Read twice for the link bit, which holds a drop
/// until it is read.
pub fn link(address: u32) Link {
    _ = gmac.readPhy(address, bmsr);
    const status = gmac.readPhy(address, bmsr) orelse return .{};
    if (status & bmsr_link == 0 or status & bmsr_complete == 0) return .{};
    const ours = gmac.readPhy(address, anar) orelse return .{};
    const theirs = gmac.readPhy(address, anlpar) orelse return .{};
    const both = ours & theirs;
    if (both & ability_100_full != 0) return .{ .up = true, .fast = true, .full_duplex = true };
    if (both & ability_100_half != 0) return .{ .up = true, .fast = true };
    if (both & ability_10_full != 0) return .{ .up = true, .full_duplex = true };
    return .{ .up = true };
}
