// SPDX-License-Identifier: MIT
//! Pack tables, for PackStructureTags and
//! UnpackStructureTags. A table starts with a base tag, then has one u32
//! per field:
//!
//!   bits  0-12  byte offset of the field (for a bit: of its byte)
//!   bits 13-15  bit number within that byte
//!   bits 16-25  tag minus the base tag
//!   bit  26     PSTF_EXISTS: a bit is set when the tag is there, whatever
//!               its data
//!   bits 27-28  size: byte, word, long or bit
//!   bit  29     PSTF_PACK: set, PackStructureTags passes over it
//!   bit  30     PSTF_UNPACK: set, UnpackStructureTags passes over it
//!   bit  31     PSTF_SIGNED: a signed field; for a bit, inverted
//!
//! PACK_NEWOFFSET and then a new base tag switch the base. PACK_ENDTABLE
//! (0) ends the table, so the entry of the base tag itself for an unsigned
//! byte at offset 0 can't be written.
//!
//! packEntry and packBit build the entries. The bytes of words and longs
//! are in the CPU's order, which is little-endian here, so a flag's byte is
//! `offset + bit / 8`.

const std = @import("std");
const Tag = @import("tagitem.zig").Tag;

pub const PSTF_SIGNED: u32 = 1 << 31;
pub const PSTF_UNPACK: u32 = 1 << 30;
pub const PSTF_PACK: u32 = 1 << 29;
pub const PSTF_EXISTS: u32 = 1 << 26;

/// Which way an entry works.
pub const PKCTRL_PACKUNPACK: u32 = 0x0000_0000;
pub const PKCTRL_PACKONLY: u32 = PSTF_UNPACK;
pub const PKCTRL_UNPACKONLY: u32 = PSTF_PACK;

/// Field types. Signed fields are sign-extended when unpacked.
pub const PKCTRL_BYTE: u32 = 0x8000_0000;
pub const PKCTRL_WORD: u32 = 0x8800_0000;
pub const PKCTRL_LONG: u32 = 0x9000_0000;
pub const PKCTRL_UBYTE: u32 = 0x0000_0000;
pub const PKCTRL_UWORD: u32 = 0x0800_0000;
pub const PKCTRL_ULONG: u32 = 0x1000_0000;
pub const PKCTRL_BIT: u32 = 0x1800_0000;
pub const PKCTRL_FLIPBIT: u32 = 0x9800_0000;

pub const PACK_ENDTABLE: u32 = 0;
pub const PACK_NEWOFFSET: u32 = 0xFFFF_FFFF;

/// PACK_ENTRY: `tag` into the field at `field_offset` (@offsetOf), as
/// `control` says (PKCTRL_ULONG, PKCTRL_WORD | PKCTRL_PACKONLY, ...).
pub fn packEntry(tag_base: Tag, tag: Tag, field_offset: usize, control: u32) u32 {
    std.debug.assert(tag - tag_base <= 0x3FF and field_offset <= 0x1FFF);
    return control | (tag - tag_base) << 16 | @as(u32, @intCast(field_offset));
}

/// PACK_BYTEBIT, PACK_WORDBIT and PACK_LONGBIT in one: `flag` is the
/// field's bit (one set bit), `control` PKCTRL_BIT or PKCTRL_FLIPBIT.
/// Little-endian, so its byte is `field_offset + bit / 8` whatever the
/// field's size.
pub fn packBit(tag_base: Tag, tag: Tag, field_offset: usize, control: u32, flag: u32) u32 {
    std.debug.assert(@popCount(flag) == 1);
    const bit = @ctz(flag);
    return packEntry(tag_base, tag, field_offset + bit / 8, control) | @as(u32, bit % 8) << 13;
}
