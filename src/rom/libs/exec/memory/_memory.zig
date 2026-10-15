// SPDX-License-Identifier: MPL-2.0
//! Memory regions and what is allocated from them. A region carries its
//! own MemHeader at its start; the free space behind it is a chain of
//! MemChunks, address-ordered and never adjacent - a free block is always
//! merged with its free neighbours, so an emptied region ends up as one
//! chunk again. SysBase's memory list holds the regions by priority, and
//! AllocMem takes the first that suits.
//!
//! **Every block AllocMem hands out carries a MemBlock in front**, one
//! MEM_BLOCKSIZE: the task that owns it (its number, `Task.id`, or the
//! system's), its size, and whether it is private. AllocMem writes it under
//! the memory lock, with the block cut from the region, so a region read
//! under that lock is always whole: free chunks and blocks, one after the
//! other (`sdk.exec.RegionWalk`). FreeMem reads it back and refuses a block
//! not in use or a size not the block's. The owner is the calling task -
//! inside library code too, which runs on its caller - unless the call
//! asks for MEMF_SYSTEM or the task is inside `BeginSystemMemory`; exec's
//! own tasks have the system's number. `AllocVec` is AllocMem: the size it
//! remembers is the MemBlock's.
//!
//! `Allocate` and `Deallocate` take no lock: the region is the caller's and
//! so is keeping others away from it, which is what lets a pool cut up a
//! puddle with the same code. `AllocMem` and `FreeMem` are those two over
//! the system list, under exec's memory lock; a pool's are under the
//! pool's own lock.
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
const ExecBase = exec.ExecBase;

const Node = sdk.exec.Node;
const List = sdk.exec.List;
const MemHeader = sdk.exec.MemHeader;
const MemBlock = sdk.exec.MemBlock;
const MEM_BLOCKSIZE = sdk.exec.MEM_BLOCKSIZE;
const MEMF_INTERNAL = sdk.exec.MEMF_INTERNAL;
const MEMF_EXTERNAL = sdk.exec.MEMF_EXTERNAL;
const MEMF_DMA = sdk.exec.MEMF_DMA;

/// The MEMF_* bits that describe what a region *is*. The rest of the word
/// is allocation options - clear it, take it from the top, do not expunge -
/// which a region never carries, so this mask is what a requirement is
/// matched against.
pub const attribute_mask = MEMF_INTERNAL | MEMF_EXTERNAL | MEMF_DMA;

/// What a block of `byte_size` takes from its region: the size rounded up
/// to MEM_BLOCKSIZE, its MemBlock, and its wall when it has one. Null when
/// that does not fit a word.
///
/// INPUTS:
/// - `byte_size` - what was asked for.
/// - `walled` - whether the block gets a wall (memory debugging is on).
pub fn wholeSize(byte_size: usize, walled: bool) ?usize {
    const rounded = @addWithOverflow(byte_size, MEM_BLOCKSIZE - 1);
    if (rounded[1] != 0) return null;
    const extra: usize = MEM_BLOCKSIZE + if (walled) @as(usize, sdk.exec.MEM_WALLSIZE) else 0;
    const whole = @addWithOverflow(alignDown(rounded[0], MEM_BLOCKSIZE), extra);
    if (whole[1] != 0) return null;
    _ = fitsWord(whole[0]) orelse return null;
    return whole[0];
}

/// The owner a block allocated now is marked with: the system's for
/// MEMF_SYSTEM, before there is a task at all, and while the task is
/// inside `BeginSystemMemory`; otherwise the running task's number.
///
/// INPUTS:
/// - `base` - exec: the boot task, and FindTask through the table.
/// - `requirements` - the MEMF_* word of the call.
pub fn ownerFor(base: *ExecBase, requirements: u32) u32 {
    if (requirements & sdk.exec.MEMF_SYSTEM != 0) return sdk.exec.MEMOWNER_SYSTEM;
    // The boot task is the first thing allocated: before it, nothing runs
    // that could own a block.
    if (base.boot_task == null) return sdk.exec.MEMOWNER_SYSTEM;
    const task = base.iface().FindTask(null) orelse return sdk.exec.MEMOWNER_SYSTEM;
    if (task.system_memory_nest != 0) return sdk.exec.MEMOWNER_SYSTEM;
    return task.id;
}

/// A chunk just cut from a region made a block: its MemBlock written, the
/// address past it answered. Under the memory lock, as the cut was. The
/// wall, for a walled block, is the caller's to write once the lock is
/// let go (`debugNew`): until then the region reads as whole all the same.
///
/// INPUTS:
/// - `chunk` - what `Allocate` answered for `wholeSize`.
/// - `whole` - that size.
/// - `owner` - from `ownerFor`.
/// - `requirements` - the call's MEMF_* word: MEMF_PRIVATE is kept.
/// - `walled` - whether `whole` has room for a wall.
pub fn markBlock(chunk: *anyopaque, whole: usize, owner: u32, requirements: u32, walled: bool) *anyopaque {
    const header: *MemBlock = @ptrCast(@alignCast(chunk));
    const wall: usize = if (walled) sdk.exec.MEM_WALLSIZE else 0;
    const size: u32 = @intCast(whole - MEM_BLOCKSIZE - wall);
    header.* = .{
        .owner = owner,
        .size = size | sdk.exec.MEMBF_INUSE | (requirements & sdk.exec.MEMBF_PRIVATE) |
            if (walled) sdk.exec.MEMBF_WALLED else 0,
    };
    return @ptrFromInt(@intFromPtr(chunk) + MEM_BLOCKSIZE);
}

/// Gives a block another owner. One aligned word written, so a walk under
/// the memory lock reads the old owner or the new one and never half of
/// either; the caller holds the block, so nothing frees it meanwhile.
///
/// INPUTS:
/// - `block` - what AllocMem answered.
/// - `owner` - a task's number or MEMOWNER_SYSTEM.
pub fn setOwner(block: *anyopaque, owner: u32) void {
    const word: *volatile u32 = &MemBlock.of(block).owner;
    word.* = owner;
}

/// The region on exec's memory list that holds `address`, or null. Under
/// the memory lock.
///
/// INPUTS:
/// - `base` - exec: its memory list.
/// - `address` - any address in a block.
pub fn regionOf(base: *ExecBase, address: usize) ?*MemHeader {
    var it = base.mem_list.iterator();
    while (it.next()) |node| {
        const mh: *MemHeader = @fieldParentPtr("node", node);
        if (address >= @intFromPtr(mh.lower) and address < @intFromPtr(mh.upper)) return mh;
    }
    return null;
}

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
/// region gives up - the request rounded up to `MEM_BLOCKSIZE`, and the
/// block's MemBlock - so `outstanding` and the fall in what `Avail` reports
/// are the same number.
///
/// A printed line is `A <size> <block> from <caller>` and `F` for the way
/// back, on the kernel's own serial line, where it cannot disturb the
/// console being measured. **The caller is exec's own jump-table wrapper
/// whenever the call came through the jump table**, which is every call a
/// module or a program makes; what tells those apart is the size and the
/// block, which is what a `FreeMem` that never comes is found by.
///
/// Off, it costs one test per allocation, which is why it can live here.
pub const Trace = extern struct {
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

/// Counts one event of the trace, and prints it when the trace is loud.
///
/// INPUTS:
/// - `base` - exec: the trace, in its base.
/// - `letter` - 'A' for an allocation, 'F' for a free.
/// - `size` - what the region gives up or takes back (`wholeSize`).
/// - `block` - the block.
/// - `caller` - the return address of `AllocMem` or `FreeMem`.
pub fn traceEvent(base: *ExecBase, letter: u8, size: usize, block: ?*anyopaque, caller: usize) void {
    const trace = &base.mem_trace;
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

// --- memory debugging (s3> memdebug) -----------------------------------------
//
// While it is on, every block allocated gets a wall behind it, holding the
// size asked for and a pattern from there on; what was not cleared holds
// MEM_PATTERN_NEW; and every free chunk holds MEM_PATTERN_FREED behind its
// MemChunk. FreeMem checks the wall, and AllocMem checks that the free
// memory it hands out still holds the pattern - what wrote it, wrote memory
// after it was freed. Blocks keep their wall whether the mode stays on or
// not; the free memory's pattern is made whole each time it is switched on.

/// What memory debugging has found since it was last switched on.
pub const Debug = extern struct {
    /// Whether it is on: new blocks walled, freed memory filled.
    on: bool = false,
    /// Walls FreeMem found written over.
    walls: u32 = 0,
    /// Free memory AllocMem found written after it was freed.
    freed_writes: u32 = 0,
};

/// `bytes` bytes from `at`, a multiple of 4, set to `pattern` a word at a
/// time.
fn fill(at: usize, bytes: usize, pattern: u32) void {
    const words: [*]u32 = @ptrFromInt(at);
    for (0..bytes / 4) |index| words[index] = pattern;
}

/// The offset of the first word of the `bytes` from `at` that is not
/// `pattern`, or null.
fn firstNot(at: usize, bytes: usize, pattern: u32) ?usize {
    const words: [*]const u32 = @ptrFromInt(at);
    for (0..bytes / 4) |index| {
        if (words[index] != pattern) return index * 4;
    }
    return null;
}

/// Memory debugging switched on: every free chunk's memory behind its
/// MemChunk filled with MEM_PATTERN_FREED, under the memory lock, and new
/// blocks walled from here.
///
/// INPUTS:
/// - `base` - exec: its regions, its lock and the debugging state.
pub fn debugOn(base: *ExecBase) void {
    const sys = base.iface();
    sys.AcquireLock(&base.lock_memory);
    defer sys.ReleaseLock(&base.lock_memory);
    var it = base.mem_list.iterator();
    while (it.next()) |node| {
        const mh: *MemHeader = @fieldParentPtr("node", node);
        var chunk = mh.first;
        while (chunk) |free_chunk| : (chunk = free_chunk.next) {
            fill(@intFromPtr(free_chunk) + MEM_BLOCKSIZE, free_chunk.bytes - MEM_BLOCKSIZE, sdk.exec.MEM_PATTERN_FREED);
        }
    }
    base.mem_debug = .{ .on = true };
}

/// A walled block made ready: the free memory it came from checked for
/// writes after its free, the block filled - zeros for MEMF_CLEAR,
/// MEM_PATTERN_NEW otherwise - and its wall written. Outside the memory
/// lock: the block is the caller's already.
///
/// INPUTS:
/// - `base` - exec: the debugging counts.
/// - `block` - what AllocMem is about to answer.
/// - `byte_size` - what was asked for.
/// - `requirements` - the call's MEMF_* word.
pub fn debugNew(base: *ExecBase, block: *anyopaque, byte_size: usize, requirements: u32) void {
    const header = MemBlock.of(block);
    const at = @intFromPtr(block);
    const rounded = header.bytes();
    if (firstNot(at, rounded + sdk.exec.MEM_WALLSIZE, sdk.exec.MEM_PATTERN_FREED)) |offset| {
        base.mem_debug.freed_writes +%= 1;
        exec.kprintf("memdebug: free memory at %08x was written after it was freed\n", .{@as(u32, @truncate(at + offset))});
    }
    const bytes: [*]u8 = @ptrCast(block);
    if (requirements & sdk.exec.MEMF_CLEAR != 0) {
        @memset(bytes[0..byte_size], 0);
    } else {
        fill(at, alignDown(byte_size, 4), sdk.exec.MEM_PATTERN_NEW);
        for (alignDown(byte_size, 4)..byte_size) |index| bytes[index] = 0xAB;
    }
    @memset(bytes[byte_size..rounded], @as(u8, @truncate(sdk.exec.MEM_PATTERN_WALL)));
    fill(at + rounded, sdk.exec.MEM_WALLSIZE, sdk.exec.MEM_PATTERN_WALL);
    const first: *u32 = @ptrFromInt(at + rounded);
    first.* = @as(u32, @intCast(byte_size)) ^ sdk.exec.MEM_PATTERN_WALL;
}

/// What a free left in its region, filled while memory debugging is on, so
/// that every free chunk holds MEM_PATTERN_FREED behind its MemChunk: the
/// block, the MemChunk Deallocate wrote at its start when the chunk below
/// took it in, and the next chunk's MemChunk when it took that in. Under
/// the memory lock, right after Deallocate.
///
/// INPUTS:
/// - `region` - the region the block went back to.
/// - `start` - where it started: its MemBlock.
/// - `whole` - what it took, MemBlock and wall included.
pub fn debugFreed(region: *MemHeader, start: usize, whole: usize) void {
    const end = start + whole;
    fill(start + MEM_BLOCKSIZE, whole - MEM_BLOCKSIZE, sdk.exec.MEM_PATTERN_FREED);
    var chunk = region.first;
    while (chunk) |free_chunk| : (chunk = free_chunk.next) {
        const from = @intFromPtr(free_chunk);
        if (from > start) return;
        if (from + free_chunk.bytes < end) continue;
        if (from < start) fill(start, MEM_BLOCKSIZE, sdk.exec.MEM_PATTERN_FREED);
        if (from + free_chunk.bytes > end) fill(end, MEM_BLOCKSIZE, sdk.exec.MEM_PATTERN_FREED);
        return;
    }
}

/// One thing `debugCheck` found: a walled block written past its end, or
/// free memory written after its free.
pub const Damage = struct {
    /// The first byte found wrong.
    at: usize,
    /// The block's owner; MEMOWNER_SYSTEM for free memory.
    owner: u32,
    /// Free memory rather than a wall.
    freed: bool,
};

/// Every wall and, while debugging is on, all free memory checked, under
/// the memory lock: the first `found.len` things wrong kept, all counted.
///
/// INPUTS:
/// - `base` - exec: its regions.
/// - `found` - where what is wrong is kept.
///
/// RESULT:
/// How many things were wrong.
pub fn debugCheck(base: *ExecBase, found: []Damage) u32 {
    const sys = base.iface();
    sys.AcquireLock(&base.lock_memory);
    defer sys.ReleaseLock(&base.lock_memory);
    var count: u32 = 0;
    var it = base.mem_list.iterator();
    while (it.next()) |node| {
        const mh: *MemHeader = @fieldParentPtr("node", node);
        var walk = sdk.exec.RegionWalk.init(mh);
        while (walk.next()) |stretch| {
            var wrong: ?Damage = null;
            if (stretch.free) {
                if (base.mem_debug.on) {
                    if (firstNot(stretch.start + MEM_BLOCKSIZE, stretch.bytes - MEM_BLOCKSIZE, sdk.exec.MEM_PATTERN_FREED)) |offset| {
                        wrong = .{ .at = stretch.start + MEM_BLOCKSIZE + offset, .owner = sdk.exec.MEMOWNER_SYSTEM, .freed = true };
                    }
                }
            } else if (stretch.walled) {
                const header: *const MemBlock = @ptrFromInt(stretch.start);
                if (header.wallDamage()) |offset| {
                    wrong = .{ .at = stretch.start + MEM_BLOCKSIZE + offset, .owner = stretch.owner, .freed = false };
                }
            }
            const damage = wrong orelse continue;
            if (count < found.len) found[count] = damage;
            count += 1;
        }
        if (walk.damaged) |at| {
            if (count < found.len) found[count] = .{ .at = at, .owner = sdk.exec.MEMOWNER_SYSTEM, .freed = false };
            count += 1;
        }
    }
    return count;
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
    /// Held around everything done to the pool, so one pool may be used
    /// from more than one task. A semaphore: a new puddle is an AllocMem.
    lock: sdk.exec.SignalSemaphore = .{},
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
    /// Who the puddles belong to: the pool's own owner, whichever task's
    /// AllocPooled takes them.
    owner: u32 = sdk.exec.MEMOWNER_SYSTEM,
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
