// SPDX-License-Identifier: MIT
//! The 82576, a gigabit controller on PCI Express, and the parts built
//! like it. Its interrupt registers are at 0x000C0 and eight bytes
//! apart; the generation after it moved them to 0x01500 and put them
//! four apart.
//!
//! The copper parts are listed. A fibre or SerDes one of the same
//! generation answers at the same registers, but its link comes up
//! through another medium than the copper PHY this device sets going,
//! so it is left out until there is one to try.

const Family = @import("_family.zig").Family;

/// 82576 dual copper, quad copper, quad copper ET2, and NS.
const devices = [_]u16{ 0x10C9, 0x10E8, 0x1526, 0x150A, 0 };

pub const family: Family = .{
    .name = "82576",
    .devices = &devices,
    .icr = 0x000C0,
    .ics = 0x000C8,
    .ims = 0x000D0,
    .imc = 0x000D8,
    .bps = 1_000_000_000,
};
