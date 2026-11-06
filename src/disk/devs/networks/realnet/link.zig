// SPDX-License-Identifier: MIT
//! The link, for realnet.device: what the part is told to negotiate for,
//! and what came of it.
//!
//! The PHY is told what to offer and then to start again, which is one
//! write to each of three registers: the two standard advertisement
//! registers for the speeds that have been there since twisted pair,
//! and one of the PHY's own for 2.5 gigabits, which is newer than the
//! standard registers are.
//!
//! What came of it is in one register of the MAC's: whether there is a
//! carrier, at what speed, and in which direction at a time. The part
//! raises a cause of its own when that changes, so a cable going in or
//! out reaches the unit without anything being polled.

const mac = @import("mac.zig");

/// The PHY's standard registers, by their number on the management bus.
const bmcr = 0;
const anar = 4;
const gtcr = 9;

/// What the control register is told: start again, negotiate, and reset
/// the PHY while doing it.
const bmcr_reset: u16 = 0x8000;
const bmcr_negotiate: u16 = 0x1000;
const bmcr_restart: u16 = 0x0200;

/// What is offered on the standard registers: ten and a hundred
/// megabits each way, and the two flow control bits, with the selector
/// field that says this is Ethernet.
const anar_ethernet: u16 = 0x0001;
const anar_10: u16 = 0x0020;
const anar_10_fdx: u16 = 0x0040;
const anar_100: u16 = 0x0080;
const anar_100_fdx: u16 = 0x0100;
const anar_pause: u16 = 0x0400;
const anar_pause_asym: u16 = 0x0800;

/// What is offered on the gigabit register.
const gtcr_1000: u16 = 0x0100;
const gtcr_1000_fdx: u16 = 0x0200;

/// The PHY's own register for the faster speeds, and the bit in it for
/// 2.5 gigabits full duplex. Five and ten are not offered: the parts
/// that reach them want settings of their own that this device does not
/// write, so a link of theirs comes up at 2.5 like the rest.
const advertise = 0xa5d4;
const advertise_2500_fdx: u16 = 0x0080;

/// The two registers that let the PHY drop to a slower speed on its own
/// while there is nothing to send.
const lite_one = 0xa428;
const lite_two = 0xa5ea;

/// The PHY told to offer everything it has and to negotiate again.
pub fn negotiate(at: usize) void {
    mac.phyOcpClear(at, lite_one, 0x0200);
    mac.phyOcpClear(at, lite_two, 0x0001);

    mac.phyWrite(at, anar, anar_ethernet | anar_10 | anar_10_fdx |
        anar_100 | anar_100_fdx | anar_pause | anar_pause_asym);
    mac.phyWrite(at, gtcr, gtcr_1000 | gtcr_1000_fdx);
    mac.phyOcpWrite(at, advertise, mac.phyOcpRead(at, advertise) | advertise_2500_fdx);
    mac.phyWrite(at, bmcr, bmcr_reset | bmcr_negotiate | bmcr_restart);
}

/// What the link is doing.
pub const State = struct {
    up: bool,
    bps: u64,
    full_duplex: bool,
};

pub fn state(at: usize) State {
    const status = mac.linkStatus(at);
    const up = status & mac.phy_link != 0;
    return .{
        .up = up,
        .full_duplex = status & mac.phy_fdx != 0,
        .bps = if (!up) 0 else if (status & mac.phy_5000 != 0)
            5_000_000_000
        else if (status & mac.phy_2500 != 0)
            2_500_000_000
        else if (status & mac.phy_1000 != 0)
            1_000_000_000
        else if (status & mac.phy_100 != 0)
            100_000_000
        else
            10_000_000,
    };
}
