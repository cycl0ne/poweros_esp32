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
//! add the target segment's base to the address word at the offset. The
//! linker has already done every PC-relative fixup, so this is all that
//! is left: on Xtensa an l32r finds its literal at a fixed distance in the
//! code segment; on RISC-V the code is built PC-relative (medany) and the
//! file has one segment for code, data and bss, so they keep their
//! distances wherever it is loaded.
//!
//! The header says which CPU the code is for and how wide an address word
//! is, so a file built for another chip is refused rather than run.
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

/// load_Version: the format below. Version 1 had no `machine` (0 there)
/// and no `word_size`, and was Xtensa's.
pub const VERSION: u16 = 2;

/// `machine`: ELF's e_machine for the CPU the code is for.
pub const MACHINE_XTENSA: u16 = 94;
pub const MACHINE_RISCV: u16 = 243;

/// The CPU this code is built for, as a load file names it: a host build
/// (the tests) counts as Xtensa, as it sees the ESP32-S3's hardware.
pub const native_machine: u16 = switch (@import("builtin").cpu.arch) {
    .riscv32, .riscv64 => MACHINE_RISCV,
    else => MACHINE_XTENSA,
};

/// The bytes of an address word on that CPU: 4 on the ESP32s, and on a
/// host build, which stands in for the S3.
pub const native_word_size: u8 = switch (@import("builtin").cpu.arch) {
    .riscv64 => 8,
    else => 4,
};

/// How many bytes of a header a version-1 file has.
pub const HEADER_V1_SIZE = 16;

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
    /// The CPU the code is for (`MACHINE_*`).
    machine: u16 = native_machine,
    /// The entry's offset in that segment.
    entry_offset: u32,
    /// The bytes of an address word, which is what a relocation adds a
    /// segment's base to: 4 on a 32-bit CPU.
    word_size: u8 = native_word_size,
    pad: [3]u8 = .{ 0, 0, 0 },
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

/// Where a loaded segment starts: on this boundary, the coarsest a
/// program's section may ask for (elf2seg refuses a coarser one). A cache
/// line, so a DMA buffer a program aligns to one keeps it.
pub const SEGMENT_ALIGN = 64;

pub fn alignUp(n: u32) u32 {
    return (n + (ALIGN - 1)) & ~@as(u32, ALIGN - 1);
}
