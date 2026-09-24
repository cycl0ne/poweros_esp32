// SPDX-License-Identifier: MIT
//! Host tests of `fat32/names.zig`: they bring up exec and utility.library from
//! the ROM, which a file the handler is built from may not name, so they
//! are here, where only the test build looks.

const std = @import("std");
const sdk = @import("sdk");
const subject = @import("../fat32/names.zig");
const LongName = subject.LongName;
const Short = subject.Short;
const UtilityBase = sdk.interface.utility.UtilityBase;
const asShort = subject.asShort;
const basisOf = subject.basisOf;
const case_lower_base = subject.case_lower_base;
const case_lower_ext = subject.case_lower_ext;
const exec = sdk.exec;
const fat = sdk.dos.fat;
const fillPiece = subject.fillPiece;
const pieceCount = subject.pieceCount;
const pieceUnits = subject.pieceUnits;
const same = subject.same;
const shortName = subject.shortName;
const short_max = subject.short_max;
const validLong = subject.validLong;
const withTail = subject.withTail;

const testing = std.testing;
const utility_library = @import("host_rom").utility;
const kexec = @import("host_rom").exec;

/// The library the names are cased through, brought up as its own tests
/// do.
fn utilityUp() !*UtilityBase {
    const ub = try utility_library.setUp();
    return ub.iface();
}

fn entryWith(bytes: *const [11]u8, case: u8) [fat.entry_bytes]u8 {
    var entry: [fat.entry_bytes]u8 = @splat(0);
    @memcpy(entry[0..11], bytes);
    entry[fat.ent_case] = case;
    return entry;
}

test "a short name is spelled out with its dot and its case" {
    const ub = try utilityUp();
    defer kexec.deinit();
    var into: [short_max]u8 = undefined;
    try testing.expectEqualStrings("README.TXT", shortName(ub, &entryWith("README  TXT", 0), &into));
    try testing.expectEqualStrings("MAKEFILE", shortName(ub, &entryWith("MAKEFILE   ", 0), &into));
    try testing.expectEqualStrings("readme.txt", shortName(ub, &entryWith("README  TXT", case_lower_base | case_lower_ext), &into));
    try testing.expectEqualStrings("readme.TXT", shortName(ub, &entryWith("README  TXT", case_lower_base), &into));
    // A name that really begins with the erase byte.
    try testing.expectEqualStrings("\xE5AB", shortName(ub, &entryWith("\x05AB        ", 0), &into));
}

test "a name that fits eight and three in one case needs no long name" {
    const ub = try utilityUp();
    defer kexec.deinit();
    const plain = asShort(ub, "README.TXT").?;
    try testing.expectEqualSlices(u8, "README  TXT", &plain.bytes);
    try testing.expectEqual(@as(u8, 0), plain.case);

    const small = asShort(ub, "readme.txt").?;
    try testing.expectEqualSlices(u8, "README  TXT", &small.bytes);
    try testing.expectEqual(case_lower_base | case_lower_ext, small.case);

    const digits = asShort(ub, "2026.log").?;
    try testing.expectEqual(case_lower_ext, digits.case);

    // Each of these needs a long name.
    try testing.expectEqual(@as(?Short, null), asShort(ub, "ReadMe.txt"));
    try testing.expectEqual(@as(?Short, null), asShort(ub, "toolongname.txt"));
    try testing.expectEqual(@as(?Short, null), asShort(ub, "a.b.c"));
    try testing.expectEqual(@as(?Short, null), asShort(ub, "with space"));
    try testing.expectEqual(@as(?Short, null), asShort(ub, "file.html"));
    try testing.expectEqual(@as(?Short, null), asShort(ub, "caf\xE9"));
    try testing.expectEqual(@as(?Short, null), asShort(ub, "trail."));
    try testing.expectEqual(@as(?Short, null), asShort(ub, ".profile"));
}

test "what a new name may not be" {
    try validLong("Good name.txt");
    try validLong("caf\xE9");
    try testing.expectError(error.InvalidName, validLong(""));
    try testing.expectError(error.InvalidName, validLong("."));
    try testing.expectError(error.InvalidName, validLong(".."));
    try testing.expectError(error.InvalidName, validLong("what?"));
    try testing.expectError(error.InvalidName, validLong("a*b"));
    try testing.expectError(error.InvalidName, validLong("back\\slash"));
    try testing.expectError(error.InvalidName, validLong("ends."));
    try testing.expectError(error.InvalidName, validLong("ends "));
    try testing.expectError(error.InvalidName, validLong("tab\there"));
    var long: [256]u8 = @splat('x');
    try validLong(long[0..255]);
    try testing.expectError(error.InvalidName, validLong(&long));
}

test "the short name made up for a long one" {
    const ub = try utilityUp();
    defer kexec.deinit();
    const basis = basisOf(ub, "The quick brown fox.jpeg");
    try testing.expectEqualSlices(u8, "THEQUICK", basis.base[0..basis.base_len]);
    try testing.expectEqualSlices(u8, "JPE", &basis.ext);
    try testing.expectEqualSlices(u8, "THEQUI~1JPE", &withTail(basis, 1));
    try testing.expectEqualSlices(u8, "THEQU~12JPE", &withTail(basis, 12));

    // Leading dots go, the last dot marks the extension, characters a
    // short name cannot hold become underscores.
    const dotted = basisOf(ub, ".config.old.bak");
    try testing.expectEqualSlices(u8, "CONFIGOL", dotted.base[0..dotted.base_len]);
    try testing.expectEqualSlices(u8, "BAK", &dotted.ext);
    const odd = basisOf(ub, "caf\xE9+tea");
    try testing.expectEqualSlices(u8, "CAF__TEA", odd.base[0..odd.base_len]);
    try testing.expectEqualSlices(u8, "   ", &odd.ext);

    // A short basis keeps all of itself.
    try testing.expectEqualSlices(u8, "AB~1       ", &withTail(basisOf(ub, "ab"), 1));
    // A name of nothing but dots still gets a basis.
    const empty = basisOf(ub, "...");
    try testing.expectEqualSlices(u8, "_", empty.base[0..empty.base_len]);
}

test "a long name goes into pieces and comes back" {
    const ub = try utilityUp();
    defer kexec.deinit();
    const name = "A file with a long name.text"; // 28: three pieces
    try testing.expectEqual(@as(usize, 3), pieceCount(name.len));
    const short = withTail(basisOf(ub, name), 1);
    const checksum = fat.shortNameChecksum(&short);

    // On the medium the last piece comes first.
    var entries: [3][fat.entry_bytes]u8 = undefined;
    for (0..3) |at| fillPiece(&entries[at], name, 3 - at, checksum);
    try testing.expect(entries[0][fat.lfn_order] & fat.lfn_last != 0);
    try testing.expect(fat.isLongName(&entries[0]));

    // The last piece: two characters, the end, then padding.
    var units: [fat.lfn_chars]u16 = undefined;
    pieceUnits(&entries[0], &units);
    try testing.expectEqual(@as(u16, 'x'), units[0]);
    try testing.expectEqual(@as(u16, 't'), units[1]);
    try testing.expectEqual(@as(u16, 0), units[2]);
    try testing.expectEqual(@as(u16, 0xFFFF), units[3]);

    var long: LongName = .{};
    for (&entries) |*entry| long.take(entry);
    var short_entry: [fat.entry_bytes]u8 = @splat(0);
    @memcpy(short_entry[0..11], &short);
    try testing.expect(long.completes(&short_entry));
    var into: [fat.name_max]u8 = undefined;
    try testing.expectEqualStrings(name, long.latin1(&into).?);
}

test "pieces that do not belong to the entry are not its name" {
    const ub = try utilityUp();
    defer kexec.deinit();
    const name = "Twenty-six characters long"; // 26: exactly two pieces
    const short = withTail(basisOf(ub, name), 1);
    const checksum = fat.shortNameChecksum(&short);
    var entries: [2][fat.entry_bytes]u8 = undefined;
    fillPiece(&entries[0], name, 2, checksum);
    fillPiece(&entries[1], name, 1, checksum);

    // Renamed by something that knows nothing of long names: the short
    // name changed, the check no longer holds.
    var renamed: [fat.entry_bytes]u8 = @splat(0);
    @memcpy(renamed[0..11], "OTHER   TXT");
    var long: LongName = .{};
    for (&entries) |*entry| long.take(entry);
    try testing.expect(!long.completes(&renamed));

    // A piece missing from the middle.
    long.reset();
    long.take(&entries[0]);
    var third: [fat.entry_bytes]u8 = undefined;
    fillPiece(&third, "x" ** 39, 1, checksum);
    third[fat.lfn_order] = 3; // out of order
    long.take(&third);
    var short_entry: [fat.entry_bytes]u8 = @splat(0);
    @memcpy(short_entry[0..11], &short);
    try testing.expect(!long.completes(&short_entry));
}

test "a long name with a character past Latin-1 is not given out" {
    const ub = try utilityUp();
    defer kexec.deinit();
    const name = "abc";
    const short = withTail(basisOf(ub, name), 1);
    var entry: [fat.entry_bytes]u8 = undefined;
    fillPiece(&entry, name, 1, fat.shortNameChecksum(&short));
    fat.putU16(&entry, fat.lfn_part1_at + 2, 0x20AC); // the euro sign
    var long: LongName = .{};
    long.take(&entry);
    var into: [fat.name_max]u8 = undefined;
    try testing.expectEqual(@as(?[]const u8, null), long.latin1(&into));
}

test "names compare without regard to case, over Latin-1" {
    const ub = try utilityUp();
    defer kexec.deinit();
    try testing.expect(same(ub, "ReadMe.TXT", "readme.txt"));
    try testing.expect(same(ub, "CAF\xC9", "caf\xE9"));
    try testing.expect(!same(ub, "abc", "abd"));
    try testing.expect(!same(ub, "abc", "abcd"));
}
