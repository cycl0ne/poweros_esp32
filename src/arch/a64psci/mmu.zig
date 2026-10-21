// SPDX-License-Identifier: MPL-2.0
//! The identity map start.S made, as the kernel finishes it once it knows
//! the machine: every GiB the device tree says has RAM in it is normal
//! memory, where the boot's window from the board's facts did not reach.
//!
//! An entry that maps is changed the way the architecture asks
//! (break-before-make): made invalid, the TLBs told on every core, and
//! only then written anew. That is safe for a GiB nothing uses yet, which
//! is every one changed here; the two the boot split into tables - the
//! first GiB and the kernel's own - are left as they are.

const std = @import("std");
const Range = @import("fdt.zig").Range;

extern var a64_page_table: [512]u64;

/// A level-1 entry: a block (low bits 01) or a table (11).
const DESC_MASK: u64 = 3;
const DESC_BLOCK: u64 = 1;
/// The attributes start.S gives a block (start.S's ATTR_RAM, ATTR_DEVICE).
const ATTR_RAM: u64 = 0x704;
/// AttrIndx: memory type 0, device memory.
const ATTR_INDEX_MASK: u64 = 7 << 2;

const gib = 1 << 30;

/// Every GiB of `ranges` normal memory.
pub fn refine(ranges: []const Range) void {
    for (ranges) |range| {
        if (range.end <= range.start) continue;
        var at = range.start / gib;
        const last = (range.end - 1) / gib;
        while (at <= last and at < a64_page_table.len) : (at += 1) makeRam(at);
    }
}

/// GiB `index` normal memory, if it is a block of device memory now.
fn makeRam(index: usize) void {
    const entry = @as(*volatile u64, &a64_page_table[index]);
    const old = entry.*;
    if (old & DESC_MASK != DESC_BLOCK) return; // a table, or nothing
    if (old & ATTR_INDEX_MASK != 0) return; // normal memory already
    const new = @as(u64, index) * gib | ATTR_RAM | DESC_BLOCK;
    entry.* = 0;
    asm volatile (
        \\dsb ishst
        \\tlbi vmalle1is
        \\dsb ish
        \\isb
        ::: .{ .memory = true });
    entry.* = new;
    asm volatile (
        \\dsb ishst
        \\isb
        ::: .{ .memory = true });
}

comptime {
    std.debug.assert(gib == 0x4000_0000);
}
