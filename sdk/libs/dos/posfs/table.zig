// SPDX-License-Identifier: MIT
//! A posfs volume in a partition table (`POS\1`): the table a card carries
//! in its first block, read and written. The volume is the first
//! partition of type `mbr_type`. The table is the one a PC reads, so a
//! card laid out this way shows a PC a partition it knows of, if not what
//! is in it.
//!
//! A table counts in 32-bit blocks, so a partition ends within 2^32
//! blocks of the medium's first: 2 TiB of 512-byte blocks.

const dos = @import("../dos.zig");
const fat = dos.fat;
const posfs = @import("posfs.zig");
const layout = @import("layout.zig");

/// The volume's partition in a medium's first block: its first entry of
/// type `mbr_type`, in blocks of the medium. Null when the block holds no
/// table, or a table without one.
pub fn volumeIn(block: []const u8) ?fat.Partition {
    if (!fat.signed(block)) return null;
    var which: usize = 0;
    while (which < fat.partition_count) : (which += 1) {
        const partition = fat.partitionOf(block, which);
        if (partition.kind == posfs.mbr_type and partition.real()) return partition;
    }
    return null;
}

/// Whether a volume's first bytes are a posfs label: what a probe of a
/// medium looks for at its first block.
pub fn isLabel(block: []const u8) bool {
    return block.len >= 4 and fat.u32At(block, 0) == layout.label_magic;
}

/// The first block of the partition a format makes on a medium of
/// `blocks` blocks of `block_bytes`: the medium's unit of writing - 4 MiB,
/// as cards are made, but never more than a 64th of the medium, so a
/// small one gives little of itself to it.
pub fn firstBlockFor(blocks: u64, block_bytes: u32) u64 {
    const bytes = blocks * block_bytes;
    var unit: u64 = 4 * 1024 * 1024;
    while (unit > block_bytes and unit * 64 > bytes) unit /= 2;
    const first = unit / block_bytes;
    return if (first == 0) 1 else first;
}

/// The table a format writes, into `block` - one block of the medium,
/// cleared and filled whole: one partition of type `mbr_type` from block
/// `first`, `count` blocks long, the other three entries empty, and
/// `signature` the disk's, which a PC tells its disks apart by. Its start
/// and end as cylinder, head and sector are the marks that say to go by
/// the block numbers instead.
pub fn writeTable(block: []u8, first: u32, count: u32, signature: u32) void {
    @memset(block, 0);
    fat.putU32(block, disk_signature_at, signature);
    const at = fat.partition_table_at;
    @memcpy(block[at + 1 ..][0..3], &chs_past);
    block[at + 4] = posfs.mbr_type;
    @memcpy(block[at + 5 ..][0..3], &chs_past);
    fat.putU32(block, at + 8, first);
    fat.putU32(block, at + 12, count);
    fat.putU16(block, fat.signature_at, fat.signature);
}

/// Where a table keeps its disk's signature.
const disk_signature_at: usize = 440;

/// Cylinder 1023, head 254, sector 63: past what the three bytes hold.
const chs_past = [3]u8{ 0xFE, 0xFF, 0xFF };
