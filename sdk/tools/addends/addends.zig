// SPDX-License-Identifier: MIT
//! addends: an archive of GCC-built Xtensa objects made fit for LLD.
//!
//! usage: addends <in.a> <out.a>
//!
//! **Why.** A word that holds an address (R_XTENSA_32) is computed by the
//! GNU linker as symbol + addend + what the word already holds: the GNU
//! assembler for Xtensa often leaves the addend in the word and 0 in the
//! relocation - a switch's jump table, `.word .L5`, is a column of offsets
//! into its function against the function's section. LLD computes symbol
//! + addend and writes over the word, so every such entry would point at
//! the start of the section. Folding the word into the addend, and the
//! word to 0, gives the same address under both.
//!
//! **How.** Only bytes inside the members change, never a size, so the
//! archive is patched where it lies and its index stays right. Every ELF
//! member's RELA sections are walked; a relocation that is R_XTENSA_32 on
//! an allocated section with a nonzero word gets that word added to its
//! addend. Anything that is not ELF (the index, the long-name table) is
//! left as it is.

const std = @import("std");
const mem = std.mem;

const SHT_RELA = 4;
const SHT_NOBITS = 8;
const R_XTENSA_32 = 1;
const EM_XTENSA = 94;

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("addends: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

fn u16At(bytes: []const u8, at: usize) u16 {
    return mem.readInt(u16, bytes[at..][0..2], .little);
}

fn u32At(bytes: []const u8, at: usize) u32 {
    return mem.readInt(u32, bytes[at..][0..4], .little);
}

/// Every in-place addend of one object folded into its relocation;
/// answers how many there were.
pub fn foldObject(elf: []u8) usize {
    if (elf.len < 52 or !mem.eql(u8, elf[0..4], "\x7fELF")) return 0;
    if (elf[4] != 1 or elf[5] != 1 or u16At(elf, 0x12) != EM_XTENSA) return 0;
    const shoff = u32At(elf, 0x20);
    const shentsize = u16At(elf, 0x2E);
    const shnum = u16At(elf, 0x30);
    if (shoff + @as(usize, shnum) * shentsize > elf.len) fatal("a member's section table is cut short", .{});
    var folded: usize = 0;
    for (0..shnum) |index| {
        const header = shoff + index * shentsize;
        if (u32At(elf, header + 4) != SHT_RELA) continue;
        const rela_offset = u32At(elf, header + 16);
        const rela_size = u32At(elf, header + 20);
        const target_index = u32At(elf, header + 28);
        if (target_index >= shnum) continue;
        const target = shoff + target_index * shentsize;
        if (u32At(elf, target + 4) == SHT_NOBITS) continue;
        if (u32At(elf, target + 8) & 2 == 0) continue; // not allocated: debug
        const target_offset = u32At(elf, target + 16);
        const target_size = u32At(elf, target + 20);
        var at: usize = 0;
        while (at + 12 <= rela_size) : (at += 12) {
            const entry = rela_offset + at;
            if (u32At(elf, entry + 4) & 0xFF != R_XTENSA_32) continue;
            const site = u32At(elf, entry);
            if (site + 4 > target_size) fatal("a relocation lies past its section", .{});
            const word_at = target_offset + site;
            const word = u32At(elf, word_at);
            if (word == 0) continue;
            const addend = u32At(elf, entry + 8);
            mem.writeInt(u32, elf[entry + 8 ..][0..4], addend +% word, .little);
            mem.writeInt(u32, elf[word_at..][0..4], 0, .little);
            folded += 1;
        }
    }
    return folded;
}

/// Every member of an archive, folded.
pub fn foldArchive(archive: []u8) usize {
    if (!mem.startsWith(u8, archive, "!<arch>\n")) fatal("not an archive", .{});
    var at: usize = 8;
    var folded: usize = 0;
    while (at + 60 <= archive.len) {
        const size_text = mem.trim(u8, archive[at + 48 .. at + 58], " ");
        const size = std.fmt.parseInt(usize, size_text, 10) catch fatal("a member's size is not a number", .{});
        const start = at + 60;
        if (start + size > archive.len) fatal("a member runs past the end", .{});
        folded += foldObject(archive[start .. start + size]);
        at = start + size + (size & 1);
    }
    return folded;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 3) fatal("usage: addends <in.a> <out.a>", .{});
    const cwd = std.Io.Dir.cwd();
    const archive = try cwd.readFileAlloc(io, args[1], arena, .unlimited);
    _ = foldArchive(archive);
    try cwd.writeFile(io, .{ .sub_path = args[2], .data = archive });
}

test foldObject {
    // An object with a data section of two words and one RELA section:
    // the first word's addend is in place (0x40), the second's is in the
    // relocation (0x10) with the word 0.
    var elf: [52 + 8 + 24 + 4 * 40]u8 = @splat(0);
    @memcpy(elf[0..6], "\x7fELF\x01\x01");
    mem.writeInt(u16, elf[0x12..][0..2], EM_XTENSA, .little);
    const data_at = 52;
    const rela_at = data_at + 8;
    const shoff = rela_at + 24;
    mem.writeInt(u32, elf[0x20..][0..4], shoff, .little);
    mem.writeInt(u16, elf[0x2E..][0..2], 40, .little);
    mem.writeInt(u16, elf[0x30..][0..2], 4, .little);
    mem.writeInt(u32, elf[data_at..][0..4], 0x40, .little);
    // Section 1: .data, PROGBITS, allocated.
    const data_header = shoff + 40;
    mem.writeInt(u32, elf[data_header + 4 ..][0..4], 1, .little);
    mem.writeInt(u32, elf[data_header + 8 ..][0..4], 3, .little);
    mem.writeInt(u32, elf[data_header + 16 ..][0..4], data_at, .little);
    mem.writeInt(u32, elf[data_header + 20 ..][0..4], 8, .little);
    // Section 2: .rela.data, on section 1.
    const rela_header = shoff + 80;
    mem.writeInt(u32, elf[rela_header + 4 ..][0..4], SHT_RELA, .little);
    mem.writeInt(u32, elf[rela_header + 16 ..][0..4], rela_at, .little);
    mem.writeInt(u32, elf[rela_header + 20 ..][0..4], 24, .little);
    mem.writeInt(u32, elf[rela_header + 28 ..][0..4], 1, .little);
    mem.writeInt(u32, elf[rela_at + 4 ..][0..4], 5 << 8 | R_XTENSA_32, .little);
    mem.writeInt(u32, elf[rela_at + 12 ..][0..4], 4, .little);
    mem.writeInt(u32, elf[rela_at + 16 ..][0..4], 5 << 8 | R_XTENSA_32, .little);
    mem.writeInt(u32, elf[rela_at + 20 ..][0..4], 0x10, .little);

    try std.testing.expectEqual(@as(usize, 1), foldObject(&elf));
    try std.testing.expectEqual(@as(u32, 0), u32At(&elf, data_at));
    try std.testing.expectEqual(@as(u32, 0x40), u32At(&elf, rela_at + 8));
    try std.testing.expectEqual(@as(u32, 0x10), u32At(&elf, rela_at + 20));
    try std.testing.expectEqual(@as(usize, 0), foldObject(&elf));
}
