// SPDX-License-Identifier: MIT
//! Host tests of digests.zig's lines: a line written as sha256sum writes
//! it, and lines of every form read back, a name that is no UTF-8 read
//! as Latin-1.

const std = @import("std");
const digests = @import("../digests.zig");

const testing = std.testing;

test "a line written as sha256sum writes it, the name as it is" {
    var line: [128]u8 = undefined;
    const length = digests.formatLine(&.{ 0xAB, 0x01 }, "Caf\xc3\xa9.txt", &line).?;
    try testing.expectEqualStrings("ab01  Caf\xc3\xa9.txt\n", line[0..length]);
    const odd = digests.formatLine(&.{0xFF}, "a\\b", &line).?;
    try testing.expectEqualStrings("\\ff  a\\\\b\n", line[0..odd]);
    const both = digests.formatLine(&.{0xFF}, "Caf\xc3\xa9\\x\xc3\xa4", &line).?;
    try testing.expectEqualStrings("\\ff  Caf\xc3\xa9\\\\x\xc3\xa4\n", line[0..both]);
    try testing.expect(digests.formatLine(&.{0xFF}, "long name", line[0..6]) == null);
}

test "lines read back: GNU, binary, BSD, SFV, escaped, comments" {
    var entry: digests.Entry = .{};
    var name: [64]u8 = undefined;
    try testing.expectEqual(digests.LineKind.entry, digests.parseLine("ab01cd02  Caf\xc3\xa9.txt\r\n", &entry, &name));
    try testing.expectEqualStrings("Caf\xc3\xa9.txt", entry.name);
    try testing.expectEqualSlices(u8, &.{ 0xAB, 0x01, 0xCD, 0x02 }, entry.digest[0..entry.digest_len]);
    try testing.expect(entry.algorithm == null);

    const md5 = "d41d8cd98f00b204e9800998ecf8427e";
    try testing.expectEqual(digests.LineKind.entry, digests.parseLine(md5 ++ " *./dir/empty", &entry, &name));
    try testing.expectEqualStrings("dir/empty", entry.name);
    try testing.expectEqual(@as(usize, 16), entry.digest_len);

    try testing.expectEqual(digests.LineKind.entry, digests.parseLine("MD5 (a (b).txt) = " ++ md5, &entry, &name));
    try testing.expectEqualStrings("a (b).txt", entry.name);
    try testing.expectEqual(digests.Algorithm.md5, entry.algorithm.?);

    try testing.expectEqual(digests.LineKind.entry, digests.parseLine("My File.lha CBF43926", &entry, &name));
    try testing.expectEqualStrings("My File.lha", entry.name);
    try testing.expectEqual(digests.Algorithm.crc32, entry.algorithm.?);
    try testing.expectEqualSlices(u8, &.{ 0xCB, 0xF4, 0x39, 0x26 }, entry.digest[0..4]);

    try testing.expectEqual(digests.LineKind.entry, digests.parseLine("\\ff00ff00  a\\\\b\\nc", &entry, &name));
    try testing.expectEqualStrings("a\\b\nc", entry.name);

    // A name that is no UTF-8 - a list a Latin-1 system wrote - read so.
    try testing.expectEqual(digests.LineKind.entry, digests.parseLine("ff00ff00  Caf\xe9.txt", &entry, &name));
    try testing.expectEqualStrings("Caf\xc3\xa9.txt", entry.name);
    var tight: [5]u8 = undefined;
    try testing.expectEqual(digests.LineKind.malformed, digests.parseLine("ff00ff00  Caf\xe9.", &entry, &tight));

    // UTF-8 stays as it is.
    try testing.expectEqual(digests.LineKind.entry, digests.parseLine("ff00ff00  \xe6\x97\xa5.txt", &entry, &name));
    try testing.expectEqualStrings("\xe6\x97\xa5.txt", entry.name);

    try testing.expectEqual(digests.LineKind.nothing, digests.parseLine("; made by an SFV tool", &entry, &name));
    try testing.expectEqual(digests.LineKind.nothing, digests.parseLine("", &entry, &name));
    try testing.expectEqual(digests.LineKind.malformed, digests.parseLine("hello world", &entry, &name));
    try testing.expectEqual(digests.LineKind.malformed, digests.parseLine("abc  name", &entry, &name));
}
