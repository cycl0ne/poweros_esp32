// SPDX-License-Identifier: MPL-2.0
//! Code objects for the graphics block's compute engine: what LoadGPUCode
//! and FindGPUKernel read of one.
//!
//! **A code object** is an ELF shared object of the vendor's kind for its
//! graphics blocks (amdgcn-amdhsa): 64-bit, little-endian, its ABI the
//! vendor's for code object versions 4 to 6, its machine the block's
//! graphics processor (gfx1103 on the graphics block 11.0.1). The build's
//! own compiler and linker make one (`poweros_sdk.addGPUCode`). Its
//! loadable segments are placed in one piece of the device's memory, each
//! at its address less the first segment's page; what a segment has no
//! bytes for is zero. Relocations of the one kind such an object uses for
//! its own addresses - the piece's start added (R_AMDGPU_RELATIVE64) -
//! are applied; an object with any other kind is refused.
//!
//! **A kernel** is found by its descriptor, 64 bytes the code object
//! holds for it (kernel_descriptor_t): the symbol `<name>.kd`, or - as
//! the build's compiler names a kernel it exports, after the file it is
//! in - the descriptor whose code starts where the function `<name>`
//! does. The descriptor gives where the kernel's code is, from the
//! descriptor itself, its program's resource words, the bytes of its
//! arguments, of the group memory a group uses and of private memory a
//! lane does, and the values it takes in its registers.
//!
//! Everything read is checked against the image's length first: a code
//! object that names a place outside itself is refused, not read.

const amdgpu = @import("sdk").resources.amdgpu;

/// The ELF header's identification and the machine the object is for.
const ELFCLASS64 = 2;
const ELFDATA2LSB = 1;
const ELFOSABI_AMDGPU_HSA = 64;
const abi_versions = [_]u8{ 2, 3, 4 };
const ET_DYN = 3;
const EM_AMDGPU = 224;
const EF_AMDGPU_MACH_MASK: u32 = 0xff;
/// The machine of the graphics block 11.0.1.
pub const EF_AMDGPU_MACH_GFX1103: u32 = 0x44;

pub const PT_LOAD = 1;
const PT_DYNAMIC = 2;
const SHT_SYMTAB = 2;
const SHT_DYNSYM = 11;
const STT_OBJECT = 1;
const STT_FUNC = 2;
const DT_NULL = 0;
const DT_PLTRELSZ = 2;
const DT_RELA = 7;
const DT_RELASZ = 8;
const DT_RELAENT = 9;
const DT_RELSZ = 18;
const R_AMDGPU_RELATIVE64 = 13;

const header_bytes = 64;
const program_header_bytes = 56;
const section_header_bytes = 64;
const symbol_bytes = 24;
const dynamic_bytes = 16;
const rela_bytes = 24;
pub const relocation_bytes = rela_bytes;
pub const descriptor_bytes = 64;
/// The most a code object's segments may span.
pub const most_bytes: u64 = 64 << 20;
pub const page: u64 = 4096;

/// A little-endian value of `T` at byte `at` of `image`, or null where
/// it is not all in the image.
fn read(comptime T: type, image: []const u8, at: u64) ?T {
    const size = @sizeOf(T);
    if (at > image.len or image.len - at < size) return null;
    const start: usize = @intCast(at);
    var value: T = 0;
    inline for (0..size) |index| value |= @as(T, image[start + index]) << (8 * index);
    return value;
}

/// What the ELF header says of the object, once it is one for `machine`.
pub const Header = struct {
    phoff: u64,
    phnum: u16,
    shoff: u64,
    shnum: u16,
};

pub fn header(image: []const u8, machine: u32) ?Header {
    if (image.len < header_bytes) return null;
    if (image[0] != 0x7f or image[1] != 'E' or image[2] != 'L' or image[3] != 'F') return null;
    if (image[4] != ELFCLASS64 or image[5] != ELFDATA2LSB or image[7] != ELFOSABI_AMDGPU_HSA) return null;
    var known = false;
    for (abi_versions) |version| known = known or image[8] == version;
    if (!known) return null;
    if (read(u16, image, 16).? != ET_DYN or read(u16, image, 18).? != EM_AMDGPU) return null;
    if (read(u32, image, 48).? & EF_AMDGPU_MACH_MASK != machine) return null;
    if (read(u16, image, 54).? != program_header_bytes) return null;
    const sections = read(u16, image, 60).?;
    if (sections != 0 and read(u16, image, 58).? != section_header_bytes) return null;
    return .{ .phoff = read(u64, image, 32).?, .phnum = read(u16, image, 56).?, .shoff = read(u64, image, 40).?, .shnum = sections };
}

/// A program header: its type, where its bytes are in the image and how
/// many, and where it goes and how many bytes it takes there.
pub const Segment = struct { kind: u32, offset: u64, file_bytes: u64, address: u64, memory_bytes: u64 };

pub fn segment(image: []const u8, head: Header, index: u16) ?Segment {
    const at = head.phoff + @as(u64, index) * program_header_bytes;
    const one: Segment = .{
        .kind = read(u32, image, at) orelse return null,
        .offset = read(u64, image, at + 8) orelse return null,
        .address = read(u64, image, at + 16) orelse return null,
        .file_bytes = read(u64, image, at + 32) orelse return null,
        .memory_bytes = read(u64, image, at + 40) orelse return null,
    };
    if (one.kind == PT_LOAD or one.kind == PT_DYNAMIC) {
        if (one.file_bytes > one.memory_bytes or one.offset > image.len or image.len - one.offset < one.file_bytes) return null;
        if (one.address > most_bytes << 8 or one.memory_bytes > most_bytes) return null;
    }
    return one;
}

/// The addresses the loadable segments span, from the first one's page
/// to the end of the last one's, rounded up to a page: null where there
/// is none, a header cannot be read or they span more than `most_bytes`.
pub const Span = struct { first: u64, bytes: u64 };

pub fn span(image: []const u8, head: Header) ?Span {
    var first: u64 = ~@as(u64, 0);
    var last: u64 = 0;
    for (0..head.phnum) |index| {
        const one = segment(image, head, @intCast(index)) orelse return null;
        if (one.kind != PT_LOAD or one.memory_bytes == 0) continue;
        first = @min(first, one.address & ~(page - 1));
        last = @max(last, one.address + one.memory_bytes);
    }
    if (last == 0) return null;
    const bytes = (last - first + page - 1) & ~(page - 1);
    if (bytes > most_bytes) return null;
    return .{ .first = first, .bytes = bytes };
}

/// Where in the image the bytes at `address` are, `bytes` of them, by the
/// loadable segment that holds them; null where none holds them all.
pub fn offsetOf(image: []const u8, head: Header, address: u64, bytes: u64) ?u64 {
    for (0..head.phnum) |index| {
        const one = segment(image, head, @intCast(index)) orelse return null;
        if (one.kind != PT_LOAD) continue;
        if (address < one.address or address - one.address > one.file_bytes or one.file_bytes - (address - one.address) < bytes) continue;
        return one.offset + (address - one.address);
    }
    return null;
}

/// The relocations the object asks of its loader: where its table of
/// them is, by address, and how many bytes; null where it asks for a kind
/// the loader does not do - relocations without addends, or of its
/// procedure linkage.
pub const Relocations = struct { address: u64, bytes: u64 };

pub fn relocations(image: []const u8, head: Header) ?Relocations {
    var asked: Relocations = .{ .address = 0, .bytes = 0 };
    for (0..head.phnum) |index| {
        const one = segment(image, head, @intCast(index)) orelse return null;
        if (one.kind != PT_DYNAMIC) continue;
        var at = one.offset;
        while (at + dynamic_bytes <= one.offset + one.file_bytes) : (at += dynamic_bytes) {
            const tag = read(u64, image, at) orelse return null;
            const value = read(u64, image, at + 8) orelse return null;
            switch (tag) {
                DT_NULL => break,
                DT_RELA => asked.address = value,
                DT_RELASZ => asked.bytes = value,
                DT_RELAENT => if (value != rela_bytes) return null,
                DT_RELSZ, DT_PLTRELSZ => if (value != 0) return null,
                else => {},
            }
        }
    }
    return asked;
}

/// A relocation: where it writes, by address, and the value - the
/// piece's start added to `addend`; null where it is not the kind the
/// loader does.
pub const Relocation = struct { address: u64, addend: u64 };

pub fn relocation(image: []const u8, at: u64) ?Relocation {
    const info = read(u64, image, at + 8) orelse return null;
    if (info != R_AMDGPU_RELATIVE64) return null;
    return .{ .address = read(u64, image, at) orelse return null, .addend = read(u64, image, at + 16) orelse return null };
}

/// A symbol: its name's place in its table's strings, its type, its
/// address and its size.
const Symbol = struct { name: u64, kind: u8, value: u64, size: u64 };

/// The symbol tables' sections, each with its strings: where in the
/// image, and how many bytes.
const Table = struct { symbols: u64, symbols_bytes: u64, strings: u64, strings_bytes: u64 };

fn symbolTable(image: []const u8, head: Header, index: u16) ?Table {
    const at = head.shoff + @as(u64, index) * section_header_bytes;
    const kind = read(u32, image, at + 4) orelse return null;
    if (kind != SHT_SYMTAB and kind != SHT_DYNSYM) return null;
    const link = read(u32, image, at + 40) orelse return null;
    if (link >= head.shnum) return null;
    const strings_at = head.shoff + @as(u64, link) * section_header_bytes;
    const found: Table = .{
        .symbols = read(u64, image, at + 24) orelse return null,
        .symbols_bytes = read(u64, image, at + 32) orelse return null,
        .strings = read(u64, image, strings_at + 24) orelse return null,
        .strings_bytes = read(u64, image, strings_at + 32) orelse return null,
    };
    if (found.symbols > image.len or image.len - found.symbols < found.symbols_bytes) return null;
    if (found.strings > image.len or image.len - found.strings < found.strings_bytes) return null;
    return found;
}

fn symbol(image: []const u8, at: u64) ?Symbol {
    return .{
        .name = read(u32, image, at) orelse return null,
        .kind = (read(u8, image, at + 4) orelse return null) & 0xf,
        .value = read(u64, image, at + 8) orelse return null,
        .size = read(u64, image, at + 16) orelse return null,
    };
}

/// Whether the name at `at` of `strings` is `name` followed by `suffix`.
fn named(image: []const u8, strings: Table, at: u64, name: [*:0]const u8, suffix: []const u8) bool {
    var index: u64 = 0;
    while (name[@intCast(index)] != 0) : (index += 1) {
        if (at + index >= strings.strings_bytes or image[@intCast(strings.strings + at + index)] != name[@intCast(index)]) return false;
    }
    for (suffix) |char| {
        if (at + index >= strings.strings_bytes or image[@intCast(strings.strings + at + index)] != char) return false;
        index += 1;
    }
    return at + index < strings.strings_bytes and image[@intCast(strings.strings + at + index)] == 0;
}

/// Whether the name at `at` of `strings` ends in `suffix`.
fn endsIn(image: []const u8, strings: Table, at: u64, suffix: []const u8) bool {
    var end = at;
    while (end < strings.strings_bytes and image[@intCast(strings.strings + end)] != 0) end += 1;
    if (end >= strings.strings_bytes or end - at < suffix.len) return false;
    for (suffix, 0..) |char, index| {
        if (image[@intCast(strings.strings + end - suffix.len + index)] != char) return false;
    }
    return true;
}

/// The first symbol of the object's tables for which `wanted` answers
/// true, by its address; null where none does.
fn findSymbol(image: []const u8, head: Header, context: anytype, comptime wanted: fn (@TypeOf(context), []const u8, Table, Symbol) bool) ?u64 {
    for (0..head.shnum) |index| {
        const strings = symbolTable(image, head, @intCast(index)) orelse continue;
        var at = strings.symbols;
        while (at + symbol_bytes <= strings.symbols + strings.symbols_bytes) : (at += symbol_bytes) {
            const one = symbol(image, at) orelse break;
            if (wanted(context, image, strings, one)) return one.value;
        }
    }
    return null;
}

/// A kernel's descriptor, as the code object holds it.
pub const Descriptor = struct {
    group_bytes: u32,
    private_bytes: u32,
    argument_bytes: u32,
    entry: i64,
    rsrc3: u32,
    rsrc1: u32,
    rsrc2: u32,
    properties: u16,
    preloaded: u16,
};

pub fn descriptorAt(image: []const u8, at: u64) ?Descriptor {
    return .{
        .group_bytes = read(u32, image, at) orelse return null,
        .private_bytes = read(u32, image, at + 4) orelse return null,
        .argument_bytes = read(u32, image, at + 8) orelse return null,
        .entry = @bitCast(read(u64, image, at + 16) orelse return null),
        .rsrc3 = read(u32, image, at + 44) orelse return null,
        .rsrc1 = read(u32, image, at + 48) orelse return null,
        .rsrc2 = read(u32, image, at + 52) orelse return null,
        .properties = read(u16, image, at + 56) orelse return null,
        .preloaded = read(u16, image, at + 58) orelse return null,
    };
}

/// The address of the descriptor of the kernel `name`: the symbol
/// `<name>.kd`, else the descriptor whose code starts at the function
/// `<name>`.
pub fn kernelDescriptor(image: []const u8, head: Header, name: [*:0]const u8) ?u64 {
    const ByName = struct {
        fn wanted(wanted_name: [*:0]const u8, bytes: []const u8, strings: Table, one: Symbol) bool {
            return one.kind == STT_OBJECT and one.size == descriptor_bytes and named(bytes, strings, one.name, wanted_name, ".kd");
        }
    };
    if (findSymbol(image, head, name, ByName.wanted)) |address| return address;
    const Function = struct {
        fn wanted(wanted_name: [*:0]const u8, bytes: []const u8, strings: Table, one: Symbol) bool {
            return one.kind == STT_FUNC and named(bytes, strings, one.name, wanted_name, "");
        }
    };
    const entry = findSymbol(image, head, name, Function.wanted) orelse return null;
    const Starting = struct {
        image: []const u8,
        head: Header,
        entry: u64,
        fn wanted(context: @This(), bytes: []const u8, strings: Table, one: Symbol) bool {
            if (one.kind != STT_OBJECT or one.size != descriptor_bytes or !endsIn(bytes, strings, one.name, ".kd")) return false;
            const at = offsetOf(context.image, context.head, one.value, descriptor_bytes) orelse return false;
            const found = descriptorAt(context.image, at) orelse return false;
            return one.value +% @as(u64, @bitCast(found.entry)) == context.entry;
        }
    };
    return findSymbol(image, head, Starting{ .image = image, .head = head, .entry = entry }, Starting.wanted);
}

// --- tests --------------------------------------------------------------------------------

const testing = @import("std").testing;

test "the kernel C:test/Gpu runs, as the build makes it" {
    const image: []const u8 = @embedFile("gpu_test_code");
    const head = header(image, EF_AMDGPU_MACH_GFX1103) orelse return error.NotACodeObject;
    try testing.expect(header(image, 0x41) == null);
    const covered = span(image, head) orelse return error.NoSegments;
    try testing.expectEqual(@as(u64, 0), covered.first);
    try testing.expect(covered.bytes >= 3 * page and covered.bytes % page == 0);
    const asked = relocations(image, head) orelse return error.UnknownRelocations;
    try testing.expectEqual(@as(u64, 0), asked.bytes);

    const at = kernelDescriptor(image, head, "fill") orelse return error.NoKernel;
    const found = descriptorAt(image, offsetOf(image, head, at, descriptor_bytes).?).?;
    const entry = at +% @as(u64, @bitCast(found.entry));
    try testing.expectEqual(@as(u64, 0), entry % 256);
    try testing.expect(entry > at and entry < covered.bytes);
    try testing.expectEqual(@as(u16, amdgpu.GPUKERNEL_ARGUMENTS | amdgpu.GPUKERNEL_WAVE32), found.properties);
    try testing.expectEqual(@as(u32, 0), found.private_bytes);
    try testing.expectEqual(@as(u32, 0), found.group_bytes);
    try testing.expect(found.argument_bytes >= 16);
    try testing.expectEqual(@as(u32, 2), (found.rsrc2 >> 1) & 0x1f);
    try testing.expectEqual(@as(u32, 0), found.rsrc2 & 1);
    try testing.expectEqual(@as(u16, 0), found.preloaded);
    try testing.expect(kernelDescriptor(image, head, "fil") == null);
    try testing.expect(kernelDescriptor(image, head, "fills") == null);

    // `walk` recurses: its stack grows as it runs, past the private bytes
    // its descriptor gives, and its properties say so.
    const walk_at = kernelDescriptor(image, head, "walk") orelse return error.NoKernel;
    const walk = descriptorAt(image, offsetOf(image, head, walk_at, descriptor_bytes).?).?;
    try testing.expect(walk.properties & amdgpu.GPUKERNEL_DYNAMIC_STACK != 0);
    try testing.expect(walk.private_bytes > 0);
    try testing.expectEqual(@as(u32, 1), walk.rsrc2 & 1);
}

test "a code object cut short is refused" {
    const image: []const u8 = @embedFile("gpu_test_code");
    try testing.expect(header(image[0..40], EF_AMDGPU_MACH_GFX1103) == null);
    const head = header(image, EF_AMDGPU_MACH_GFX1103).?;
    const short = image[0 .. head.phoff + 10];
    try testing.expect(span(short, head) == null);
    var other: [header_bytes]u8 = image[0..header_bytes].*;
    other[18] = 62;
    try testing.expect(header(&other, EF_AMDGPU_MACH_GFX1103) == null);
}
