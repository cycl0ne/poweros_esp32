// SPDX-License-Identifier: MPL-2.0
//! Memory regions and what is allocated from them. A region carries its
//! own MemHeader at its start; the free space behind it is a chain of
//! MemChunks, address-ordered and never adjacent - a free block is always
//! merged with its free neighbours, so an emptied region ends up as one
//! chunk again. SysBase's memory list holds the regions by priority, and
//! AllocMem takes the first that suits.
//!
//! `Allocate` and `Deallocate` take no lock: the region is the caller's and
//! so is keeping others away from it, which is what lets a pool cut up a
//! puddle with the same code. `AllocMem` and `FreeMem` are those two over
//! the system list, with Forbid around them.
//!
//!   base ────► ┌──────────────────────┐
//!              │ MemHeader            │  mh_Node (NT_MEMORY), mh_Attributes
//!              ├──────────────────────┤  mh_Lower = mh_First
//!              │ MemChunk: next, bytes│
//!              │ free ...             │
//!              └──────────────────────┘  mh_Upper
//!
//! Memory pools: many small blocks that are taken one at a time and given
//! back together.
//!
//! A pool owns **puddles** - stretches of memory it takes from the system
//! with AllocMem and then cuts up itself. The cutting is not new code: a
//! puddle carries a `MemHeader` over its own free space, and `Allocate` and
//! `Deallocate` work on it exactly as they work on one of the machine's
//! memory regions. So a pool is exec's allocator over a smaller arena, not
//! a second allocator to keep right.
//!
//!   puddle ──► ┌──────────────────────┐
//!              │ Puddle: node, bytes  │  on the pool's list
//!              ├──────────────────────┤
//!              │ MemHeader            │  the free space behind it,
//!              │ MemChunk: next, bytes│  in chunks, as a region is
//!              └──────────────────────┘
//!
//! **A pooled block carries no header of its own**, which is the whole
//! reason to have pools: `FreePooled` is told the size instead. A caller
//! that allocates 24-byte nodes in their thousands pays nothing per node,
//! where `AllocVec` would pay a whole block for the size word in front of
//! each.
//!
//! An ordinary puddle stays with the pool once taken, because a pool whose
//! puddles came and went would be back to one system allocation per node
//! whenever the population happened to fall to zero. `DeletePool` is how
//! the memory comes back, and for a pool whose whole point is that its
//! contents die together - a window's clip rectangles, a region's - that is
//! one call rather than a walk. A block at or above the pool's threshold is
//! the exception: it gets a puddle to itself and hands it straight back
//! when freed, since nothing else could use the space anyway.
//!
//! The calls, the pool calls and CopyMem, CopyMemQuick and SetMem are a
//! file each in this folder; this file is what they share: the arithmetic
//! on block bounds, the attribute mask a requirement is matched with,
//! `AllocVec`'s size word, the allocation trace, and the pool and puddle
//! a pool is made of.

const sdk = @import("sdk");
const exec = @import("../exec.zig");

const Node = sdk.exec.Node;
const List = sdk.exec.List;
const MemHeader = sdk.exec.MemHeader;
const MEM_BLOCKSIZE = sdk.exec.MEM_BLOCKSIZE;
const MEMF_INTERNAL = sdk.exec.MEMF_INTERNAL;
const MEMF_EXTERNAL = sdk.exec.MEMF_EXTERNAL;
const MEMF_DMA = sdk.exec.MEMF_DMA;

/// The MEMF_* bits that describe what a region *is*. The rest of the word
/// is allocation options - clear it, take it from the top, do not expunge -
/// which a region never carries, so this mask is what a requirement is
/// matched against.
pub const attribute_mask = MEMF_INTERNAL | MEMF_EXTERNAL | MEMF_DMA;

/// AllocVec's header in front of the memory. The whole block's size is in
/// its last word, right below the address AllocVec answers. It is a full
/// `MEM_BLOCKSIZE` rather than just the word, so that what AllocVec hands
/// back is aligned exactly as AllocMem's is.
pub const vec_header = MEM_BLOCKSIZE;

/// `value` rounded up to a multiple of `alignment`, a power of two.
///
/// INPUTS:
/// - `value` - the address or size to round. Rounding it up must not pass
///   the top of the address space.
/// - `alignment` - a power of two.
pub fn alignUp(value: usize, alignment: usize) usize {
    return alignDown(value + (alignment - 1), alignment);
}

/// `value` rounded down to a multiple of `alignment`, a power of two.
///
/// INPUTS:
/// - `value` - the address or size to round.
/// - `alignment` - a power of two.
pub fn alignDown(value: usize, alignment: usize) usize {
    return value & ~(alignment - 1);
}

/// `value` as a 32-bit word, or null when it does not fit - a chunk's size
/// and a region's free count are words.
///
/// INPUTS:
/// - `value` - the size to narrow.
pub fn fitsWord(value: usize) ?u32 {
    if (value > ~@as(u32, 0)) return null;
    return @intCast(value);
}

/// What the system has handed out and taken back since the counting
/// started, and whether each event is printed as well as counted.
///
/// It answers the question a memory figure before and after a program
/// cannot: not *how much* is gone but *what* took it. Sizes are what the
/// region gives up - the request rounded up to `MEM_BLOCKSIZE` - so
/// `outstanding` and the fall in what `Avail` reports are the same number.
///
/// A printed line is `A <size> <block> from <caller>` and `F` for the way
/// back, on the kernel's own serial line, where it cannot disturb the
/// console being measured. **The caller is exec's own jump-table wrapper
/// whenever the call came through the jump table**, which is every call a
/// module or a program makes; what tells those apart is the size and the
/// block, which is what a `FreeMem` that never comes is found by.
///
/// Off, it costs one test per allocation, which is why it can live here.
pub const Trace = struct {
    /// Whether anything is counted at all.
    on: bool = false,
    /// Whether every event is printed as well as counted.
    loud: bool = false,
    /// Events below this are counted but not printed, so that a run can be
    /// watched for the big blocks without the small ones burying them.
    min_size: usize = 0,
    allocs: u32 = 0,
    frees: u32 = 0,
    alloc_bytes: u64 align(4) = 0,
    free_bytes: u64 align(4) = 0,

    /// What went out and has not come back. Negative means more was freed
    /// than was taken, which is what a program that cleans up after an
    /// earlier one looks like.
    pub fn outstanding(t: *const Trace) i64 {
        return @as(i64, @intCast(t.alloc_bytes)) - @as(i64, @intCast(t.free_bytes));
    }

    /// Start counting, from nothing.
    pub fn start(t: *Trace, loud: bool) void {
        const min = t.min_size;
        t.* = .{ .on = true, .loud = loud, .min_size = min };
    }
};

/// The system's one trace. It is exec's own state rather than a module's,
/// like `SysBase` and the hardware hooks beside it.
pub var trace: Trace = .{};

/// Counts one event of the trace, and prints it when the trace is loud.
///
/// INPUTS:
/// - `letter` - 'A' for an allocation, 'F' for a free.
/// - `byte_size` - the size asked for; the region's rounded size is what is
///   counted.
/// - `block` - the block.
/// - `caller` - the return address of `AllocMem` or `FreeMem`.
pub fn traceEvent(letter: u8, byte_size: usize, block: ?*anyopaque, caller: usize) void {
    const size = alignUp(byte_size, MEM_BLOCKSIZE);
    if (letter == 'A') {
        trace.allocs += 1;
        trace.alloc_bytes += size;
    } else {
        trace.frees += 1;
        trace.free_bytes += size;
    }
    if (!trace.loud or size < trace.min_size) return;
    // An address on this machine is 32 bits; the host, where the tests
    // compile this, has wider ones, and %x takes a word.
    exec.kprintf("%c %ld %08x from %08x\n", .{
        letter,
        @as(u64, size),
        @as(u32, @truncate(@intFromPtr(block))),
        @as(u32, @truncate(caller)),
    });
}

// --- pools ------------------------------------------------------------------

/// One stretch of memory the pool has taken from the system.
pub const Puddle = struct {
    /// On the pool's list of them.
    node: Node = .{},
    /// What AllocMem was asked for, so FreeMem can be told the same.
    bytes: usize = 0,
    /// The free space in this puddle. It lives inside the puddle, behind
    /// this header.
    header: *MemHeader,
    /// Made for one block too big for an ordinary puddle, and freed with
    /// it.
    alone: bool = false,
};

/// What CreatePool hands back, seen from the inside.
pub const Pool = struct {
    /// Every puddle, newest first: the one most likely to have room is the
    /// one tried first.
    puddles: List = .{},
    /// What every puddle is taken with, less MEMF_CLEAR - a block is
    /// cleared as it is handed out, so clearing a whole puddle as well
    /// would be the same work twice.
    requirements: u32 = 0,
    /// Whether a block is cleared before it is handed out.
    clear: bool = false,
    /// What the pool asks the system for at a time. A puddle's own header
    /// comes out of this.
    puddle_size: usize = 0,
    /// A request this big or bigger gets a puddle to itself.
    thresh_size: usize = 0,
};

/// What a puddle spends before any of it can be handed out: this header,
/// the MemHeader behind it, and the alignment of each.
pub const puddle_overhead = @sizeOf(Puddle) + @sizeOf(MemHeader) + 2 * MEM_BLOCKSIZE;

// --- tests (host: ./zig build test) -----------------------------------------

const testing = @import("std").testing;

/// Asserts that a region's free chunks are sorted, aligned, inside the
/// region, never adjacent (a merge was missed) and add up to mh_Free. For the
/// tests in this folder.
pub fn expectConsistent(mh: *const MemHeader) !void {
    var total: usize = 0;
    var last_end: usize = 0;
    var chunk = mh.first;
    while (chunk) |free_chunk| : (chunk = free_chunk.next) {
        const addr = @intFromPtr(free_chunk);
        try testing.expect(addr % MEM_BLOCKSIZE == 0 and free_chunk.bytes % MEM_BLOCKSIZE == 0 and free_chunk.bytes > 0);
        try testing.expect(addr >= @intFromPtr(mh.lower) and addr + free_chunk.bytes <= @intFromPtr(mh.upper));
        try testing.expect(addr > last_end or last_end == 0);
        last_end = addr + free_chunk.bytes;
        total += free_chunk.bytes;
    }
    try testing.expectEqual(@as(usize, mh.free), total);
}

/// Asserts that a region is wholly free: one chunk from mh_Lower to
/// mh_Upper. For the tests in this folder.
pub fn expectOneChunk(mh: *const MemHeader) !void {
    try expectConsistent(mh);
    try testing.expect(mh.first != null and mh.first.?.next == null);
    try testing.expectEqual(@intFromPtr(mh.lower), @intFromPtr(mh.first.?));
    try testing.expectEqual(@intFromPtr(mh.upper) - @intFromPtr(mh.lower), @as(usize, mh.free));
}

test "alignUp, alignDown and fitsWord" {
    try testing.expectEqual(@as(usize, 16), alignUp(1, 16));
    try testing.expectEqual(@as(usize, 16), alignUp(16, 16));
    try testing.expectEqual(@as(usize, 0), alignUp(0, 16));
    try testing.expectEqual(@as(usize, 16), alignDown(31, 16));
    try testing.expectEqual(@as(?u32, 5), fitsWord(5));
    if (@sizeOf(usize) > 4) try testing.expect(fitsWord(@as(usize, 1) << 32) == null);
}
