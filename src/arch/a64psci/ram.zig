// SPDX-License-Identifier: MPL-2.0
//! The machine's free RAM, handed to exec: every range the device tree
//! lists, or else the one the board says (SYSTAG_RamBase,
//! SYSTAG_RamSize), less what is in use - the kernel's image with
//! AbsExecBase's page below it, the disk image the loader put in RAM
//! (sdk.hardware.ramdisk), the ranges the device tree reserves
//! (`reserved`: the firmware's own), the blocks kept for the board's
//! parts to share with another master (`keep`), and page 0, which the
//! map leaves out where RAM starts at 0 (start.S). A tree that reserves nothing gets
//! nothing below the kernel handed out, as the firmware's boot code is
//! there and has not said where (QEMU's).
//!
//! It is all DRAM, so it is both internal and external memory as exec's
//! callers ask for them. Only what is below `dma_limit` is MEMF_DMA: the
//! devices' descriptors may hold 32-bit addresses, so a region that
//! crosses the line is cut there; past it, a range is one region however
//! large. The region the kernel's heap starts in comes first, as it holds
//! SysBase; then the rest above the kernel, then what is below it.
//! DMA memory is at a lower priority than the rest, so an allocation that
//! does not ask for MEMF_DMA takes memory past the limit first and what
//! DMA reaches is kept for what needs it.

const exec = @import("../../rom/libs/exec/exec.zig");
const layout = @import("layout.zig");
const sdk = @import("sdk");
const ramdisk = sdk.hardware.ramdisk;
const fdt = @import("fdt.zig");
const Range = fdt.Range;
const max_reserved = fdt.max_reserved;

/// Room for the pieces several ranges of RAM and the reserved ranges cut
/// it into.
pub const max_regions = 16;

/// Where RAM is, which the kernel sets from the device tree or the board.
pub var memory: [fdt.max_memory]Range = undefined;
pub var memory_count: usize = 0;

/// What the device tree reserves, which the kernel sets from it.
pub var reserved: [max_reserved]Range = undefined;
pub var reserved_count: usize = 0;

/// Where DMA stops reaching, which the kernel sets from the board.
pub var dma_limit: usize = 1 << 32;

/// The blocks kept for the board's parts (`keep`).
pub const max_kept = 2;
pub var kept: [max_kept]Range = undefined;
pub var kept_count: usize = 0;

/// The size the map's blocks are, and what is kept is made of.
pub const block = 2 * 1024 * 1024;

/// `bytes`, rounded up to whole 2 MiB blocks, kept from exec for a part
/// that shares it: the highest such stretch of RAM that ends at or below
/// `below` and holds nothing in use. Its address, or null where there is
/// none, or no room to note it. Called before `regions`.
pub fn keep(bytes: usize, below: usize) ?usize {
    if (kept_count == max_kept or bytes == 0) return null;
    const size = (bytes + block - 1) & ~@as(usize, block - 1);
    var hole_buf: [max_reserved + 3 + max_kept]Range = undefined;
    const in_use = holes(&hole_buf);
    var best: ?usize = null;
    for (ranges()) |range| {
        const top = @min(range.end, below) & ~@as(usize, block - 1);
        var at = top;
        while (at >= range.start + size and at >= size) : (at -= block) {
            const start = at - size;
            if (start < range.start) break;
            var clear = true;
            for (in_use) |hole| {
                if (hole.start < at and hole.end > start) clear = false;
            }
            if (clear) {
                if (best == null or start > best.?) best = start;
                break;
            }
        }
    }
    const start = best orelse return null;
    kept[kept_count] = .{ .start = start, .end = start + size };
    kept_count += 1;
    return start;
}

/// RAM's ranges.
pub fn ranges() []const Range {
    return memory[0..memory_count];
}

/// The lowest address of RAM.
pub fn ramBase() usize {
    var lowest: usize = ~@as(usize, 0);
    for (ranges()) |range| lowest = @min(lowest, range.start);
    return if (memory_count == 0) 0 else lowest;
}

/// One past the highest address of RAM.
pub fn ramEnd() usize {
    var highest: usize = 0;
    for (ranges()) |range| highest = @max(highest, range.end);
    return highest;
}

/// Whether `address` is in RAM.
pub fn isRam(address: usize) bool {
    for (ranges()) |range| {
        if (address >= range.start and address < range.end) return true;
    }
    return false;
}

/// A region too small for a MemHeader and a block is not handed out.
const smallest = 64 * 1024;
/// DMA memory's place on the memory list: behind the rest.
const dma_pri: i8 = -10;
const page = 4096;

/// What is not free, each widened to whole pages: the kernel first, then
/// page 0, the disk image, the reserved ranges and the kept blocks, in no
/// order.
fn holes(buf: *[max_reserved + 3 + max_kept]Range) []const Range {
    var count: usize = 0;
    buf[count] = .{ .start = @intFromPtr(sdk.exec.AbsExecBase) & ~@as(usize, page - 1), .end = layout.heapStart() };
    count += 1;
    buf[count] = .{ .start = 0, .end = page };
    count += 1;
    if (ramdisk.size != 0) {
        buf[count] = .{ .start = ramdisk.base, .end = ramdisk.base + ramdisk.size };
        count += 1;
    }
    for (reserved[0..reserved_count]) |range| {
        buf[count] = range;
        count += 1;
    }
    for (kept[0..kept_count]) |range| {
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
    var hole_buf: [max_reserved + 3 + max_kept]Range = undefined;
    const in_use = holes(&hole_buf);
    const kernel = in_use[0];
    var count: usize = 0;
    // The kernel's own range first, from its end.
    var own: ?usize = null;
    for (ranges(), 0..) |range, index| {
        if (kernel.end > range.start and kernel.end <= range.end) own = index;
    }
    if (own) |index| free(buf, &count, in_use, kernel.end, memory[index].end);
    // Then every other range above the kernel.
    for (ranges(), 0..) |range, index| {
        if (own != null and index == own.?) continue;
        if (range.start >= kernel.end) free(buf, &count, in_use, range.start, range.end);
    }
    // A tree that reserves nothing has not said where the firmware is,
    // which is below the kernel: none of it is handed out then.
    if (reserved_count != 0) {
        for (ranges()) |range| {
            if (range.start < kernel.start) free(buf, &count, in_use, range.start, @min(range.end, kernel.start));
        }
    }
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

/// `from` to `to` as regions: cut where it crosses the DMA limit; nothing
/// for a range too small to keep, or one there is no room left for.
fn add(buf: *[max_regions]exec.MemRegion, count: *usize, from: usize, to: usize) void {
    if (from < dma_limit and to > dma_limit) {
        add(buf, count, from, dma_limit);
        add(buf, count, dma_limit, to);
        return;
    }
    if (to -| from < smallest or count.* == max_regions) return;
    const dma = to <= dma_limit;
    buf[count.*] = .{
        .name = if (dma) "dma memory" else "memory",
        .base = @ptrFromInt(from),
        .size = to - from,
        .attributes = exec.MEMF_INTERNAL | exec.MEMF_EXTERNAL | if (dma) exec.MEMF_DMA else 0,
        .pri = if (dma) dma_pri else 0,
    };
    count.* += 1;
}
