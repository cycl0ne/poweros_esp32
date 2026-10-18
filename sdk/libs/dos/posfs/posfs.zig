// SPDX-License-Identifier: MIT
//! posfs, the PowerOS file system: what everything that names it shares -
//! the handler (src/rom/handler/posfs), the host tool that builds a disk
//! image (tools/mkfs), the check (tools/posfsck), C:PosFS and whatever
//! probes a medium for it.
//!
//! posfs keeps its directories, its files' extents and its free space in
//! copy-on-write B+trees, and every change in a journal of what was done
//! rather than of the blocks it touched. A block that a durable state
//! refers to is never written over, so a cut at any moment leaves the
//! newest checkpoint and the journal after it, and the next mount replays
//! the one onto the other. There is no validator and no scan.
//!
//! The structures on the medium are in `layout.zig`, the names and their
//! case folding in `fold.zig`, the handler's own packets (the ones
//! C:PosFS sends) in `packets.zig`, and the partition table a card's
//! volume may sit in in `table.zig`.

const dos = @import("../dos.zig");

pub const layout = @import("layout.zig");
pub const fold = @import("fold.zig");
pub const packets = @import("packets.zig");
pub const table = @import("table.zig");

/// The handler's name, as the RDB's partitions and the mountlist give it.
pub const HANDLER_NAME = "posfs-handler";

/// ID_POSFS_DISK: what Info answers in id_DiskType, and the DosType of a
/// partition that is a posfs volume from its first block to its last:
/// "POS\0".
pub const ID_POSFS_DISK: u32 = 0x504F_5300;

/// The DosType of an area that begins with a partition table, the volume
/// in its first partition of type `mbr_type`: "POS\1". A card laid out
/// this way still shows a PC a partition table it knows.
pub const ID_POSFS_MBR: u32 = 0x504F_5301;

/// The partition type posfs takes in a partition table.
pub const mbr_type: u8 = 0x7F;

/// The DosType's first three bytes, the same for both layouts.
const type_mask: u32 = 0xFFFF_FF00;

/// Whether a DosType names posfs, in either layout.
pub fn isPosfsType(dos_type: u32) bool {
    return dos_type & type_mask == ID_POSFS_DISK and dos_type & 0xFF <= 1;
}

/// Whether a DosType says its area begins with a partition table.
pub fn partitionedType(dos_type: u32) bool {
    return dos_type == ID_POSFS_MBR;
}

/// The longest name, comment, soft link target, volume name and snapshot
/// name, in bytes of UTF-8.
pub const max_name: usize = dos.name_max;
pub const max_comment: usize = 79;
pub const max_link: usize = dos.path_max;
pub const max_volume_name: usize = 30;
pub const max_snapshot_name: usize = 31;

/// The most snapshots a volume holds at once.
pub const max_snapshots: usize = 30;

/// The block sizes a volume may have: a power of two between these.
pub const min_block_size: u32 = 1024;
pub const max_block_size: u32 = 64 * 1024;

/// The block size a format picks when nothing asks for another, and the
/// least it picks from a partition's own.
pub const default_block_size: u32 = 4096;

/// The hidden, read-only directory in the root under which the snapshots
/// are found, and the visible one that holds what was deleted while the
/// Recycled feature was on.
pub const snapshots_name = ".snapshots";
pub const recycled_name = "Recycled";

/// The objects every volume has. A user object's id is `first_user_oid`
/// or above, and an id is never given twice.
pub const root_oid: u64 = 1;
pub const recycled_oid: u64 = 2;
pub const orphan_oid: u64 = 3;
pub const first_user_oid: u64 = 16;

/// The block size a format takes: `wanted` when it is one (0 for the
/// default), else the partition's own block, raised to the default.
/// `sector` is the device's block, `erase` its erase unit (0 when it has
/// none). Null when `wanted` cannot be one on this medium.
pub fn chooseBlockSize(wanted: u32, partition_block: u32, sector: u32, erase: u32) ?u32 {
    var size = wanted;
    if (size == 0) {
        size = if (partition_block > default_block_size) partition_block else default_block_size;
        if (erase > size) size = erase;
    }
    if (!validBlockSize(size, sector, erase)) return null;
    return size;
}

/// Whether `size` can be a volume's block on a medium whose block is
/// `sector` and whose erase unit is `erase`.
pub fn validBlockSize(size: u32, sector: u32, erase: u32) bool {
    if (size < min_block_size or size > max_block_size) return false;
    if (size & (size - 1) != 0) return false;
    if (sector != 0 and size % sector != 0) return false;
    if (erase != 0 and size % erase != 0) return false;
    return true;
}
