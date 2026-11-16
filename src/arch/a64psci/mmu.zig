// SPDX-License-Identifier: MPL-2.0
//! The identity map start.S made, as the kernel finishes it once it knows
//! the machine: every GiB the device tree says has RAM in it is normal
//! memory, where the boot's window from the board's facts did not reach.
//!
//! **A GiB that is RAM in part** gets a table of 2 MiB blocks of its own,
//! RAM normal memory and the rest device memory: on the Raspberry Pi 4
//! the chip's peripherals are the last 64 MiB below 4 GiB, in the same GiB
//! as the RAM below them, and a block of normal memory over registers
//! would let the cores read them ahead and keep them in their caches. A
//! 2 MiB block with RAM in any of it is RAM: exec is handed the whole of
//! every range, and no machine yet has registers in the same 2 MiB as
//! RAM. There are two tables for this (start.S's `a64_spare_l2`); a GiB
//! past them stays device memory.
//!
//! **Memory another master owns** - the VideoCore's, which holds the
//! picture its firmware shows - is made normal memory without caches
//! (`uncached`): the cores write it and the display reads it, and nothing
//! has to be written back for the picture to change.
//!
//! An entry that maps is changed the way the architecture asks
//! (break-before-make): made invalid, the TLBs told on every core, and
//! only then written anew. That is safe for a GiB nothing uses yet, which
//! is every one changed here, and for blocks nothing but the caller uses;
//! the two the boot split into tables - the first GiB and the kernel's
//! own - keep their tables, and only their blocks are changed.

const std = @import("std");
const Range = @import("fdt.zig").Range;

extern var a64_page_table: [512]u64;
extern var a64_low_l3: [512]u64;
extern var a64_spare_l2: [spare_tables][512]u64;

/// How many level-2 tables start.S keeps for GiBs that are RAM in part
/// (its SPARE_TABLES).
const spare_tables = 2;
var spares_used: usize = 0;

/// A descriptor: a block (low bits 01), or a table or a page (11).
const DESC_MASK: u64 = 3;
const DESC_BLOCK: u64 = 1;
const DESC_TABLE: u64 = 3;
const DESC_PAGE: u64 = 3;
/// The output address of a table descriptor.
const TABLE_ADDRESS: u64 = 0x0000_FFFF_FFFF_F000;
/// The attributes start.S gives a block (start.S's ATTR_RAM, ATTR_DEVICE),
/// and normal memory without caches (memory type 2) that never runs.
const ATTR_RAM: u64 = 0x704;
const ATTR_DEVICE: u64 = 0x0060_0000_0000_0400;
const ATTR_UNCACHED: u64 = 0x0060_0000_0000_0408;
/// AttrIndx: memory type 0, device memory.
const ATTR_INDEX_MASK: u64 = 7 << 2;

const gib = 1 << 30;
const block = 1 << 21;

/// Every GiB of `ranges` normal memory: whole where RAM fills it, in 2
/// MiB blocks where it fills part of it.
pub fn refine(ranges: []const Range) void {
    for (ranges) |range| {
        if (range.end <= range.start) continue;
        var at = range.start / gib;
        const last = (range.end - 1) / gib;
        while (at <= last and at < a64_page_table.len) : (at += 1) {
            if (ramBlocks(ranges, at) == 512) makeRam(at) else split(ranges, at);
        }
    }
}

/// Whether any of `ranges` has RAM in the 2 MiB block at `address`.
fn hasRam(ranges: []const Range, address: usize) bool {
    for (ranges) |range| {
        if (range.start < address + block and range.end > address) return true;
    }
    return false;
}

/// How many of GiB `index`'s 2 MiB blocks have RAM in them.
fn ramBlocks(ranges: []const Range, index: usize) u32 {
    var count: u32 = 0;
    for (0..512) |which| {
        if (hasRam(ranges, index * gib + which * block)) count += 1;
    }
    return count;
}

/// The TLBs of every core told that an entry went.
fn forget() void {
    asm volatile (
        \\dsb ishst
        \\tlbi vmalle1is
        \\dsb ish
        \\isb
        ::: .{ .memory = true });
}

/// An entry written is seen by the walks from here on.
fn publish() void {
    asm volatile (
        \\dsb ishst
        \\isb
        ::: .{ .memory = true });
}

/// `entry` replaced with `new`, break-before-make.
fn replace(entry: *volatile u64, new: u64) void {
    entry.* = 0;
    forget();
    entry.* = new;
    publish();
}

/// GiB `index` normal memory, if it is a block of device memory now.
fn makeRam(index: usize) void {
    const entry = @as(*volatile u64, &a64_page_table[index]);
    const old = entry.*;
    if (old & DESC_MASK != DESC_BLOCK) return; // a table, or nothing
    if (old & ATTR_INDEX_MASK != 0) return; // normal memory already
    replace(entry, @as(u64, index) * gib | ATTR_RAM | DESC_BLOCK);
}

/// GiB `index`, a block of device memory now, as a table of 2 MiB
/// blocks: RAM where `ranges` has it, device memory around it. Left as it
/// is where it is a table already, normal memory, or there is no table
/// left for it.
fn split(ranges: []const Range, index: usize) void {
    const entry = @as(*volatile u64, &a64_page_table[index]);
    const old = entry.*;
    if (old & DESC_MASK != DESC_BLOCK) return;
    if (old & ATTR_INDEX_MASK != 0) return;
    if (spares_used == spare_tables) return;
    const table = &a64_spare_l2[spares_used];
    spares_used += 1;
    for (table, 0..) |*slot, which| {
        const address = index * gib + which * block;
        slot.* = @as(u64, address) | (if (hasRam(ranges, address)) ATTR_RAM else ATTR_DEVICE) | DESC_BLOCK;
    }
    replace(entry, @as(u64, @intFromPtr(table)) | DESC_TABLE);
}

/// `range` normal memory without caches: every 2 MiB block it touches,
/// in a GiB the boot or `refine` made a table of. A block that is pages
/// itself - the first 2 MiB, the kernel's code - is left as it is, and so
/// is a GiB that is one block: no picture has been there yet. True when
/// every block of it is uncached now.
pub fn uncached(range: Range) bool {
    if (range.end <= range.start) return true;
    var all = true;
    var at = range.start & ~@as(usize, block - 1);
    while (at < range.end) : (at += block) {
        const index = at / gib;
        if (index >= a64_page_table.len) return false;
        const top = a64_page_table[index];
        if (top & DESC_MASK != DESC_TABLE) {
            all = false;
            continue;
        }
        const table: *[512]u64 = @ptrFromInt(top & TABLE_ADDRESS);
        const entry = @as(*volatile u64, &table[(at % gib) / block]);
        if (entry.* & DESC_MASK != DESC_BLOCK) {
            all = false;
            continue;
        }
        replace(entry, @as(u64, at) | ATTR_UNCACHED | DESC_BLOCK);
    }
    return all;
}

/// Page 0 mapped, normal memory, or unmapped again. The map leaves it out
/// so that a null pointer faults; the Raspberry Pi 4's firmware keeps its
/// spin table there, which the kernel writes to let a core go
/// (cpu1.zig), with no other core yet running.
pub fn pageZero(mapped: bool) void {
    const entry = @as(*volatile u64, &a64_low_l3[0]);
    if (mapped) {
        // Nothing mapped before: no break needed.
        entry.* = ATTR_RAM | DESC_PAGE;
        publish();
    } else {
        entry.* = 0;
        forget();
    }
}

comptime {
    std.debug.assert(gib == 0x4000_0000);
}
