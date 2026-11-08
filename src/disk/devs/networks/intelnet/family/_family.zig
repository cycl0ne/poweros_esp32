// SPDX-License-Identifier: MIT
//! What differs between the generations of Intel's gigabit controllers
//! this device drives, and the table of them. Everything else - the
//! descriptor rings at 0x0C000 and 0x0E000, the receive filter, the
//! extended interrupt registers, the advanced descriptors, the PHY
//! through MDIC - is at the same place with the same bits in all of
//! them, so a family is what it is called, which PCI functions are of
//! it, where its first interrupt register block sits, and how fast its
//! link can go.
//!
//! **The interrupt block is given register by register.** It is not one
//! base with a stride: the older generation spaces the four registers
//! eight bytes apart and the newer one four, so each address is named.

/// One generation.
pub const Family = extern struct {
    /// What a listing calls it.
    name: [*:0]const u8,
    /// Its PCI device IDs under vendor 0x8086, ended by 0.
    devices: [*]const u16,
    /// Its first interrupt register block, each register named: the
    /// cause read, the cause set, the mask set and the mask clear. The
    /// block moved between the generations, and so did the spacing
    /// inside it; the extended registers it feeds did neither.
    icr: u32,
    ics: u32,
    ims: u32,
    imc: u32,
    /// The fastest its link goes, in bits a second. What a link that has
    /// come up actually runs at is read from the status register.
    bps: u64 align(4),
};

/// Every family, in the order a function is matched against them.
pub const all = [_]*const Family{
    &@import("82576.zig").family,
    &@import("i225.zig").family,
};

/// The family of PCI device `id`, or null where no family claims it.
pub fn of(id: u16) ?*const Family {
    for (all) |family| {
        var at: usize = 0;
        while (family.devices[at] != 0) : (at += 1) {
            if (family.devices[at] == id) return family;
        }
    }
    return null;
}
