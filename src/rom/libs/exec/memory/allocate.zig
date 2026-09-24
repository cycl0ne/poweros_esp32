// SPDX-License-Identifier: MPL-2.0
//! Allocate: cuts a block from one region, first fit. It takes no lock -
//! the region is the caller's and so is keeping others away from it, which
//! is what lets a pool cut up a puddle with the same code.

const sdk = @import("sdk");
const _memory = @import("_memory.zig");

const ExecBase = @import("../exec.zig").ExecBase;
const MemChunk = sdk.exec.MemChunk;
const MemHeader = sdk.exec.MemHeader;
const MEM_BLOCKSIZE = sdk.exec.MEM_BLOCKSIZE;
const CreateMemHeader = @import("creatememheader.zig").CreateMemHeader;
const Deallocate = @import("deallocate.zig").Deallocate;

/// Takes a block from one memory region, with no locking of any kind.
///
/// SYNOPSIS:
/// ```zig
/// fn Allocate(_: *ExecBase, mh: *MemHeader, byte_size: usize) ?*anyopaque
/// ```
///
/// SINCE: 1.0. LVO -100.
///
/// INPUTS:
/// - `mh` - the region to take from. The caller's, or one on the system
///   list with the caller holding Forbid.
/// - `byte_size` - bytes wanted. Rounded up to `MEM_BLOCKSIZE`, so the
///   block that is actually spent may be larger than what was asked for.
///
/// RESULT:
/// The block, `MEM_BLOCKSIZE`-aligned, or null: 0 bytes, or no free chunk
/// is big enough. The memory is **not** cleared.
///
/// BEHAVIOR:
/// First fit: the first free chunk that is big enough, and the block comes
/// off its start. What is left over stays a chunk in the chain.
///
/// It takes no Forbid, on purpose. Keeping others away from `mh` is the
/// caller's job, which is what lets a pool use the same code on a puddle
/// nobody else can see - and what makes it the wrong call to reach for on a
/// system region.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: only on a region the interrupt owns outright. On anything
///   a task may be allocating from, no.
/// - Forbid: not taken here. The caller's, and needed for any region on the
///   system list.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The caller's until `Deallocate` on the same region, with the same size.
///
/// NOTES:
/// `byte_size` must be handed back to `Deallocate` unchanged: the block
/// carries no header saying how big it is, which is the whole reason a
/// pooled block costs no more than its own bytes.
///
/// The block comes off the chunk's start, and what is left of the chunk
/// stays where it was on the chain, so the chain stays in address order
/// without being walked again.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `Deallocate`, `AllocMem`, `AllocPooled`
///
/// EXAMPLES:
/// ```zig
/// const block = sys.Allocate(mh, 256) orelse return;
/// defer sys.Deallocate(mh, block, 256);
/// ```
pub fn Allocate(_: *ExecBase, mh: *MemHeader, byte_size: usize) ?*anyopaque {
    if (byte_size == 0 or byte_size > mh.free) return null;
    const size: u32 = @intCast(_memory.alignUp(byte_size, MEM_BLOCKSIZE));

    var link: *?*MemChunk = &mh.first;
    while (link.*) |chunk| : (link = &chunk.next) {
        if (chunk.bytes < size) continue;
        if (chunk.bytes == size) {
            link.* = chunk.next;
        } else {
            const rest: *MemChunk = @ptrFromInt(@intFromPtr(chunk) + size);
            rest.* = .{ .next = chunk.next, .bytes = chunk.bytes - size };
            link.* = rest;
        }
        mh.free -= size;
        return chunk;
    }
    return null;
}

// --- tests (host: ./zig build test) -----------------------------------------

const std = @import("std");
const testing = std.testing;

test "Allocate takes from the first fitting chunk, Deallocate merges back" {
    const base: *ExecBase = undefined; // the region calls never read it
    var buf: [1024]u8 align(16) = undefined;
    const mh = CreateMemHeader(base, buf.len, sdk.exec.MEMF_ANY, 0, &buf, "test").?;
    const total = mh.free;

    try testing.expect(Allocate(base, mh, 0) == null);
    try testing.expect(Allocate(base, mh, total + 1) == null);

    const a = Allocate(base, mh, 1).?; // rounded up to one block
    const b = Allocate(base, mh, 3 * MEM_BLOCKSIZE).?;
    const c = Allocate(base, mh, 100).?;
    try testing.expectEqual(@intFromPtr(mh.lower), @intFromPtr(a));
    try testing.expectEqual(@intFromPtr(a) + MEM_BLOCKSIZE, @intFromPtr(b));
    try testing.expectEqual(@intFromPtr(b) + 3 * MEM_BLOCKSIZE, @intFromPtr(c));
    const c_size = std.mem.alignForward(usize, 100, MEM_BLOCKSIZE);
    try testing.expectEqual(total - MEM_BLOCKSIZE - 3 * MEM_BLOCKSIZE - c_size, mh.free);
    try _memory.expectConsistent(mh);

    // A hole in front: the next small allocation reuses it (first fit).
    Deallocate(base, mh, b, 3 * MEM_BLOCKSIZE);
    try _memory.expectConsistent(mh);
    try testing.expectEqual(@intFromPtr(b), @intFromPtr(Allocate(base, mh, 2 * MEM_BLOCKSIZE).?));
    Deallocate(base, mh, b, 2 * MEM_BLOCKSIZE);

    Deallocate(base, mh, c, 100);
    Deallocate(base, mh, null, 8);
    Deallocate(base, mh, a, 1);
    try _memory.expectOneChunk(mh);

    // The whole region in one piece, then nothing is left.
    const all = Allocate(base, mh, total).?;
    try testing.expect(mh.first == null and mh.free == 0);
    try testing.expect(Allocate(base, mh, 1) == null);
    Deallocate(base, mh, all, total);
    try _memory.expectOneChunk(mh);
}
