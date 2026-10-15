// SPDX-License-Identifier: MPL-2.0
//! AllocMem: a block from the system's memory list. It takes the first
//! region by priority that has every attribute asked for and room; when
//! none has, it asks the low-memory handlers to free something and tries
//! again after each one that did.
//!
//! The regions are walked under exec's memory lock, and the block's
//! MemBlock - its owner, size and MEMF_PRIVATE - is written under it too;
//! the handlers run outside it, under their own semaphore.

const sdk = @import("sdk");
const _memory = @import("_memory.zig");

const ExecBase = @import("../exec.zig").ExecBase;
const Interrupt = sdk.exec.Interrupt;
const MemChunk = sdk.exec.MemChunk;
const MemHeader = sdk.exec.MemHeader;
const MEM_BLOCKSIZE = sdk.exec.MEM_BLOCKSIZE;

/// Allocates memory from the system, from the first region that suits.
///
/// SYNOPSIS:
/// ```zig
/// fn AllocMem(base: *ExecBase, byte_size: usize,
///     requirements: u32) ?*anyopaque
/// ```
///
/// SINCE: 1.0. LVO -108.
///
/// INPUTS:
/// - `byte_size` - bytes wanted. Rounded up to `MEM_BLOCKSIZE`.
/// - `requirements` - what the memory must be, and how to take it:
///   - `MEMF_ANY` - anywhere. On this machine that is external memory
///     first, since internal memory is at the higher priority and kept for
///     what needs it.
///   - `MEMF_INTERNAL` - internal SRAM. What an interrupt reads, and what
///     survives the caches being suspended.
///   - `MEMF_EXTERNAL` - PSRAM. Where the big buffers go.
///   - `MEMF_DMA` - reachable by a DMA descriptor's twenty address bits,
///     and needing no cache maintenance.
///   - `MEMF_PRIVATE` - the block is the owner's alone; without it, shared.
///   - `MEMF_CLEAR` - zero the block before answering.
///   - `MEMF_REVERSE` - take it from the top of the region.
///   - `MEMF_SYSTEM` - the block is the system's, not the calling task's.
///   - `MEMF_NO_EXPUNGE` - fail rather than ask the low-memory handlers.
///
/// RESULT:
/// The block, `MEM_BLOCKSIZE`-aligned, or null: 0 bytes, or nothing fits
/// even after the handlers have run.
///
/// BEHAVIOR:
/// Regions are tried in priority order and the first that has every
/// attribute bit asked for and room for the block wins.
///
/// **The block carries a MemBlock in front** (`sdk.exec.MemBlock`), one
/// `MEM_BLOCKSIZE` taken from the region with it: the owner, the size and
/// MEMF_PRIVATE. The owner is the system for `MEMF_SYSTEM`, for exec's own
/// tasks and for a task inside `BeginSystemMemory`; otherwise the calling
/// task's number (`Task.id`) - also when the call is made from library
/// code, which runs on its caller. FreeMem checks the size against it.
///
/// **When nothing fits**, and `MEMF_NO_EXPUNGE` was not asked for, the
/// low-memory handlers are called highest priority first, and the
/// allocation is retried after each one that says it did something. One
/// handler is exec's own, which expunges libraries and devices nobody has
/// open - one per call, so only as much goes as the allocation needed.
///
/// The regions are searched under exec's memory lock, a few hundred
/// cycles; the handlers run outside it, under the memory handlers'
/// semaphore, so that what they free goes straight back.
///
/// CONTEXT:
/// - Waits: only when memory runs short, for the memory handlers'
///   semaphore while another task runs them. A handler waits for nothing:
///   exec's own only tries the locks it needs.
/// - Interrupts: no. It takes exec's memory lock, and an interrupt must
///   not allocate.
/// - Locks: takes exec's memory lock, and the memory handlers' semaphore when
///   memory runs short; no spinlock may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The caller's until `FreeMem` with the same size, and marked as its
/// task's, or the system's, until then. Nothing frees it when the task
/// ends: a block left over shows under the task's number in
/// `Avail OWNERS` and `s3> memowners`.
///
/// **While memory debugging is on** (`s3> memdebug`), the block also gets a
/// wall of `MEM_WALLSIZE` behind it, which records the size asked for and
/// which `FreeMem` checks; it holds `MEM_PATTERN_NEW` unless `MEMF_CLEAR`
/// asked for zeros; and the free memory it is cut from is checked for
/// `MEM_PATTERN_FREED`, a write to it after its free going to the system
/// log.
///
/// NOTES:
/// The size a region actually gives up is the request rounded up, the
/// MemBlock and any wall, which is why `memtrace`'s outstanding figure and
/// the fall in what `AvailMem` reports are the same number. MEMF_PRIVATE is
/// recorded, not enforced: nothing checks who reads or writes the block.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `FreeMem`, `AllocVec`, `AvailMem`, `AddMemHandler`, `BeginSystemMemory`
///
/// EXAMPLES:
/// ```zig
/// const buf = sys.AllocMem(1024, exec.MEMF_INTERNAL | exec.MEMF_CLEAR)
///     orelse return;
/// defer sys.FreeMem(buf, 1024);
/// ```
pub fn AllocMem(base: *ExecBase, byte_size: usize, requirements: u32) ?*anyopaque {
    if (byte_size == 0) return null;
    const caller = @returnAddress();
    // A size past a word fits no region, but is still worth the handlers'
    // run: asking for more than there is expunges everything idle.
    const walled = base.mem_debug.on;
    const whole = _memory.wholeSize(byte_size, walled) orelse ~@as(usize, 0);
    const owner = _memory.ownerFor(base, requirements);
    const block = allocFromList(base, whole, requirements, owner, walled, caller) orelse
        lowMemory(base, byte_size, whole, requirements, owner, walled, caller) orelse
        return null;
    // The block is the caller's already: walled or cleared without the
    // lock.
    if (walled) {
        _memory.debugNew(base, block, byte_size, requirements);
    } else if (requirements & sdk.exec.MEMF_CLEAR != 0) {
        const bytes: [*]u8 = @ptrCast(block);
        @memset(bytes[0.._memory.alignUp(byte_size, MEM_BLOCKSIZE)], 0);
    }
    return block;
}

/// The first region on the memory list with every attribute bit asked for
/// and room for the block, or null if there is none - under exec's memory
/// lock, which the block's MemBlock is written and the trace's counts are
/// kept under too.
///
/// INPUTS:
/// - `base` - exec: its memory list and lock, and the jump table
///   `Allocate` is called through.
/// - `whole` - what the region gives up (`wholeSize`).
/// - `requirements` - the MEMF_* word; `MEMF_REVERSE` takes the block
///   from the top of the region.
/// - `owner` - who the block is marked as.
/// - `walled` - whether `whole` has room for a wall.
/// - `caller` - AllocMem's caller, for the trace.
///
/// RESULT:
/// The block, past its MemBlock.
fn allocFromList(base: *ExecBase, whole: usize, requirements: u32, owner: u32, walled: bool, caller: usize) ?*anyopaque {
    const sys = base.iface();
    sys.AcquireLock(&base.lock_memory);
    defer sys.ReleaseLock(&base.lock_memory);
    const wanted = requirements & _memory.attribute_mask;
    var it = base.mem_list.iterator();
    while (it.next()) |node| {
        const mh: *MemHeader = @fieldParentPtr("node", node);
        if (@as(u32, mh.attributes) & wanted != wanted) continue;
        const chunk = (if (requirements & sdk.exec.MEMF_REVERSE != 0)
            allocateReverse(mh, whole)
        else
            sys.Allocate(mh, whole)) orelse continue;
        const block = _memory.markBlock(chunk, whole, owner, requirements, walled);
        if (base.mem_trace.on) _memory.traceEvent(base, 'A', whole, block, caller);
        return block;
    }
    return null;
}

/// Out of memory: asks the handlers, highest priority first, and retries
/// after each one that says it did something.
///
/// `MEM_TRY_AGAIN` asks the same handler again with `MEMHF_RECYCLE`, so a
/// handler that frees one thing at a time is driven until the allocation
/// succeeds.
///
/// The handlers run under their own semaphore, which keeps their list still
/// and one task at a time in them, and not under the memory lock: what
/// they free goes back through FreeMem. A handler that allocates comes
/// back here and runs them again, as the semaphore's owner.
///
/// INPUTS:
/// - `base` - exec: its handler list and memory list.
/// - `byte_size`, `requirements` - the failed allocation's, handed to each
///   handler in a `MemHandlerData` so it knows how much to look for.
/// - `whole`, `owner`, `walled` - what `allocFromList` is asked again
///   with.
/// - `caller` - AllocMem's caller, for the trace.
///
/// RESULT:
/// The block, or null when every handler is spent - and at once under
/// `MEMF_NO_EXPUNGE`.
fn lowMemory(base: *ExecBase, byte_size: usize, whole: usize, requirements: u32, owner: u32, walled: bool, caller: usize) ?*anyopaque {
    // The caller asked to fail rather than have anything expunged.
    if (requirements & sdk.exec.MEMF_NO_EXPUNGE != 0) return null;
    const sys = base.iface();
    sys.ObtainSemaphore(&base.sem_memhandlers);
    defer sys.ReleaseSemaphore(&base.sem_memhandlers);
    var data: sdk.exec.MemHandlerData = .{
        .request_size = _memory.fitsWord(byte_size) orelse ~@as(u32, 0),
        .request_flags = requirements,
        .flags = 0,
    };
    var node = base.mem_handlers.first();
    while (node) |current| {
        const handler: *Interrupt = @fieldParentPtr("node", current);
        const code: sdk.exec.MemHandlerFn = @ptrCast(@alignCast(handler.code.?));
        const result = code(&data, handler.data);
        if (result != sdk.exec.MEM_DID_NOTHING) {
            if (allocFromList(base, whole, requirements, owner, walled, caller)) |block| return block;
        }
        if (result == sdk.exec.MEM_TRY_AGAIN) {
            data.flags = sdk.exec.MEMHF_RECYCLE;
            continue;
        }
        data.flags = 0;
        node = if (current.succ.?.succ != null) current.succ else null;
    }
    return null;
}

/// `Allocate` for `MEMF_REVERSE`: the *last* chunk that fits, and the block
/// comes off its top end rather than its start. Taking from the top keeps
/// a long-lived allocation out of the way of the growing end of a region.
///
/// INPUTS:
/// - `mh` - the region.
/// - `byte_size` - what is wanted.
///
/// RESULT:
/// The block or null, on the same terms as `Allocate`.
fn allocateReverse(mh: *MemHeader, byte_size: usize) ?*anyopaque {
    if (byte_size == 0 or byte_size > mh.free) return null;
    const size: u32 = @intCast(_memory.alignUp(byte_size, MEM_BLOCKSIZE));

    var fitting: ?*?*MemChunk = null;
    var link: *?*MemChunk = &mh.first;
    while (link.*) |chunk| : (link = &chunk.next) {
        if (chunk.bytes >= size) fitting = link;
    }
    const chunk_link = fitting orelse return null;
    const chunk = chunk_link.*.?;
    mh.free -= size;
    if (chunk.bytes == size) {
        chunk_link.* = chunk.next;
        return chunk;
    }
    chunk.bytes -= size;
    return @ptrFromInt(@intFromPtr(chunk) + chunk.bytes);
}
