// SPDX-License-Identifier: MIT
//! Memory (exec/memory.h): the MEMF_* attributes and requirements, memory
//! headers and memory handlers. A memory region carries its own MemHeader
//! at its start; the free space behind it is a chain of MemChunks, and
//! every block AllocMem has handed out from it starts with a MemBlock:
//! who owns the block, its size, whether it is private.
//!
//!   base ────► ┌──────────────────────┐
//!              │ MemHeader            │  mh_Node (NT_MEMORY), mh_Attributes
//!              ├──────────────────────┤  mh_Lower
//!              │ MemBlock: owner, size│  a block: what AllocMem answered
//!              │ the block ...        │  is the address past its MemBlock
//!              ├──────────────────────┤
//!              │ MemChunk: next, bytes│  free space (mh_First)
//!              │ free ...             │
//!              └──────────────────────┘  mh_Upper
//!
//! Block and free chunk follow one another without a gap, so a region can
//! be walked from mh_Lower to mh_Upper (`RegionWalk`): what is not on the
//! free chain is a block, and its MemBlock says how far it goes.

const std = @import("std");
const Node = @import("nodes.zig").Node;

/// Memory attributes and AllocMem requirements (MEMF_*).
///
/// Bits 0-15 describe memory. Bits 1, 2 and 9 say what a region is and are
/// matched against MemHeader.attributes, which is 16 bits wide; bit 0 says
/// what a block is for (MEMF_PRIVATE) and is kept in the block's MemBlock.
/// Bits 16 and up are options for the one call.
///
/// Bits 8 and 10 are left unassigned: they held attributes that said
/// nothing about this machine, and a program built before they went keeps
/// allocating because a bit no region carries is simply not matched.
pub const MEMF_ANY: u32 = 0;
/// The block is its owner's alone: nothing in it is put in a message or an
/// IORequest, or handed to a library or another task. Without it a block is
/// shared, which suits anything. AllocMem keeps it in the block's MemBlock,
/// where the system's tools show it; no access is checked against it. A
/// private block its owner has not freed is freed when the owner ends
/// (`RemTask`) - which is why nothing else may hold on to it.
pub const MEMF_PRIVATE: u32 = 1 << 0;
/// Internal SRAM: no cache in the path, so it can be read and written while
/// the caches are suspended.
pub const MEMF_INTERNAL: u32 = 1 << 1;
/// PSRAM behind the data cache: the bulk of the memory, slower than internal
/// SRAM, and unusable while the caches are off.
pub const MEMF_EXTERNAL: u32 = 1 << 2;
/// A DMA engine addresses this memory directly: a descriptor chain may live
/// here, and a buffer in it needs no cache maintenance.
pub const MEMF_DMA: u32 = 1 << 9;
pub const MEMF_CLEAR: u32 = 1 << 16;
pub const MEMF_LARGEST: u32 = 1 << 17;
pub const MEMF_REVERSE: u32 = 1 << 18;
pub const MEMF_TOTAL: u32 = 1 << 19;
/// The block is the system's rather than the calling task's: what a
/// library, device or handler allocates for itself, which outlives the call
/// it was made in - its base, a cache, a node it keeps. Without it a block
/// belongs to the task that allocated it, which is the caller even inside
/// library code. (`BeginSystemMemory` makes every allocation of a stretch
/// of code the system's.)
pub const MEMF_SYSTEM: u32 = 1 << 20;
pub const MEMF_NO_EXPUNGE: u32 = 1 << 31;

/// struct MemChunk: a free block inside a MemHeader's region.
pub const MemChunk = extern struct {
    /// mc_Next: the next free chunk, in address order.
    next: ?*MemChunk = null,
    /// mc_Bytes: size of this free chunk.
    bytes: u32 = 0,
};

/// Allocation granularity: every chunk is a multiple of this and aligned to
/// it, so a free chunk always has room for its own MemChunk.
pub const MEM_BLOCKSIZE = @sizeOf(MemChunk);
pub const MEM_BLOCKMASK = MEM_BLOCKSIZE - 1;

/// The owner of a block that is no task's: the system's (MEMF_SYSTEM), and
/// what exec's own tasks allocate. A task's own number is never this.
pub const MEMOWNER_SYSTEM: u32 = 0;

/// In MemBlock.size, below the size: the block is private (MEMF_PRIVATE).
pub const MEMBF_PRIVATE: u32 = MEMF_PRIVATE;
/// In MemBlock.size, below the size: the block is handed out. FreeMem
/// takes it away as the block goes, so a block freed twice is told from one
/// in use.
pub const MEMBF_INUSE: u32 = 1 << 1;
/// In MemBlock.size, below the size: a wall of MEM_WALLSIZE bytes follows
/// the block - it was allocated while memory debugging was on (`s3>
/// memdebug`), and FreeMem checks that nothing ran past its end.
pub const MEMBF_WALLED: u32 = 1 << 2;

/// The wall behind a block allocated while memory debugging is on. Its
/// first word holds the size that was asked for, as `size ^
/// MEM_PATTERN_WALL`; the rest of it, and the block's bytes between that
/// size and the rounded one, hold MEM_PATTERN_WALL.
pub const MEM_WALLSIZE = 2 * MEM_BLOCKSIZE;
/// What a wall holds, word by word (its bytes are all 0xFD).
pub const MEM_PATTERN_WALL: u32 = 0xFDFD_FDFD;
/// What a block allocated while memory debugging is on holds before it is
/// written, unless MEMF_CLEAR asked for zeros: read as a pointer or a
/// count, it is plainly wrong.
pub const MEM_PATTERN_NEW: u32 = 0xABAD_CAFE;
/// What freed memory holds while memory debugging is on, behind each free
/// chunk's MemChunk: what reads it after the free gets this, and what
/// writes it is found when the memory is handed out again.
pub const MEM_PATTERN_FREED: u32 = 0xDEAD_BEEF;

/// MemDebug's actions: only tell the state, switch memory debugging on or
/// off, or check every wall and all free memory now.
pub const MEMDEBUG_ASK: u32 = 0;
pub const MEMDEBUG_ON: u32 = 1;
pub const MEMDEBUG_OFF: u32 = 2;
pub const MEMDEBUG_CHECK: u32 = 3;

/// Where memory debugging stands, as MemDebug tells it - and as exec keeps
/// it. The counts start over each time the mode is switched on.
pub const MemDebugInfo = extern struct {
    /// Whether it is on: new blocks walled, freed memory filled.
    on: bool = false,
    /// Walls FreeMem found written over.
    walls: u32 = 0,
    /// Free memory AllocMem found written after it was freed.
    freed_writes: u32 = 0,
};

/// MemDamage.kind: a walled block written past its end.
pub const MEMDAMAGE_WALL: u8 = 0;
/// MemDamage.kind: free memory written after its free.
pub const MEMDAMAGE_FREED: u8 = 1;
/// MemDamage.kind: a region whose blocks no longer chain - a MemBlock or a
/// MemChunk written over; the walk of that region stopped here.
pub const MEMDAMAGE_CHAIN: u8 = 2;

/// One thing MemDebug's MEMDEBUG_CHECK found wrong.
pub const MemDamage = extern struct {
    /// The first byte found wrong.
    at: usize = 0,
    /// The block's owner for MEMDAMAGE_WALL; MEMOWNER_SYSTEM otherwise.
    owner: u32 = MEMOWNER_SYSTEM,
    /// MEMDAMAGE_*: what is wrong there.
    kind: u8 = MEMDAMAGE_WALL,
};

/// What is in front of every block AllocMem answers, one MEM_BLOCKSIZE
/// long: the block's owner, its size and its MEMBF_* flags. The size is
/// in the word right below the block on every chip; on a 64-bit one the
/// first half of the MemBlock is padding.
pub const MemBlock = extern struct {
    pad: [MEM_BLOCKSIZE - 8]u8 = @splat(0),
    /// A task's number (`Task.id`), or MEMOWNER_SYSTEM.
    owner: u32 = MEMOWNER_SYSTEM,
    /// The block's bytes, rounded up to MEM_BLOCKSIZE and without the
    /// MemBlock, with MEMBF_* in the bits below MEM_BLOCKSIZE.
    size: u32 = 0,

    /// The MemBlock of a block AllocMem answered.
    pub fn of(block: *anyopaque) *MemBlock {
        return @ptrFromInt(@intFromPtr(block) - MEM_BLOCKSIZE);
    }

    /// The block's bytes, without the MemBlock.
    pub fn bytes(header: *const MemBlock) usize {
        return header.size & ~@as(u32, MEM_BLOCKMASK);
    }

    pub fn private(header: *const MemBlock) bool {
        return header.size & MEMBF_PRIVATE != 0;
    }

    pub fn inUse(header: *const MemBlock) bool {
        return header.size & MEMBF_INUSE != 0;
    }

    pub fn walled(header: *const MemBlock) bool {
        return header.size & MEMBF_WALLED != 0;
    }

    /// What follows the MemBlock in the region: the block, and its wall
    /// when it has one.
    pub fn extent(header: *const MemBlock) usize {
        return header.bytes() + if (header.walled()) @as(usize, MEM_WALLSIZE) else 0;
    }

    /// Where a walled block was written past its end: the offset, from the
    /// block's start, of the first byte past the size asked for that does
    /// not hold the wall's pattern - or null when the wall is whole, and
    /// for a block without one. A wall whose first word no longer gives a
    /// size that rounds up to the block's is damaged at that word.
    pub fn wallDamage(header: *const MemBlock) ?usize {
        if (!header.walled()) return null;
        const block: [*]const u8 = @ptrFromInt(@intFromPtr(header) + MEM_BLOCKSIZE);
        const rounded = header.bytes();
        const wall: [*]align(4) const u8 = @alignCast(block + rounded);
        const first: *const u32 = @ptrCast(wall);
        const wanted = first.* ^ MEM_PATTERN_WALL;
        if (wanted > rounded or wanted + MEM_BLOCKSIZE <= rounded) return rounded;
        for (wanted..rounded) |at| {
            if (block[at] != @as(u8, @truncate(MEM_PATTERN_WALL))) return at;
        }
        for (4..MEM_WALLSIZE) |at| {
            if (wall[at] != @as(u8, @truncate(MEM_PATTERN_WALL))) return rounded + at;
        }
        return null;
    }

    /// The size a walled block was asked for, from its wall; the rounded
    /// size for one without a wall.
    pub fn askedSize(header: *const MemBlock) usize {
        if (!header.walled()) return header.bytes();
        const first: *const u32 = @ptrFromInt(@intFromPtr(header) + MEM_BLOCKSIZE + header.bytes());
        return first.* ^ MEM_PATTERN_WALL;
    }
};

comptime {
    if (@sizeOf(MemBlock) != MEM_BLOCKSIZE) @compileError("a MemBlock is one MEM_BLOCKSIZE");
}

/// One stretch of a region as `RegionWalk` finds it: a block someone holds,
/// or free space.
pub const Stretch = struct {
    /// Where it starts: a block's MemBlock, or a free chunk.
    start: usize,
    /// How long it is, a block's MemBlock included.
    bytes: usize,
    /// Free space rather than a block.
    free: bool,
    /// A block's owner (MemBlock.owner).
    owner: u32 = MEMOWNER_SYSTEM,
    /// A block's MEMF_PRIVATE.
    private: bool = false,
    /// A block with a wall behind it (`MemBlock.walled`).
    walled: bool = false,
};

/// The blocks and the free space of one region, in address order, read
/// from their MemBlocks and MemChunks.
///
/// Only with the region held still: exec's memory list locked
/// (`LockExecList(EXECLIST_MEMORY)`), which a spinlock does - so the walk
/// waits for nothing and allocates nothing, and copies out what it wants
/// to print after `UnlockExecList`. It reads no more than it walks, so a
/// walk that stops early is as short as that.
///
/// A place that is neither free space nor the start of a block in use -
/// a MemBlock overwritten, by a block below running past its end, or a
/// free chain out of order - ends the walk there, with `damaged` set to
/// it.
pub const RegionWalk = struct {
    region: *const MemHeader,
    at: usize,
    free: ?*const MemChunk,
    /// Where the walk met something that is neither, or null.
    damaged: ?usize = null,

    pub fn init(region: *const MemHeader) RegionWalk {
        return .{ .region = region, .at = @intFromPtr(region.lower), .free = region.first };
    }

    /// The next stretch, or null at the region's end and where it is
    /// damaged.
    pub fn next(walk: *RegionWalk) ?Stretch {
        const upper = @intFromPtr(walk.region.upper);
        if (walk.damaged != null or walk.at >= upper) return null;
        var limit = upper;
        if (walk.free) |chunk| {
            const chunk_at = @intFromPtr(chunk);
            if (chunk_at == walk.at) {
                if (chunk.bytes == 0 or chunk_at + chunk.bytes > upper) return walk.fail();
                walk.free = chunk.next;
                walk.at += chunk.bytes;
                return .{ .start = chunk_at, .bytes = chunk.bytes, .free = true };
            }
            if (chunk_at < walk.at) return walk.fail();
            limit = chunk_at;
        }
        if (walk.at + MEM_BLOCKSIZE > limit) return walk.fail();
        const header: *const MemBlock = @ptrFromInt(walk.at);
        const whole = header.extent() + MEM_BLOCKSIZE;
        if (!header.inUse() or header.bytes() == 0 or whole > limit - walk.at) return walk.fail();
        const start = walk.at;
        walk.at += whole;
        return .{ .start = start, .bytes = whole, .free = false, .owner = header.owner, .private = header.private(), .walled = header.walled() };
    }

    fn fail(walk: *RegionWalk) ?Stretch {
        walk.damaged = walk.at;
        return null;
    }
};

/// struct MemHeader.
pub const MemHeader = extern struct {
    /// mh_Node: ln_Type NT_MEMORY, ln_Pri, ln_Name.
    node: Node = .{ .type = .memory },
    /// mh_Attributes: MEMF_* flags describing this region.
    attributes: u16 = 0,
    /// mh_First: first free chunk.
    first: ?*MemChunk = null,
    /// mh_Lower: lowest address the chunks can cover.
    lower: ?*anyopaque = null,
    /// mh_Upper: one past the highest address the chunks can cover.
    upper: ?*anyopaque = null,
    /// mh_Free: total free bytes.
    free: u32 = 0,

    pub fn name(mh: *const MemHeader) [:0]const u8 {
        return std.mem.span(mh.node.name orelse return "");
    }
};

/// struct MemHandlerData: what a memory handler is told about the failed
/// allocation.
pub const MemHandlerData = extern struct {
    /// memh_RequestSize
    request_size: u32,
    /// memh_RequestFlags: the AllocMem requirements.
    request_flags: u32,
    /// memh_Flags: MEMHF_RECYCLE when the same handler is called again.
    flags: u32,
};

pub const MEMHF_RECYCLE: u32 = 1 << 0;

/// Memory handler results.
pub const MEM_DID_NOTHING: i32 = 0;
/// Freed memory and can't free more: retry, then go on to the next handler.
pub const MEM_ALL_DONE: i32 = -1;
/// Freed memory and could free more: retry, and if that fails, call this
/// handler again with MEMHF_RECYCLE.
pub const MEM_TRY_AGAIN: i32 = 1;

/// is_Code of a memory handler; `is_data` is the Interrupt's is_Data.
pub const MemHandlerFn = *const fn (data: *const MemHandlerData, is_data: ?*anyopaque) callconv(.c) i32;
