// SPDX-License-Identifier: MPL-2.0
//! CreateMemHeader: lays a MemHeader over a block of memory and makes the
//! rest of it one free MemChunk. The header sits at the block's start,
//! aligned for itself; the free space behind it starts and ends on
//! `MEM_BLOCKSIZE`, so every chunk ever cut from it is aligned the same.

const sdk = @import("sdk");
const _memory = @import("_memory.zig");

const ExecBase = @import("../exec.zig").ExecBase;
const MemChunk = sdk.exec.MemChunk;
const MemHeader = sdk.exec.MemHeader;
const MEM_BLOCKSIZE = sdk.exec.MEM_BLOCKSIZE;

/// Lays a MemHeader over a block of memory, without adding it to the
/// system.
///
/// SYNOPSIS:
/// ```zig
/// fn CreateMemHeader(_: *ExecBase, size: usize, attributes: u32, pri: i8,
///     region: *anyopaque, name: ?[*:0]const u8) ?*MemHeader
/// ```
///
/// SINCE: 1.0. LVO -92.
///
/// INPUTS:
/// - `size` - bytes at `region`, header included.
/// - `attributes` - what this memory *is*: `MEMF_INTERNAL`, `MEMF_EXTERNAL`,
///   `MEMF_DMA`. The allocation options (`MEMF_CLEAR` and the rest) are not
///   region attributes and are ignored here.
/// - `pri` - where the region goes on the memory list. `AllocMem` tries
///   higher priorities first, so the memory that should be spent last is
///   given the lower number.
/// - `region` - the block. Aligned up to the header's alignment inside, so an
///   unaligned base costs a few bytes rather than failing.
/// - `name` - what a listing calls it, or null. Not copied: it must outlive
///   the region, which for a region named by the kernel is the ROM image.
///
/// RESULT:
/// The header, which sits at the start of the block, or null: the block is
/// too small for a header and one chunk, or the free space will not fit a
/// `u32`.
///
/// BEHAVIOR:
/// The free space is one chunk covering everything from behind the header,
/// rounded up to `MEM_BLOCKSIZE`, to the top rounded down - so a region
/// never hands out a block that straddles its own end.
///
/// The region is not on the memory list, so `AllocMem` cannot reach it.
/// `AddMemList` is both steps; this one exists for memory that is to be cut
/// up privately, which is what a pool's puddle is.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: safe. It touches only the caller's block.
/// - Forbid: not needed. Nothing else knows about this memory yet.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The header lives in the caller's block, so the two cannot be separated:
/// freeing the block frees the region.
///
/// NOTES:
/// This is how exec's own regions are made at boot, and how a pool lays a
/// header over a puddle - exec's allocator over a smaller arena rather than
/// a second allocator.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AddMemList`, `Allocate`, `CreatePool`
///
/// EXAMPLES:
/// ```zig
/// const mh = sys.CreateMemHeader(block_size, exec.MEMF_INTERNAL,
///     0, block, "scratch") orelse return;
/// ```
pub fn CreateMemHeader(_: *ExecBase, size: usize, attributes: u32, pri: i8, region: *anyopaque, name: ?[*:0]const u8) ?*MemHeader {
    const start = @intFromPtr(region);
    const header = _memory.alignUp(start, @alignOf(MemHeader));
    const lower = _memory.alignUp(header + @sizeOf(MemHeader), MEM_BLOCKSIZE);
    const upper = _memory.alignDown(start + size, MEM_BLOCKSIZE);
    if (upper < lower + MEM_BLOCKSIZE) return null;
    const bytes = _memory.fitsWord(upper - lower) orelse return null;

    const chunk: *MemChunk = @ptrFromInt(lower);
    chunk.* = .{ .next = null, .bytes = bytes };
    const mh: *MemHeader = @ptrFromInt(header);
    mh.* = .{
        .node = .{ .type = .memory, .pri = pri, .name = name },
        .attributes = @truncate(attributes),
        .first = chunk,
        .lower = @ptrFromInt(lower),
        .upper = @ptrFromInt(upper),
        .free = bytes,
    };
    return mh;
}

// --- tests (host: ./zig build test) -----------------------------------------

const testing = @import("std").testing;

test "CreateMemHeader: one free chunk on block bounds, too small is null" {
    const base: *ExecBase = undefined; // CreateMemHeader never reads it
    var buf: [1024]u8 align(16) = undefined;
    const mh = CreateMemHeader(base, buf.len - 3, sdk.exec.MEMF_INTERNAL, 5, @ptrCast(&buf[1]), "test").?;
    try testing.expect(@intFromPtr(mh) >= @intFromPtr(&buf[1]));
    try testing.expectEqual(@as(usize, 0), @intFromPtr(mh.lower) % MEM_BLOCKSIZE);
    try testing.expectEqual(@as(usize, 0), @intFromPtr(mh.upper) % MEM_BLOCKSIZE);
    try testing.expect(@intFromPtr(mh.upper) <= @intFromPtr(&buf[1]) + buf.len - 3);
    try testing.expectEqual(@as(i8, 5), mh.node.pri);
    try testing.expectEqual(@as(u32, sdk.exec.MEMF_INTERNAL), @as(u32, mh.attributes));
    try _memory.expectOneChunk(mh);

    try testing.expect(CreateMemHeader(base, @sizeOf(MemHeader), 0, 0, &buf, null) == null);
}
