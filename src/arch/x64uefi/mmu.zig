// SPDX-License-Identifier: MPL-2.0
//! The map the kernel makes for itself, once it knows the machine.
//!
//! The firmware leaves a map behind that identifies every address with
//! itself, and the kernel runs on it until here: that is enough to read
//! the handover, the firmware's tables and the board, and it is why the
//! stub hands over with nothing of its own built. But the firmware's map
//! is in memory the kernel is about to hand out, so it cannot be kept; and
//! two things are wanted of a map of the kernel's own that the firmware's
//! does not give. Address 0 is left unmapped, so that a null pointer
//! faults where it is used instead of reading whatever is at the bottom of
//! memory. And the kernel's code is made read-only, which with CR0.WP set
//! (cpu.zig) holds at this privilege level too.
//!
//! **What is mapped** is every address up to the end of the highest thing
//! the machine has: RAM as the handover lists it, the framebuffer the
//! firmware lit, and the mebibytes at the top of the first four gibibytes
//! where this architecture's devices are - the interrupt controllers, and
//! whatever is behind the PCI bridge. Identity, all of it: a physical
//! address and the address the kernel uses for it are the same number,
//! which is what every driver in the tree assumes and what the firmware
//! already had.
//!
//! **The page sizes.** The first gibibyte is 2 MiB blocks, and its first
//! 2 MiB and the blocks the kernel's code is in are 4 KiB pages - the
//! first so that page 0 can be left out, the second so that the code can
//! be read-only without the data beside it becoming so. Above the first
//! gibibyte a core that has 1 GiB pages gets them, which maps the whole
//! address space from one table; one that has not gets 2 MiB blocks from
//! the tables below, which reach eight gibibytes. The kernel says which it
//! used and how far it reached, so a machine with more memory than that
//! and a core without the larger pages is not quietly left with less.
//!
//! **Device memory is uncached**, so that a register read reaches the
//! device and a write does not wait in a cache line. The firmware's
//! framebuffer is device memory by that rule, and writing a screen a word
//! at a time to uncached memory is as slow as it sounds - so the kernel
//! asks for the screen's own blocks to be write-combining (`gather`): the
//! writes to them are gathered and sent on as whole bursts, in order,
//! which is what a picture written once and read every frame wants. It is
//! asked for a range rather than decided here, because what a range holds
//! - a screen, or a device's registers, which must have every write of
//! their own - is not something an address says.

const std = @import("std");
const cpu = @import("cpu.zig");
const layout = @import("layout.zig");
const Range = @import("../../boot/uefi/handover.zig").Range;

const kib = 1024;
const mib = 1024 * kib;
const gib = 1024 * mib;

/// A page table's entries, and what one holds.
const entries = 512;
const PRESENT: u64 = 1 << 0;
const WRITABLE: u64 = 1 << 1;
/// A block rather than a table at this level: 1 GiB at the third, 2 MiB at
/// the second.
const LARGE: u64 = 1 << 7;
/// Accessed and dirty, set here so the core never has to write them.
const TOUCHED: u64 = (1 << 5) | (1 << 6);
/// Write-through and uncached, which device memory wants.
const WRITE_THROUGH: u64 = 1 << 3;
const UNCACHED: u64 = 1 << 4;
/// A block's own attribute bit, which with the other two clear picks the
/// page attribute table's fifth entry: write-combining, as every core sets
/// that entry up (`cpu.takePat`). It is bit 12 of a block and bit 7 of a
/// page, which is why only blocks are marked here.
const GATHERED: u64 = 1 << 12;
const ADDRESS: u64 = 0x000F_FFFF_FFFF_F000;

/// How many gibibytes above the first the 2 MiB tables below reach, for a
/// core with no 1 GiB pages.
const pool_gibibytes = 7;
/// How many 2 MiB blocks of the kernel's code get pages of their own, so
/// that the code in them can be read-only: past them it stays writable.
const code_tables = 4;

/// The tables, in the kernel's own .bss so that nothing hands them out.
var level4: [entries]u64 align(4 * kib) = @splat(0);
var level3: [entries]u64 align(4 * kib) = @splat(0);
/// The first gibibyte, in 2 MiB blocks.
var low_level2: [entries]u64 align(4 * kib) = @splat(0);
/// Its first 2 MiB, in 4 KiB pages, whose first is left out.
var low_level1: [entries]u64 align(4 * kib) = @splat(0);
/// The 2 MiB blocks the kernel's code is in, in 4 KiB pages.
var code_level1: [code_tables][entries]u64 align(4 * kib) = @splat(@splat(0));
/// The gibibytes above the first, in 2 MiB blocks, for a core with no
/// 1 GiB pages.
var pool_level2: [pool_gibibytes][entries]u64 align(4 * kib) = @splat(@splat(0));
/// One gibibyte in 2 MiB blocks, for `gather` to split where the core has
/// 1 GiB blocks: a screen is a few mebibytes and the registers in the
/// gibibyte around it must keep every write of their own.
var screen_level2: [entries]u64 align(4 * kib) = @splat(0);

/// Whether 1 GiB blocks were used, and how far the map reaches: what the
/// kernel reports.
pub var large_pages = false;
pub var mapped_end: usize = 0;

/// Leaf 0x8000_0001, EDX bit 26: the core has 1 GiB blocks.
fn hasLargePages() bool {
    if (cpu.leaf(0x8000_0000, 0).eax < 0x8000_0001) return false;
    return cpu.leaf(0x8000_0001, 0).edx & (1 << 26) != 0;
}

/// Whether an address is one of the machine's devices rather than its
/// memory: everything in the top of the first four gibibytes, which is
/// where this architecture has put them since it had them, and anything
/// past the memory the handover listed. Device memory is mapped uncached:
/// a register read must reach the device, and a write must not wait in a
/// cache line.
fn isDevice(at: usize, memory: []const Range) bool {
    for (memory) |range| {
        if (at >= range.start and at < range.end) return false;
    }
    return true;
}

/// The map built and switched to: `memory` is where RAM is, and
/// everything else is device memory. Nothing is reached through the
/// firmware's map afterwards, which is what lets the memory it was in be
/// handed out.
pub fn take(memory: []const Range) void {
    const large = hasLargePages();
    large_pages = large;

    // The first 2 MiB in pages, page 0 left out so that a null pointer
    // faults. Nothing of the kernel is down there.
    low_level1[0] = 0;
    for (1..entries) |page| {
        const at = page * 4 * kib;
        low_level1[page] = at | PRESENT | WRITABLE | TOUCHED | deviceBits(at, memory);
    }
    low_level2[0] = @intFromPtr(&low_level1) | PRESENT | WRITABLE | TOUCHED;

    // The rest of the first gibibyte in 2 MiB blocks.
    for (1..entries) |block| {
        const at = block * 2 * mib;
        low_level2[block] = at | PRESENT | WRITABLE | LARGE | TOUCHED | deviceBits(at, memory);
    }
    // The blocks the kernel's code is in, in pages, the code read-only.
    takeCode();
    level3[0] = @intFromPtr(&low_level2) | PRESENT | WRITABLE | TOUCHED;

    // Everything above the first gibibyte.
    var reach: usize = gib;
    if (large) {
        for (1..entries) |block| {
            const at = block * gib;
            level3[block] = at | PRESENT | WRITABLE | LARGE | TOUCHED | deviceBits(at, memory);
        }
        reach = entries * gib;
    } else {
        for (&pool_level2, 0..) |*table, index| {
            const base = (index + 1) * gib;
            for (table, 0..) |*block, number| {
                const at = base + number * 2 * mib;
                block.* = at | PRESENT | WRITABLE | LARGE | TOUCHED | deviceBits(at, memory);
            }
            level3[index + 1] = @intFromPtr(table) | PRESENT | WRITABLE | TOUCHED;
        }
        reach = (pool_gibibytes + 1) * gib;
    }
    mapped_end = reach;

    level4[0] = @intFromPtr(&level3) | PRESENT | WRITABLE | TOUCHED;
    cpu.writeCr3(@intFromPtr(&level4));
}

/// The blocks `range` lies in made write-combining: the writes to them
/// gathered into bursts instead of each reaching the machine on its own.
/// True when they are; false, and nothing changed, where the range is not
/// mapped in blocks this can mark - which the kernel says, since a screen
/// written word by word to uncached memory is slow enough to be worth
/// knowing about.
///
/// The range is taken out to whole 2 MiB blocks, so what shares one with
/// the screen is gathered too. Where the core has 1 GiB blocks the
/// gibibyte the screen is in is split into 2 MiB blocks first, each
/// keeping what the gibibyte had, so that the devices beside it are
/// untouched; there is one table for that, so a range lying across two
/// gibibytes is left alone.
pub fn gather(range: Range) bool {
    const first = std.mem.alignBackward(usize, range.start, 2 * mib);
    const end = std.mem.alignForward(usize, range.end, 2 * mib);
    if (end <= first or end > mapped_end) return false;

    if (large_pages and first >= gib) {
        if ((end - 1) / gib != first / gib) return false;
        const which = first / gib;
        const base = which * gib;
        const had = level3[which] & (UNCACHED | WRITE_THROUGH);
        for (&screen_level2, 0..) |*block, number| {
            const at = base + number * 2 * mib;
            const inside = at >= first and at < end;
            block.* = at | PRESENT | WRITABLE | LARGE | TOUCHED | (if (inside) GATHERED else had);
        }
        level3[which] = @intFromPtr(&screen_level2) | PRESENT | WRITABLE | TOUCHED;
    } else {
        // Already 2 MiB blocks: each is marked where it lies. A block that
        // holds a table of pages instead - the bottom of memory, and the
        // kernel's own code - is not one of them, and nothing is changed.
        var at = first;
        while (at < end) : (at += 2 * mib) {
            const table = blockTable(at) orelse return false;
            const number = (at / (2 * mib)) % entries;
            if (table[number] & LARGE == 0) return false;
            table[number] = (table[number] & ~(UNCACHED | WRITE_THROUGH)) | GATHERED;
        }
    }
    // The map changed under a core that has read it: its own translations
    // of those blocks go with the write.
    cpu.writeCr3(@intFromPtr(&level4));
    return true;
}

/// The table of 2 MiB blocks `at` is in, where it is in one at all.
fn blockTable(at: usize) ?*[entries]u64 {
    if (at < gib) return &low_level2;
    const which = at / gib - 1;
    if (which >= pool_gibibytes) return null;
    return &pool_level2[which];
}

/// Whether the map reaches `highest`: a core with no 1 GiB blocks and a
/// machine with memory or devices past where the tables above end would
/// lose what is beyond, and the kernel says so rather than finding out
/// later.
pub fn reaches(highest: usize) bool {
    return highest <= mapped_end;
}

fn deviceBits(at: usize, memory: []const Range) u64 {
    return if (isDevice(at, memory)) UNCACHED | WRITE_THROUGH else 0;
}

/// The 2 MiB blocks the kernel's code is in, as pages: the code's
/// read-only, everything else in them as it was. A block past the tables
/// there are for it keeps its 2 MiB block and stays writable.
fn takeCode() void {
    const text_start = layout.textStart();
    const text_end = layout.textEnd();
    var block = text_start / (2 * mib);
    const last = (text_end - 1) / (2 * mib);
    var table: usize = 0;
    while (block <= last and table < code_tables) : ({
        block += 1;
        table += 1;
    }) {
        if (block >= entries) break; // the kernel is in the first gibibyte
        const base = block * 2 * mib;
        for (&code_level1[table], 0..) |*page, number| {
            const at = base + number * 4 * kib;
            const code = at >= text_start and at < text_end;
            page.* = at | PRESENT | TOUCHED | (if (code) 0 else WRITABLE);
        }
        low_level2[block] = @intFromPtr(&code_level1[table]) | PRESENT | WRITABLE | TOUCHED;
    }
}

comptime {
    std.debug.assert(gib == 0x4000_0000);
    std.debug.assert(@sizeOf(@TypeOf(level4)) == 4 * kib);
}
