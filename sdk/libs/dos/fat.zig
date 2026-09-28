// SPDX-License-Identifier: MIT
//! The structures on a card formatted the way cards are sold: the
//! partition table in its first block, the boot sector of a volume, and
//! the directory entries of a FAT volume.
//!
//! They are read by two places that must agree - dos.library's mount,
//! which looks at a card to decide what to put on the device list, and
//! fat-handler, which then reads the volume - so they live here rather
//! than in either.
//!
//! **Nothing here is aligned.** A boot sector has 16-bit fields at odd
//! offsets, so every field is read out of a byte slice with `u16At` and
//! `u32At` instead of being mapped onto a struct. That costs nothing on
//! this machine and cannot go wrong on any offset. The numbers are
//! stored least significant byte first, which is the order this machine
//! uses, so the readers are shifts and not swaps.
//!
//! **A cluster number is 32 bits, of which 28 are used.** The top four
//! bits of a table entry belong to whoever wrote them and are kept on a
//! write; a value at or above `eoc_low` ends a chain and `bad` marks a
//! cluster not to use. `clusterOf` masks and then promotes anything at
//! or above the bad value, so everything above the table compares
//! against one pair of constants and never has to know how wide the
//! table is.

// --- reading and writing what is on the medium -------------------------------

pub fn u16At(bytes: []const u8, at: usize) u16 {
    return @as(u16, bytes[at]) | (@as(u16, bytes[at + 1]) << 8);
}

pub fn u32At(bytes: []const u8, at: usize) u32 {
    return @as(u32, bytes[at]) |
        (@as(u32, bytes[at + 1]) << 8) |
        (@as(u32, bytes[at + 2]) << 16) |
        (@as(u32, bytes[at + 3]) << 24);
}

pub fn u64At(bytes: []const u8, at: usize) u64 {
    return @as(u64, u32At(bytes, at)) | (@as(u64, u32At(bytes, at + 4)) << 32);
}

pub fn putU16(bytes: []u8, at: usize, value: u16) void {
    bytes[at] = @truncate(value);
    bytes[at + 1] = @truncate(value >> 8);
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

/// The two bytes at the end of a boot sector or a partition table that
/// say it is one.
pub const signature: u16 = 0xAA55;
pub const signature_at: usize = 510;

pub fn signed(block: []const u8) bool {
    return block.len > signature_at + 1 and u16At(block, signature_at) == signature;
}

// --- the partition table -----------------------------------------------------

/// Where the four partition entries start, and how long each is.
pub const partition_table_at: usize = 446;
pub const partition_entry_bytes: usize = 16;
pub const partition_count: usize = 4;

/// What a partition says it holds. Only the ones worth mounting are
/// named; a card as it is sold carries one of these.
pub const TYPE_FAT16_SMALL: u8 = 0x04;
pub const TYPE_EXTENDED: u8 = 0x05;
pub const TYPE_FAT16: u8 = 0x06;
pub const TYPE_NTFS_OR_EXFAT: u8 = 0x07;
pub const TYPE_FAT32: u8 = 0x0B;
pub const TYPE_FAT32_LBA: u8 = 0x0C;
pub const TYPE_FAT16_LBA: u8 = 0x0E;
pub const TYPE_EXTENDED_LBA: u8 = 0x0F;

/// One partition, as the table has it.
pub const Partition = struct {
    /// What it says it holds; 0 means the entry is empty.
    kind: u8,
    /// Its first block, counted from the start of the medium.
    first: u32,
    /// How many blocks it has.
    blocks: u32,
    /// Whether the entry is one worth looking at: it names a type and
    /// has somewhere to be.
    pub fn real(self: Partition) bool {
        return self.kind != 0 and self.blocks != 0;
    }
};

/// Partition `which` of a first block. The entry is read whatever it
/// says; whether it is worth mounting is `real` and `mountable`.
pub fn partitionOf(block: []const u8, which: usize) Partition {
    const at = partition_table_at + which * partition_entry_bytes;
    return .{
        .kind = block[at + 4],
        .first = u32At(block, at + 8),
        .blocks = u32At(block, at + 12),
    };
}

/// Whether a partition of this type is one this system reads.
pub fn mountable(kind: u8) bool {
    return switch (kind) {
        TYPE_FAT16_SMALL, TYPE_FAT16, TYPE_NTFS_OR_EXFAT, TYPE_FAT32, TYPE_FAT32_LBA, TYPE_FAT16_LBA => true,
        else => false,
    };
}

// --- what is on a volume -----------------------------------------------------

/// Which file system a volume's first block says it holds.
pub const Format = enum {
    fat32,
    exfat,
    /// Something else, or nothing that can be read.
    unknown,
};

/// The eight bytes an exFAT volume names itself with, at offset 3 of its
/// first block.
pub const exfat_name = "EXFAT   ";
/// Where a FAT volume writes what it is. It is a label and not a
/// promise - a volume may say FAT32 and not be one - so it is read only
/// after the arithmetic has already said the same thing.
pub const fat32_label_at: usize = 82;
pub const fat_label_at: usize = 54;

// The BPB, at the offsets a boot sector has them.
pub const bpb_bytes_per_sector: usize = 11;
pub const bpb_sectors_per_cluster: usize = 13;
pub const bpb_reserved_sectors: usize = 14;
pub const bpb_fat_count: usize = 16;
pub const bpb_root_entries: usize = 17;
pub const bpb_total_sectors_16: usize = 19;
pub const bpb_media: usize = 21;
pub const bpb_sectors_per_fat_16: usize = 22;
pub const bpb_sectors_per_track: usize = 24;
pub const bpb_heads: usize = 26;
pub const bpb_hidden_sectors: usize = 28;
pub const bpb_total_sectors_32: usize = 32;
// The part only a 32-bit volume has.
pub const bpb_sectors_per_fat_32: usize = 36;
pub const bpb_ext_flags: usize = 40;
pub const bpb_version: usize = 42;
pub const bpb_root_cluster: usize = 44;
pub const bpb_fs_info: usize = 48;
pub const bpb_backup_boot: usize = 50;
pub const bpb_volume_id: usize = 67;
pub const bpb_volume_label: usize = 71;
pub const bpb_volume_label_bytes: usize = 11;

/// What a volume's first block says it is.
///
/// exFAT names itself outright. A FAT volume does not: what makes it a
/// 32-bit one is that it keeps no fixed root directory and counts its
/// table in the 32-bit field, so that is what is tested, rather than the
/// label at the end - which some tools write wrongly and others leave
/// blank.
pub fn formatOf(block: []const u8) Format {
    if (block.len < 512) return .unknown;
    var named_exfat = true;
    for (block[3..11], exfat_name) |have, want| named_exfat = named_exfat and have == want;
    if (named_exfat) return .exfat;
    if (!signed(block)) return .unknown;

    const bytes_per_sector = u16At(block, bpb_bytes_per_sector);
    const sectors_per_cluster = block[bpb_sectors_per_cluster];
    const reserved = u16At(block, bpb_reserved_sectors);
    const fats = block[bpb_fat_count];
    if (!validSectorSize(bytes_per_sector)) return .unknown;
    if (!validClusterSectors(sectors_per_cluster)) return .unknown;
    if (reserved == 0 or fats == 0 or fats > 2) return .unknown;

    // A 32-bit volume has no fixed root directory and its table length
    // is in the 32-bit field. A 12- or 16-bit one is the other way
    // round, and is not read here.
    if (u16At(block, bpb_root_entries) != 0) return .unknown;
    if (u16At(block, bpb_sectors_per_fat_16) != 0) return .unknown;
    if (u32At(block, bpb_sectors_per_fat_32) == 0) return .unknown;
    if (u32At(block, bpb_root_cluster) < first_cluster) return .unknown;
    return .fat32;
}

/// A sector size a volume may have: a power of two from 512 to 4096.
pub fn validSectorSize(bytes: u16) bool {
    return switch (bytes) {
        512, 1024, 2048, 4096 => true,
        else => false,
    };
}

/// Sectors in a cluster: a power of two, and at most a cluster of 32 KiB
/// on a 512-byte sector.
pub fn validClusterSectors(sectors: u8) bool {
    return sectors != 0 and sectors & (sectors - 1) == 0 and sectors <= 128;
}

// --- the table ---------------------------------------------------------------

/// The first cluster a volume can use. Entries 0 and 1 of the table hold
/// the medium byte and the volume's flags, not a chain.
pub const first_cluster: u32 = 2;

/// Only the low 28 bits of a table entry are the cluster number; the top
/// four belong to whoever wrote them and are kept.
pub const cluster_mask: u32 = 0x0FFF_FFFF;
/// A cluster that must not be used.
pub const bad: u32 = 0x0FFF_FFF7;
/// At or above this a chain ends.
pub const eoc_low: u32 = 0x0FFF_FFF8;
/// What is written to end a chain.
pub const eoc: u32 = 0x0FFF_FFFF;
/// An entry of this is a cluster nothing is using.
pub const free_cluster: u32 = 0;

/// The cluster a table entry names, or one of the marks above.
pub fn clusterOf(entry: u32) u32 {
    return entry & cluster_mask;
}

/// Whether a value ends a chain.
pub fn endsChain(cluster: u32) bool {
    return cluster >= eoc_low;
}

/// Whether a value is a cluster a file can be in at all.
pub fn usable(cluster: u32, cluster_count: u32) bool {
    return cluster >= first_cluster and cluster < first_cluster + cluster_count;
}

/// A table entry with a new cluster number in it, keeping the four bits
/// that are not ours.
pub fn entryWith(was: u32, cluster: u32) u32 {
    return (was & ~cluster_mask) | (cluster & cluster_mask);
}

// --- the free-count sector ---------------------------------------------------

/// The sector that carries the free count and where to look next. Both
/// are hints: a volume whose count is wrong is still a good volume, and
/// the count is recomputed rather than trusted when it does not hold.
pub const fsinfo_lead: u32 = 0x4161_5252;
pub const fsinfo_struct: u32 = 0x6141_7272;
pub const fsinfo_trail: u32 = 0xAA55_0000;
pub const fsinfo_lead_at: usize = 0;
pub const fsinfo_struct_at: usize = 484;
pub const fsinfo_free_count_at: usize = 488;
pub const fsinfo_next_free_at: usize = 492;
pub const fsinfo_trail_at: usize = 508;
/// What either field holds when it says nothing.
pub const fsinfo_unknown: u32 = 0xFFFF_FFFF;

pub fn fsinfoSound(block: []const u8) bool {
    return block.len >= 512 and
        u32At(block, fsinfo_lead_at) == fsinfo_lead and
        u32At(block, fsinfo_struct_at) == fsinfo_struct and
        u32At(block, fsinfo_trail_at) == fsinfo_trail;
}

// --- a directory entry -------------------------------------------------------

/// The bytes one entry takes. A directory is a run of these.
pub const entry_bytes: usize = 32;

// Its fields, at their offsets.
pub const ent_name: usize = 0;
pub const ent_name_bytes: usize = 11;
pub const ent_attr: usize = 11;
pub const ent_case: usize = 12;
pub const ent_create_tenth: usize = 13;
pub const ent_create_time: usize = 14;
pub const ent_create_date: usize = 16;
pub const ent_access_date: usize = 18;
pub const ent_cluster_high: usize = 20;
pub const ent_write_time: usize = 22;
pub const ent_write_date: usize = 24;
pub const ent_cluster_low: usize = 26;
pub const ent_size: usize = 28;

/// The first cluster of what an entry names. The number is in two halves
/// at opposite ends of the entry, because the high half was added to a
/// layout that had no room left in one piece.
pub fn entryCluster(entry: []const u8) u32 {
    return (@as(u32, u16At(entry, ent_cluster_high)) << 16) | u16At(entry, ent_cluster_low);
}

pub fn setEntryCluster(entry: []u8, cluster: u32) void {
    putU16(entry, ent_cluster_high, @truncate(cluster >> 16));
    putU16(entry, ent_cluster_low, @truncate(cluster));
}

// --- the entries that carry a long name --------------------------------------

/// An entry with these four attribute bits is not a file: it is one
/// piece of the name of the entry that follows the run.
pub const attr_long_name: u8 = 0x0F;

pub const lfn_order: usize = 0;
pub const lfn_attr: usize = 11;
pub const lfn_type: usize = 12;
pub const lfn_checksum: usize = 13;
pub const lfn_cluster: usize = 26;
/// Where the thirteen characters of a piece sit: five, then six, then
/// two, around the fields that had to stay where a reader expecting a
/// file would find them.
pub const lfn_part1_at: usize = 1;
pub const lfn_part1_len: usize = 5;
pub const lfn_part2_at: usize = 14;
pub const lfn_part2_len: usize = 6;
pub const lfn_part3_at: usize = 28;
pub const lfn_part3_len: usize = 2;
/// The characters one piece carries.
pub const lfn_chars: usize = lfn_part1_len + lfn_part2_len + lfn_part3_len;
/// The piece that comes first on the medium carries this bit, and it is
/// the last piece of the name.
pub const lfn_last: u8 = 0x40;
/// The most pieces a name can take, and so the longest name there is.
pub const lfn_max_pieces: usize = 20;
pub const name_max: usize = 255;

/// Whether an entry is a piece of a long name rather than a file. The
/// whole byte is tested, not the volume-label bit alone: a piece of a
/// long name has that bit set too, and a scan that tested only for it
/// would take every long name for a volume label.
pub fn isLongName(entry: []const u8) bool {
    return entry[ent_attr] == attr_long_name;
}

/// The check on the short name that every piece of a long name carries.
/// A run whose pieces do not carry this value for the entry that follows
/// them belongs to a name that something without long names has since
/// renamed, and the long name must be ignored.
///
/// It is a rotate and add over the eleven bytes of the short name.
pub fn shortNameChecksum(name: []const u8) u8 {
    var sum: u8 = 0;
    for (name[0..ent_name_bytes]) |char| {
        sum = (sum >> 1) +% (sum << 7) +% char;
    }
    return sum;
}

// --- exFAT -------------------------------------------------------------------
//
// An exFAT volume starts with a boot region of twelve sectors - the boot
// sector, eight extended boot sectors, one of OEM parameters, one
// reserved, and one that repeats a checksum over the eleven before it -
// and a backup of the same twelve behind it. Its table (FAT) links the
// clusters of a file only when they are not one run: a file whose
// clusters follow one another says so (`exfat_no_fat_chain`) and its
// table entries mean nothing. Which clusters are in use is a bitmap's to
// say, not the table's.

/// The boot sector's fields, at their offsets.
pub const exfat_partition_offset: usize = 64;
pub const exfat_volume_length: usize = 72;
pub const exfat_fat_offset: usize = 80;
pub const exfat_fat_length: usize = 84;
pub const exfat_heap_offset: usize = 88;
pub const exfat_cluster_count: usize = 92;
pub const exfat_root_cluster: usize = 96;
pub const exfat_serial: usize = 100;
pub const exfat_revision: usize = 104;
pub const exfat_volume_flags: usize = 106;
pub const exfat_sector_shift: usize = 108;
pub const exfat_cluster_shift: usize = 109;
pub const exfat_fat_count: usize = 110;
pub const exfat_percent_in_use: usize = 112;
/// From byte 11 to here the boot sector must be zero: where a FAT volume
/// keeps its BPB, so nothing that reads one takes this for one.
pub const exfat_zero_from: usize = 11;
pub const exfat_zero_to: usize = 64;

/// VolumeFlags: which of two tables is in use, whether the volume was
/// left in the middle of a change, whether the medium has reported
/// failures.
pub const exfat_active_fat: u16 = 1 << 0;
pub const exfat_volume_dirty: u16 = 1 << 1;
pub const exfat_media_failure: u16 = 1 << 2;

/// The revision this reads: 1.00. A volume of a later major revision may
/// be laid out differently and is not guessed at.
pub const exfat_major_revision: u8 = 1;

/// Sectors in a boot region, and where its checksum sector is.
pub const exfat_boot_sectors: u32 = 12;
pub const exfat_checksum_sector: u32 = 11;
/// What PercentInUse holds when it says nothing.
pub const exfat_percent_unknown: u8 = 0xFF;

/// The boot region's checksum, over the first eleven sectors, carried
/// forward from `sum` so the sectors can be given one at a time. Three
/// bytes of the boot sector are left out: VolumeFlags and PercentInUse,
/// which change while the volume is in use, so that changing them does not
/// mean writing the checksum sector again.
pub fn exfatBootChecksum(sum: u32, sector: []const u8, is_boot_sector: bool) u32 {
    var checksum = sum;
    for (sector, 0..) |byte, at| {
        if (is_boot_sector and (at == exfat_volume_flags or at == exfat_volume_flags + 1 or at == exfat_percent_in_use)) continue;
        checksum = ((checksum & 1) << 31 | checksum >> 1) +% byte;
    }
    return checksum;
}

/// The first cluster a volume can use, as on FAT: entries 0 and 1 of the
/// table are not clusters.
pub const exfat_first_cluster: u32 = 2;
/// A cluster that must not be used, and the end of a chain.
pub const exfat_bad: u32 = 0xFFFF_FFF7;
pub const exfat_eoc: u32 = 0xFFFF_FFFF;

// A directory entry is 32 bytes, as on FAT, and its first byte says what
// it is: bit 7 that it is in use, bit 6 that it belongs to the entry
// before it (a secondary), bit 5 that a reader may pass over it if it
// does not know it (benign), and the low five bits which kind.

pub const exfat_entry_in_use: u8 = 0x80;
pub const exfat_entry_secondary: u8 = 0x40;
pub const exfat_entry_benign: u8 = 0x20;
/// The end of a directory: nothing past it is in use.
pub const exfat_entry_end: u8 = 0x00;

pub const exfat_type_bitmap: u8 = 0x81;
pub const exfat_type_upcase: u8 = 0x82;
pub const exfat_type_label: u8 = 0x83;
pub const exfat_type_file: u8 = 0x85;
pub const exfat_type_guid: u8 = 0xA0;
pub const exfat_type_stream: u8 = 0xC0;
pub const exfat_type_name: u8 = 0xC1;

// The allocation bitmap's and the up-case table's entries: where each
// lies and how long it is. The table's entry carries its checksum too.
pub const exfat_bitmap_flags: usize = 1;
pub const exfat_upcase_checksum: usize = 4;
pub const exfat_region_cluster: usize = 20;
pub const exfat_region_length: usize = 24;

// The volume label's entry: up to eleven characters of UTF-16.
pub const exfat_label_length: usize = 1;
pub const exfat_label_chars: usize = 2;
pub const exfat_label_max: usize = 11;

// A file's entry: how many entries follow it, their checksum, the
// attribute byte (FAT's, in a 16-bit field), and three moments.
pub const exfat_file_secondaries: usize = 1;
pub const exfat_file_checksum: usize = 2;
pub const exfat_file_attributes: usize = 4;
pub const exfat_file_created: usize = 8;
pub const exfat_file_modified: usize = 12;
pub const exfat_file_accessed: usize = 16;
pub const exfat_file_created_10ms: usize = 20;
pub const exfat_file_modified_10ms: usize = 21;
pub const exfat_file_created_utc: usize = 22;
pub const exfat_file_modified_utc: usize = 23;
pub const exfat_file_accessed_utc: usize = 24;

// The stream extension that follows it: where the data is and how much
// of it there is. The valid length is how much has been written; what
// lies between it and the data length reads as zeroes.
pub const exfat_stream_flags: usize = 1;
pub const exfat_stream_name_length: usize = 3;
pub const exfat_stream_name_hash: usize = 4;
pub const exfat_stream_valid_length: usize = 8;
pub const exfat_stream_cluster: usize = 20;
pub const exfat_stream_data_length: usize = 24;
/// Stream flags: the stream may have clusters at all, and they are one
/// run with no table chain.
pub const exfat_allocation_possible: u8 = 1 << 0;
pub const exfat_no_fat_chain: u8 = 1 << 1;

/// A name entry carries fifteen characters of UTF-16 from byte 2.
pub const exfat_name_chars_at: usize = 2;
pub const exfat_name_chars: usize = 15;

/// The most secondaries a file has: its stream and the name entries of
/// the longest name.
pub const exfat_max_secondaries: usize = 1 + (name_max + exfat_name_chars - 1) / exfat_name_chars;

/// A UTC offset byte that holds one: bit 7 set, the offset in quarter
/// hours in the seven bits below it.
pub const exfat_utc_valid: u8 = 0x80;

/// The checksum over a file's entry set: every byte of it except the two
/// the checksum is kept in, carried forward from `sum` so the entries can
/// be given one at a time. `first` says the entry given is the file entry.
pub fn exfatSetChecksum(sum: u16, entry: []const u8, first: bool) u16 {
    var checksum = sum;
    for (entry[0..entry_bytes], 0..) |byte, at| {
        if (first and (at == exfat_file_checksum or at == exfat_file_checksum + 1)) continue;
        checksum = ((checksum & 1) << 15 | checksum >> 1) +% byte;
    }
    return checksum;
}

/// The hash of a name as the up-case table makes it, each character
/// taken as two bytes, low one first: what a stream extension carries so
/// a search can pass over a name without reading its entries.
pub fn exfatNameHash(upcased: []const u16) u16 {
    var hash: u16 = 0;
    for (upcased) |unit| {
        for ([_]u8{ @truncate(unit), @truncate(unit >> 8) }) |byte| {
            hash = ((hash & 1) << 15 | hash >> 1) +% byte;
        }
    }
    return hash;
}

/// The up-case table's checksum, over its bytes as they are stored.
pub fn exfatTableChecksum(sum: u32, bytes: []const u8) u32 {
    var checksum = sum;
    for (bytes) |byte| checksum = ((checksum & 1) << 31 | checksum >> 1) +% byte;
    return checksum;
}
