// SPDX-License-Identifier: MIT
//! elf2seg: turns a linked program (src/disk/c, linked with program.ld and
//! --emit-relocs) into a load file for dos.library's LoadSeg
//! (sdk/libs/dos/loadfile.zig).
//!
//! usage: elf2seg <in.elf> <out.seg>
//!
//! The program is already linked, so every PC-relative fixup is done: on
//! Xtensa an l32r finds its literal at a fixed distance, and the linker
//! resolved it (those relocations stay in the file as R_XTENSA_SLOT0_OP and
//! are ignored here); on RISC-V the code is built PC-relative (medany), and
//! its auipc pairs, branches and calls are resolved the same way. What is
//! left are the words that hold an address: R_XTENSA_32, R_RISCV_32. For
//! each one this writes down which segment the word is in, its offset
//! there, and which segment it points into; the loader adds that segment's
//! base to the word.
//!
//! The linker wrote the address the program was linked at, so each such word
//! is made relative to the segment it points into first: the loader knows
//! only where it put each segment, each segment being its own address
//! space. Without this a pointer into a segment that wasn't linked
//! at 0 would come out too high by that segment's link address.
//!
//! A word that points at an absolute symbol - one a linker script sets to
//! a fixed address, as the chip ROM's functions and data are - is not the
//! program's: it holds that address already and is left as it is.
//!
//! Sections become segments. On Xtensa an executable one (SHF_EXECINSTR)
//! is code, a NOBITS one is bss, any other allocatable one is data; code
//! comes first, since the entry is in it. On RISC-V all of them make one
//! segment, code first and bss last (program_esp32p4.ld), because
//! PC-relative code reaches its data at a fixed distance: they have to be
//! loaded together.
//!
//! What a loaded program could not survive fails the build here: an
//! absolute address in RISC-V code (built without medany), a PC-relative
//! reach of a fixed address (a direct call into the ROM - go through a
//! pointer, which is a word the loader leaves alone), the GOT or TLS.

const std = @import("std");
const mem = std.mem;
const loadfile = @import("sdk").dos.loadfile;

// ELF32 header offsets (little-endian; the same hand-rolled style as
// tools/ressize.zig, which needs no std.elf either).
const e_type = 0x10;
const e_machine = 0x12;
const e_entry = 0x18;
const e_shoff = 0x20;
const e_shentsize = 0x2E;
const e_shnum = 0x30;
const e_shstrndx = 0x32;

const sh_name = 0;
const sh_type = 4;
const sh_flags = 8;
const sh_addr = 12;
const sh_offset = 16;
const sh_size = 20;
const sh_link = 24;
const sh_info = 28;
const sh_entsize = 36;

const SHT_PROGBITS = 1;
const SHT_SYMTAB = 2;
const SHT_NOBITS = 8;
const SHT_RELA = 4;
const SHF_ALLOC = 2;
const SHF_EXECINSTR = 4;

const SHN_ABS = 0xFFF1;

const EM_XTENSA = 94;
const EM_RISCV = 243;
const ET_EXEC = 2;

const R_XTENSA_NONE = 0;
const R_XTENSA_32 = 1;
const R_XTENSA_ASM_EXPAND = 11;
const R_XTENSA_DIFF32 = 19;
const R_XTENSA_SLOT0_OP = 20;

const R_RISCV_NONE = 0;
const R_RISCV_32 = 1;
const R_RISCV_BRANCH = 16;
const R_RISCV_JAL = 17;
const R_RISCV_CALL = 18;
const R_RISCV_CALL_PLT = 19;
const R_RISCV_PCREL_HI20 = 23;
const R_RISCV_PCREL_LO12_I = 24;
const R_RISCV_PCREL_LO12_S = 25;
const R_RISCV_HI20 = 26;
const R_RISCV_LO12_I = 27;
const R_RISCV_LO12_S = 28;
const R_RISCV_ADD8 = 33;
const R_RISCV_SUB64 = 40;
const R_RISCV_ALIGN = 43;
const R_RISCV_RVC_BRANCH = 44;
const R_RISCV_RVC_JUMP = 45;
const R_RISCV_RELAX = 51;
const R_RISCV_SUB6 = 52;
const R_RISCV_SET32 = 56;
const R_RISCV_32_PCREL = 57;
const R_RISCV_PLT32 = 59;
const R_RISCV_SET_ULEB128 = 60;
const R_RISCV_SUB_ULEB128 = 61;

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("elf2seg: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

fn u16At(buf: []const u8, off: usize) u16 {
    return mem.readInt(u16, buf[off..][0..2], .little);
}

fn u32At(buf: []const u8, off: usize) u32 {
    return mem.readInt(u32, buf[off..][0..4], .little);
}

const Section = struct {
    name: []const u8,
    type: u32,
    flags: u32,
    addr: u32,
    offset: u32,
    size: u32,
    link: u32,
    info: u32,
    entsize: u32,
    /// Which segment it became, if any.
    segment: ?u16 = null,
};

/// A segment being built: the sections that make it, its bytes and the
/// relocations into each target.
const Segment = struct {
    kind: loadfile.SegmentKind,
    addr: u32 = 0,
    size: u32 = 0,
    bytes: std.ArrayList(u8),
    /// One list of offsets per target segment.
    relocs: [3]std.ArrayList(u32),
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 3) fatal("usage: elf2seg <in.elf> <out.seg>", .{});

    const cwd = std.Io.Dir.cwd();
    const elf = try cwd.readFileAlloc(io, args[1], arena, .unlimited);
    if (elf.len < 52 or !mem.eql(u8, elf[0..4], "\x7fELF") or elf[4] != 1 or elf[5] != 1)
        fatal("{s}: not a little-endian ELF32 file", .{args[1]});
    const machine = u16At(elf, e_machine);
    if (machine != EM_XTENSA and machine != EM_RISCV) fatal("{s}: neither an Xtensa nor a RISC-V file", .{args[1]});
    if (u16At(elf, e_type) != ET_EXEC) fatal("{s}: not a linked executable", .{args[1]});

    const sections = try readSections(elf, arena);

    // The three segments, in the order the loader sees them.
    var segments = [_]Segment{
        .{ .kind = .code, .bytes = .empty, .relocs = .{ .empty, .empty, .empty } },
        .{ .kind = .data, .bytes = .empty, .relocs = .{ .empty, .empty, .empty } },
        .{ .kind = .bss, .bytes = .empty, .relocs = .{ .empty, .empty, .empty } },
    };

    // Each allocatable section joins its segment, which must be contiguous:
    // program.ld lays them out in order, so a gap would mean a stray section.
    // On RISC-V there is one segment, its bss last.
    var bss_seen = false;
    for (sections) |*s| {
        if (s.flags & SHF_ALLOC == 0 or s.size == 0) continue;
        const index: u16 = if (machine == EM_RISCV)
            0
        else if (s.flags & SHF_EXECINSTR != 0)
            0
        else if (s.type == SHT_NOBITS)
            2
        else
            1;
        if (machine == EM_RISCV) {
            if (s.type == SHT_NOBITS) {
                bss_seen = true;
            } else if (bss_seen) {
                fatal("section {s} at 0x{x} follows bss: program_esp32p4.ld puts bss last", .{ s.name, s.addr });
            }
        }
        const seg = &segments[index];
        if (seg.size == 0) {
            seg.addr = s.addr;
        } else if (s.addr != seg.addr + seg.size) {
            const pad = s.addr -% (seg.addr + seg.size);
            if (s.addr < seg.addr + seg.size or pad > 64)
                fatal("section {s} at 0x{x} does not follow its segment (0x{x}..0x{x})", .{ s.name, s.addr, seg.addr, seg.addr + seg.size });
            if (s.type != SHT_NOBITS) try seg.bytes.appendNTimes(arena, 0, pad);
            seg.size += pad;
        }
        if (s.type != SHT_NOBITS) try seg.bytes.appendSlice(arena, elf[s.offset..][0..s.size]);
        seg.size += s.size;
        s.segment = index;
    }
    if (segments[0].size == 0) fatal("{s}: no code", .{args[1]});

    try collectRelocs(elf, machine, sections, &segments, arena);

    const entry = u32At(elf, e_entry);
    if (entry < segments[0].addr or entry >= segments[0].addr + segments[0].size)
        fatal("entry 0x{x} is not in the code segment", .{entry});

    const out = try write(&segments, machine, entry - segments[0].addr, arena);
    try cwd.writeFile(io, .{ .sub_path = args[2], .data = out });
}

fn readSections(elf: []const u8, arena: mem.Allocator) ![]Section {
    const shoff = u32At(elf, e_shoff);
    const shentsize = u16At(elf, e_shentsize);
    const shnum = u16At(elf, e_shnum);
    const shstrndx = u16At(elf, e_shstrndx);
    if (shoff == 0 or shnum == 0) fatal("no section headers", .{});
    const names_off = u32At(elf, shoff + @as(usize, shstrndx) * shentsize + sh_offset);

    const sections = try arena.alloc(Section, shnum);
    for (sections, 0..) |*s, i| {
        const h = shoff + i * shentsize;
        const name_off = names_off + u32At(elf, h + sh_name);
        const end = mem.indexOfScalarPos(u8, elf, name_off, 0) orelse elf.len;
        s.* = .{
            .name = elf[name_off..end],
            .type = u32At(elf, h + sh_type),
            .flags = u32At(elf, h + sh_flags),
            .addr = u32At(elf, h + sh_addr),
            .offset = u32At(elf, h + sh_offset),
            .size = u32At(elf, h + sh_size),
            .link = u32At(elf, h + sh_link),
            .info = u32At(elf, h + sh_info),
            .entsize = u32At(elf, h + sh_entsize),
        };
    }
    return sections;
}

/// Every R_XTENSA_32 or R_RISCV_32 of an allocatable section: the word at
/// its offset holds an address, so the target's segment and the site's
/// segment are written down. The relocations the linker already applied
/// are skipped; anything else fails the build, since the loader could not
/// do it.
fn collectRelocs(elf: []const u8, machine: u16, sections: []Section, segments: *[3]Segment, arena: mem.Allocator) !void {
    for (sections) |rela| {
        if (rela.type != SHT_RELA or rela.entsize < 12) continue;
        if (rela.info >= sections.len) continue;
        const target = &sections[rela.info];
        const site_segment = target.segment orelse continue; // debug sections
        const symtab = if (rela.link < sections.len) &sections[rela.link] else fatal("relocations without a symbol table", .{});
        if (symtab.type != SHT_SYMTAB) fatal("{s}: link is not a symbol table", .{rela.name});

        var off: usize = 0;
        while (off + 12 <= rela.size) : (off += rela.entsize) {
            const e = rela.offset + off;
            const r_offset = u32At(elf, e);
            const r_info = u32At(elf, e + 4);
            const addend = u32At(elf, e + 8);
            const kind = r_info & 0xFF;
            const sym = r_info >> 8;
            if (machine == EM_RISCV) {
                switch (riscvKind(kind)) {
                    .address => {},
                    .done => continue,
                    // PC-relative: resolved by the linker, and right
                    // wherever the segment goes - as long as what it reaches
                    // goes with it. A fixed address does not; the linker
                    // names one by symbol 0 and the address as the addend.
                    .pc_relative => {
                        const reached = symbolValue(elf, symtab, sym) +% addend;
                        if (symbolSection(elf, symtab, sym) == SHN_ABS or !inProgram(segments, reached))
                            fatal("{s}: the code at 0x{x} reaches 0x{x}, a fixed address, PC-relatively (a direct call into the ROM?): reach it through a pointer", .{ rela.name, r_offset, reached });
                        continue;
                    },
                    .absolute_code => fatal("{s}: an absolute address in the code at 0x{x}: build with -mcmodel=medany", .{ rela.name, r_offset }),
                    .unsupported => fatal("{s}: relocation type {d} at 0x{x} is not supported (GOT, TLS?)", .{ rela.name, kind, r_offset }),
                }
            } else switch (kind) {
                R_XTENSA_32 => {},
                R_XTENSA_NONE, R_XTENSA_SLOT0_OP, R_XTENSA_ASM_EXPAND, R_XTENSA_DIFF32 => continue,
                else => fatal("{s}: relocation type {d} at 0x{x} is not supported", .{ rela.name, kind, r_offset }),
            }
            if (symbolSection(elf, symtab, sym) == SHN_ABS) continue;
            const value = symbolValue(elf, symtab, sym);
            const address = value +% addend;
            const to = segmentOf(segments, address) orelse
                fatal("{s}: 0x{x} points outside the program", .{ rela.name, address });
            const seg = &segments[site_segment];
            if (r_offset < seg.addr or r_offset + 4 > seg.addr + seg.size)
                fatal("{s}: relocation at 0x{x} is outside its segment", .{ rela.name, r_offset });
            const site = r_offset - seg.addr;
            if (site + 4 > seg.bytes.items.len)
                fatal("{s}: relocation at 0x{x} has no bytes (a bss segment?)", .{ rela.name, r_offset });
            // The word holds the linked address; the loader adds where it
            // put that segment, so store the offset into it.
            const stored = mem.readInt(u32, seg.bytes.items[site..][0..4], .little);
            if (stored != address)
                fatal("{s}: the word at 0x{x} is 0x{x}, not the 0x{x} its relocation names", .{ rela.name, r_offset, stored, address });
            mem.writeInt(u32, seg.bytes.items[site..][0..4], address - segments[to].addr, .little);
            try seg.relocs[to].append(arena, site);
        }
    }
}

/// What a RISC-V relocation asks of the loader.
const RiscvKind = enum {
    /// A word holding an address: the loader adds its segment's base.
    address,
    /// Applied by the linker, nothing left: label differences, the low
    /// half of an auipc pair (named by the auipc's label), alignment and
    /// relaxation markers.
    done,
    /// Applied by the linker, PC-relative to the symbol it names.
    pc_relative,
    /// An absolute address in an instruction (lui, or a load or store
    /// off it): only right at the address the program was linked at.
    absolute_code,
    unsupported,
};

fn riscvKind(kind: u32) RiscvKind {
    return switch (kind) {
        R_RISCV_32 => .address,
        R_RISCV_NONE, R_RISCV_PCREL_LO12_I, R_RISCV_PCREL_LO12_S, R_RISCV_ALIGN, R_RISCV_RELAX => .done,
        R_RISCV_ADD8...R_RISCV_SUB64, R_RISCV_SUB6...R_RISCV_SET32, R_RISCV_SET_ULEB128, R_RISCV_SUB_ULEB128 => .done,
        R_RISCV_BRANCH, R_RISCV_JAL, R_RISCV_CALL, R_RISCV_CALL_PLT, R_RISCV_PCREL_HI20 => .pc_relative,
        R_RISCV_RVC_BRANCH, R_RISCV_RVC_JUMP, R_RISCV_32_PCREL, R_RISCV_PLT32 => .pc_relative,
        R_RISCV_HI20, R_RISCV_LO12_I, R_RISCV_LO12_S => .absolute_code,
        else => .unsupported,
    };
}

fn symbolValue(elf: []const u8, symtab: *const Section, index: u32) u32 {
    const entsize: u32 = if (symtab.entsize != 0) symtab.entsize else 16;
    if ((index + 1) * entsize > symtab.size) fatal("symbol {d} is outside the symbol table", .{index});
    return u32At(elf, symtab.offset + index * entsize + 4); // st_value
}

/// The section index of a symbol (st_shndx), SHN_ABS for a fixed address.
fn symbolSection(elf: []const u8, symtab: *const Section, index: u32) u16 {
    const entsize: u32 = if (symtab.entsize != 0) symtab.entsize else 16;
    if ((index + 1) * entsize > symtab.size) fatal("symbol {d} is outside the symbol table", .{index});
    return mem.readInt(u16, elf[symtab.offset + index * entsize + 14 ..][0..2], .little);
}

/// Whether an address is in the program, or the byte just past one of
/// its segments (a symbol marking an end).
fn inProgram(segments: *const [3]Segment, address: u32) bool {
    for (segments) |*seg| {
        if (seg.size != 0 and address >= seg.addr and address <= seg.addr + seg.size) return true;
    }
    return false;
}

/// Which segment an address is in. A bss address may be the byte past the
/// data segment, so bss is tried first.
fn segmentOf(segments: *const [3]Segment, address: u32) ?u16 {
    for ([_]u16{ 2, 0, 1 }) |i| {
        const s = &segments[i];
        if (s.size != 0 and address >= s.addr and address < s.addr + s.size) return i;
    }
    return null;
}

fn write(segments: *[3]Segment, machine: u16, entry_offset: u32, arena: mem.Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    // Each segment's place in the file: an empty one is left out, and the
    // relocations name the segments by their place.
    var place: [3]u16 = undefined;
    var count: u16 = 0;
    for (segments, 0..) |*s, i| {
        place[i] = count;
        if (s.size != 0) count += 1;
    }
    try append(&out, arena, loadfile.Header{
        .segments = count,
        .entry_segment = 0,
        .machine = if (machine == EM_RISCV) loadfile.MACHINE_RISCV else loadfile.MACHINE_XTENSA,
        .entry_offset = entry_offset,
        .word_size = 4,
    });
    for (segments) |*s| {
        if (s.size == 0) continue;
        const file_size: u32 = @intCast(s.bytes.items.len);
        var groups: u32 = 0;
        for (s.relocs) |list| {
            if (list.items.len != 0) groups += 1;
        }
        try append(&out, arena, loadfile.SegmentHeader{
            .kind = s.kind,
            .file_size = file_size,
            .mem_size = s.size,
            .reloc_groups = groups,
        });
        try out.appendSlice(arena, s.bytes.items);
        try out.appendNTimes(arena, 0, loadfile.alignUp(file_size) - file_size);
    }
    // The groups come after every segment's bytes, in the same order, so the
    // loader can read the file straight through.
    for (segments) |*s| {
        if (s.size == 0) continue;
        for (s.relocs, 0..) |list, target| {
            if (list.items.len == 0) continue;
            try append(&out, arena, loadfile.RelocGroup{
                .target_segment = place[target],
                .count = @intCast(list.items.len),
            });
            for (list.items) |offset| try append(&out, arena, offset);
        }
    }
    return out.items;
}

fn append(out: *std.ArrayList(u8), arena: mem.Allocator, value: anytype) !void {
    try out.appendSlice(arena, mem.asBytes(&value));
}
