// SPDX-License-Identifier: MPL-2.0
//! The machine's free RAM, handed to exec: from above the kernel's boot
//! stack to the end of RAM, as the device tree or else the board says
//! (SYSTAG_RamBase, SYSTAG_RamSize), less the disk image the loader put in
//! it (sdk.hardware.ramdisk) - a region below the image and one above.
//! Everything below the kernel - the firmware, and on the JH7110 what
//! U-Boot leaves, the device tree and the disk image among it - is left
//! alone.
//!
//! It is all DRAM, so it is both internal and external memory as exec's
//! callers ask for them. Only what is below 4 GiB is MEMF_DMA: the DMA
//! engines' descriptors hold 32-bit addresses, so a region that crosses
//! the line is cut there. And exec counts a region's free bytes in 32
//! bits (MemHeader.free, MemChunk.bytes), so none is larger than 2 GiB:
//! the VisionFive 2's 8 GiB are four regions.

const exec = @import("../../rom/libs/exec/exec.zig");
const layout = @import("layout.zig");
const ramdisk = @import("sdk").hardware.ramdisk;

/// Below and above the disk image, each cut at 4 GiB and into pieces of
/// `largest`: 8 GiB from 0x40000000 is 8 at the most.
pub const max_regions = 8;

/// Where RAM is, which the kernel sets from the board.
pub var ram_base: usize = 0;
pub var ram_size: usize = 0;

pub fn ramEnd() usize {
    return ram_base + ram_size;
}

/// A region too small for a MemHeader and a block is not handed out.
const smallest = 64 * 1024;
/// Where DMA stops reaching.
const dma_limit: usize = 1 << 32;
/// The most one region holds.
const largest: usize = 1 << 31;

/// Regions for the bootstrap. The first one also holds SysBase.
pub fn regions(buf: *[max_regions]exec.MemRegion) []const exec.MemRegion {
    const start = layout.heapStart();
    const end = ramEnd();
    const page = 4096;
    // The image, widened to whole pages, where it is inside the free RAM.
    const disk_start = if (ramdisk.size != 0) ramdisk.base & ~@as(usize, page - 1) else end;
    const disk_end = if (ramdisk.size != 0) (ramdisk.base + ramdisk.size + page - 1) & ~@as(usize, page - 1) else end;
    var count: usize = 0;
    add(buf, &count, start, @max(start, @min(disk_start, end)));
    add(buf, &count, @min(end, @max(start, disk_end)), end);
    return buf[0..count];
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
