// SPDX-License-Identifier: MPL-2.0
//! The machine's free RAM, handed to exec: all of RAM as the device tree
//! or else the board says (SYSTAG_RamBase, SYSTAG_RamSize), less what is
//! in use - the kernel's image with AbsExecBase's page below it, the disk
//! image the loader put in RAM (sdk.hardware.ramdisk), and the ranges the
//! device tree reserves (`reserved`: OpenSBI's own, and the disk image
//! again where U-Boot lists it). On the JH7110 that gives exec the
//! gigabyte below the kernel too, less OpenSBI's 256 KiB at its start:
//! what U-Boot left there - the image it was loaded at, the device tree -
//! is done with once the kernel has read the tree. A tree that reserves
//! nothing gets nothing below the kernel handed out, as the firmware is
//! there and has not said where.
//!
//! It is all DRAM, so it is both internal and external memory as exec's
//! callers ask for them. Only what is below 4 GiB is MEMF_DMA: the DMA
//! engines' descriptors hold 32-bit addresses, so a region that crosses
//! the line is cut there. And exec counts a region's free bytes in 32
//! bits (MemHeader.free, MemChunk.bytes), so none is larger than 2 GiB.
//! The region the kernel's heap starts in comes first, as it holds
//! SysBase; then the rest above the kernel, then what is below it.

const exec = @import("../../rom/libs/exec/exec.zig");
const layout = @import("layout.zig");
const sdk = @import("sdk");
const ramdisk = sdk.hardware.ramdisk;
const Range = @import("fdt.zig").Range;
const max_reserved = @import("fdt.zig").max_reserved;

/// The VisionFive 2's 8 GiB: above the kernel, to 4 GiB and three pieces
/// of `largest` after it; below it, around the disk image. Room besides
/// for the pieces more reserved ranges cut.
pub const max_regions = 12;

/// Where RAM is, which the kernel sets from the board.
pub var ram_base: usize = 0;
pub var ram_size: usize = 0;

/// What the device tree reserves, which the kernel sets from it.
pub var reserved: [max_reserved]Range = undefined;
pub var reserved_count: usize = 0;

pub fn ramEnd() usize {
    return ram_base + ram_size;
}

/// A region too small for a MemHeader and a block is not handed out.
const smallest = 64 * 1024;
/// Where DMA stops reaching.
const dma_limit: usize = 1 << 32;
/// The most one region holds.
const largest: usize = 1 << 31;
const page = 4096;

/// What is not free, each widened to whole pages: the kernel, the disk
/// image and the reserved ranges, in no order.
fn holes(buf: *[max_reserved + 2]Range) []const Range {
    var count: usize = 0;
    buf[count] = .{ .start = @intFromPtr(sdk.exec.AbsExecBase) & ~@as(usize, page - 1), .end = layout.heapStart() };
    count += 1;
    if (ramdisk.size != 0) {
        buf[count] = .{ .start = ramdisk.base, .end = ramdisk.base + ramdisk.size };
        count += 1;
    }
    for (reserved[0..reserved_count]) |range| {
        buf[count] = range;
        count += 1;
    }
    for (buf[0..count]) |*hole| {
        hole.start &= ~@as(usize, page - 1);
        hole.end = (hole.end +| (page - 1)) & ~@as(usize, page - 1);
    }
    return buf[0..count];
}

/// Regions for the bootstrap. The first one also holds SysBase.
pub fn regions(buf: *[max_regions]exec.MemRegion) []const exec.MemRegion {
    var hole_buf: [max_reserved + 2]Range = undefined;
    const in_use = holes(&hole_buf);
    const kernel = in_use[0];
    var count: usize = 0;
    free(buf, &count, in_use, kernel.end, ramEnd());
    // A tree that reserves nothing has not said where the firmware is,
    // which is below the kernel: none of it is handed out then.
    if (reserved_count != 0) free(buf, &count, in_use, ram_base, kernel.start);
    return buf[0..count];
}

/// The free parts of `from` to `to` as regions: what lies between the
/// holes in it, lowest first.
fn free(buf: *[max_regions]exec.MemRegion, count: *usize, in_use: []const Range, from: usize, to: usize) void {
    var at = from;
    while (at < to) {
        // Past every hole `at` is in.
        var moved = true;
        while (moved) {
            moved = false;
            for (in_use) |hole| {
                if (hole.start <= at and hole.end > at) {
                    at = hole.end;
                    moved = true;
                }
            }
        }
        if (at >= to) return;
        // Up to the next hole above it.
        var stop = to;
        for (in_use) |hole| {
            if (hole.start > at and hole.start < stop) stop = hole.start;
        }
        add(buf, count, at, stop);
        at = stop;
    }
}

/// `from` to `to` as regions: cut where it crosses 4 GiB, and into
/// pieces of `largest`; nothing for a range too small to keep, or one
/// there is no room left for.
fn add(buf: *[max_regions]exec.MemRegion, count: *usize, from: usize, to: usize) void {
    if (from < dma_limit and to > dma_limit) {
        add(buf, count, from, dma_limit);
        add(buf, count, dma_limit, to);
        return;
    }
    if (to -| from > largest) {
        add(buf, count, from, from + largest);
        add(buf, count, from + largest, to);
        return;
    }
    if (to -| from < smallest or count.* == max_regions) return;
    const dma = to <= dma_limit;
    buf[count.*] = .{
        .name = if (count.* == 0) "memory" else if (dma) "more memory" else "memory above 4 GiB",
        .base = @ptrFromInt(from),
        .size = to - from,
        .attributes = exec.MEMF_INTERNAL | exec.MEMF_EXTERNAL | if (dma) exec.MEMF_DMA else 0,
        .pri = 0,
    };
    count.* += 1;
}
