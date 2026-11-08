// SPDX-License-Identifier: MPL-2.0
//! The machine's free RAM, handed to exec: every range the firmware called
//! memory, as the stub gathered them (`src/boot/uefi/handover.zig`), less
//! what is in use - the kernel's image with AbsExecBase's page below it,
//! the disk image the stub read off the boot partition
//! (sdk.hardware.ramdisk), the ranges the firmware keeps for its own
//! runtime half (`reserved`), and page 0, which the kernel's map leaves out
//! so that a null pointer faults (mmu.zig).
//!
//! **What counts as free is the stub's judgement, not this file's.** The
//! firmware describes its memory by what it was used for, and the stub
//! turns that into two lists: what the kernel may hand out once the
//! firmware has gone - which includes the firmware's own boot-time code and
//! data, and the stub's own - and what must be left alone. So the stub's
//! own image, and the pages it read the kernel and the disk image into, are
//! in the free list: the kernel's image is kept out of it here, by the
//! linker's symbols, and the disk image by where the handover says it is.
//!
//! It is all DRAM, so it is both internal and external memory as exec's
//! callers ask for them. Only what is below `dma_limit` is MEMF_DMA: the
//! devices' descriptors may hold 32-bit addresses, so a region that
//! crosses the line is cut there. And exec counts a region's free bytes
//! in 32 bits (MemHeader.free, MemChunk.bytes), so none is larger than
//! 2 GiB. The region the kernel's heap starts in comes first, as it holds
//! SysBase; then the rest above the kernel, then what is below it.

const exec = @import("../../rom/libs/exec/exec.zig");
const layout = @import("layout.zig");
const sdk = @import("sdk");
const ramdisk = sdk.hardware.ramdisk;
const handover = @import("../../boot/uefi/handover.zig");
const Range = handover.Range;
const max_reserved = handover.max_reserved;

/// Room for the pieces several ranges of RAM and the reserved ranges cut
/// it into, at 2 GiB each. A PC's firmware describes its memory finely,
/// and the stub joins what touches, so this is roomier than the other
/// 64-bit machines need.
pub const max_regions = 24;

/// Where RAM is, which the kernel sets from the handover.
pub var memory: [handover.max_memory]Range = undefined;
pub var memory_count: usize = 0;

/// What the firmware keeps, which the kernel sets from the handover.
pub var reserved: [max_reserved]Range = undefined;
pub var reserved_count: usize = 0;

/// Where DMA stops reaching, which the kernel sets from the board.
pub var dma_limit: usize = 1 << 32;

/// What the kernel took for itself before exec was built: the cores' own
/// tables, which are as many as the machine has cores
/// (`coretables.take`). It is RAM like any other and the map covers it;
/// it is only kept out of what exec hands out.
pub var taken: Range = .{ .start = 0, .end = 0 };

/// `bytes` of RAM for the kernel's own use, whole pages, off the end of
/// the largest range: where it is, or 0 where no range has room. Called
/// once, before `regions`, and nothing frees it.
pub fn take(bytes: usize) usize {
    const want = (bytes + page - 1) & ~@as(usize, page - 1);
    var biggest: ?*Range = null;
    for (memory[0..memory_count]) |*range| {
        if (range.end - range.start < want + smallest) continue;
        if (biggest == null or range.end - range.start > biggest.?.end - biggest.?.start) biggest = range;
    }
    const range = biggest orelse return 0;
    taken = .{ .start = range.end - want, .end = range.end };
    return taken.start;
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
/// The most one region holds.
const largest: usize = 1 << 31;
const page = 4096;

/// What is not free, each widened to whole pages: the kernel first, then
/// page 0, the disk image, the cores' tables and the reserved ranges, in
/// no order.
fn holes(buf: *[max_reserved + 4]Range) []const Range {
    var count: usize = 0;
    buf[count] = .{ .start = @intFromPtr(sdk.exec.AbsExecBase) & ~@as(usize, page - 1), .end = layout.heapStart() };
    count += 1;
    buf[count] = .{ .start = 0, .end = page };
    count += 1;
    if (ramdisk.size != 0) {
        buf[count] = .{ .start = ramdisk.base, .end = ramdisk.base + ramdisk.size };
        count += 1;
    }
    if (taken.end != taken.start) {
        buf[count] = taken;
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
    var hole_buf: [max_reserved + 4]Range = undefined;
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
    // A firmware that reserves nothing has not said where it is, which
    // may be below the kernel: none of it is handed out then.
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

/// `from` to `to` as regions: cut where it crosses the DMA limit, and
/// into pieces of `largest`; nothing for a range too small to keep, or
/// one there is no room left for.
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
        .name = if (count.* == 0) "memory" else if (dma) "more memory" else "memory beyond DMA",
        .base = @ptrFromInt(from),
        .size = to - from,
        .attributes = exec.MEMF_INTERNAL | exec.MEMF_EXTERNAL | if (dma) exec.MEMF_DMA else 0,
        .pri = 0,
    };
    count.* += 1;
}
