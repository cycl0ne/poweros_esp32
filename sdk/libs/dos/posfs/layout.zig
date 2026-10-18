// SPDX-License-Identifier: MIT
//! posfs on the medium: every structure the handler writes, and the
//! checksum that guards each one.
//!
//! A volume is a run of blocks of one size, chosen at format and kept in
//! the label (a power of two from 1 to 64 KiB). Every address is a block
//! number from the volume's first block, every number little-endian, and
//! every field 32 or 64 bits wide on its natural boundary:
//!
//!     block 0                 the label (written once, at format)
//!     blocks 1..8             checkpoint ring A
//!     blocks 9..count-10      the pool: tree nodes, file data, bitmaps,
//!                             journal blocks, the volume table, deadlists
//!     blocks count-9..count-2 checkpoint ring B
//!     block count-1           the label's copy
//!
//! **A checkpoint** is one slot in a ring: the roots of the object tree and
//! the space tree, the volume table, and where in the journal the changes
//! since begin. Checkpoints alternate between the rings, so the newest and
//! the one before it are never in the same block.
//!
//! **The trees** are B+trees of one block a node. A pointer to a node
//! carries the generation the node was written in, and the node carries
//! its own address and the volume's id: a node read from the wrong place,
//! half written or left by an earlier volume fails one of the three.
//!
//! **The journal** is a chain of blocks of records, each record one
//! change as it was asked for (create, rename, a file's new content).
//! A record is written into a unit of the medium that has never been
//! written since its block was taken, and its checksum is seeded with the
//! volume's id and the mount's `life`, so a record left over from before
//! is never taken for a new one.
//!
//! **Every checksum** is the reflected crc32 (polynomial 0xEDB88320), run
//! first over the volume's id and then over the bytes it covers. It
//! covers only bytes the handler wrote with meaning - never padding, never
//! the free space in a node - and is the last field of what it guards.

const dos = @import("../dos.zig");
const posfs = @import("posfs.zig");

// --- magic numbers -----------------------------------------------------------

/// The label's magic, "POSL".
pub const label_magic: u32 = 0x504F_534C;
/// A tree node's, a deadlist block's and the volume table's, "PNOD".
pub const node_magic: u32 = 0x504E_4F44;
/// A journal block's, "PJNL".
pub const journal_magic: u32 = 0x504A_4E4C;
/// A checkpoint slot's, "PCKP".
pub const checkpoint_magic: u32 = 0x5043_4B50;

/// The format this code writes and the only one it reads.
pub const format_version: u32 = 1;

/// The label's feature masks. A volume using a feature in `incompat`
/// cannot be read by a handler that does not know it; one in `ro_compat`
/// can be read but not written; one in `compat` is no matter. A handler
/// refuses a volume with a bit it does not know in the first, and mounts
/// it read-only with one in the second.
pub const INCOMPAT_LZ4: u32 = 1 << 0;
pub const RO_COMPAT_CHECKSUMS: u32 = 1 << 0;
pub const RO_COMPAT_SNAPSHOTS: u32 = 1 << 1;
pub const COMPAT_RECYCLED: u32 = 1 << 0;

pub const known_incompat: u32 = INCOMPAT_LZ4;
pub const known_ro_compat: u32 = RO_COMPAT_CHECKSUMS | RO_COMPAT_SNAPSHOTS;

/// The case fold the root starts with (`fold.zig`'s table 1), and the name
/// hash (the top 24 bits of the crc32 of the folded name).
pub const fold_1: u32 = 1;
pub const name_hash_1: u32 = 1;

/// The blocks of each checkpoint ring.
pub const ring_blocks: u32 = 8;

/// The fewest blocks a volume has: the label and its copy, both rings,
/// and a pool that holds a first tree, a journal and room to work.
pub const min_blocks: u64 = 64;

/// The most blocks: addresses keep their top bits for the handler's own
/// use in memory.
pub const max_blocks: u64 = 1 << 48;

/// What a compressed extent's logical chunk is, as a power of two, and
/// in bytes.
pub const chunk_shift: u32 = 16;
pub const chunk_size: u32 = 1 << chunk_shift;

// --- the label ---------------------------------------------------------------

/// Block 0, and its copy in the last block: what the volume is. Written
/// at format and never again, so every other structure can be found from
/// it.
pub const Label = extern struct {
    magic: u32 = label_magic,
    version: u32 = format_version,
    incompat: u32 = 0,
    ro_compat: u32 = 0,
    compat: u32 = 0,
    /// The bytes of a block, a power of two.
    block_size: u32 = 0,
    /// The blocks of the volume, both labels included.
    block_count: u64 align(4) = 0,
    /// The bytes the journal and the slots are written in: the device's
    /// write unit, at least 256.
    write_unit: u32 = 0,
    /// The device's erase unit, 0 when it needs no erasing.
    erase_size: u32 = 0,
    /// The bytes of a checkpoint slot.
    slot_size: u32 = 0,
    /// The blocks of each ring.
    ring_blocks: u32 = ring_blocks,
    /// The first block of each ring.
    ring_a: u64 align(4) = 0,
    ring_b: u64 align(4) = 0,
    /// The case fold a new directory gets (`fold_1`).
    fold_default: u32 = fold_1,
    /// How a name is hashed into its directory position (`name_hash_1`).
    name_hash: u32 = name_hash_1,
    /// The most bytes a file keeps in its tree entry rather than a block.
    inline_max: u32 = 0,
    /// The logical chunk of a compressed extent, as a power of two.
    chunk_shift: u32 = chunk_shift,
    /// When the volume was formatted, in microseconds since 1 Jan 1978.
    created: u64 align(4) = 0,
    /// The volume's id, from the hardware's random numbers. Every other
    /// checksum is seeded with it.
    uuid: [16]u8 = @splat(0),
    /// 0 in block 0, 1 in the copy.
    copy: u32 = 0,
    /// crc32 of every byte before it.
    checksum: u32 = 0,
};

// --- tree nodes ----------------------------------------------------------------

/// Which tree a node belongs to, or what else a block with a node header
/// is.
pub const tree_object: u32 = 1;
pub const tree_space: u32 = 2;
pub const tree_voltab: u32 = 3;
pub const tree_deadlist: u32 = 4;

/// The first 64 bytes of every tree node, of the volume table and of a
/// deadlist block. A reader checks `self` against where it read the
/// block, `uuid` against the label, and `gen` against the pointer it
/// followed.
pub const NodeHeader = extern struct {
    /// The block this was written to.
    self: u64 align(4) = 0,
    /// The generation it was written in: the checkpoint it belongs to.
    gen: u64 align(4) = 0,
    /// tree_object, tree_space, ...
    tree: u32 = 0,
    /// 0 for a leaf.
    level: u32 = 0,
    /// The entries in the node.
    count: u32 = 0,
    /// Where a leaf's data begins: it grows down from the block's end.
    heap: u32 = 0,
    flags: u32 = 0,
    /// Bytes of the heap no entry points at any more.
    dead: u32 = 0,
    uuid: [16]u8 = @splat(0),
    magic: u32 = node_magic,
    /// Seeded crc32 of the bytes before it, the entries, and the heap.
    checksum: u32 = 0,
};

pub const node_header_size: u32 = @sizeOf(NodeHeader);

/// What a tree is sorted by: the object, what kind of item, and where in
/// the object (a file offset, a directory position, ...).
pub const Key = extern struct {
    oid: u64 align(4) = 0,
    kind: u32 = 0,
    reserved: u32 = 0,
    offset: u64 align(4) = 0,

    pub fn order(a: Key, b: Key) Order {
        if (a.oid != b.oid) return if (a.oid < b.oid) .lt else .gt;
        if (a.kind != b.kind) return if (a.kind < b.kind) .lt else .gt;
        if (a.offset != b.offset) return if (a.offset < b.offset) .lt else .gt;
        return .eq;
    }

    pub fn eql(a: Key, b: Key) bool {
        return a.order(b) == .eq;
    }

    pub fn lessThan(a: Key, b: Key) bool {
        return a.order(b) == .lt;
    }
};

pub const Order = enum { lt, eq, gt };

/// The smallest and the largest key.
pub const key_min: Key = .{};
pub const key_max: Key = .{ .oid = ~@as(u64, 0), .kind = ~@as(u32, 0), .reserved = 0, .offset = ~@as(u64, 0) };

/// A leaf's entry: the key, and where its item's data is in the block.
pub const LeafEntry = extern struct {
    key: Key = .{},
    data_off: u32 = 0,
    data_len: u32 = 0,
};

/// An inner node's entry: the smallest key under the child, the child,
/// and the generation the child was written in.
pub const InnerEntry = extern struct {
    key: Key = .{},
    child: u64 align(4) = 0,
    child_gen: u64 align(4) = 0,
};

/// What a leaf of `block_size` bytes holds for entries and data.
pub fn leafRoom(block_size: u32) u32 {
    return block_size - node_header_size;
}

/// The most entries an inner node holds.
pub fn innerCapacity(block_size: u32) u32 {
    return (block_size - node_header_size) / @sizeOf(InnerEntry);
}

/// The most data one item holds, so that any three fit in a leaf and a
/// leaf split always leaves both halves room.
pub fn itemMax(block_size: u32) u32 {
    const third = leafRoom(block_size) / 3;
    return (third - @sizeOf(LeafEntry)) & ~@as(u32, 7);
}

/// The most crcs a csum item holds: what one item takes, at most 256. A
/// checksummed extent has no more blocks than that.
pub fn csumPerItem(block_size: u32) u32 {
    const most = itemMax(block_size) / 4;
    return if (most < max_csums) most else max_csums;
}

pub const max_csums: u32 = 256;

/// The most bytes of a file kept inline, in its tree entry.
pub fn inlineMax(block_size: u32) u32 {
    const most = itemMax(block_size);
    return if (most < 1024) most else 1024;
}

// --- object tree items -----------------------------------------------------------

/// What an item is. The order is the order of an object's items in the
/// tree, so what is read together lies together.
pub const Kind = enum(u32) {
    /// (oid, 0): Inode.
    inode = 1,
    /// (oid, 0): the comment's bytes.
    comment = 2,
    /// (oid, offset): a soft link's target, in pieces of at most an item.
    link_target = 3,
    /// (oid, 0): Recycle, for an object in Recycled.
    recycle = 4,
    /// (oid, 0): a small file's content.
    inline_data = 5,
    /// (parent, position): DirEntry and the name.
    dir_entry = 6,
    /// (oid, file offset): Extent.
    extent = 7,
    /// (oid, file offset of the extent): a u32 crc per block of a raw,
    /// checksummed extent, each seeded with the volume's id.
    csum = 8,
    /// (orphan_oid, oid): Orphan, a delete or truncate finished as a job.
    orphan = 9,
    /// (recycled_oid, 0): RecycleStats.
    recycle_stats = 10,
    /// (recycled_oid, rseq): RecycleQueue, the order Recycled is emptied in.
    recycle_queue = 11,
    /// Kept for attributes beyond the ones dos has.
    xattr = 12,
    /// (0, group): Bmap, in the space tree.
    bmap = 32,
    _,
};

/// Inode.flags
pub const INODE_INLINE: u32 = 1 << 0;
pub const INODE_ORPHAN: u32 = 1 << 1;
/// Never compress this file's data / never checksum it.
pub const INODE_NOCOMP: u32 = 1 << 2;
pub const INODE_NOCSUM: u32 = 1 << 3;

/// An object: everything about it but its names, its comment and its
/// content.
pub const Inode = extern struct {
    /// dos's ST_FILE, ST_USERDIR, ST_ROOT, ST_SOFTLINK.
    entry_type: i32 = 0,
    /// fib_Protection, the whole word.
    protection: u32 = 0,
    owner_uid: u32 = 0,
    owner_gid: u32 = 0,
    /// The names it has (a file's hard links); 1 for a directory.
    nlink: u32 = 1,
    flags: u32 = 0,
    /// A directory's case fold.
    fold: u32 = 0,
    /// Where its name is in `parent`.
    pos: u32 = 0,
    /// The directory it is in, and so `pos`: exact for a directory and a
    /// soft link. A file's is one of its names, or 0 once the name it gave
    /// went while others stayed - a file's names are not found from it -
    /// until it is given a new one.
    parent: u64 align(4) = 0,
    /// A file's bytes.
    size: u64 align(4) = 0,
    /// The blocks its data takes on the medium.
    blocks: u64 align(4) = 0,
    /// A directory's entries.
    entries: u64 align(4) = 0,
    /// Modified (fib_Date), changed (any of its attributes) and made, in
    /// microseconds since 1 Jan 1978.
    mtime: u64 align(4) = 0,
    ctime: u64 align(4) = 0,
    btime: u64 align(4) = 0,
};

/// A name in a directory, followed by its bytes.
pub const DirEntry = extern struct {
    oid: u64 align(4) = 0,
    entry_type: i32 = 0,
    name_len: u32 = 0,
};

/// Extent.flags
pub const EXTENT_COMPRESSED: u32 = 1 << 0;
pub const EXTENT_CHECKSUMMED: u32 = 1 << 1;
/// The compression, in bits 8 to 15.
pub const EXTENT_ALG_SHIFT: u5 = 8;
pub const alg_lz4: u32 = 1;

/// A run of a file's data: `length` bytes from its key's offset, stored
/// in `blocks` blocks from `block`. A compressed one holds one chunk,
/// `stored` bytes of it on the medium.
pub const Extent = extern struct {
    block: u64 align(4) = 0,
    /// The generation the extent entered the tree in, which decides
    /// whether a snapshot still holds its blocks when it goes.
    birth: u64 align(4) = 0,
    /// Logical bytes.
    length: u64 align(4) = 0,
    blocks: u32 = 0,
    flags: u32 = 0,
    /// A compressed extent's bytes on the medium; 0 for a raw one.
    stored: u32 = 0,
    /// A compressed extent's crc32 of its stored bytes.
    crc: u32 = 0,

    pub fn compressed(e: *const Extent) bool {
        return e.flags & EXTENT_COMPRESSED != 0;
    }

    pub fn checksummed(e: *const Extent) bool {
        return e.flags & EXTENT_CHECKSUMMED != 0;
    }
};

/// An object in Recycled: where it was and when it went. Its old name
/// follows.
pub const Recycle = extern struct {
    parent: u64 align(4) = 0,
    deleted: u64 align(4) = 0,
    rseq: u64 align(4) = 0,
    name_len: u32 = 0,
    reserved: u32 = 0,
};

/// A delete or truncate that frees its blocks over several checkpoints:
/// the object's data from `from` on is still to go.
pub const Orphan = extern struct {
    from: u64 align(4) = 0,
    /// ORPHAN_DELETE: the object goes once its data has.
    flags: u32 = 0,
    reserved: u32 = 0,
};

pub const ORPHAN_DELETE: u32 = 1 << 0;

/// What Recycled holds, and the next number of its queue.
pub const RecycleStats = extern struct {
    count: u64 align(4) = 0,
    bytes: u64 align(4) = 0,
    next_rseq: u64 align(4) = 1,
};

pub const RecycleQueue = extern struct {
    oid: u64 align(4) = 0,
};

/// A group of the volume's blocks in the space tree: where its bitmap is
/// and its crc. A group's bits are the item's own data, after this, when
/// they fit in an item (`block` is 0).
pub const Bmap = extern struct {
    block: u64 align(4) = 0,
    gen: u64 align(4) = 0,
    free: u32 = 0,
    crc: u32 = 0,
};

/// The blocks a bitmap group covers: a block's bits.
pub fn groupBlocks(block_size: u32) u64 {
    return @as(u64, block_size) * 8;
}

// --- the journal -------------------------------------------------------------------

/// The start of a journal block. `next` is taken when the block is, so a
/// record never waits for an allocation and replay knows the chain.
pub const JournalHeader = extern struct {
    /// The block's place in the journal, counted over the volume's life.
    jseq: u64 align(4) = 0,
    next: u64 align(4) = 0,
    /// The lsn of the first record in it.
    first_lsn: u64 align(4) = 0,
    /// The mount that wrote it.
    life: u64 align(4) = 0,
    uuid: [16]u8 = @splat(0),
    magic: u32 = journal_magic,
    checksum: u32 = 0,
};

/// A record's start; its payload follows, padded to eight bytes. The
/// padding is not covered.
pub const RecordHeader = extern struct {
    /// Counted over the volume's life, one a record, never twice.
    lsn: u64 align(4) = 0,
    kind: u32 = 0,
    /// The payload's bytes, without the padding.
    len: u32 = 0,
    flags: u32 = 0,
    /// Seeded with the id and the life, over this header and the payload.
    checksum: u32 = 0,
};

/// RecordHeader.flags: more of this record's group follows. A group is
/// applied whole or not at all.
pub const RECORD_CONTINUED: u32 = 1 << 0;

pub const Record = enum(u32) {
    create = 1,
    link = 2,
    unlink = 3,
    recycle = 4,
    rename = 5,
    set_attr = 6,
    commit = 7,
    _,
};

/// Record.create: an object made in a directory. The name follows, then
/// a soft link's target.
pub const CreateRecord = extern struct {
    oid: u64 align(4) = 0,
    parent: u64 align(4) = 0,
    pos: u64 align(4) = 0,
    time: u64 align(4) = 0,
    entry_type: i32 = 0,
    protection: u32 = 0,
    owner_uid: u32 = 0,
    owner_gid: u32 = 0,
    fold: u32 = 0,
    name_len: u32 = 0,
    link_len: u32 = 0,
    reserved: u32 = 0,
};

/// Record.link: another name for a file. The name follows.
pub const LinkRecord = extern struct {
    oid: u64 align(4) = 0,
    parent: u64 align(4) = 0,
    pos: u64 align(4) = 0,
    time: u64 align(4) = 0,
    name_len: u32 = 0,
    reserved: u32 = 0,
};

/// Record.unlink: a name gone. When it was the object's last, the object
/// goes too - at once, or as a job (`mode`).
pub const UnlinkRecord = extern struct {
    parent: u64 align(4) = 0,
    pos: u64 align(4) = 0,
    oid: u64 align(4) = 0,
    time: u64 align(4) = 0,
    mode: u32 = 0,
    reserved: u32 = 0,
};

pub const unlink_now: u32 = 0;
pub const unlink_job: u32 = 1;

/// Record.recycle: an object's last name moved into Recycled under `name`
/// (which follows) at `new_pos`.
pub const RecycleRecord = extern struct {
    parent: u64 align(4) = 0,
    pos: u64 align(4) = 0,
    oid: u64 align(4) = 0,
    time: u64 align(4) = 0,
    new_pos: u64 align(4) = 0,
    rseq: u64 align(4) = 0,
    name_len: u32 = 0,
    reserved: u32 = 0,
};

/// Record.rename: a name moved, perhaps to another directory. The new
/// name follows. Out of Recycled it is an undelete.
pub const RenameRecord = extern struct {
    from_parent: u64 align(4) = 0,
    from_pos: u64 align(4) = 0,
    to_parent: u64 align(4) = 0,
    to_pos: u64 align(4) = 0,
    oid: u64 align(4) = 0,
    time: u64 align(4) = 0,
    name_len: u32 = 0,
    flags: u32 = 0,
};

/// SetAttrRecord.mask
pub const ATTR_PROTECTION: u32 = 1 << 0;
pub const ATTR_OWNER: u32 = 1 << 1;
pub const ATTR_DATE: u32 = 1 << 2;
pub const ATTR_COMMENT: u32 = 1 << 3;

/// Record.set_attr: what `mask` names, set. A comment follows.
pub const SetAttrRecord = extern struct {
    oid: u64 align(4) = 0,
    time: u64 align(4) = 0,
    date: u64 align(4) = 0,
    mask: u32 = 0,
    protection: u32 = 0,
    owner_uid: u32 = 0,
    owner_gid: u32 = 0,
    comment_len: u32 = 0,
    reserved: u32 = 0,
};

/// CommitRecord.flags
/// Drop everything the file held before.
pub const COMMIT_TRUNC_ALL: u32 = 1 << 0;
/// The content is the inline bytes that follow.
pub const COMMIT_INLINE: u32 = 1 << 1;
/// Drop what the file held at and past `trim`, before the new data goes in.
pub const COMMIT_TRIM: u32 = 1 << 2;
/// Drop it as a job, over several checkpoints.
pub const COMMIT_TRIM_JOB: u32 = 1 << 3;

/// Record.commit: a file's new content, at close or flush. `specs`
/// ExtSpecs follow, each with its crcs, then `inline_len` bytes.
pub const CommitRecord = extern struct {
    oid: u64 align(4) = 0,
    size: u64 align(4) = 0,
    mtime: u64 align(4) = 0,
    time: u64 align(4) = 0,
    /// COMMIT_TRIM's offset.
    trim: u64 align(4) = 0,
    flags: u32 = 0,
    specs: u32 = 0,
    inline_len: u32 = 0,
    reserved: u32 = 0,
};

/// A run of new data a commit puts into the file at `offset`. A raw,
/// checksummed one (EXTENT_CHECKSUMMED) is followed by a u32 crc per
/// block, at most `csumPerItem` of them. A compressed one
/// (EXTENT_COMPRESSED) is one chunk at a chunk's offset: `length` bytes
/// of the file in `stored` bytes of `blocks` blocks, `crc` over those.
pub const ExtSpec = extern struct {
    offset: u64 align(4) = 0,
    block: u64 align(4) = 0,
    length: u64 align(4) = 0,
    blocks: u32 = 0,
    flags: u32 = 0,
    stored: u32 = 0,
    crc: u32 = 0,
};

// --- checkpoints -------------------------------------------------------------------

/// CheckpointSlot.flags: written by an unmount, with nothing after it in
/// the journal.
pub const CHECKPOINT_CLEAN: u32 = 1 << 0;

/// A checkpoint: everything mount starts from.
pub const CheckpointSlot = extern struct {
    gen: u64 align(4) = 0,
    life: u64 align(4) = 0,
    /// The lsn the first record after this checkpoint has.
    next_lsn: u64 align(4) = 0,
    /// Where replay starts: the journal block, its jseq, and the offset of
    /// the first record in it.
    jblock: u64 align(4) = 0,
    jseq: u64 align(4) = 0,
    joffset: u32 = 0,
    flags: u32 = 0,
    obj_root: u64 align(4) = 0,
    obj_gen: u64 align(4) = 0,
    obj_height: u32 = 0,
    space_height: u32 = 0,
    space_root: u64 align(4) = 0,
    space_gen: u64 align(4) = 0,
    /// The checkpoint before's space tree: its blocks stay untouched
    /// until two checkpoints after a mount.
    prev_space_root: u64 align(4) = 0,
    prev_space_gen: u64 align(4) = 0,
    voltab: u64 align(4) = 0,
    voltab_gen: u64 align(4) = 0,
    next_oid: u64 align(4) = 0,
    free_blocks: u64 align(4) = 0,
    /// Where the allocator goes on from, so wear keeps moving over boots.
    alloc_cursor: u64 align(4) = 0,
    /// When it was written, in microseconds since 1 Jan 1978.
    time: u64 align(4) = 0,
    uuid: [16]u8 = @splat(0),
    magic: u32 = checkpoint_magic,
    checksum: u32 = 0,
};

/// The bytes of a slot: the write unit, at least 256.
pub fn slotSize(write_unit: u32) u32 {
    return if (write_unit < 256) 256 else write_unit;
}

// --- the volume table ------------------------------------------------------------

/// The volume table's bytes, in as many blocks as that takes.
pub const voltab_size: u32 = 4096;

pub fn voltabBlocks(block_size: u32) u32 {
    return (voltab_size + block_size - 1) / block_size;
}

/// VolTab.flags: the switches C:PosFS sets.
pub const VT_RECYCLED: u32 = 1 << 0;
pub const VT_CHECKSUMS: u32 = 1 << 1;
pub const VT_COMPRESS: u32 = 1 << 2;

/// A chain of deadlist blocks: the newest first.
pub const DeadList = extern struct {
    head: u64 align(4) = 0,
    head_gen: u64 align(4) = 0,
    count: u64 align(4) = 0,
};

/// A deadlist block's start, after its node header.
pub const DeadHeader = extern struct {
    next: u64 align(4) = 0,
    next_gen: u64 align(4) = 0,
};

/// A run of blocks a snapshot still holds after the live tree let go.
pub const DeadEntry = extern struct {
    start: u64 align(4) = 0,
    birth: u64 align(4) = 0,
    count: u64 align(4) = 0,
};

pub fn deadEntries(block_size: u32) u32 {
    return (block_size - node_header_size - @sizeOf(DeadHeader)) / @sizeOf(DeadEntry);
}

/// Work that takes several checkpoints, resumed after a mount.
pub const Job = extern struct {
    /// job_none, job_delete_snapshot, job_free_tree.
    kind: u32 = 0,
    /// The snapshot it is about.
    snapshot: u32 = 0,
    /// How far it has come.
    cursor: u64 align(4) = 0,
    a: u64 align(4) = 0,
    b: u64 align(4) = 0,
};

pub const job_none: u32 = 0;
/// Merge a deleted snapshot's deadlist into its successor's.
pub const job_delete_snapshot: u32 = 1;
/// Free what a rolled-back tree held beyond its snapshot.
pub const job_free_tree: u32 = 2;

pub const max_jobs: usize = 4;

/// A snapshot: the object tree as it was at a checkpoint.
pub const Snapshot = extern struct {
    id: u32 = 0,
    flags: u32 = 0,
    gen: u64 align(4) = 0,
    root: u64 align(4) = 0,
    root_gen: u64 align(4) = 0,
    height: u32 = 0,
    name_len: u32 = 0,
    /// When it was made, in microseconds since 1 Jan 1978.
    created: u64 align(4) = 0,
    /// What the live tree let go of while this was the newest snapshot.
    dead: DeadList = .{},
    name: [32]u8 = @splat(0),
};

/// Snapshot.flags: being deleted, by a job.
pub const SNAPSHOT_DELETING: u32 = 1 << 0;

/// The volume table: the settings, the volume's name, the snapshots and
/// the jobs - what no snapshot holds, so a rollback never changes it.
pub const VolTab = extern struct {
    header: NodeHeader = .{ .tree = tree_voltab },
    flags: u32 = 0,
    compress_alg: u32 = 0,
    recycled_max_count: u32 = 0,
    inline_max: u32 = 0,
    recycled_max_bytes: u64 align(4) = 0,
    /// The idle checkpoint's delay, in milliseconds (0: the handler's).
    idle_ms: u32 = 0,
    name_len: u32 = 0,
    name: [32]u8 = @splat(0),
    incompat: u32 = 0,
    ro_compat: u32 = 0,
    compat: u32 = 0,
    snapshot_count: u32 = 0,
    next_snapshot_id: u32 = 1,
    reserved: u32 = 0,
    live_dead: DeadList = .{},
    jobs: [max_jobs]Job = @splat(.{}),
    snapshots: [posfs.max_snapshots]Snapshot = @splat(.{}),
    /// When a check last ended finding nothing, in microseconds since 1
    /// Jan 1978; 0 for never.
    last_check: u64 align(4) = 0,

    pub fn volumeName(vt: *const VolTab) []const u8 {
        const len = if (vt.name_len > vt.name.len) vt.name.len else vt.name_len;
        return vt.name[0..len];
    }
};

// --- dates -----------------------------------------------------------------------

const us_per_tick: u64 = 20_000;
const us_per_minute: u64 = 60_000_000;
const us_per_day: u64 = 86_400_000_000;

/// A DateStamp as microseconds since 1 Jan 1978. A stamp before then is 0.
pub fn microsOf(stamp: dos.DateStamp) u64 {
    if (stamp.days < 0 or stamp.minute < 0 or stamp.tick < 0) return 0;
    return @as(u64, @intCast(stamp.days)) * us_per_day +
        @as(u64, @intCast(stamp.minute)) * us_per_minute +
        @as(u64, @intCast(stamp.tick)) * us_per_tick;
}

/// Microseconds since 1 Jan 1978 as a DateStamp, cut to its ticks.
pub fn stampOf(micros: u64) dos.DateStamp {
    const days = micros / us_per_day;
    const rest = micros % us_per_day;
    return .{
        .days = @intCast(days & 0x7FFF_FFFF),
        .minute = @intCast(rest / us_per_minute),
        .tick = @intCast((rest % us_per_minute) / us_per_tick),
    };
}

// --- checksums ---------------------------------------------------------------------

/// crc32 a byte at a time, from a table worked out at compile time.
const crc_table = blk: {
    @setEvalBranchQuota(4000);
    var table: [256]u32 = undefined;
    for (&table, 0..) |*entry, i| {
        var c: u32 = i;
        for (0..8) |_| c = if (c & 1 != 0) 0xEDB8_8320 ^ (c >> 1) else c >> 1;
        entry.* = c;
    }
    break :blk table;
};

pub fn crcStart() u32 {
    return 0xFFFF_FFFF;
}

/// More bytes into a running crc; `crcEnd` finishes it.
pub fn crcAdd(running: u32, bytes: []const u8) u32 {
    var crc = running;
    for (bytes) |byte| crc = crc_table[(crc ^ byte) & 0xFF] ^ (crc >> 8);
    return crc;
}

pub fn crcEnd(running: u32) u32 {
    return ~running;
}

/// The crc32 of one run of bytes, unseeded (what the label and a name's
/// hash use).
pub fn crc32(bytes: []const u8) u32 {
    return crcEnd(crcAdd(crcStart(), bytes));
}

/// A running crc seeded with the volume's id.
pub fn seeded(uuid: *const [16]u8) u32 {
    return crcAdd(crcStart(), uuid);
}

/// A running crc seeded with the volume's id and a mount's life, which is
/// what a journal record's starts from.
pub fn seededLife(uuid: *const [16]u8, life: u64) u32 {
    var bytes: [8]u8 = undefined;
    putU64(&bytes, 0, life);
    return crcAdd(seeded(uuid), &bytes);
}

/// The seeded crc32 of one run of bytes.
pub fn crcSeeded(uuid: *const [16]u8, bytes: []const u8) u32 {
    return crcEnd(crcAdd(seeded(uuid), bytes));
}

/// A structure's bytes.
pub fn bytesOf(value: anytype) []const u8 {
    const T = @TypeOf(value.*);
    const p: [*]const u8 = @ptrCast(value);
    return p[0..@sizeOf(T)];
}

/// A structure's bytes, to fill in.
pub fn bytesOfMut(value: anytype) []u8 {
    const T = @TypeOf(value.*);
    const p: [*]u8 = @ptrCast(value);
    return p[0..@sizeOf(T)];
}

/// A structure's bytes up to its checksum field, which is what the
/// checksum covers.
pub fn checked(value: anytype) []const u8 {
    const T = @TypeOf(value.*);
    const p: [*]const u8 = @ptrCast(value);
    return p[0..@offsetOf(T, "checksum")];
}

/// The label's checksum: unseeded, since the label is where the id is.
pub fn labelChecksum(label: *const Label) u32 {
    return crc32(checked(label));
}

/// A slot's or a journal block header's checksum, seeded with the id.
pub fn checksumOf(uuid: *const [16]u8, value: anytype) u32 {
    return crcSeeded(uuid, checked(value));
}

// --- bytes --------------------------------------------------------------------------

pub fn getU32(bytes: []const u8, at: usize) u32 {
    return @as(u32, bytes[at]) |
        (@as(u32, bytes[at + 1]) << 8) |
        (@as(u32, bytes[at + 2]) << 16) |
        (@as(u32, bytes[at + 3]) << 24);
}

pub fn getU64(bytes: []const u8, at: usize) u64 {
    return @as(u64, getU32(bytes, at)) | (@as(u64, getU32(bytes, at + 4)) << 32);
}

pub fn putU32(bytes: []u8, at: usize, value: u32) void {
    bytes[at] = @truncate(value);
    bytes[at + 1] = @truncate(value >> 8);
    bytes[at + 2] = @truncate(value >> 16);
    bytes[at + 3] = @truncate(value >> 24);
}

pub fn putU64(bytes: []u8, at: usize, value: u64) void {
    putU32(bytes, at, @truncate(value));
    putU32(bytes, at + 4, @truncate(value >> 32));
}

/// `length` rounded up to eight bytes, the alignment of records and of a
/// leaf's data.
pub fn pad8(length: usize) usize {
    return (length + 7) & ~@as(usize, 7);
}

comptime {
    // The layout is the format. Each size and each checksum's place is
    // fixed here, so a change that moves one does not build.
    if (@sizeOf(Label) != 112 or @offsetOf(Label, "checksum") != 108) @compileError("the label's layout moved");
    if (@sizeOf(NodeHeader) != 64 or @offsetOf(NodeHeader, "checksum") != 60) @compileError("the node header's layout moved");
    if (@sizeOf(Key) != 24 or @sizeOf(LeafEntry) != 32 or @sizeOf(InnerEntry) != 40) @compileError("a tree entry's layout moved");
    if (@sizeOf(Inode) != 88 or @sizeOf(DirEntry) != 16 or @sizeOf(Extent) != 40) @compileError("an item's layout moved");
    if (@sizeOf(Recycle) != 32 or @sizeOf(Orphan) != 16 or @sizeOf(RecycleStats) != 24 or @sizeOf(Bmap) != 24) @compileError("an item's layout moved");
    if (@sizeOf(JournalHeader) != 56 or @offsetOf(JournalHeader, "checksum") != 52) @compileError("the journal header's layout moved");
    if (@sizeOf(RecordHeader) != 24 or @offsetOf(RecordHeader, "checksum") != 20) @compileError("the record header's layout moved");
    if (@sizeOf(CreateRecord) != 64 or @sizeOf(LinkRecord) != 40 or @sizeOf(UnlinkRecord) != 40) @compileError("a record's layout moved");
    if (@sizeOf(RecycleRecord) != 56 or @sizeOf(RenameRecord) != 56 or @sizeOf(SetAttrRecord) != 48) @compileError("a record's layout moved");
    if (@sizeOf(CommitRecord) != 56 or @sizeOf(ExtSpec) != 40) @compileError("a record's layout moved");
    if (@sizeOf(CheckpointSlot) != 176 or @offsetOf(CheckpointSlot, "checksum") != 172) @compileError("the checkpoint slot's layout moved");
    if (@sizeOf(DeadList) != 24 or @sizeOf(DeadHeader) != 16 or @sizeOf(DeadEntry) != 24) @compileError("a deadlist's layout moved");
    if (@sizeOf(Job) != 32 or @sizeOf(Snapshot) != 104) @compileError("the volume table's layout moved");
    if (@sizeOf(VolTab) > voltab_size) @compileError("the volume table does not fit its bytes");
    if (@offsetOf(VolTab, "flags") != node_header_size) @compileError("the volume table's body moved");
}
