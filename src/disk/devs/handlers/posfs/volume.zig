// SPDX-License-Identifier: MPL-2.0
//! A posfs volume in memory: what the label says, the trees' roots, the
//! nodes being changed, and the blocks read and written for them.
//!
//! Everything else in the core works on a `*Volume` - the trees
//! (btree.zig), the free space (space.zig), the checkpoints
//! (checkpoint.zig), the journal (journal.zig), and the objects, names and
//! files above them. The core calls no library: what it needs of the
//! machine - memory, the clock, the medium - comes through the `Device`
//! (media.zig), so it runs the same in the handler, in the host tool that
//! builds a disk image, and in the tests.
//!
//! **Reading a node** checks it before anything looks inside: its magic,
//! the volume's id, its own address and the generation its pointer said,
//! its checksum, and that every count and offset in it stays inside the
//! block. A node that fails is an error (`Corrupt`), never a panic. On a
//! medium that can be read as memory a node is read where it lies, and
//! checked the first time it is read after it was written (`verified`);
//! on any other the cache holds the nodes read and written.
//!
//! **Reading file data** of a checksummed extent checks each block it
//! touches against its crc first (`readChecked`): a block that does not
//! match is `BadChecksum`, never its bytes. On a medium read as memory a
//! block is checked once (`data_checked`); on any other the last block
//! read in part is kept, checked, for the next read of it.
//!
//! **Writing a node** happens only at a checkpoint, to a block taken for
//! it then. Until that a changed node is a buffer of its own, numbered in
//! the dirty table, and the pointer to it says so (`dirty_bit`).

const sdk = @import("sdk");
const posfs = sdk.dos.posfs;
const layout = posfs.layout;
const media = @import("media.zig");
const Cache = @import("cache.zig").Cache;
const btree = @import("btree.zig");
const space_area = @import("space.zig");
const journal_area = @import("journal.zig");
const snapshots_area = @import("snapshots.zig");
const objects = @import("objects.zig");
const compress = @import("compress.zig");

pub const Error = error{
    /// Memory ran out.
    NoMemory,
    /// The medium refused a read or a write.
    Io,
    /// Something read does not check out: the volume is damaged.
    Corrupt,
    /// File data that does not match its checksum.
    BadChecksum,
    /// No room left.
    DiskFull,
    /// The volume cannot be written (the medium, or a damage found).
    ReadOnly,
    // What a packet can be refused for.
    NotFound,
    Exists,
    InUse,
    NotEmpty,
    WrongType,
    BadName,
    DeleteProtected,
    WriteProtected,
    ReadProtected,
    CommentTooBig,
    InvalidArgument,
    /// A path longer than posfs keeps.
    LineTooLong,
    IsSoftLink,
    TooManyLevels,
    BufferOverflow,
    NotImplemented,
    InvalidLock,
    /// A lock on a volume that is not in the drive.
    NotMounted,
    SeekError,
    NoMoreEntries,
    /// The directory something is to go back to is not there.
    DirNotFound,
    /// No posfs volume on the medium.
    NotPosfs,
};

/// A pointer in memory to a node being changed: the dirty table's index,
/// with this bit set. Block addresses never reach it.
pub const dirty_bit: u64 = 1 << 63;

/// A block address that is none: what a cache of one block says when it
/// holds nothing.
pub const no_block: u64 = ~@as(u64, 0);

/// How deep a tree may grow.
pub const max_height: u32 = 16;

pub const Volume = struct {
    dev: media.Device,
    label: layout.Label = .{},
    block_size: u32 = 0,
    block_shift: u6 = 0,
    write_unit: u32 = 0,
    erase_size: u32 = 0,
    block_count: u64 = 0,
    uuid: [16]u8 = @splat(0),
    /// The medium as memory, when it can be read that way.
    map: ?[*]const u8 = null,
    /// The volume's first byte on the medium it is given: 0 where the
    /// medium is the volume, as the handler's is - it finds the volume
    /// itself, in a partition table or not.
    first_byte: u64 = 0,

    cache: Cache = undefined,
    cache_ready: bool = false,
    /// The blocks the cache is made with at a mount: 0 for about a
    /// megabyte's worth. One count for the drive, whatever medium is in.
    cache_blocks: u32 = 0,
    /// A bit per block: checked once, on a medium read as memory.
    verified: []u8 = &.{},
    /// A block of room for reshaping a node.
    scratch: []u8 = &.{},
    /// A block of room for reading file data that does not start or end
    /// on a block.
    bounce: []u8 = &.{},
    /// Where a file's blocks in memory are put one after another to go to
    /// the medium in one command (files.zig): made the first time, and
    /// empty when there was no memory for it.
    gather: []u8 = &.{},
    /// The last block of checksummed file data read in part, checked, and
    /// its address (`no_block` for none): on a medium not read as memory.
    checked: []u8 = &.{},
    checked_block: u64 = no_block,
    /// A bit per block: file data checked against its crc, on a medium
    /// read as memory.
    data_checked: []u8 = &.{},
    /// The buffers compressed chunks are written and read through.
    chunks: compress.Chunks = .{},

    obj: btree.Tree = .{ .id = layout.tree_object },
    space_tree: btree.Tree = .{ .id = layout.tree_space },

    /// The nodes being changed, by number; an empty slot is free.
    dirty: [][]u8 = &.{},
    dirty_count: u32 = 0,

    /// The generation being built: the newest durable checkpoint's plus
    /// one.
    gen: u64 = 1,
    /// The newest durable checkpoint, and the one before it.
    durable: layout.CheckpointSlot = .{},
    previous: layout.CheckpointSlot = .{},
    have_previous: bool = false,
    /// The mount's life: what the journal written now is seeded with.
    life: u64 = 0,
    next_oid: u64 = posfs.first_user_oid,

    space: space_area.Space = .{},
    journal: journal_area.Journal = .{},
    /// The deadlist entries waiting for the next checkpoint, and a
    /// snapshot it is to make.
    snapshots: snapshots_area.State = .{},
    /// The volume table as it is now, and whether it has changed since
    /// the last checkpoint.
    voltab: *layout.VolTab = undefined,
    voltab_ready: bool = false,
    voltab_dirty: bool = false,
    /// Where this checkpoint wrote the volume table, 0 when it did not.
    voltab_written: u64 = 0,

    read_only: bool = false,
    mounted: bool = false,
    /// The volume was not put away cleanly before this mount: a block
    /// that reads as erased may still not be.
    unclean: bool = false,
    /// The first change of this mount has been made: the checkpoint that
    /// raises the life is written.
    session_started: bool = false,
    /// A write failed: nothing more is written until the next mount.
    failed: bool = false,
    /// Blocks written since the last barrier, which a record may name: the
    /// journal writes nothing more before a barrier has put them down.
    unordered: bool = false,
    /// What the mount found in the journal and applied.
    replayed: objects.Replayed = .{},
    /// What the file system above can give up when the volume is full and
    /// checkpoints have made no room: true when it gave up something.
    make_room: ?*const fn (vol: *Volume) Error!bool = null,

    // --- memory -------------------------------------------------------------

    pub fn alloc(vol: *Volume, len: usize) Error![]u8 {
        return vol.dev.alloc(len) orelse error.NoMemory;
    }

    /// Not cleared: for a buffer filled whole before it is read.
    pub fn allocRaw(vol: *Volume, len: usize) Error![]u8 {
        return vol.dev.allocRaw(len) orelse error.NoMemory;
    }

    pub fn free(vol: *Volume, memory: []u8) void {
        if (memory.len != 0) vol.dev.free(memory);
    }

    pub fn allocSlice(vol: *Volume, comptime T: type, count: usize) Error![]T {
        if (count == 0) return &.{};
        const bytes = try vol.alloc(count * @sizeOf(T));
        const items: [*]T = @ptrCast(@alignCast(bytes.ptr));
        return items[0..count];
    }

    pub fn freeSlice(vol: *Volume, comptime T: type, items: []T) void {
        if (items.len == 0) return;
        const bytes: [*]u8 = @ptrCast(items.ptr);
        vol.dev.free(bytes[0 .. items.len * @sizeOf(T)]);
    }

    pub fn now(vol: *Volume) u64 {
        return vol.dev.now();
    }

    // --- geometry ----------------------------------------------------------------

    /// What the label says made the volume's own: its sizes, its id, its
    /// buffers.
    pub fn takeLabel(vol: *Volume, label: *const layout.Label) Error!void {
        vol.label = label.*;
        vol.block_size = label.block_size;
        vol.block_shift = @intCast(log2(label.block_size));
        vol.write_unit = label.write_unit;
        vol.erase_size = label.erase_size;
        vol.block_count = label.block_count;
        vol.uuid = label.uuid;
        vol.map = vol.dev.mapped();
        if (vol.scratch.len != vol.block_size) {
            vol.free(vol.scratch);
            vol.scratch = &.{};
            vol.scratch = try vol.alloc(vol.block_size);
            vol.free(vol.bounce);
            vol.bounce = &.{};
            vol.bounce = try vol.alloc(vol.block_size);
            vol.free(vol.checked);
            vol.checked = &.{};
            vol.checked = try vol.alloc(vol.block_size);
            vol.free(vol.gather);
            vol.gather = &.{};
        }
        vol.checked_block = no_block;
        compress.release(vol);
        if (!vol.voltab_ready) {
            const table = try vol.alloc(layout.voltab_size);
            vol.voltab = @ptrCast(@alignCast(table.ptr));
            vol.voltab_ready = true;
        }
        vol.voltab.* = .{};
        if (vol.map != null) {
            vol.free(vol.verified);
            vol.verified = &.{};
            vol.verified = try vol.alloc(@intCast((vol.block_count + 7) / 8));
            vol.free(vol.data_checked);
            vol.data_checked = &.{};
            vol.data_checked = try vol.alloc(@intCast((vol.block_count + 7) / 8));
            @memset(vol.data_checked, 0);
        } else if (!vol.cache_ready or vol.cache.block_size != vol.block_size) {
            if (vol.cache_ready) vol.cache.deinit();
            vol.cache_ready = false;
            const blocks = if (vol.cache_blocks != 0) vol.cache_blocks else defaultCache(vol.block_size);
            if (!vol.cache.init(vol.dev, vol.block_size, blocks)) {
                if (!vol.cache.init(vol.dev, vol.block_size, 32)) return error.NoMemory;
            }
            vol.cache_ready = true;
        } else vol.cache.clear();
    }

    /// Everything the volume holds in memory given back.
    pub fn release(vol: *Volume) void {
        vol.dropDirty();
        vol.freeSlice([]u8, vol.dirty);
        vol.dirty = &.{};
        space_area.release(vol);
        journal_area.release(vol);
        snapshots_area.release(vol);
        vol.free(vol.verified);
        vol.verified = &.{};
        vol.free(vol.scratch);
        vol.scratch = &.{};
        vol.free(vol.bounce);
        vol.bounce = &.{};
        vol.free(vol.gather);
        vol.gather = &.{};
        vol.free(vol.checked);
        vol.checked = &.{};
        vol.checked_block = no_block;
        vol.free(vol.data_checked);
        vol.data_checked = &.{};
        compress.release(vol);
        if (vol.cache_ready) vol.cache.deinit();
        vol.cache_ready = false;
        if (vol.voltab_ready) {
            const bytes: [*]u8 = @ptrCast(vol.voltab);
            vol.dev.free(bytes[0..layout.voltab_size]);
        }
        vol.voltab_ready = false;
        vol.mounted = false;
    }

    /// The bytes of the volume's block `addr` on the medium.
    pub fn byteOf(vol: *const Volume, addr: u64) u64 {
        return vol.first_byte + (addr << vol.block_shift);
    }

    // --- reading -------------------------------------------------------------------

    /// The block at `addr` where it lies in memory, unchecked: on a medium
    /// read as memory only.
    pub fn mappedView(vol: *Volume, addr: u64) []const u8 {
        const at: usize = @intCast(vol.byteOf(addr));
        return vol.map.?[at..][0..vol.block_size];
    }

    /// Blocks read into a buffer of the caller's.
    pub fn readBlocks(vol: *Volume, addr: u64, into: []u8) Error!void {
        const count = @as(u64, into.len) >> vol.block_shift;
        if (addr >= vol.block_count or count > vol.block_count - addr) return error.Corrupt;
        if (vol.map) |base| {
            const at: usize = @intCast(vol.byteOf(addr));
            @memcpy(into, base[at..][0..into.len]);
            return;
        }
        if (!vol.dev.read(vol.byteOf(addr), into)) return error.Io;
    }

    /// File data: `into.len` bytes from byte `inner` of the run of blocks
    /// at `first`. Whole blocks go straight into `into`; only the edges
    /// pass through `bounce`.
    pub fn readData(vol: *Volume, first: u64, inner: u64, into: []u8) Error!void {
        const size = vol.block_size;
        const last_byte = inner + into.len;
        const blocks = (last_byte + size - 1) >> vol.block_shift;
        if (first >= vol.block_count or blocks > vol.block_count - first) return error.Corrupt;
        if (vol.map) |base| {
            const at: usize = @intCast(vol.byteOf(first) + inner);
            @memcpy(into, base[at..][0..into.len]);
            return;
        }
        var done: usize = 0;
        while (done < into.len) {
            const offset = inner + done;
            const block = first + (offset >> vol.block_shift);
            const within: usize = @intCast(offset & (size - 1));
            const left = into.len - done;
            if (within == 0 and left >= size) {
                const whole = left & ~@as(usize, size - 1);
                if (!vol.dev.read(vol.byteOf(block), into[done..][0..whole])) return error.Io;
                done += whole;
                continue;
            }
            if (!vol.dev.read(vol.byteOf(block), vol.bounce)) return error.Io;
            const piece = @min(left, size - within);
            @memcpy(into[done..][0..piece], vol.bounce[within..][0..piece]);
            done += piece;
        }
    }

    /// File data as `readData` reads it, each block it touches checked
    /// against its crc in `crcs` - the run's, from its first block - before
    /// a byte of it is given: BadChecksum for one that does not match.
    pub fn readChecked(vol: *Volume, first: u64, inner: u64, into: []u8, crcs: []const u32) Error!void {
        const size = vol.block_size;
        const last_byte = inner + into.len;
        const blocks = (last_byte + size - 1) >> vol.block_shift;
        if (first >= vol.block_count or blocks > vol.block_count - first or blocks > crcs.len) return error.Corrupt;
        var done: usize = 0;
        while (done < into.len) {
            const offset = inner + done;
            const index: usize = @intCast(offset >> vol.block_shift);
            const block = first + index;
            const within: usize = @intCast(offset & (size - 1));
            const left = into.len - done;
            if (vol.map != null) {
                const view = vol.mappedView(block);
                if (!bitOf(vol.data_checked, block)) {
                    if (layout.crcSeeded(&vol.uuid, view) != crcs[index]) return error.BadChecksum;
                    setBit(vol.data_checked, block, true);
                }
                const piece = @min(left, size - within);
                @memcpy(into[done..][0..piece], view[within..][0..piece]);
                done += piece;
                continue;
            }
            if (within == 0 and left >= size) {
                const whole = left & ~@as(usize, size - 1);
                const target = into[done..][0..whole];
                if (!vol.dev.read(vol.byteOf(block), target)) return error.Io;
                var at: usize = 0;
                while (at < whole) : (at += size) {
                    if (layout.crcSeeded(&vol.uuid, target[at..][0..size]) != crcs[index + at / size]) return error.BadChecksum;
                }
                done += whole;
                continue;
            }
            if (vol.checked_block != block) {
                vol.checked_block = no_block;
                if (!vol.dev.read(vol.byteOf(block), vol.checked)) return error.Io;
                if (layout.crcSeeded(&vol.uuid, vol.checked) != crcs[index]) return error.BadChecksum;
                vol.checked_block = block;
            }
            const piece = @min(left, size - within);
            @memcpy(into[done..][0..piece], vol.checked[within..][0..piece]);
            done += piece;
        }
    }

    /// What is kept of blocks [addr, addr + count) as file data read
    /// forgotten: they are being written.
    fn forgetData(vol: *Volume, addr: u64, count: u64) void {
        if (vol.checked_block >= addr and vol.checked_block - addr < count) vol.checked_block = no_block;
        if (vol.data_checked.len != 0) {
            var at = addr;
            while (at < addr + count) : (at += 1) setBit(vol.data_checked, at, false);
        }
        compress.forget(vol, addr, count);
    }

    fn isVerified(vol: *const Volume, addr: u64) bool {
        if (vol.verified.len == 0) return false;
        const at: usize = @intCast(addr);
        return vol.verified[at / 8] & (@as(u8, 1) << @intCast(at % 8)) != 0;
    }

    fn setVerified(vol: *Volume, addr: u64, on: bool) void {
        if (vol.verified.len == 0) return;
        const at: usize = @intCast(addr);
        const bit = @as(u8, 1) << @intCast(at % 8);
        if (on) vol.verified[at / 8] |= bit else vol.verified[at / 8] &= ~bit;
    }

    /// A node of tree `tree`, read from `addr` where a pointer that said
    /// generation `gen` led, and checked. Good until the next node is
    /// asked for. The cache holds nodes only, each checked when it was
    /// read, so a node found there needs only its generation compared.
    pub fn nodeView(vol: *Volume, addr: u64, gen: u64, tree: u32) Error![]const u8 {
        if (addr >= vol.block_count) return error.Corrupt;
        if (vol.map != null) {
            const block = vol.mappedView(addr);
            if (vol.isVerified(addr)) {
                const header = headerOf(block);
                if (header.gen != gen or header.tree != tree) return error.Corrupt;
                return block;
            }
            try vol.checkNode(block, addr, gen, tree);
            vol.setVerified(addr, true);
            return block;
        }
        if (vol.cache.find(addr)) |block| {
            const header = headerOf(block);
            if (header.gen != gen or header.tree != tree) return error.Corrupt;
            return block;
        }
        const block = vol.cache.insert(addr) orelse return error.NoMemory;
        if (!vol.dev.read(vol.byteOf(addr), block)) {
            vol.cache.forget(addr);
            return error.Io;
        }
        vol.checkNode(block, addr, gen, tree) catch |err| {
            vol.cache.forget(addr);
            return err;
        };
        return block;
    }

    /// Whether a block read from `addr` is a sound node of `tree`, written
    /// in generation `gen`.
    pub fn checkNode(vol: *Volume, block: []const u8, addr: u64, gen: u64, tree: u32) Error!void {
        const header = headerOf(block);
        if (header.magic != layout.node_magic or header.self != addr or header.gen != gen or header.tree != tree) return error.Corrupt;
        if (!eqlBytes(&header.uuid, &vol.uuid)) return error.Corrupt;
        if (!vol.nodeShapeOk(block)) return error.Corrupt;
        if (nodeChecksum(vol, block) != header.checksum) return error.Corrupt;
    }

    /// Every count and offset in a node inside its block.
    fn nodeShapeOk(vol: *const Volume, block: []const u8) bool {
        const header = headerOf(block);
        const size = vol.block_size;
        if (header.tree == layout.tree_object or header.tree == layout.tree_space) {
            if (header.level >= max_height) return false;
            if (header.level == 0) {
                const end = @as(u64, layout.node_header_size) + @as(u64, header.count) * @sizeOf(layout.LeafEntry);
                if (end > header.heap or header.heap > size) return false;
                for (btree.leafEntries(block)) |entry| {
                    if (entry.data_off < header.heap or entry.data_off % 8 != 0) return false;
                    if (@as(u64, entry.data_off) + entry.data_len > size) return false;
                }
            } else {
                if (header.count == 0) return false;
                const end = @as(u64, layout.node_header_size) + @as(u64, header.count) * @sizeOf(layout.InnerEntry);
                if (end > size) return false;
            }
            return true;
        }
        if (header.tree == layout.tree_deadlist) {
            return header.count <= layout.deadEntries(size);
        }
        return false;
    }

    // --- writing ------------------------------------------------------------------

    /// A block the volume is about to write for the first time since it
    /// was taken, made writable: erased on flash, unless it is known to be
    /// erased already.
    pub fn prepare(vol: *Volume, addr: u64, count: u64) Error!void {
        if (vol.erase_size == 0) return;
        var at = addr;
        while (at < addr + count) : (at += 1) {
            if (space_area.isErased(vol, at)) continue;
            if (!vol.unclean and vol.map != null and blank(vol.mappedView(at))) {
                space_area.setErased(vol, at, true);
                continue;
            }
            if (!vol.dev.erase(vol.byteOf(at), vol.block_size)) return error.Io;
            space_area.setErased(vol, at, true);
        }
    }

    /// Bytes written at block `addr`, offset `offset`: the block was
    /// prepared, and no unit of it written since.
    pub fn writeAt(vol: *Volume, addr: u64, offset: u32, from: []const u8) Error!void {
        if (vol.failed or vol.read_only) return error.ReadOnly;
        if (addr >= vol.block_count) return error.Corrupt;
        if (offset == 0) space_area.setErased(vol, addr, false);
        if (vol.map == null) vol.cache.forget(addr) else vol.setVerified(addr, false);
        vol.forgetData(addr, 1);
        if (!vol.dev.write(vol.byteOf(addr) + offset, from)) {
            vol.failed = true;
            return error.Io;
        }
    }

    /// Whole blocks written from `from`, at `addr` on.
    pub fn writeBlocks(vol: *Volume, addr: u64, from: []const u8) Error!void {
        const count = @as(u64, from.len) >> vol.block_shift;
        if (addr >= vol.block_count or count > vol.block_count - addr) return error.Corrupt;
        try vol.prepare(addr, count);
        if (vol.failed or vol.read_only) return error.ReadOnly;
        var at = addr;
        while (at < addr + count) : (at += 1) {
            space_area.setErased(vol, at, false);
            if (vol.map == null) vol.cache.forget(at) else vol.setVerified(at, false);
        }
        vol.forgetData(addr, count);
        vol.unordered = true;
        if (!vol.dev.write(vol.byteOf(addr), from)) {
            vol.failed = true;
            return error.Io;
        }
    }

    /// A node written to `addr`: its header made its own and sealed. On a
    /// medium read as memory it is checked again the first time it is
    /// read, from what the medium holds: a write that did not land whole
    /// is found there, not taken for the node.
    pub fn writeNode(vol: *Volume, addr: u64, block: []u8) Error!void {
        const header = headerOfMut(block);
        header.self = addr;
        header.uuid = vol.uuid;
        header.magic = layout.node_magic;
        header.checksum = nodeChecksum(vol, block);
        try vol.writeBlocks(addr, block);
        if (vol.map == null) {
            if (vol.cache.insert(addr)) |buffer| @memcpy(buffer, block);
        }
    }

    /// Everything written so far on the medium itself.
    pub fn barrier(vol: *Volume) Error!void {
        if (vol.failed) return error.ReadOnly;
        if (!vol.dev.update()) {
            vol.failed = true;
            return error.Io;
        }
        vol.unordered = false;
    }

    // --- nodes being changed --------------------------------------------------------

    /// A new node in memory, cleared: its number in the dirty table.
    pub fn newDirty(vol: *Volume) Error!u32 {
        var slot: usize = 0;
        while (slot < vol.dirty.len and vol.dirty[slot].len != 0) slot += 1;
        if (slot == vol.dirty.len) {
            const grown = try vol.allocSlice([]u8, if (vol.dirty.len == 0) 32 else vol.dirty.len * 2);
            for (grown) |*entry| entry.* = &.{};
            @memcpy(grown[0..vol.dirty.len], vol.dirty);
            vol.freeSlice([]u8, vol.dirty);
            vol.dirty = grown;
        }
        const buffer = try vol.alloc(vol.block_size);
        vol.dirty[slot] = buffer;
        vol.dirty_count += 1;
        return @intCast(slot);
    }

    pub fn dirtyBuffer(vol: *Volume, slot: u32) []u8 {
        return vol.dirty[slot];
    }

    pub fn freeDirty(vol: *Volume, slot: u32) void {
        vol.free(vol.dirty[slot]);
        vol.dirty[slot] = &.{};
        vol.dirty_count -= 1;
    }

    /// Every node being changed dropped unwritten: the medium went, or the
    /// volume is put away after a failure.
    pub fn dropDirty(vol: *Volume) void {
        for (vol.dirty, 0..) |entry, slot| {
            if (entry.len != 0) vol.freeDirty(@intCast(slot));
        }
    }
};

/// The cache's default size: about a megabyte.
fn defaultCache(block_size: u32) u32 {
    const blocks = (1024 * 1024) / block_size;
    return if (blocks < 32) 32 else blocks;
}

pub fn log2(value: u32) u32 {
    var shift: u32 = 0;
    while ((@as(u64, 1) << @intCast(shift)) < value) shift += 1;
    return shift;
}

pub fn headerOf(block: []const u8) *const layout.NodeHeader {
    return @ptrCast(@alignCast(block.ptr));
}

pub fn headerOfMut(block: []u8) *layout.NodeHeader {
    return @ptrCast(@alignCast(block.ptr));
}

/// A node's checksum: seeded, over its header up to the checksum, its
/// entries and its data - never the room between them.
pub fn nodeChecksum(vol: *const Volume, block: []const u8) u32 {
    const header = headerOf(block);
    var crc = layout.seeded(&vol.uuid);
    crc = layout.crcAdd(crc, block[0..@offsetOf(layout.NodeHeader, "checksum")]);
    const entries_end: usize = switch (header.tree) {
        layout.tree_deadlist => layout.node_header_size + @sizeOf(layout.DeadHeader) + @as(usize, header.count) * @sizeOf(layout.DeadEntry),
        else => if (header.level == 0)
            layout.node_header_size + @as(usize, header.count) * @sizeOf(layout.LeafEntry)
        else
            layout.node_header_size + @as(usize, header.count) * @sizeOf(layout.InnerEntry),
    };
    crc = layout.crcAdd(crc, block[layout.node_header_size..entries_end]);
    if (header.tree != layout.tree_deadlist and header.level == 0) crc = layout.crcAdd(crc, block[header.heap..vol.block_size]);
    return layout.crcEnd(crc);
}

/// A bit of a bitmap a bit a block, false past its end.
fn bitOf(bits: []const u8, addr: u64) bool {
    if (addr >= @as(u64, bits.len) * 8) return false;
    const at: usize = @intCast(addr);
    return bits[at / 8] & (@as(u8, 1) << @intCast(at % 8)) != 0;
}

fn setBit(bits: []u8, addr: u64, on: bool) void {
    if (addr >= @as(u64, bits.len) * 8) return;
    const at: usize = @intCast(addr);
    const bit = @as(u8, 1) << @intCast(at % 8);
    if (on) bits[at / 8] |= bit else bits[at / 8] &= ~bit;
}

pub fn eqlBytes(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x != y) return false;
    }
    return true;
}

/// Whether a block reads as erased flash.
pub fn blank(block: []const u8) bool {
    const words: [*]const u32 = @ptrCast(@alignCast(block.ptr));
    for (words[0 .. block.len / 4]) |word| {
        if (word != 0xFFFF_FFFF) return false;
    }
    return true;
}
