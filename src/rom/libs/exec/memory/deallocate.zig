// SPDX-License-Identifier: MPL-2.0
//! Deallocate: gives a block back to one region. The free chain stays in
//! address order and a freed block is merged with a free neighbour on
//! either side, so an emptied region ends up as one chunk again.

const sdk = @import("sdk");
const _memory = @import("_memory.zig");

const ExecBase = @import("../exec.zig").ExecBase;
const MemChunk = sdk.exec.MemChunk;
const MemHeader = sdk.exec.MemHeader;
const MEM_BLOCKSIZE = sdk.exec.MEM_BLOCKSIZE;
const MEM_BLOCKMASK = sdk.exec.MEM_BLOCKMASK;
const Allocate = @import("allocate.zig").Allocate;
const CreateMemHeader = @import("creatememheader.zig").CreateMemHeader;

/// Gives a block back to the region it came from, merging it with its free
/// neighbours.
///
/// SYNOPSIS:
/// ```zig
/// fn Deallocate(_: *ExecBase, mh: *MemHeader, memory_block: ?*anyopaque,
///     byte_size: usize) void
/// ```
///
/// SINCE: 1.0. LVO -104.
///
/// INPUTS:
/// - `mh` - the region the block came from. The wrong region is fatal.
/// - `memory_block` - what `Allocate` answered, or null, which does
///   nothing.
/// - `byte_size` - the size that was allocated. 0 does nothing.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// The block is rounded out to `MEM_BLOCKSIZE`, put into the
/// address-ordered free chain and merged with a free chunk on either side,
/// so a region that is emptied ends up with one chunk again rather than a
/// chain of the pieces it was cut into.
///
/// Two things are fatal rather than ignored, because both mean memory is
/// already being handed to two owners and carrying on would hide that until
/// somewhere else:
///
/// **Outside the region.** The block is not between the region's bounds.
///
/// **Freed twice.** The block overlaps free memory - a chunk below it
/// reaches into it, or the chunk above starts before its end.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: only on a region the interrupt owns outright.
/// - Forbid: not taken here. The caller's, as with `Allocate`.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The memory is the region's again and must not be touched.
///
/// NOTES:
/// A block outside the region, or one that overlaps free memory, stops the
/// machine: either is a caller that has lost track of its memory, and
/// carrying on would hand the same bytes out twice.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `Allocate`, `FreeMem`
///
/// EXAMPLES:
/// ```zig
/// sys.Deallocate(mh, block, 256);
/// ```
pub fn Deallocate(_: *ExecBase, mh: *MemHeader, memory_block: ?*anyopaque, byte_size: usize) void {
    const block = memory_block orelse return;
    if (byte_size == 0) return;
    const start = @intFromPtr(block) & ~@as(usize, MEM_BLOCKMASK);
    const end = _memory.alignUp(@intFromPtr(block) + byte_size, MEM_BLOCKSIZE);
    if (start < @intFromPtr(mh.lower) or end > @intFromPtr(mh.upper)) {
        @panic("Deallocate: block is not inside this MemHeader");
    }

    // Free chunks around the block: prev below it, next at or above it.
    var prev: ?*MemChunk = null;
    var next = mh.first;
    while (next) |n| {
        if (@intFromPtr(n) >= start) break;
        prev = n;
        next = n.next;
    }
    if (prev) |p| {
        if (@intFromPtr(p) + p.bytes > start) @panic("Deallocate: memory freed twice");
    }
    if (next) |n| {
        if (@intFromPtr(n) < end) @panic("Deallocate: memory freed twice");
    }

    const chunk: *MemChunk = @ptrFromInt(start);
    chunk.* = .{ .next = next, .bytes = @intCast(end - start) };
    mh.free += chunk.bytes;
    if (next) |n| {
        if (@intFromPtr(n) == end) {
            chunk.bytes += n.bytes;
            chunk.next = n.next;
        }
    }
    if (prev) |p| {
        if (@intFromPtr(p) + p.bytes == start) {
            p.bytes += chunk.bytes;
            p.next = chunk.next;
        } else {
            p.next = chunk;
        }
    } else {
        mh.first = chunk;
    }
}

// --- tests (host: ./zig build test) -----------------------------------------

const std = @import("std");
const testing = std.testing;

test "random Allocate/Deallocate keeps the chunk list consistent" {
    const base: *ExecBase = undefined; // the region calls never read it
    var buf: [32 * 1024]u8 align(16) = undefined;
    const mh = CreateMemHeader(base, buf.len, sdk.exec.MEMF_ANY, 0, &buf, "stress").?;

    var prng = std.Random.DefaultPrng.init(7);
    const random = prng.random();
    var live: [48]?[]u8 = @splat(null);
    for (0..4000) |_| {
        const slot = random.uintLessThan(usize, live.len);
        if (live[slot]) |block| {
            try testing.expect(std.mem.allEqual(u8, block, @intCast(slot)));
            Deallocate(base, mh, block.ptr, block.len);
            live[slot] = null;
        } else {
            const len = random.intRangeAtMost(usize, 1, 1500);
            const bytes: [*]u8 = @ptrCast(Allocate(base, mh, len) orelse continue);
            @memset(bytes[0..len], @intCast(slot));
            live[slot] = bytes[0..len];
        }
        try _memory.expectConsistent(mh);
    }
    for (&live, 0..) |*entry, slot| {
        if (entry.*) |block| {
            try testing.expect(std.mem.allEqual(u8, block, @intCast(slot)));
            Deallocate(base, mh, block.ptr, block.len);
        }
    }
    try _memory.expectOneChunk(mh);
}
