// SPDX-License-Identifier: MIT
//! The chip's backplane, for cyw43455.device: the AXI bus inside the
//! CYW43455 that its cores - the ARM that runs the firmware, its RAM, the
//! radio, the SDIO core itself - hang on, reached through SDIO function 1.
//!
//! **The window.** Function 1 shows 32 KiB of the backplane at a time:
//! three of its registers hold the window's address (`setWindow`), and a
//! CMD53 of four bytes to an offset in it with bit 15 set is one 32-bit
//! access there. The window is remembered, so that reads in the same 32
//! KiB set it once.
//!
//! **The clock.** Out of reset the backplane runs on no clock the host
//! may count on: function 1's clock register asks for the ALP clock (the
//! crystal's), which the chip's PMU brings up, and then forces it on
//! (`clockUp`) - what Linux's brcmfmac does before it reads anything.
//!
//! **The cores** are in the chip's enumeration ROM (EROM), which
//! chipcommon - always at 0x1800_0000 - points to: each core's ID, its
//! revision, its registers and its wrapper's (`scan`).

const host_file = @import("host.zig");
const sdio = @import("sdio.zig");
const Error = host_file.Error;

/// Function 1's own registers.
const SBADDRLOW = 0x1000A;
const SBADDRMID = 0x1000B;
const SBADDRHIGH = 0x1000C;
pub const CHIPCLKCSR = 0x1000E;
const SDIOPULLUP = 0x1000F;

/// The window: an offset in it, and the bit that makes a 4-byte access.
const WINDOW_MASK: u32 = 0xFFFF_8000;
pub const OFFSET_MASK: u32 = 0x7FFF;
pub const ACCESS_4B: u32 = 0x8000;

/// CHIPCLKCSR's bits.
pub const FORCE_ALP: u8 = 0x01;
pub const FORCE_HT: u8 = 0x02;
pub const ALP_AVAIL_REQ: u8 = 0x08;
pub const HT_AVAIL_REQ: u8 = 0x10;
pub const FORCE_HW_CLKREQ_OFF: u8 = 0x20;
pub const ALP_AVAIL: u8 = 0x40;
pub const HT_AVAIL: u8 = 0x80;
const AVAIL_BITS: u8 = ALP_AVAIL | HT_AVAIL;

/// Where chipcommon is, and its registers: the chip's ID and where the
/// EROM is.
pub const CHIPCOMMON: u32 = 0x1800_0000;
const CC_CHIPID = 0x00;
const CC_EROMPTR = 0xFC;
/// The chip's ID word: the chip, its revision, its kind of backplane.
const CHIPID_TYPE_SHIFT = 28;
const SOCI_AI: u32 = 1;

/// The cores the device looks for.
pub const CORE_CHIPCOMMON: u16 = 0x800;
pub const CORE_INTERNAL_MEM: u16 = 0x80E;
pub const CORE_80211: u16 = 0x812;
pub const CORE_PMU: u16 = 0x827;
pub const CORE_SDIO_DEV: u16 = 0x829;
pub const CORE_ARM_CR4: u16 = 0x83E;
pub const CORE_GCI: u16 = 0x840;
pub const CORE_SYS_MEM: u16 = 0x849;

/// The EROM's descriptors: their kind in the low four bits.
const DESC_TYPE_MASK: u32 = 0xF;
const DESC_EMPTY: u32 = 0x0;
const DESC_VALID: u32 = 0x1;
const DESC_COMPONENT: u32 = 0x1;
const DESC_MASTER_PORT: u32 = 0x3;
const DESC_ADDRESS: u32 = 0x5;
const DESC_ADDRSIZE_GT32: u32 = 0x8;
const DESC_EOT: u32 = 0xF;
const COMP_PARTNUM_MASK: u32 = 0x000F_FF00;
const COMP_PARTNUM_SHIFT = 8;
const COMP_REVISION_SHIFT = 24;
const COMP_NUM_SWRAP_MASK: u32 = 0x00F8_0000;
const COMP_NUM_MWRAP_MASK: u32 = 0x0007_C000;
const SLAVE_ADDR_BASE_MASK: u32 = 0xFFFF_F000;
const SLAVE_TYPE_MASK: u32 = 0xC0;
const SLAVE_TYPE_SHIFT = 6;
const SLAVE_TYPE_SLAVE: u32 = 0;
const SLAVE_TYPE_SWRAP: u32 = 2;
const SLAVE_TYPE_MWRAP: u32 = 3;
const SLAVE_SIZE_TYPE_MASK: u32 = 0x30;
const SLAVE_SIZE_TYPE_SHIFT = 4;
const SLAVE_SIZE_4K: u32 = 0;
const SLAVE_SIZE_8K: u32 = 1;
const SLAVE_SIZE_DESC: u32 = 3;
/// The most descriptors read before the EROM is taken as broken.
const erom_limit = 1024;

/// How long the ALP clock may take to come: Linux waits up to a second.
const alp_tries = 1000;
const alp_wait_us = 1000;

/// The most cores kept.
pub const max_cores = 16;

/// A core on the backplane: its ID, its revision, and where its
/// registers and its wrapper's are.
pub const Core = extern struct {
    id: u16 = 0,
    rev: u8 = 0,
    pad: u8 = 0,
    base: u32 = 0,
    wrap: u32 = 0,
};

/// The chip as its chipcommon and its EROM say.
pub const Chip = extern struct {
    id: u32 = 0,
    rev: u32 = 0,
    core_count: u32 = 0,
    cores: [max_cores]Core = @splat(.{}),

    /// The core with ID `id`, if the chip has one.
    pub fn core(chip: *const Chip, id: u16) ?*const Core {
        for (chip.cores[0..chip.core_count]) |*one| {
            if (one.id == id) return one;
        }
        return null;
    }
};

/// The way into the backplane: the card, and the window open now.
pub const Backplane = extern struct {
    card: sdio.Card,
    window: u32 = 1,
};

/// The window moved to the 32 KiB that hold `address`, if it is not there.
pub fn setWindow(bp: *Backplane, address: u32) Error!void {
    const window = address & WINDOW_MASK;
    if (window == bp.window) return;
    bp.window = 1;
    try sdio.write8(&bp.card, 1, SBADDRLOW, @truncate(window >> 8));
    try sdio.write8(&bp.card, 1, SBADDRMID, @truncate(window >> 16));
    try sdio.write8(&bp.card, 1, SBADDRHIGH, @truncate(window >> 24));
    bp.window = window;
}

/// The 32-bit register at `address` read.
pub fn read32(bp: *Backplane, address: u32) Error!u32 {
    try setWindow(bp, address);
    var word: [4]u8 = undefined;
    try sdio.bytes(&bp.card, false, 1, (address & OFFSET_MASK) | ACCESS_4B, &word, true);
    return @as(u32, word[0]) | @as(u32, word[1]) << 8 | @as(u32, word[2]) << 16 | @as(u32, word[3]) << 24;
}

/// The 32-bit register at `address` written.
pub fn write32(bp: *Backplane, address: u32, value: u32) Error!void {
    try setWindow(bp, address);
    var word = [4]u8{ @truncate(value), @truncate(value >> 8), @truncate(value >> 16), @truncate(value >> 24) };
    try sdio.bytes(&bp.card, true, 1, (address & OFFSET_MASK) | ACCESS_4B, &word, true);
}

/// Function 1's block size, which the device gives it: Linux's.
pub const block_bytes = 64;

/// A run of the backplane inside one window read or written: in whole
/// blocks of function 1 when it is made of them, else as bytes - fewer
/// than 512 of them.
pub fn access(bp: *Backplane, write: bool, address: u32, buffer: []u8) Error!void {
    try setWindow(bp, address);
    const at = (address & OFFSET_MASK) | ACCESS_4B;
    if (buffer.len >= block_bytes and buffer.len % block_bytes == 0) {
        try sdio.blocks(&bp.card, write, 1, at, buffer, block_bytes, true);
    } else {
        try sdio.bytes(&bp.card, write, 1, at, buffer, true);
    }
}

/// The ALP clock asked for, waited for and forced on, the hardware's own
/// requests for a clock off, and function 1's extra pull-ups off. What
/// CHIPCLKCSR read when the clock came, or the error.
pub fn clockUp(bp: *Backplane, wait: sdio.Wait, context: *anyopaque) Error!u8 {
    const request = FORCE_HW_CLKREQ_OFF | ALP_AVAIL_REQ;
    try sdio.write8(&bp.card, 1, CHIPCLKCSR, request);
    var value = try sdio.read8(&bp.card, 1, CHIPCLKCSR);
    if (value & ~AVAIL_BITS != request) return error.Failed;
    var tries: u32 = 0;
    while (value & AVAIL_BITS == 0) : (tries += 1) {
        if (tries == alp_tries) return error.Timeout;
        wait(context, alp_wait_us);
        value = try sdio.read8(&bp.card, 1, CHIPCLKCSR);
    }
    try sdio.write8(&bp.card, 1, CHIPCLKCSR, FORCE_HW_CLKREQ_OFF | FORCE_ALP);
    wait(context, 65);
    try sdio.write8(&bp.card, 1, SDIOPULLUP, 0);
    return value;
}

/// The chip's ID and revision from chipcommon, and its cores from the
/// EROM. False for a chip whose backplane is not AXI - one this does not
/// know.
pub fn scan(bp: *Backplane, chip: *Chip) Error!bool {
    const id = try read32(bp, CHIPCOMMON + CC_CHIPID);
    chip.* = .{ .id = id & 0xFFFF, .rev = (id >> 16) & 0xF };
    if (id >> CHIPID_TYPE_SHIFT != SOCI_AI) return false;
    var erom = try read32(bp, CHIPCOMMON + CC_EROMPTR);
    var read: u32 = 0;
    while (read < erom_limit) : (read += 1) {
        const first = try next(bp, &erom);
        if (first & DESC_TYPE_MASK == DESC_EOT) break;
        if (first & DESC_VALID == 0 or first & DESC_TYPE_MASK != DESC_COMPONENT) continue;
        const second = try next(bp, &erom);
        if (second & DESC_TYPE_MASK != DESC_COMPONENT) return false;
        const part: u16 = @intCast((first & COMP_PARTNUM_MASK) >> COMP_PARTNUM_SHIFT);
        const wrappers = second & (COMP_NUM_MWRAP_MASK | COMP_NUM_SWRAP_MASK);
        if (wrappers == 0 and part != CORE_PMU and part != CORE_GCI) continue;
        var one: Core = .{ .id = part, .rev = @truncate(second >> COMP_REVISION_SHIFT) };
        if (!try addresses(bp, &erom, &one)) continue;
        if (chip.core_count < max_cores) {
            chip.cores[chip.core_count] = one;
            chip.core_count += 1;
        }
    }
    return true;
}

/// The next EROM descriptor.
fn next(bp: *Backplane, erom: *u32) Error!u32 {
    const value = try read32(bp, erom.*);
    erom.* += 4;
    return value;
}

/// The kind of a descriptor, with an address's size flag taken off.
fn kind(value: u32) u32 {
    const type_bits = value & DESC_TYPE_MASK;
    return if (type_bits & ~DESC_ADDRSIZE_GT32 == DESC_ADDRESS) DESC_ADDRESS else type_bits;
}

/// A core's registers and its wrapper's, from the address descriptors
/// after its component descriptors: the first 4 or 8 KiB slave region,
/// and the first wrapper of the core's kind. False for a core with
/// neither port nor address, or an EROM that ends inside it.
fn addresses(bp: *Backplane, erom: *u32, core: *Core) Error!bool {
    const first = try next(bp, erom);
    const wrap_type = switch (kind(first)) {
        DESC_MASTER_PORT => SLAVE_TYPE_MWRAP,
        DESC_ADDRESS => blk: {
            erom.* -= 4;
            break :blk SLAVE_TYPE_SWRAP;
        },
        else => {
            erom.* -= 4;
            return false;
        },
    };
    while (core.base == 0 or core.wrap == 0) {
        var value: u32 = 0;
        while (true) {
            value = try next(bp, erom);
            const found = kind(value);
            if (found == DESC_EOT) {
                erom.* -= 4;
                return false;
            }
            if (found == DESC_COMPONENT) {
                erom.* -= 4;
                return true;
            }
            if (found == DESC_ADDRESS) break;
        }
        if (value & DESC_ADDRSIZE_GT32 != 0) _ = try next(bp, erom);
        const size_type = (value & SLAVE_SIZE_TYPE_MASK) >> SLAVE_SIZE_TYPE_SHIFT;
        if (size_type == SLAVE_SIZE_DESC) {
            const size = try next(bp, erom);
            if (size & DESC_ADDRSIZE_GT32 != 0) _ = try next(bp, erom);
        }
        if (size_type != SLAVE_SIZE_4K and size_type != SLAVE_SIZE_8K) continue;
        const slave_type = (value & SLAVE_TYPE_MASK) >> SLAVE_TYPE_SHIFT;
        if (core.base == 0 and slave_type == SLAVE_TYPE_SLAVE) core.base = value & SLAVE_ADDR_BASE_MASK;
        if (core.wrap == 0 and slave_type == wrap_type) core.wrap = value & SLAVE_ADDR_BASE_MASK;
    }
    return true;
}
