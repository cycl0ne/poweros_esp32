// SPDX-License-Identifier: MIT
//! The I225 and I226, 2.5 gigabit controllers on PCI Express. Their
//! interrupt registers are at 0x01500 and four bytes apart, and their
//! link reports a third speed - 2500 Mbit/s - that the generation
//! before had not.

const Family = @import("_family.zig").Family;

/// I225 LM, V, I, K, K2, LMvP and IT; then I226 LM, V, IT and K.
const devices = [_]u16{
    0x15F2, 0x15F3, 0x15F8, 0x3100, 0x3101, 0x5502, 0x0D9F,
    0x125B, 0x125C, 0x125D, 0x5503, 0,
};

pub const family: Family = .{
    .name = "I225",
    .devices = &devices,
    .icr = 0x01500,
    .ics = 0x01504,
    .ims = 0x01508,
    .imc = 0x0150C,
    .bps = 2_500_000_000,
};
