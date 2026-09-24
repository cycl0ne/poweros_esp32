// SPDX-License-Identifier: MPL-2.0
//! AllocMem: a block from the system's memory list. It takes the first
//! region by priority that has every attribute asked for and room; when
//! none has, it asks the low-memory handlers to free something and tries
//! again after each one that did.
//!
//! The regions are walked under Forbid, and the handlers run inside it,
//! so none of them may wait.

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
///   - `MEMF_CLEAR` - zero the block before answering.
///   - `MEMF_REVERSE` - take it from the top of the region.
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
/// **When nothing fits**, and `MEMF_NO_EXPUNGE` was not asked for, the
/// low-memory handlers are called highest priority first, and the
/// allocation is retried after each one that says it did something. One
/// handler is exec's own, which expunges libraries and devices nobody has
/// open - one per call, so only as much goes as the allocation needed.
///
/// CONTEXT:
/// - Waits: no, and it must not - the handlers run inside its Forbid and
///   are forbidden to wait for the same reason.
/// - Interrupts: no. It takes Forbid, and an interrupt must not allocate.
/// - Forbid: taken here, around the search, the handlers and the clear.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The caller's until `FreeMem` with the same size. Nothing tracks it, so a
/// block whose size is lost is a leak - which is what `AllocVec` exists to
/// prevent.
///
/// NOTES:
/// The size a region actually gives up is the request rounded up, which is
/// why `memtrace`'s outstanding figure and the fall in what `AvailMem`
/// reports are the same number.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `FreeMem`, `AllocVec`, `AvailMem`, `AddMemHandler`
///
/// EXAMPLES:
/// ```zig
/// const buf = sys.AllocMem(1024, exec.MEMF_INTERNAL | exec.MEMF_CLEAR)
///     orelse return;
/// defer sys.FreeMem(buf, 1024);
/// ```
pub fn AllocMem(base: *ExecBase, byte_size: usize, requirements: u32) ?*anyopaque {
    if (byte_size == 0) return null;
    const sys = base.iface();
    sys.Forbid();
    defer sys.Permit();

    const block = allocFromList(base, byte_size, requirements) orelse
        (if (requirements & sdk.exec.MEMF_NO_EXPUNGE != 0) null else lowMemory(base, byte_size, requirements)) orelse
        return null;
    if (requirements & sdk.exec.MEMF_CLEAR != 0) {
        const bytes: [*]u8 = @ptrCast(block);
        @memset(bytes[0.._memory.alignUp(byte_size, MEM_BLOCKSIZE)], 0);
    }
    if (_memory.trace.on) _memory.traceEvent('A', byte_size, block, @returnAddress());
    return block;
}

/// The first region on the memory list with every attribute bit asked for
/// and room for the block, or null if there is none.
///
/// INPUTS:
/// - `base` - exec: its memory list, and the jump table `Allocate` is
///   called through.
/// - `byte_size` - what is wanted.
/// - `requirements` - the MEMF_* word; `MEMF_REVERSE` takes the block
///   from the top of the region.
fn allocFromList(base: *ExecBase, byte_size: usize, requirements: u32) ?*anyopaque {
    const sys = base.iface();
    const wanted = requirements & _memory.attribute_mask;
    var it = base.mem_list.iterator();
    while (it.next()) |node| {
        const mh: *MemHeader = @fieldParentPtr("node", node);
        if (@as(u32, mh.attributes) & wanted != wanted) continue;
        const block = if (requirements & sdk.exec.MEMF_REVERSE != 0)
            allocateReverse(mh, byte_size)
        else
            sys.Allocate(mh, byte_size);
        return block orelse continue;
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
/// INPUTS:
/// - `base` - exec: its handler list and memory list.
/// - `byte_size`, `requirements` - the failed allocation's, handed to each
///   handler in a `MemHandlerData` so it knows how much to look for.
///
/// RESULT:
/// The block, or null when every handler is spent.
fn lowMemory(base: *ExecBase, byte_size: usize, requirements: u32) ?*anyopaque {
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
            if (allocFromList(base, byte_size, requirements)) |block| return block;
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
