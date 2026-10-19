// SPDX-License-Identifier: MIT
//! The GUID partition table (GPT), the table PCs and most other machines
//! keep their partitions in: read and checked, and made.
//!
//! **Where it lies.** Block 0 holds a protective MBR, one partition of
//! type 0xEE over the whole medium, so a program that knows only MBRs sees
//! the medium as taken. Block 1 holds the header, and its entries follow
//! from block 2: 128 entries of 128 bytes, 16 KiB, which is 32 blocks of
//! 512 bytes or 4 of 4096. A copy of both is kept at the end of the
//! medium - the entries, then the header in the last block - so a medium
//! whose start is damaged still says what is on it. The blocks between
//! the two copies are the usable ones (`first_usable_lba` to
//! `last_usable_lba`), and every partition lies inside them.
//!
//! **How it is checked.** A header is taken when its signature, revision
//! and size are right, its crc32 agrees (over its own bytes, with the crc
//! field taken as zero), it says it is in the block it was read from, and
//! the blocks it names fit the medium: its entries, of up to a block each,
//! are outside the usable blocks and clear of block 0, block 1 and the
//! last. Its entries are taken
//! when their crc32, which the header holds, agrees, and every used one (a
//! type that is not all zeroes) lies inside the usable blocks and shares no
//! block with another. A reader takes the header in block 1 with its
//! entries, and the copy in the last block where either is not sound.
//!
//! **GUIDs** are 16 bytes. Their text writes the first three fields as
//! numbers: the bytes of the 4-, 2- and 2-byte fields are stored least
//! significant first, and the last eight bytes in the order they are
//! written. `C12A7328-F81F-11D2-BA4B-00A0C93EC93B`, the EFI System
//! partition's type, begins with the bytes 28 73 2A C1.
//!
//! **A PowerOS container** is a partition of the type `TYPE_CONTAINER`.
//! Its first blocks hold a RigidDiskBlock (sdk/libs/dos/hardblocks.zig),
//! whose partitions count their blocks and cylinders from the container's
//! first block, so the table is the same wherever the container lies.
//! rdb.library opens a container as a disk of its own; a medium has one,
//! the first. A container starts on a multiple of its table's cylinder,
//! as every partition this file makes starts on a multiple of
//! `alignment_bytes`.
//!
//! The structures are little-endian on the medium, as they are in memory
//! on every machine here, so a header and an entry are copied in and out
//! as they lie.

const fat = @import("fat.zig");
const flashfs = @import("flashfs.zig");

/// A GUID, as its 16 bytes lie on the medium.
pub const Guid = [16]u8;

/// The characters of a GUID's text, without a NUL.
pub const guid_text_len = 36;

/// What a header begins with.
pub const header_signature = "EFI PART";
/// The revision this file writes; a header of any 1.x is read.
pub const header_revision: u32 = 0x0001_0000;
/// The bytes of a header, which its crc covers.
pub const header_bytes: u32 = 92;
/// The bytes of an entry this file writes, and the least a table may have.
pub const entry_bytes: u32 = 128;
/// The entries a table made here has room for.
pub const entries_made: u32 = 128;
/// The most bytes of entries a table read here may have.
pub const max_entries_bytes: u64 = 1 << 16;
/// The block the header is in; its entries follow it.
pub const header_block: u64 = 1;
/// The UTF-16 code units of an entry's name.
pub const name_units = 36;

/// The MBR partition type that says a GPT is on the medium.
pub const PROTECTIVE_TYPE: u8 = 0xEE;

/// Where a partition made here starts: on a multiple of 1 MiB, which is
/// at least a medium's unit of writing and what partitioning tools use.
pub const alignment_bytes: u64 = 1 << 20;

/// An entry's attributes, its `attributes` bits.
/// The partition is needed for the machine to work; tools leave it alone.
pub const ATTR_REQUIRED: u64 = 1 << 0;
/// Firmware reads no file system on it.
pub const ATTR_NO_BLOCK_IO: u64 = 1 << 1;
/// A BIOS may start from it.
pub const ATTR_LEGACY_BOOTABLE: u64 = 1 << 2;
/// The partition is not mounted when its medium comes in.
pub const ATTR_NO_AUTOMOUNT: u64 = 1 << 63;

/// The header, the first `header_bytes` of its block.
pub const Header = extern struct {
    signature: [8]u8 = header_signature.*,
    revision: u32 = header_revision,
    header_size: u32 = header_bytes,
    /// crc32 of the header's `header_size` bytes, this field taken as 0.
    header_crc32: u32 = 0,
    reserved: u32 = 0,
    /// The block this header is in, and the block of the other copy.
    my_lba: u64 align(4) = 0,
    alternate_lba: u64 align(4) = 0,
    /// The blocks partitions may use, both included.
    first_usable_lba: u64 align(4) = 0,
    last_usable_lba: u64 align(4) = 0,
    disk_guid: Guid = @splat(0),
    /// The first block of this copy's entries.
    partition_entry_lba: u64 align(4) = 0,
    number_of_partition_entries: u32 = entries_made,
    size_of_partition_entry: u32 = entry_bytes,
    /// crc32 of the entries, all `number_of_partition_entries` of them.
    partition_entry_array_crc32: u32 = 0,
};

/// One entry, the first `entry_bytes` of its place in the entries.
pub const Entry = extern struct {
    /// What the partition holds (`TYPE_*`); all zeroes for an unused
    /// entry.
    partition_type_guid: Guid = @splat(0),
    /// The partition's own GUID.
    unique_partition_guid: Guid = @splat(0),
    /// Its first and last block, both included.
    starting_lba: u64 align(4) = 0,
    ending_lba: u64 align(4) = 0,
    /// ATTR_*; bits 48 to 63 are the type's own.
    attributes: u64 align(4) = 0,
    /// Its name, UTF-16, NUL-padded.
    partition_name: [name_units]u16 = @splat(0),
};

comptime {
    if (@offsetOf(Header, "partition_entry_array_crc32") + 4 != header_bytes) @compileError("the GPT header is not 92 bytes");
    if (@sizeOf(Entry) != entry_bytes) @compileError("a GPT entry is not 128 bytes");
}

// --- types ---------------------------------------------------------------------

/// A GUID's text as its bytes; null for text that is not one. Hex digits
/// in either case, in groups of 8, 4, 4, 4 and 12 between dashes.
///
/// INPUTS:
/// - `text` - the 36 characters, without braces.
pub fn parseGuid(text: []const u8) ?Guid {
    if (text.len != guid_text_len) return null;
    // Where each byte's two digits are in the text, in the order the
    // bytes lie.
    const at = [16]u8{ 6, 4, 2, 0, 11, 9, 16, 14, 19, 21, 24, 26, 28, 30, 32, 34 };
    for ([_]usize{ 8, 13, 18, 23 }) |dash| {
        if (text[dash] != '-') return null;
    }
    var guid: Guid = undefined;
    for (&guid, at) |*byte, index| {
        const high = hexValue(text[index]) orelse return null;
        const low = hexValue(text[index + 1]) orelse return null;
        byte.* = high << 4 | low;
    }
    return guid;
}

fn hexValue(char: u8) ?u8 {
    return switch (char) {
        '0'...'9' => char - '0',
        'a'...'f' => char - 'a' + 10,
        'A'...'F' => char - 'A' + 10,
        else => null,
    };
}

/// A GUID's text into `into`, upper case, NUL-terminated.
///
/// INPUTS:
/// - `guid` - the bytes as they lie.
/// - `into` - where the text goes.
pub fn formatGuid(guid: *const Guid, into: *[guid_text_len:0]u8) void {
    const digits = "0123456789ABCDEF";
    const order = [_]u8{ 3, 2, 1, 0, 0xFF, 5, 4, 0xFF, 7, 6, 0xFF, 8, 9, 0xFF, 10, 11, 12, 13, 14, 15 };
    var at: usize = 0;
    for (order) |index| {
        if (index == 0xFF) {
            into[at] = '-';
            at += 1;
            continue;
        }
        into[at] = digits[guid[index] >> 4];
        into[at + 1] = digits[guid[index] & 0xF];
        at += 2;
    }
    into[guid_text_len] = 0;
}

/// Whether a GUID is all zeroes: the type of an unused entry.
pub fn isNull(guid: *const Guid) bool {
    for (guid) |byte| {
        if (byte != 0) return false;
    }
    return true;
}

/// Whether two GUIDs are the same.
pub fn sameGuid(one: *const Guid, other: *const Guid) bool {
    for (one, other) |a, b| {
        if (a != b) return false;
    }
    return true;
}

/// Sixteen random bytes made a random GUID: its version 4 and its variant
/// set, as a new disk's and partition's GUIDs are.
///
/// INPUTS:
/// - `guid` - random bytes, changed in place.
pub fn markRandom(guid: *Guid) void {
    guid[7] = (guid[7] & 0x0F) | 0x40;
    guid[8] = (guid[8] & 0x3F) | 0x80;
}

/// A type GUID from its text, at compile time.
fn typeGuid(comptime text: []const u8) Guid {
    return comptime parseGuid(text) orelse @compileError("not a GUID: " ++ text);
}

/// The types a program names.
pub const TYPE_EFI_SYSTEM = typeGuid("C12A7328-F81F-11D2-BA4B-00A0C93EC93B");
pub const TYPE_BASIC_DATA = typeGuid("EBD0A0A2-B9E5-4433-87C0-68B6B72699C7");
pub const TYPE_MS_RESERVED = typeGuid("E3C9E316-0B5C-4DB8-817D-F92DF00215AE");
pub const TYPE_BIOS_BOOT = typeGuid("21686148-6449-6E6F-744E-656564454649");
pub const TYPE_LINUX = typeGuid("0FC63DAF-8483-4772-8E79-3D69D8477DE4");
pub const TYPE_LINUX_SWAP = typeGuid("0657FD6D-A4AB-43C4-84E5-0933C84B4F4F");
/// A PowerOS container: a RigidDiskBlock and its partitions inside.
pub const TYPE_CONTAINER = typeGuid("4CA96E42-B070-42FB-A098-B3C5B1F92837");

pub const KnownType = struct {
    guid: Guid,
    name: [*:0]const u8,
};

/// The types there is a name for, in the order a program offers them.
pub const known_types = [_]KnownType{
    .{ .guid = TYPE_CONTAINER, .name = "PowerOS container" },
    .{ .guid = TYPE_BASIC_DATA, .name = "Basic data" },
    .{ .guid = TYPE_EFI_SYSTEM, .name = "EFI System" },
    .{ .guid = TYPE_LINUX, .name = "Linux file system" },
    .{ .guid = TYPE_LINUX_SWAP, .name = "Linux swap" },
    .{ .guid = TYPE_MS_RESERVED, .name = "Microsoft reserved" },
    .{ .guid = TYPE_BIOS_BOOT, .name = "BIOS boot" },
};

/// The name of a partition type, or null for one there is none for.
///
/// INPUTS:
/// - `guid` - the entry's `partition_type_guid`.
pub fn typeName(guid: *const Guid) ?[*:0]const u8 {
    for (&known_types) |*known| {
        if (sameGuid(&known.guid, guid)) return known.name;
    }
    return null;
}

/// Whether an entry is a PowerOS container.
pub fn isContainer(entry: *const Entry) bool {
    return sameGuid(&entry.partition_type_guid, &TYPE_CONTAINER);
}

// --- names ----------------------------------------------------------------------

/// An entry's name as text, into `into`: a character outside printable
/// ASCII becomes `?`. The text, without the NUL after it.
///
/// INPUTS:
/// - `entry` - the entry.
/// - `into` - where the text goes, NUL-terminated.
pub fn nameText(entry: *const Entry, into: *[name_units:0]u8) []const u8 {
    var length: usize = 0;
    for (entry.partition_name) |unit| {
        if (unit == 0) break;
        into[length] = if (unit >= 0x20 and unit < 0x7F) @intCast(unit) else '?';
        length += 1;
    }
    @memset(into[length..], 0);
    return into[0..length];
}

/// An entry's name set from text: as much of it as fits, the rest of the
/// field zeroes.
///
/// INPUTS:
/// - `entry` - the entry, changed.
/// - `text` - the name, in ASCII.
pub fn setName(entry: *Entry, text: []const u8) void {
    entry.partition_name = @splat(0);
    for (text[0..@min(text.len, name_units)], 0..) |char, index| entry.partition_name[index] = char;
}

// --- reading ----------------------------------------------------------------------

/// Whether a medium's first block is a protective MBR: signed, with a
/// partition of type 0xEE. A hybrid MBR, which names other partitions
/// beside it, is one too.
///
/// INPUTS:
/// - `block` - the medium's first block.
pub fn protective(block: []const u8) bool {
    if (!fat.signed(block)) return false;
    var which: usize = 0;
    while (which < fat.partition_count) : (which += 1) {
        if (fat.partitionOf(block, which).kind == PROTECTIVE_TYPE) return true;
    }
    return false;
}

/// Whether a block begins with a header's signature, sound or not.
///
/// INPUTS:
/// - `block` - the block.
pub fn signed(block: []const u8) bool {
    if (block.len < header_signature.len) return false;
    for (block[0..header_signature.len], header_signature) |have, want| {
        if (have != want) return false;
    }
    return true;
}

/// The header in a block, or null when it is not one the medium can have
/// in that block (see the top of the file).
///
/// INPUTS:
/// - `block` - the whole block.
/// - `at` - its number: block 1, or the last.
/// - `blocks` - the medium's blocks.
pub fn readHeader(block: []const u8, at: u64, blocks: u64) ?Header {
    if (block.len < header_bytes or !signed(block)) return null;
    var header: Header = .{};
    @memcpy(@as([*]u8, @ptrCast(&header))[0..header_bytes], block[0..header_bytes]);
    if (header.revision >> 16 != header_revision >> 16) return null;
    if (header.header_size < header_bytes or header.header_size > block.len) return null;
    if (headerCrc(block[0..header.header_size]) != header.header_crc32) return null;
    if (header.my_lba != at or blocks < 4) return null;
    if (header.alternate_lba >= blocks or header.alternate_lba == at) return null;
    if (header.first_usable_lba > header.last_usable_lba or header.last_usable_lba >= blocks - 1) return null;
    if (header.first_usable_lba < 2) return null;
    const size = header.size_of_partition_entry;
    if (size < entry_bytes or size & (size - 1) != 0 or size > block.len) return null;
    const length = entriesLength(&header);
    if (length == 0 or length > max_entries_bytes) return null;
    const first = header.partition_entry_lba;
    const block_bytes: u64 = block.len;
    const end = first + (length + block_bytes - 1) / block_bytes;
    if (first < 2 or end > blocks - 1) return null;
    // On one side of the usable blocks, and not over this header.
    if (first <= header.last_usable_lba and header.first_usable_lba < end) return null;
    if (first <= at and at < end) return null;
    return header;
}

/// The crc32 of a header's bytes, its crc field taken as zero.
fn headerCrc(bytes: []const u8) u32 {
    const at = @offsetOf(Header, "header_crc32");
    var running = flashfs.crcAdd(flashfs.crcStart(), bytes[0..at]);
    running = flashfs.crcAdd(running, &[_]u8{ 0, 0, 0, 0 });
    running = flashfs.crcAdd(running, bytes[at + 4 ..]);
    return flashfs.crcEnd(running);
}

/// The bytes of a header's entries, all of them.
///
/// INPUTS:
/// - `header` - a header `readHeader` took, or one made here.
pub fn entriesLength(header: *const Header) u64 {
    return @as(u64, header.number_of_partition_entries) * header.size_of_partition_entry;
}

/// The blocks a header's entries take.
///
/// INPUTS:
/// - `header` - the header.
/// - `block_bytes` - the medium's block size.
pub fn entriesBlocks(header: *const Header, block_bytes: u32) u64 {
    return (entriesLength(header) + block_bytes - 1) / block_bytes;
}

/// Entry `index`, counted from 0, of a header's entries.
///
/// INPUTS:
/// - `header` - their header.
/// - `entries` - the entries' bytes, `entriesLength` of them at least.
/// - `index` - below `number_of_partition_entries`.
pub fn entryAt(header: *const Header, entries: []const u8, index: u32) Entry {
    var entry: Entry = .{};
    const at = @as(usize, index) * header.size_of_partition_entry;
    @memcpy(@as([*]u8, @ptrCast(&entry))[0..entry_bytes], entries[at..][0..entry_bytes]);
    return entry;
}

/// The entries a block of them holds.
///
/// INPUTS:
/// - `header` - their header.
/// - `block_bytes` - the medium's block size, at least an entry's.
pub fn entriesPerBlock(header: *const Header, block_bytes: u32) u32 {
    return block_bytes / header.size_of_partition_entry;
}

/// A crc32 of a header's entries, run a block of them at a time: what a
/// reader that holds one block, or a writer that makes one, checks or
/// puts in the header.
pub const EntriesCrc = struct {
    running: u32,
    /// The entries' bytes not yet run over.
    left: u64,

    /// A run over a header's entries.
    pub fn of(header: *const Header) EntriesCrc {
        return .{ .running = flashfs.crcStart(), .left = entriesLength(header) };
    }

    /// The next block of entries, as far as the entries go into it.
    pub fn add(crc: *EntriesCrc, block: []const u8) void {
        const length: usize = @intCast(@min(crc.left, block.len));
        crc.running = flashfs.crcAdd(crc.running, block[0..length]);
        crc.left -= length;
    }

    /// The crc32, once every block is run over.
    pub fn end(crc: *const EntriesCrc) u32 {
        return flashfs.crcEnd(crc.running);
    }
};

/// The crc32 of entries held whole.
///
/// INPUTS:
/// - `header` - their header.
/// - `entries` - their bytes, `entriesLength` of them at least.
pub fn entriesCrc(header: *const Header, entries: []const u8) u32 {
    return flashfs.crc32(entries[0..@intCast(entriesLength(header))]);
}

/// Whether an entry names a partition: its type is not all zeroes.
pub fn used(entry: *const Entry) bool {
    return !isNull(&entry.partition_type_guid);
}

/// Whether a header's entries are sound: their crc32 is the header's, and
/// every used one lies inside the usable blocks, the right way round, and
/// shares no block with another.
///
/// INPUTS:
/// - `header` - a header `readHeader` took.
/// - `entries` - the bytes read from its entries' blocks, at least
///   `entriesLength`.
pub fn entriesSound(header: *const Header, entries: []const u8) bool {
    const length = entriesLength(header);
    if (entries.len < length) return false;
    if (entriesCrc(header, entries) != header.partition_entry_array_crc32) return false;
    var index: u32 = 0;
    while (index < header.number_of_partition_entries) : (index += 1) {
        const entry = entryAt(header, entries, index);
        if (!used(&entry)) continue;
        if (entry.starting_lba > entry.ending_lba) return false;
        if (entry.starting_lba < header.first_usable_lba or entry.ending_lba > header.last_usable_lba) return false;
        var other: u32 = 0;
        while (other < index) : (other += 1) {
            const before = entryAt(header, entries, other);
            if (!used(&before)) continue;
            if (entry.starting_lba <= before.ending_lba and before.starting_lba <= entry.ending_lba) return false;
        }
    }
    return true;
}

/// The first container among a header's entries, and its index; null for
/// none.
///
/// INPUTS:
/// - `header` - a header whose entries are sound.
/// - `entries` - their bytes.
pub fn containerIn(header: *const Header, entries: []const u8) ?struct { entry: Entry, index: u32 } {
    var index: u32 = 0;
    while (index < header.number_of_partition_entries) : (index += 1) {
        const entry = entryAt(header, entries, index);
        if (isContainer(&entry)) return .{ .entry = entry, .index = index };
    }
    return null;
}

// --- making -----------------------------------------------------------------------

/// The block a partition made here starts at: `block` or the next one on
/// a multiple of `alignment_bytes`.
///
/// INPUTS:
/// - `block` - the lowest block it may start at.
/// - `block_bytes` - the medium's block size.
pub fn alignUp(block: u64, block_bytes: u32) u64 {
    const step = alignmentBlocks(block_bytes);
    return (block + step - 1) / step * step;
}

/// The blocks of `alignment_bytes`; 1 on a medium of larger blocks.
pub fn alignmentBlocks(block_bytes: u32) u64 {
    return @max(alignment_bytes / block_bytes, 1);
}

/// A fresh header for the copy in block 1 of a medium, with no entries
/// used: `entries_made` entries from block 2, the copy in the last block
/// and its entries before it. Null for a medium too small for both copies
/// and one aligned block between them.
///
/// INPUTS:
/// - `blocks` - the medium's blocks.
/// - `block_bytes` - its block size.
/// - `disk_guid` - the disk's GUID, new and random.
pub fn freshHeader(blocks: u64, block_bytes: u32, disk_guid: *const Guid) ?Header {
    var header: Header = .{ .disk_guid = disk_guid.* };
    const entries = entriesBlocks(&header, block_bytes);
    header.my_lba = header_block;
    header.partition_entry_lba = header_block + 1;
    header.first_usable_lba = header.partition_entry_lba + entries;
    if (blocks < header.first_usable_lba + entries + 2) return null;
    header.alternate_lba = blocks - 1;
    header.last_usable_lba = blocks - 2 - entries;
    if (alignUp(header.first_usable_lba, block_bytes) > header.last_usable_lba) return null;
    return header;
}

/// The other copy's header: in the block the first names, its entries
/// after the usable blocks.
///
/// INPUTS:
/// - `primary` - the header of block 1.
pub fn backupOf(primary: *const Header) Header {
    var backup = primary.*;
    backup.my_lba = primary.alternate_lba;
    backup.alternate_lba = primary.my_lba;
    backup.partition_entry_lba = primary.last_usable_lba + 1;
    return backup;
}

/// An entry put in its place in the entries.
///
/// INPUTS:
/// - `header` - their header.
/// - `entries` - the entries' bytes, changed.
/// - `index` - its place, from 0.
/// - `entry` - what goes there.
pub fn putEntry(header: *const Header, entries: []u8, index: u32, entry: *const Entry) void {
    const at = @as(usize, index) * header.size_of_partition_entry;
    const place = entries[at..][0..header.size_of_partition_entry];
    @memset(place, 0);
    @memcpy(place[0..entry_bytes], @as([*]const u8, @ptrCast(entry))[0..entry_bytes]);
}

/// A header's block made: the header with both its crcs and zeroes after
/// it.
///
/// INPUTS:
/// - `header` - the header, its crcs set.
/// - `entries_crc` - the crc32 of its entries (`entriesCrc`,
///   `EntriesCrc`).
/// - `block` - the whole block, written over.
pub fn putHeader(header: *Header, entries_crc: u32, block: []u8) void {
    header.header_size = header_bytes;
    header.partition_entry_array_crc32 = entries_crc;
    header.header_crc32 = 0;
    @memset(block, 0);
    @memcpy(block[0..header_bytes], @as([*]const u8, @ptrCast(header))[0..header_bytes]);
    header.header_crc32 = flashfs.crc32(block[0..header_bytes]);
    fat.putU32(block, @offsetOf(Header, "header_crc32"), header.header_crc32);
}

/// A protective MBR made in a block: one partition of type 0xEE from
/// block 1 over the rest of the medium, as far as its 32-bit count goes,
/// and the signature.
///
/// INPUTS:
/// - `block` - the medium's first block, written over.
/// - `blocks` - the medium's blocks.
pub fn makeProtective(block: []u8, blocks: u64) void {
    @memset(block, 0);
    const at = fat.partition_table_at;
    // CHS of the first block, then of a medium too large to count so.
    block[at + 1] = 0x00;
    block[at + 2] = 0x02;
    block[at + 3] = 0x00;
    block[at + 4] = PROTECTIVE_TYPE;
    block[at + 5] = 0xFF;
    block[at + 6] = 0xFF;
    block[at + 7] = 0xFF;
    fat.putU32(block, at + 8, 1);
    fat.putU32(block, at + 12, @intCast(@min(blocks - 1, 0xFFFF_FFFF)));
    fat.putU16(block, fat.signature_at, fat.signature);
}
