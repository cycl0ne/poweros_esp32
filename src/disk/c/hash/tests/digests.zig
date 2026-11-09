// SPDX-License-Identifier: MIT
//! Host tests of digests.zig's lines, on exec and utility.library: a line
//! written as sha256sum writes it, its Latin-1 name as UTF-8, and lines
//! of every form read back, their UTF-8 names made dos names.

const std = @import("std");
const host = @import("host_rom");
const UtilityBase = @import("sdk").interface.utility.UtilityBase;
const digests = @import("../digests.zig");

const testing = std.testing;

/// utility.library on the host: the names go through it.
fn utilityUp() !*UtilityBase {
    return @ptrCast(try host.utility.setUp());
}

fn utilityDown(ub: *UtilityBase) !void {
    try host.utility.tearDown(@ptrCast(@alignCast(ub)));
    try host.exec.expectNoLeaks();
}

test "a line written as sha256sum writes it, Latin-1 as UTF-8" {
    const ub = try utilityUp();
    defer host.exec.deinit();
    var line: [128]u8 = undefined;
    const length = digests.formatLine(ub, &.{ 0xAB, 0x01 }, "Caf\xe9.txt", &line).?;
    try testing.expectEqualStrings("ab01  Caf\xc3\xa9.txt\n", line[0..length]);
    const odd = digests.formatLine(ub, &.{0xFF}, "a\\b", &line).?;
    try testing.expectEqualStrings("\\ff  a\\\\b\n", line[0..odd]);
    // Escaped, its Latin-1 still UTF-8 between the escapes.
    const both = digests.formatLine(ub, &.{0xFF}, "Caf\xe9\\x\xe4", &line).?;
    try testing.expectEqualStrings("\\ff  Caf\xc3\xa9\\\\x\xc3\xa4\n", line[0..both]);
    try testing.expect(digests.formatLine(ub, &.{0xFF}, "long name", line[0..6]) == null);
    try utilityDown(ub);
}

test "lines read back: GNU, binary, BSD, SFV, escaped, comments" {
    const ub = try utilityUp();
    defer host.exec.deinit();
    var entry: digests.Entry = .{};
    var name: [64]u8 = undefined;
    try testing.expectEqual(digests.LineKind.entry, digests.parseLine(ub, "ab01cd02  Caf\xc3\xa9.txt\r\n", &entry, &name));
    try testing.expectEqualStrings("Caf\xe9.txt", entry.name);
    try testing.expectEqualSlices(u8, &.{ 0xAB, 0x01, 0xCD, 0x02 }, entry.digest[0..entry.digest_len]);
    try testing.expect(entry.algorithm == null);

    const md5 = "d41d8cd98f00b204e9800998ecf8427e";
    try testing.expectEqual(digests.LineKind.entry, digests.parseLine(ub, md5 ++ " *./dir/empty", &entry, &name));
    try testing.expectEqualStrings("dir/empty", entry.name);
    try testing.expectEqual(@as(usize, 16), entry.digest_len);

    try testing.expectEqual(digests.LineKind.entry, digests.parseLine(ub, "MD5 (a (b).txt) = " ++ md5, &entry, &name));
    try testing.expectEqualStrings("a (b).txt", entry.name);
    try testing.expectEqual(digests.Algorithm.md5, entry.algorithm.?);

    try testing.expectEqual(digests.LineKind.entry, digests.parseLine(ub, "My File.lha CBF43926", &entry, &name));
    try testing.expectEqualStrings("My File.lha", entry.name);
    try testing.expectEqual(digests.Algorithm.crc32, entry.algorithm.?);
    try testing.expectEqualSlices(u8, &.{ 0xCB, 0xF4, 0x39, 0x26 }, entry.digest[0..4]);

    try testing.expectEqual(digests.LineKind.entry, digests.parseLine(ub, "\\ff00ff00  a\\\\b\\nc", &entry, &name));
    try testing.expectEqualStrings("a\\b\nc", entry.name);

    // A name that is no UTF-8 - a list a Latin-1 system wrote - stays.
    try testing.expectEqual(digests.LineKind.entry, digests.parseLine(ub, "ff00ff00  Caf\xe9.txt", &entry, &name));
    try testing.expectEqualStrings("Caf\xe9.txt", entry.name);

    // UTF-8 outside Latin-1 stays as it is.
    try testing.expectEqual(digests.LineKind.entry, digests.parseLine(ub, "ff00ff00  \xe6\x97\xa5.txt", &entry, &name));
    try testing.expectEqualStrings("\xe6\x97\xa5.txt", entry.name);

    try testing.expectEqual(digests.LineKind.nothing, digests.parseLine(ub, "; made by an SFV tool", &entry, &name));
    try testing.expectEqual(digests.LineKind.nothing, digests.parseLine(ub, "", &entry, &name));
    try testing.expectEqual(digests.LineKind.malformed, digests.parseLine(ub, "hello world", &entry, &name));
    try testing.expectEqual(digests.LineKind.malformed, digests.parseLine(ub, "abc  name", &entry, &name));
    try utilityDown(ub);
}
