// SPDX-License-Identifier: MPL-2.0
//! ressize <in.elf> <out.elf>: fill in the kernel's resident_sizes table
//! (src/arch/esp32s3/layout.zig) after linking.
//!
//! The image has no symbol table, and a module isn't contiguous in it: its
//! code is on the instruction bus, its data on the data bus, and the linker
//! mixes all modules. So rt_EndSkip can't tell a resident's size, and this
//! tool works it out from the ELF instead:
//!
//!   1. every ROM tag in .resident (match word 0x4AFC, rt_MatchTag pointing
//!      back at it);
//!   2. the module: the directory of the symbol rt_Init points to (its
//!      InitTable or init routine). "rom.devs.timer.timer.init_table" is in
//!      "rom.devs.timer.", so it covers timer.zig and timeval.zig;
//!   3. the sizes of every function and object named in that directory:
//!      code in .text, data in .rodata and .data, plus the tag itself.
//!
//! Code the compiler inlined from elsewhere counts for the module it is in;
//! std functions and anonymous constants (string literals) count for none.

const std = @import("std");
const mem = std.mem;

const Section = struct { name: []const u8, addr: u32, offset: u32, size: u32 };
const Symbol = struct { name: []const u8, value: u32, size: u32, kind: u4, shndx: u16 };

const STT_OBJECT = 1;
const STT_FUNC = 2;
const SHT_SYMTAB = 2;
const resident_size = 28; // struct Resident on the 32-bit target
const entry_size = 12; // layout.ResidentSize: tag, code, data
/// The rt_Types whose tag is a ResidentHandler: rt_Init is null and the
/// entry is in the word after the tag, rather than behind an InitTable.
/// NodeType.handler is a dos handler and NodeType.shell is the shell,
/// which has that shape without being one.
const handler_types = [_]u8{ 20, 22 };

fn isResidentHandler(kind: u8) bool {
    for (handler_types) |t| {
        if (t == kind) return true;
    }
    return false;
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("ressize: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

fn u16At(b: []const u8, off: usize) u16 {
    return mem.readInt(u16, b[off..][0..2], .little);
}

fn u32At(b: []const u8, off: usize) u32 {
    return mem.readInt(u32, b[off..][0..4], .little);
}

fn cString(b: []const u8, off: usize) []const u8 {
    return mem.sliceTo(b[off..], 0);
}

/// "rom.devs.timer.timer.init_table" -> "rom.devs.timer.": the name without
/// its file and declaration.
fn directoryOf(name: []const u8) []const u8 {
    const decl = mem.lastIndexOfScalar(u8, name, '.') orelse return name;
    const file = mem.lastIndexOfScalar(u8, name[0..decl], '.') orelse return name[0 .. decl + 1];
    return name[0 .. file + 1];
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 3) fatal("usage: ressize <in.elf> <out.elf>", .{});

    const cwd = std.Io.Dir.cwd();
    const elf = try cwd.readFileAlloc(io, args[1], arena, .unlimited);
    if (elf.len < 52 or !mem.eql(u8, elf[0..4], "\x7fELF") or elf[4] != 1 or elf[5] != 1)
        fatal("{s}: not a little-endian ELF32 file", .{args[1]});

    // Sections, by name.
    const shoff = u32At(elf, 0x20);
    const shentsize = u16At(elf, 0x2E);
    const shnum = u16At(elf, 0x30);
    const shstrndx = u16At(elf, 0x32);
    const shstr_off = u32At(elf, shoff + @as(usize, shstrndx) * shentsize + 16);
    const sections = try arena.alloc(Section, shnum);
    var symtab_index: ?usize = null;
    for (sections, 0..) |*s, i| {
        const h = shoff + i * shentsize;
        s.* = .{
            .name = cString(elf, shstr_off + u32At(elf, h)),
            .addr = u32At(elf, h + 12),
            .offset = u32At(elf, h + 16),
            .size = u32At(elf, h + 20),
        };
        if (u32At(elf, h + 4) == SHT_SYMTAB) symtab_index = i;
    }
    const symtab_h = shoff + (symtab_index orelse fatal("no symbol table", .{})) * shentsize;
    const str_off = sections[u32At(elf, symtab_h + 24)].offset;

    // Functions and objects.
    var symbols: std.ArrayList(Symbol) = .empty;
    const sym_off = u32At(elf, symtab_h + 16);
    const sym_count = u32At(elf, symtab_h + 20) / 16;
    for (0..sym_count) |i| {
        const e = sym_off + i * 16;
        const kind: u4 = @truncate(elf[e + 12]);
        if (kind != STT_OBJECT and kind != STT_FUNC) continue;
        try symbols.append(arena, .{
            .name = cString(elf, str_off + u32At(elf, e)),
            .value = u32At(elf, e + 4),
            .size = u32At(elf, e + 8),
            .kind = kind,
            .shndx = u16At(elf, e + 14),
        });
    }

    const table = for (symbols.items) |s| {
        if (mem.eql(u8, s.name, "resident_sizes")) break s;
    } else fatal("no resident_sizes table", .{});
    const table_section = sections[table.shndx];
    const table_off = table_section.offset + (table.value - table_section.addr);
    const capacity = table.size / entry_size;

    const resident = for (sections) |s| {
        if (mem.eql(u8, s.name, ".resident")) break s;
    } else fatal("no .resident section", .{});

    checkBootCode(elf, sections, symbols.items);

    var out = try arena.dupe(u8, elf);
    var count: usize = 0;
    var off: usize = 0;
    while (off + resident_size <= resident.size) {
        const tag_off = resident.offset + off;
        const tag_addr = resident.addr + @as(u32, @intCast(off));
        if (u16At(elf, tag_off) != 0x4AFC or u32At(elf, tag_off + 4) != tag_addr) {
            off += 2;
            continue;
        }
        const is_handler = isResidentHandler(elf[tag_off + 14]);
        const init_addr = u32At(elf, tag_off + @as(usize, if (is_handler) resident_size else 24));
        var code: u32 = 0;
        var data: u32 = if (is_handler) resident_size + 4 else resident_size;
        const owner = for (symbols.items) |s| {
            if (s.value == init_addr and s.size != 0) break s;
        } else null;
        if (owner) |o| {
            const dir = directoryOf(o.name);
            for (symbols.items) |s| {
                if (!mem.startsWith(u8, s.name, dir) or s.shndx >= sections.len) continue;
                const in = sections[s.shndx].name;
                if (mem.eql(u8, in, ".text") or mem.eql(u8, in, ".flash.text") or mem.eql(u8, in, ".iram.text")) {
                    code += s.size;
                } else if (mem.eql(u8, in, ".rodata") or mem.eql(u8, in, ".data")) {
                    data += s.size;
                }
            }
        }
        if (count == capacity) fatal("more than {d} ROM tags: enlarge layout.resident_sizes", .{capacity});
        const e = table_off + count * entry_size;
        mem.writeInt(u32, out[e..][0..4], tag_addr, .little);
        mem.writeInt(u32, out[e + 4 ..][0..4], code, .little);
        mem.writeInt(u32, out[e + 8 ..][0..4], data, .little);
        count += 1;
        off += resident_size;
    }

    try cwd.writeFile(io, .{ .sub_path = args[2], .data = out });
}

/// The boot code in .iram.text runs before the code in .flash.text is
/// mapped, and flash.device's routines (src/rom/devs/flash/spiflash.zig) run
/// with the caches suspended, so neither may refer to flash code. The
/// exceptions are what runs after the mapping: kmain and the exception
/// handler (start.S), and the start of .flash.text itself (flashmap.zig).
///
/// Every call loads its target - a function's entry - from a literal, so a
/// word in .iram.text that is exactly the address of a symbol in
/// .flash.text is a reference, and fails the build. A word that lands
/// inside a function is not: read four bytes at a time, Xtensa's 2- and
/// 3-byte instructions make such a value now and then.
fn checkBootCode(elf: []const u8, sections: []const Section, symbols: []const Symbol) void {
    const iram = for (sections) |s| {
        if (mem.eql(u8, s.name, ".iram.text")) break s;
    } else return;
    const flash = for (sections) |s| {
        if (mem.eql(u8, s.name, ".flash.text")) break s;
    } else return;
    const allowed = [_][]const u8{ "kmain", "xtensa_exception", "_flash_text_start" };
    var off: usize = 0;
    while (off + 4 <= iram.size) : (off += 4) {
        const word = u32At(elf, iram.offset + off);
        if (word < flash.addr or word >= flash.addr + flash.size) continue;
        if (isAllowed(symbols, &allowed, word)) continue;
        const what = for (symbols) |s| {
            if (s.size != 0 and s.value == word) break s.name;
        } else continue; // inside a function: instruction bytes, not a reference
        fatal("code in .iram.text at 0x{x} refers to {s} (0x{x}) in .flash.text, which it may not reach", .{ iram.addr + off, what, word });
    }
}

fn isAllowed(symbols: []const Symbol, allowed: []const []const u8, word: u32) bool {
    for (symbols) |s| {
        if (s.value != word) continue;
        for (allowed) |name| {
            if (mem.eql(u8, s.name, name)) return true;
        }
    }
    return false;
}
