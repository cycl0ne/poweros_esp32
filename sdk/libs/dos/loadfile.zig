// SPDX-License-Identifier: MIT
//! The load file: what LoadSeg reads, and what `sdk/tools/elf2seg` makes
//! from a linked program. Hunks in spirit (HUNK_CODE, HUNK_DATA,
//! HUNK_BSS, HUNK_RELOC32), without the BCPL parts: sizes are
//! bytes, offsets are 32-bit, and there is a header instead of a hunk
//! table.
//!
//! A file holds segments, each with its bytes and the places in it that
//! hold an address of another segment (or of itself). Loading is: allocate
//! each segment, copy its bytes, clear the rest, then for every relocation
//! add the target segment's base to the 32-bit word at the offset. On
//! Xtensa the linker has already done every PC-relative fixup (an l32r
//! finds its literal at a fixed distance), so this is all that is left.
//!
//! The base added for a code segment is its address on the instruction bus
//! (exec's CodeAddress), for data and bss its ordinary address. That is why
//! a relocation names the segment it points into.
//!
//! Two kinds of file use the same container: a program, whose entry is a
//! CommandFn, and a module (library, device, handler, resource), whose code
//! starts with a stub that refuses to run followed by a ROM tag.

/// The first four bytes of a load file.
pub const MAGIC = [4]u8{ 'P', 'S', 'G', '1' };

/// load_Version: the format below.
pub const VERSION: u16 = 1;

pub const SegmentKind = enum(u8) {
    /// Runs: loaded where the instruction bus reaches it.
    code = 0,
    /// Read and written: rodata and data.
    data = 1,
    /// No bytes in the file, cleared when loaded.
    bss = 2,
    _,
};

/// The file's header, then each segment's header and bytes, then the
/// relocation groups of each segment in the same order. Everything is read
/// straight through: the loader never seeks.
pub const Header = extern struct {
    magic: [4]u8 = MAGIC,
    version: u16 = VERSION,
    /// How many segments follow.
    segments: u16,
    /// Which segment the entry is in (a code one).
    entry_segment: u16,
    pad: u16 = 0,
    /// The entry's offset in that segment.
    entry_offset: u32,
};

/// A segment's header, with `file_size` bytes after it (padded to 4). Its
/// `reloc_groups` groups come later, after the last segment's bytes.
pub const SegmentHeader = extern struct {
    kind: SegmentKind,
    flags: u8 = 0,
    pad: u16 = 0,
    /// Bytes in the file (0 for bss).
    file_size: u32,
    /// Bytes to allocate; the rest past file_size is cleared.
    mem_size: u32,
    /// Relocation groups after the bytes.
    reloc_groups: u32,
};

/// `count` offsets into this segment follow, each holding an address of
/// `target_segment` to which its base is added.
pub const RelocGroup = extern struct {
    target_segment: u16,
    pad: u16 = 0,
    count: u32,
};

/// Sizes are rounded up to this, so every header stays aligned.
pub const ALIGN = 4;

pub fn alignUp(n: u32) u32 {
    return (n + (ALIGN - 1)) & ~@as(u32, ALIGN - 1);
}
