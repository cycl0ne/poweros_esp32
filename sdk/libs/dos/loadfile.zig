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

// --- reading a module's ROM tag without loading it --------------------------------

/// Where a load file's bytes are read from, by offset: a file through
/// dos, or bytes already in memory.
pub const Source = struct {
    context: *anyopaque,
    /// `into.len` bytes at `offset` of the file into `into`; false if the
    /// file has not that many there.
    readAt: *const fn (context: *anyopaque, offset: u32, into: []u8) bool,
};

/// A module's ROM tag found in its load file: the segment it is in -
/// where that segment's bytes start in the file, and how many there are -
/// and the tag's offset in the segment.
///
/// Every address word in a file holds an offset into the segment it
/// points into, which loading turns into an address. A tag's
/// self-pointer is relocated against the segment it is in, so in the
/// file it reads as the tag's own offset there: that, after the match
/// word, is how a tag is told from bytes that look like one. Its name and
/// whatever else it points at are in the same segment - rodata goes with
/// the data on Xtensa, and on RISC-V there is one segment - so a pointer
/// field of the tag, read from the file, is an offset to read at
/// (`readWord`, `readBytes`, `readString`), checked against the segment.
pub const FoundTag = struct {
    file_offset: u32,
    size: u32,
    tag: u32,
};

/// The ROM tag in a module's load file, or null if the file is not a load
/// file for this CPU or holds no tag. The data segments are looked
/// through first, then the code ones; nothing is loaded and nothing runs.
pub fn findResident(source: Source) ?FoundTag {
    var header_bytes: [@sizeOf(Header)]u8 = undefined;
    if (!source.readAt(source.context, 0, header_bytes[0..HEADER_V1_SIZE])) return null;
    if (!bytesEqual(header_bytes[0..4], &MAGIC)) return null;
    const version = word16(header_bytes[4..6]);
    var header_size: u32 = HEADER_V1_SIZE;
    if (version >= 2) {
        if (!source.readAt(source.context, 0, &header_bytes)) return null;
        if (word16(header_bytes[10..12]) != native_machine) return null;
        if (header_bytes[16] != 4) return null;
        header_size = @sizeOf(Header);
    } else if (native_machine != MACHINE_XTENSA) {
        return null;
    }
    const segments = word16(header_bytes[6..8]);
    for ([_]SegmentKind{ .data, .code }) |wanted| {
        var at = header_size;
        var index: u32 = 0;
        while (index < segments) : (index += 1) {
            var segment_bytes: [@sizeOf(SegmentHeader)]u8 = undefined;
            if (!source.readAt(source.context, at, &segment_bytes)) return null;
            const kind: SegmentKind = @enumFromInt(segment_bytes[0]);
            const file_size = word32(segment_bytes[4..8]);
            const start = at + @sizeOf(SegmentHeader);
            if (kind == wanted and file_size >= @sizeOf(u32) * 2) {
                if (scanSegment(source, start, file_size)) |tag| {
                    return .{ .file_offset = start, .size = file_size, .tag = tag };
                }
            }
            at = start + alignUp(file_size);
        }
    }
    return null;
}

/// The offset of the first ROM tag in a segment's `size` bytes at
/// `start`, read a chunk at a time.
fn scanSegment(source: Source, start: u32, size: u32) ?u32 {
    const chunk = 256;
    // Each chunk overlaps the next by a tag's first eight bytes, so a tag
    // that starts near a chunk's end is still seen whole.
    var buffer: [chunk + 8]u8 = undefined;
    var base: u32 = 0;
    while (base + 8 <= size) : (base += chunk) {
        const want: u32 = @min(@as(u32, chunk + 8), size - base);
        if (!source.readAt(source.context, start + base, buffer[0..want])) return null;
        var offset: u32 = 0;
        while (offset + 8 <= want) : (offset += 4) {
            if (word16(buffer[offset..][0..2]) != 0x4AFC) continue;
            if (word32(buffer[offset + 4 ..][0..4]) == base + offset) return base + offset;
        }
    }
    return null;
}

/// The address word at `offset` of a found tag's segment (a pointer of
/// the tag: an offset into the segment), or null past its end.
pub fn readWord(source: Source, found: FoundTag, offset: u32) ?u32 {
    if (offset > found.size or found.size - offset < 4) return null;
    var bytes: [4]u8 = undefined;
    if (!source.readAt(source.context, found.file_offset + offset, &bytes)) return null;
    return word32(&bytes);
}

/// `into.len` bytes at `offset` of a found tag's segment; false past its
/// end.
pub fn readBytes(source: Source, found: FoundTag, offset: u32, into: []u8) bool {
    if (offset > found.size or found.size - offset < into.len) return false;
    return source.readAt(source.context, found.file_offset + offset, into);
}

/// The C string at `offset` of a found tag's segment into `into`, ended
/// by a NUL there; null if it does not end within `into` or the segment.
pub fn readString(source: Source, found: FoundTag, offset: u32, into: []u8) ?[:0]u8 {
    var length: u32 = 0;
    while (length < into.len) : (length += 1) {
        if (!readBytes(source, found, offset + length, into[length..][0..1])) return null;
        if (into[length] == 0) return into[0..length :0];
    }
    return null;
}

// --- a device's tag, read from its file ------------------------------------------

const resident = @import("../exec/resident.zig");
const NodeType = @import("../exec/nodes.zig").NodeType;

/// Where a ROM tag's fields lie in a load file, whose address words are
/// four bytes (its header says so): a Resident's, then a
/// ResidentDevice's own. Written out rather than taken from the types, so
/// a build with wider pointers - the host tests' - reads a file the same.
const TAG_FLAGS = 12;
const TAG_NAME = 16;
const TAG_ID_STRING = 20;
const DEVICE_SPEAKS = 28;
const DEVICE_UNIT_PART = 32;
const DEVICE_UNITS = 36;
const DEVICE_UNIT_LABELS = 40;
const DEVICE_UNIT_CHIP = 44;

comptime {
    if (@sizeOf(usize) == 4) {
        const Device = resident.ResidentDevice;
        if (@offsetOf(resident.Resident, "flags") != TAG_FLAGS or @offsetOf(resident.Resident, "name") != TAG_NAME or
            @offsetOf(resident.Resident, "id_string") != TAG_ID_STRING or @offsetOf(Device, "speaks") != DEVICE_SPEAKS or
            @offsetOf(Device, "unit_part") != DEVICE_UNIT_PART or @offsetOf(Device, "units") != DEVICE_UNITS or
            @offsetOf(Device, "unit_labels") != DEVICE_UNIT_LABELS or @offsetOf(Device, "unit_chip") != DEVICE_UNIT_CHIP)
            @compileError("loadfile: a ROM tag's fields are not where a load file has them");
    }
}

/// The most command sets a device's tag is read for.
pub const max_speaks = 8;

/// A device's ROM tag as its load file has it - a `ResidentDevice`: its
/// name, version and revision, what it speaks and where its units come
/// from; `labels` is where its unit labels' pointers lie, for
/// `readUnitLabel`.
pub const DeviceTag = struct {
    name: [32:0]u8 = @splat(0),
    version: u8 = 0,
    /// From its ID string ("acm.device 1.2 (date)"); 0 when that has none.
    revision: u16 = 0,
    /// DEVIF_*, ended by 0.
    speaks: [max_speaks + 1]u32 = @splat(0),
    unit_part: u32 = 0,
    units: u32 = 0,
    labels: u32 = 0,
    unit_chip: u32 = 0xFFFF_FFFF,
};

/// The device tag found in a module's load file, into `into`: false for a
/// tag that is not a device's saying what it speaks (RTF_DEVICEINFO), or
/// one whose name or command sets lie past its segment. A device that
/// speaks more than `max_speaks` sets is read for the first of them.
pub fn readDevice(source: Source, found: FoundTag, into: *DeviceTag) bool {
    into.* = .{};
    var head: [3]u8 = undefined;
    if (!readBytes(source, found, found.tag + TAG_FLAGS, &head)) return false;
    if (head[0] & resident.RTF_DEVICEINFO == 0 or head[2] != @intFromEnum(NodeType.device)) return false;
    into.version = head[1];
    const name_at = readWord(source, found, found.tag + TAG_NAME) orelse return false;
    _ = readString(source, found, name_at, into.name[0..into.name.len]) orelse return false;
    const id_at = readWord(source, found, found.tag + TAG_ID_STRING) orelse return false;
    if (id_at != 0) {
        var id: [64]u8 = undefined;
        if (readString(source, found, id_at, &id)) |text| into.revision = resident.revisionOf(text);
    }
    const speaks_at = readWord(source, found, found.tag + DEVICE_SPEAKS) orelse return false;
    var count: u32 = 0;
    while (count < max_speaks) : (count += 1) {
        const set = readWord(source, found, speaks_at + count * 4) orelse return false;
        if (set == 0) break;
        into.speaks[count] = set;
    }
    into.unit_part = readWord(source, found, found.tag + DEVICE_UNIT_PART) orelse return false;
    into.units = readWord(source, found, found.tag + DEVICE_UNITS) orelse return false;
    into.labels = readWord(source, found, found.tag + DEVICE_UNIT_LABELS) orelse return false;
    into.unit_chip = readWord(source, found, found.tag + DEVICE_UNIT_CHIP) orelse return false;
    return true;
}

/// Unit `index`'s label, of a device tag `readDevice` read, into `into`;
/// null for a device without labels, past its units, or one whose label
/// does not fit. A label pointer of 0 is none: offset 0 of a module's data
/// segment is its version string, never a label.
pub fn readUnitLabel(source: Source, found: FoundTag, tag: *const DeviceTag, index: u32, into: []u8) ?[:0]u8 {
    if (tag.labels == 0 or index >= tag.units) return null;
    const at = readWord(source, found, tag.labels + index * 4) orelse return null;
    if (at == 0) return null;
    return readString(source, found, at, into);
}

fn word16(bytes: *const [2]u8) u16 {
    return @as(u16, bytes[0]) | @as(u16, bytes[1]) << 8;
}

fn word32(bytes: *const [4]u8) u32 {
    return @as(u32, bytes[0]) | @as(u32, bytes[1]) << 8 | @as(u32, bytes[2]) << 16 | @as(u32, bytes[3]) << 24;
}

fn bytesEqual(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (x != y) return false;
    return true;
}
