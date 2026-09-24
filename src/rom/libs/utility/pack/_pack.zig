// SPDX-License-Identifier: MPL-2.0
//! What the pack calls share: the fields of a pack-table entry (offset,
//! bit, tag, size) and the byte order, plus the tests' record and table.

const sdk = @import("sdk");
const pack = sdk.utility.pack;

const Tag = sdk.utility.Tag;

/// The size of a pack-table field: bits 27-28 of an entry.
pub const Size = enum(u2) { byte, word, long, bit };

/// The size of the field an entry describes.
///
/// INPUTS:
/// - `entry` - a pack-table entry.
pub fn sizeOf(entry: u32) Size {
    return @enumFromInt(@as(u2, @truncate(entry >> 27)));
}

/// The byte offset of the field an entry describes (for a bit, of its
/// byte): bits 0-12.
///
/// INPUTS:
/// - `entry` - a pack-table entry.
pub fn offsetOf(entry: u32) usize {
    return entry & 0x1FFF;
}

/// The bit a bit entry describes, within its byte: bits 13-15.
///
/// INPUTS:
/// - `entry` - a pack-table entry.
pub fn bitNumber(entry: u32) u3 {
    return @truncate(entry >> 13);
}

/// The entry's tag, as its distance from the table's base tag: bits 16-25.
///
/// INPUTS:
/// - `entry` - a pack-table entry.
pub fn tagDelta(entry: u32) Tag {
    return (entry >> 16) & 0x3FF;
}

// --- tests (host: ./zig build test) -----------------------------------------

/// The structure the tests pack into and unpack from.
pub const Record = extern struct {
    long: u32 = 0,
    word: i16 = 0,
    flags: u16 = 0,
    small: u8 = 0,
};

/// The tests' first base tag.
pub const base_tag = sdk.utility.TAG_USER + 100;
/// The tests' second base tag, after `PACK_NEWOFFSET`.
pub const other_tag = sdk.utility.TAG_USER + 500;

/// The tests' pack table: every size, the bit kinds, pack-only and
/// unpack-only entries, and a switch of base tag.
pub const test_table = [_]u32{
    base_tag,
    pack.packEntry(base_tag, base_tag + 1, @offsetOf(Record, "small"), pack.PKCTRL_UBYTE),
    pack.packEntry(base_tag, base_tag + 2, @offsetOf(Record, "word"), pack.PKCTRL_WORD),
    pack.packEntry(base_tag, base_tag + 3, @offsetOf(Record, "long"), pack.PKCTRL_ULONG | pack.PKCTRL_PACKONLY),
    pack.packBit(base_tag, base_tag + 4, @offsetOf(Record, "flags"), pack.PKCTRL_BIT, 0x0100),
    pack.packBit(base_tag, base_tag + 5, @offsetOf(Record, "flags"), pack.PKCTRL_FLIPBIT, 0x0002),
    pack.packBit(base_tag, base_tag + 6, @offsetOf(Record, "flags"), pack.PKCTRL_BIT | pack.PSTF_EXISTS, 0x0004),
    pack.PACK_NEWOFFSET,
    other_tag,
    pack.packEntry(other_tag, other_tag + 1, @offsetOf(Record, "long"), pack.PKCTRL_LONG | pack.PKCTRL_UNPACKONLY),
    pack.PACK_ENDTABLE,
};
