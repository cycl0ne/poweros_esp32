// SPDX-License-Identifier: MIT
//! The link, for intelnet.device: whether there is a carrier, and how
//! fast it came up.
//!
//! Starting a link is two things. The controller is told to bring its
//! side up, and the PHY is told to negotiate with whatever is at the
//! other end of the cable. What the PHY advertises is left as it is: out
//! of its own reset it offers every speed and duplex it has, and the
//! negotiation then settles on the best both ends share, which is what
//! is wanted.
//!
//! From then on the answer is read out of the controller's status
//! register. It raises its link-status-change cause when the answer
//! becomes a different one, so nothing here is polled.

const mac = @import("mac.zig");
const Family = @import("family/_family.zig").Family;

/// STATUS: there is a carrier, the link is full duplex, and the two
/// fields that give its speed - the older one of two bits, and the one
/// bit the 2.5 gigabit parts added beside it.
const status_up: u32 = 0x0000_0002;
const status_full_duplex: u32 = 0x0000_0001;
const status_speed_mask: u32 = 0x0000_00C0;
const status_speed_100: u32 = 0x0000_0040;
const status_speed_1000: u32 = 0x0000_0080;
const status_speed_2500: u32 = 0x0040_0000;

/// The PHY's control register, which every PHY has at number 0, and the
/// two bits that turn negotiation on and start it again.
const phy_control = 0;
const phy_control_autoneg: u16 = 0x1000;
const phy_control_restart: u16 = 0x0200;

/// The link started: the controller's side brought up, and the PHY told
/// to negotiate. False where no PHY answered - a part whose medium is
/// not copper has none at that address - and then the controller's side
/// is up on its own and the status register still says what came of it.
pub fn start(at: usize) bool {
    mac.startLink(at);
    return mac.mdioWrite(at, phy_control, phy_control_autoneg | phy_control_restart);
}

/// What a link is: nothing, or a speed and a duplex.
pub const State = struct {
    /// Whether there is a carrier at all.
    up: bool,
    /// What it came up at, in bits a second; 0 where there is no
    /// carrier.
    bps: u64,
    /// Whether it is full duplex.
    full_duplex: bool,
};

/// The link as the controller reports it now.
pub fn state(at: usize, family: *const Family) State {
    const word = mac.statusWord(at);
    if (word == 0xFFFF_FFFF or word & status_up == 0) {
        return .{ .up = false, .bps = 0, .full_duplex = false };
    }
    return .{
        .up = true,
        .bps = speed(word, family),
        .full_duplex = word & status_full_duplex != 0,
    };
}

/// The speed the status word gives. The bit the 2.5 gigabit parts added
/// is read only on a part that has it; on the others it belongs to
/// something else.
fn speed(word: u32, family: *const Family) u64 {
    if (family.bps > 1_000_000_000 and word & status_speed_2500 != 0) return 2_500_000_000;
    return switch (word & status_speed_mask) {
        status_speed_1000 => 1_000_000_000,
        status_speed_100 => 100_000_000,
        else => 10_000_000,
    };
}
