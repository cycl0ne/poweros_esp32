// SPDX-License-Identifier: MPL-2.0
//! Cutting a board's display memory into buffers.
//!
//! First fit over a list of free blocks kept in order of address, merging
//! with its neighbours when a piece comes back. That is enough here and
//! chosen on purpose: the whole population of a board is a handful of
//! buffers whose lifetimes are measured in boots - the one being shown,
//! perhaps a second to draw into while the first is up, and the odd
//! off-screen one. Nothing is allocated in a loop and nothing is freed
//! under pressure, so a cleverer allocator would be more state to keep
//! right for a list that rarely holds more than two entries.
//!
//! What it does have to get right is alignment. Every piece starts on the
//! board's alignment and every piece is a whole number of them, because a
//! display reads its memory in units of that size: a buffer that began
//! inside one would be fetched in pieces that do not line up with what was
//! asked for.
//!
//! The book-keeping is in the library's own memory and never in the region
//! itself, which may be memory the CPU should not be writing into between
//! frames.

const sdk = @import("sdk");
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;

/// A stretch of the region that is free. One of these is a few words in
/// the library's memory, not a header inside the region.
const Block = struct {
    node: exec.Node = .{},
    offset: usize = 0,
    size: usize = 0,
};

/// What a board's display memory has been cut into.
pub const Arena = struct {
    /// The free blocks, in order of address.
    blocks: exec.List = .{},
    /// Where offset 0 is: the first aligned address in the region, which
    /// is not always where the region begins. Everything below works in
    /// offsets from here, so every offset on the grid is an address on it.
    origin: usize = 0,
    size: usize = 0,
    alignment: u32 = 64,
    free_bytes: usize = 0,
    /// A block record kept in hand so that giving memory back never has to
    /// allocate: a free that cannot record itself would have to drop the
    /// memory instead.
    spare: ?*Block = null,
    /// Memory that was given back and could not be recorded. It stays
    /// counted so that what is missing is at least visible.
    lost_bytes: usize = 0,

    /// `base` is where the region starts, because the alignment has to be
    /// true of the addresses a display reads and not merely of the offsets
    /// into it: a driver that hands over memory starting part-way through
    /// a line loses the bytes in front of the first aligned address, and
    /// every buffer after that is right.
    ///
    /// INPUTS:
    /// - `arena` - the region's bookkeeping.
    /// - `sys` - exec, for the bookkeeping's own memory.
    /// - `base` - where the region starts.
    /// - `size` - how many bytes it has.
    /// - `alignment` - what every piece is aligned to.
    pub fn init(arena: *Arena, sys: *ExecBase, base: usize, size: usize, alignment: u32) void {
        arena.* = .{ .size = size, .alignment = if (alignment == 0) 64 else alignment };
        sys.NewList(&arena.blocks);
        arena.free_bytes = 0;
        if (size == 0 or base == 0) return;
        // The bytes in front of the first aligned address are lost: a
        // display reads this memory in whole units of the alignment, so a
        // buffer that began inside one would be fetched in pieces that do
        // not line up with what was asked for.
        arena.origin = arena.roundUp(base);
        const skip = arena.origin - base;
        if (size <= skip) return;
        const whole = arena.roundDown(size - skip);
        if (whole == 0) return;
        const block = arena.newBlock(sys) orelse return;
        block.offset = 0;
        block.size = whole;
        sys.AddTail(&arena.blocks, &block.node);
        arena.free_bytes = whole;
    }

    /// Give every block record back. The region itself is the driver's.
    ///
    /// INPUTS:
    /// - `arena` - the region's bookkeeping.
    /// - `sys` - exec, for the bookkeeping's own memory.
    pub fn deinit(arena: *Arena, sys: *ExecBase) void {
        var node = arena.blocks.first();
        while (node) |n| {
            const next = n.next();
            sys.Remove(n);
            sys.FreeVec(@as(*Block, @fieldParentPtr("node", n)));
            node = next;
        }
        if (arena.spare) |spare| sys.FreeVec(spare);
        arena.spare = null;
        arena.free_bytes = 0;
    }

    /// Take `bytes` out of the region, aligned. The offset from the start
    /// of the region, or null if there is no piece that big.
    ///
    /// INPUTS:
    /// - `arena` - the region's bookkeeping.
    /// - `sys` - exec, for the bookkeeping's own memory.
    /// - `bytes` - how many.
    pub fn alloc(arena: *Arena, sys: *ExecBase, bytes: usize) ?usize {
        if (bytes == 0) return null;
        const want = arena.roundUp(bytes);
        // Keep a record in hand for the free that will follow.
        arena.keepSpare(sys);

        var node = arena.blocks.first();
        while (node) |n| : (node = n.next()) {
            const block: *Block = @fieldParentPtr("node", n);
            if (block.size < want) continue;
            const offset = block.offset;
            if (block.size == want) {
                sys.Remove(n);
                arena.recycle(sys, block);
            } else {
                block.offset += want;
                block.size -= want;
            }
            arena.free_bytes -= want;
            return offset;
        }
        return null;
    }

    /// Put a piece back, merging it with whatever it touches.
    ///
    /// INPUTS:
    /// - `arena` - the region's bookkeeping.
    /// - `sys` - exec, for the bookkeeping's own memory.
    /// - `offset` - where the piece is.
    /// - `bytes` - how many it has.
    pub fn free(arena: *Arena, sys: *ExecBase, offset: usize, bytes: usize) void {
        if (bytes == 0) return;
        const size = arena.roundUp(bytes);
        const start = offset;
        const end = offset + size;

        // Where it belongs, and what it touches on either side.
        var before: ?*Block = null;
        var after: ?*Block = null;
        var node = arena.blocks.first();
        while (node) |n| : (node = n.next()) {
            const block: *Block = @fieldParentPtr("node", n);
            if (block.offset + block.size <= start) {
                before = block;
                continue;
            }
            after = block;
            break;
        }

        arena.free_bytes += size;

        const joins_before = before != null and before.?.offset + before.?.size == start;
        const joins_after = after != null and end == after.?.offset;

        if (joins_before and joins_after) {
            before.?.size += size + after.?.size;
            sys.Remove(&after.?.node);
            arena.recycle(sys, after.?);
            return;
        }
        if (joins_before) {
            before.?.size += size;
            return;
        }
        if (joins_after) {
            after.?.offset = start;
            after.?.size += size;
            return;
        }

        const block = arena.takeSpare(sys) orelse {
            // Nowhere to record it. The memory stays out of use rather
            // than being handed out twice.
            arena.free_bytes -= size;
            arena.lost_bytes += size;
            return;
        };
        block.offset = start;
        block.size = size;
        if (after) |a| {
            sys.Insert(&arena.blocks, &block.node, a.node.pred);
        } else {
            sys.AddTail(&arena.blocks, &block.node);
        }
    }

    /// Take a piece that is already spoken for out of the region: memory
    /// a driver was using before the library ever saw it, such as the
    /// buffer a display that was already running is being refreshed from.
    /// False if it is not free, in which case nothing changed.
    ///
    /// INPUTS:
    /// - `arena` - the region's bookkeeping.
    /// - `sys` - exec, for the bookkeeping's own memory.
    /// - `offset` - where the piece is.
    /// - `bytes` - how many it has.
    pub fn reserve(arena: *Arena, sys: *ExecBase, offset: usize, bytes: usize) bool {
        if (bytes == 0) return true;
        const start = arena.roundDown(offset);
        const end = arena.roundUp(offset + bytes);
        arena.keepSpare(sys);

        var node = arena.blocks.first();
        while (node) |n| : (node = n.next()) {
            const block: *Block = @fieldParentPtr("node", n);
            if (block.offset > start or block.offset + block.size < end) continue;
            const before = start - block.offset;
            const after = block.offset + block.size - end;
            arena.free_bytes -= end - start;
            if (before == 0 and after == 0) {
                sys.Remove(n);
                arena.recycle(sys, block);
                return true;
            }
            if (before == 0) {
                block.offset = end;
                block.size = after;
                return true;
            }
            block.size = before;
            if (after == 0) return true;
            // A piece out of the middle leaves the tail behind it.
            const tail = arena.takeSpare(sys) orelse {
                arena.lost_bytes += after;
                arena.free_bytes -= after;
                return true;
            };
            tail.offset = end;
            tail.size = after;
            sys.Insert(&arena.blocks, &tail.node, &block.node);
            return true;
        }
        return false;
    }

    /// The largest single piece still free.
    ///
    /// INPUTS:
    /// - `arena` - the region's bookkeeping.
    pub fn largest(arena: *Arena) usize {
        var most: usize = 0;
        var node = arena.blocks.first();
        while (node) |n| : (node = n.next()) {
            const block: *Block = @fieldParentPtr("node", n);
            if (block.size > most) most = block.size;
        }
        return most;
    }

    /// A size rounded up to the arena's alignment.
    ///
    /// INPUTS:
    /// - `arena` - the region's bookkeeping.
    /// - `bytes` - the size.
    pub fn roundUp(arena: *const Arena, bytes: usize) usize {
        const a: usize = arena.alignment;
        return (bytes + a - 1) & ~(a - 1);
    }

    /// A size rounded down to the arena's alignment.
    ///
    /// INPUTS:
    /// - `arena` - the region's bookkeeping.
    /// - `bytes` - the size.
    fn roundDown(arena: *const Arena, bytes: usize) usize {
        const a: usize = arena.alignment;
        return bytes & ~(a - 1);
    }

    /// A record for one free piece, from the spare kept or from memory.
    ///
    /// INPUTS:
    /// - `arena` - the region's bookkeeping.
    /// - `sys` - exec, for the bookkeeping's own memory.
    fn newBlock(arena: *Arena, sys: *ExecBase) ?*Block {
        _ = arena;
        const memory = sys.AllocVec(@sizeOf(Block), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return null;
        const block: *Block = @ptrCast(@alignCast(memory));
        block.* = .{};
        return block;
    }

    /// Keeps one record spare, so that a free that has to split a piece does
    /// not fail for want of memory.
    ///
    /// INPUTS:
    /// - `arena` - the region's bookkeeping.
    /// - `sys` - exec, for the bookkeeping's own memory.
    fn keepSpare(arena: *Arena, sys: *ExecBase) void {
        if (arena.spare == null) arena.spare = arena.newBlock(sys);
    }

    /// The spare record, taken.
    ///
    /// INPUTS:
    /// - `arena` - the region's bookkeeping.
    /// - `sys` - exec, for the bookkeeping's own memory.
    fn takeSpare(arena: *Arena, sys: *ExecBase) ?*Block {
        if (arena.spare) |spare| {
            arena.spare = null;
            return spare;
        }
        return arena.newBlock(sys);
    }

    /// A record no longer needed: kept as the spare, or freed.
    ///
    /// INPUTS:
    /// - `arena` - the region's bookkeeping.
    /// - `sys` - exec, for the bookkeeping's own memory.
    /// - `block` - the record.
    fn recycle(arena: *Arena, sys: *ExecBase, block: *Block) void {
        if (arena.spare == null) {
            block.* = .{};
            arena.spare = block;
            return;
        }
        sys.FreeVec(block);
    }
};
