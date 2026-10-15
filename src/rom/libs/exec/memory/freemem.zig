// SPDX-License-Identifier: MPL-2.0
//! FreeMem: gives a block back to the system's memory. The region it came
//! from is found by its address, so the caller names only the block and
//! its size - which the block's MemBlock is checked against before
//! anything is given back.

const sdk = @import("sdk");
const exec = @import("../exec.zig");
const _memory = @import("_memory.zig");

const ExecBase = exec.ExecBase;
const MemBlock = sdk.exec.MemBlock;
const MEM_BLOCKSIZE = sdk.exec.MEM_BLOCKSIZE;

/// Gives memory back to the system.
///
/// SYNOPSIS:
/// ```zig
/// fn FreeMem(base: *ExecBase, memory_block: ?*anyopaque,
///     byte_size: usize) void
/// ```
///
/// SINCE: 1.0. LVO -112.
///
/// INPUTS:
/// - `memory_block` - what `AllocMem` answered, or null, which does
///   nothing so that a cleanup path need not test it.
/// - `byte_size` - **the size that was allocated**, not the size that was
///   used. 0 does nothing.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// The region holding that address is found on the memory list, the
/// block's MemBlock is checked, and the block goes back to the region with
/// its MemBlock. A block in no region at all is fatal: it is either an
/// address that was never allocated or one already freed and handed to
/// someone else, and both are worth stopping for.
///
/// **A block with a wall** - allocated while memory debugging was on - has
/// it checked first: one written past its end is freed all the same, and
/// told with a line on the system log and a recoverable alert,
/// `AN_MemWall`. While memory debugging is on, the freed memory is filled
/// with `MEM_PATTERN_FREED`.
///
/// **A block that is not in use, or a size that is not the block's, is
/// refused**: the block is left as it is, a line naming it goes to the
/// system log - for a size, with both sizes and the owner - and a
/// recoverable alert is raised: `AN_FreeTwice` for a block freed already
/// (or whose MemBlock was written over), `AN_BadFreeSize` for the size. Freeing either size could
/// give away memory still in use; leaving the block costs only its bytes.
///
/// CONTEXT:
/// - Waits: no, unless the block is refused: the alert is shown on the
///   display, and waits there for an answer or a few seconds.
/// - Interrupts: no. It takes exec's memory lock, around the search and
///   the free.
/// - Locks: takes exec's memory lock, and lets go of it before an alert.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The memory is the system's again and must not be touched.
///
/// NOTES:
/// The size is the one asked of AllocMem, or anything that rounds up to
/// the same multiple of `MEM_BLOCKSIZE`. Part of a block cannot be given
/// back.
///
/// A block in no region stops the machine: it is a caller freeing memory
/// the system never gave out.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AllocMem`, `FreeVec`, `Deallocate`
///
/// EXAMPLES:
/// ```zig
/// defer sys.FreeMem(buf, 1024);
/// ```
pub fn FreeMem(base: *ExecBase, memory_block: ?*anyopaque, byte_size: usize) void {
    const block = memory_block orelse return;
    if (byte_size == 0) return;
    const caller = @returnAddress();
    const sys = base.iface();
    const header = MemBlock.of(block);
    // What the MemBlock said, for the report, read while the lock still
    // keeps the block where it is.
    var held: usize = 0;
    var owner: u32 = 0;
    var asked: usize = 0;
    var wall_damage: ?usize = null;
    const refused: u32 = refuse: {
        sys.AcquireLock(&base.lock_memory);
        defer sys.ReleaseLock(&base.lock_memory);
        const region = _memory.regionOf(base, @intFromPtr(block) - MEM_BLOCKSIZE) orelse
            @panic("FreeMem: block is not in any memory region");
        held = header.bytes();
        owner = header.owner;
        if (!header.inUse()) break :refuse sdk.exec.AN_FreeTwice;
        if (held != _memory.alignUp(byte_size, MEM_BLOCKSIZE)) break :refuse sdk.exec.AN_BadFreeSize;
        // A wall is checked before the memory goes: what wrote past the
        // block's end is told, and the block freed all the same.
        wall_damage = header.wallDamage();
        asked = header.askedSize();
        const whole = header.extent() + MEM_BLOCKSIZE;
        if (base.mem_trace.on) _memory.traceEvent(base, 'F', whole, block, caller);
        // Not in use from here: a second FreeMem of it is refused, even
        // where the MemBlock is left inside a free chunk.
        header.size = 0;
        sys.Deallocate(region, header, whole);
        if (base.mem_debug.on) _memory.debugFreed(region, @intFromPtr(header), whole);
        break :refuse 0;
    };
    if (wall_damage) |offset| {
        base.mem_debug.walls +%= 1;
        exec.kprintf("FreeMem: %08x written past its end at +%u (%u bytes asked), owner %u\n", .{
            @as(u32, @truncate(@intFromPtr(block))),
            @as(u32, @intCast(offset)),
            @as(u32, @intCast(asked)),
            owner,
        });
        sys.AlertAt(sdk.exec.AN_MemWall, caller, "FreeMem: the block was written past its end");
        return;
    }
    if (refused == 0) return;
    // Told outside the lock: the alert draws, and drawing allocates. A
    // block not in use has no owner or size to tell: what is there is free
    // space's, or whatever overwrote it.
    if (refused == sdk.exec.AN_FreeTwice) {
        exec.kprintf("FreeMem: %08x refused - not in use: freed already, or its MemBlock written over\n", .{
            @as(u32, @truncate(@intFromPtr(block))),
        });
        sys.AlertAt(refused, caller, "FreeMem: a block that is not in use");
        return;
    }
    exec.kprintf("FreeMem: %08x refused - %ld bytes freed, %ld held, owner %u\n", .{
        @as(u32, @truncate(@intFromPtr(block))),
        @as(u64, byte_size),
        @as(u64, held),
        owner,
    });
    sys.AlertAt(refused, caller, "FreeMem: the size is not the block's");
}
