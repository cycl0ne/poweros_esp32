// SPDX-License-Identifier: MPL-2.0
//! posfs's format definitions (sdk/libs/dos/posfs): the crc, the DosTypes,
//! the block sizes, the dates, the names - UTF-8, folded, hashed, and
//! given to dos - and the partition table a card's volume sits in.

const std = @import("std");
const testing = std.testing;
const sdk = @import("sdk");
const posfs = sdk.dos.posfs;
const layout = posfs.layout;
const fold = posfs.fold;

test "the crc is crc32" {
    try testing.expectEqual(@as(u32, 0xCBF43926), layout.crc32("123456789"));
    const uuid: [16]u8 = @splat(0x5A);
    var other = uuid;
    other[15] = 0;
    // Seeded: the same bytes on another volume give another crc.
    try testing.expect(layout.crcSeeded(&uuid, "abc") != layout.crcSeeded(&other, "abc"));
    try testing.expect(layout.seededLife(&uuid, 1) != layout.seededLife(&uuid, 2));
}

/// crc32 a byte at a time, as the format defines it.
fn crcByBytes(running: u32, bytes: []const u8) u32 {
    var crc = running;
    for (bytes) |byte| {
        crc ^= byte;
        for (0..8) |_| crc = if (crc & 1 != 0) 0xEDB8_8320 ^ (crc >> 1) else crc >> 1;
    }
    return crc;
}

test "the crc is the same eight bytes at a time, from any start and in any pieces" {
    var bytes: [4096 + 8]u8 align(8) = undefined;
    for (&bytes, 0..) |*byte, i| byte.* = @truncate(i *% 167 +% (i >> 5) *% 31 +% 7);
    for (0..8) |start| {
        for (0..81) |len| {
            const part = bytes[start..][0..len];
            try testing.expectEqual(crcByBytes(layout.crcStart(), part), layout.crcAdd(layout.crcStart(), part));
            // Split anywhere, run on: the same crc.
            const cut = len / 3;
            try testing.expectEqual(crcByBytes(layout.crcStart(), part), layout.crcAdd(layout.crcAdd(layout.crcStart(), part[0..cut]), part[cut..]));
        }
    }
    const uuid: [16]u8 = @splat(0xC3);
    const block = bytes[0..4096];
    try testing.expectEqual(~crcByBytes(crcByBytes(layout.crcStart(), &uuid), block), layout.crcSeeded(&uuid, block));
    try testing.expectEqual(~crcByBytes(crcByBytes(layout.crcStart(), &uuid), bytes[3..][0..4096]), layout.crcSeeded(&uuid, bytes[3..][0..4096]));
}

test "a DosType names posfs in both layouts" {
    try testing.expect(posfs.isPosfsType(posfs.ID_POSFS_DISK));
    try testing.expect(posfs.isPosfsType(posfs.ID_POSFS_MBR));
    try testing.expect(!posfs.isPosfsType(0x504F_5302));
    try testing.expect(!posfs.isPosfsType(sdk.dos.ID_DOS_DISK));
    try testing.expect(posfs.partitionedType(posfs.ID_POSFS_MBR));
    try testing.expect(!posfs.partitionedType(posfs.ID_POSFS_DISK));
}

test "the block size comes from the partition, raised to 4 KiB" {
    try testing.expectEqual(@as(?u32, 4096), posfs.chooseBlockSize(0, 512, 512, 0));
    try testing.expectEqual(@as(?u32, 16384), posfs.chooseBlockSize(0, 16384, 512, 0));
    try testing.expectEqual(@as(?u32, 4096), posfs.chooseBlockSize(0, 4096, 4096, 4096));
    try testing.expectEqual(@as(?u32, 65536), posfs.chooseBlockSize(65536, 512, 512, 0));
    try testing.expectEqual(@as(?u32, 1024), posfs.chooseBlockSize(1024, 4096, 512, 0));
    // Not a multiple of the erase unit, not a power of two, too large.
    try testing.expectEqual(@as(?u32, null), posfs.chooseBlockSize(1024, 4096, 256, 4096));
    try testing.expectEqual(@as(?u32, null), posfs.chooseBlockSize(3072, 512, 512, 0));
    try testing.expectEqual(@as(?u32, null), posfs.chooseBlockSize(131072, 512, 512, 0));
}

test "an item fits three to a leaf at every block size" {
    var size: u32 = posfs.min_block_size;
    while (size <= posfs.max_block_size) : (size *= 2) {
        const most = layout.itemMax(size);
        try testing.expect(3 * (most + @sizeOf(layout.LeafEntry)) <= layout.leafRoom(size));
        try testing.expect(most >= 16 + posfs.max_name);
        try testing.expect(layout.inlineMax(size) <= most);
        try testing.expect(layout.innerCapacity(size) >= 23);
    }
    try testing.expectEqual(@as(u32, 1024), layout.inlineMax(4096));
    try testing.expectEqual(@as(u32, 100), layout.innerCapacity(4096));
    try testing.expectEqual(@as(u32, 167), layout.deadEntries(4096));
}

test "a date goes to microseconds and back" {
    const stamp: sdk.dos.DateStamp = .{ .days = 17_000, .minute = 754, .tick = 49 };
    try testing.expect(sdk.dos.DateStamp.eql(stamp, layout.stampOf(layout.microsOf(stamp))));
    try testing.expectEqual(@as(u64, 0), layout.microsOf(.{ .days = -1 }));
}

test "UTF-8 is decoded strictly" {
    try testing.expect(fold.valid("plain"));
    try testing.expect(fold.valid("Café 日本 \u{10400}"));
    // Overlong, a surrogate, past U+10FFFF, cut short, a stray byte.
    try testing.expect(!fold.valid("\xC0\xAF"));
    try testing.expect(!fold.valid("\xED\xA0\x80"));
    try testing.expect(!fold.valid("\xF4\x90\x80\x80"));
    try testing.expect(!fold.valid("\xE2\x82"));
    try testing.expect(!fold.valid("a\x80b"));
    var buffer: [4]u8 = undefined;
    for ([_]u21{ 0x41, 0xE9, 0x20AC, 0x10400 }) |code| {
        const len = fold.encode(code, &buffer);
        var at: usize = 0;
        try testing.expectEqual(code, fold.decode(buffer[0..len], &at).?);
        try testing.expectEqual(len, at);
    }
}

test "names fold by simple case folding" {
    try testing.expectEqual(@as(u21, 'a'), fold.foldCode('A'));
    try testing.expectEqual(@as(u21, 0xE4), fold.foldCode(0xC4)); // Ä
    try testing.expectEqual(@as(u21, 0xDF), fold.foldCode(0xDF)); // ß stays
    try testing.expectEqual(@as(u21, 0xDF), fold.foldCode(0x1E9E)); // ẞ
    try testing.expectEqual(@as(u21, 0x3C3), fold.foldCode(0x3A3)); // Σ
    try testing.expectEqual(@as(u21, 0x3C3), fold.foldCode(0x3C2)); // ς
    try testing.expectEqual(@as(u21, 0x434), fold.foldCode(0x414)); // Д
    try testing.expectEqual(@as(u21, 0x3BC), fold.foldCode(0xB5)); // µ
    try testing.expectEqual(@as(u21, 0x10428), fold.foldCode(0x10400));
    try testing.expectEqual(@as(u21, 0x101), fold.foldCode(0x100));
    try testing.expectEqual(@as(u21, 0x101), fold.foldCode(0x101));
    // The Turkic and the full foldings are not in the table.
    try testing.expectEqual(@as(u21, 0x130), fold.foldCode(0x130));
    try testing.expectEqual(@as(u21, 'i'), fold.foldCode('I'));
    try testing.expect(fold.same("ReadMe.TXT", "readme.txt"));
    try testing.expect(fold.same("ΣΟΦΊΑ", "σοφία"));
    try testing.expect(!fold.same("Straße", "STRASSE"));
    try testing.expect(!fold.same("abc", "abcd"));
    try testing.expect(!fold.same("caf\u{e9}", "cafe\u{301}"));
}

test "a name's hash is pinned" {
    // The format: these never change.
    try testing.expectEqual(@as(u32, 0x873586F3), fold.hash("ReadMe"));
    try testing.expectEqual(@as(u32, 0x06B9DF6F), fold.hash("C"));
    try testing.expectEqual(@as(u32, 0x89B7BA87), fold.hash("日本.TXT"));
    try testing.expectEqual(@as(u32, 0xFF46787D), fold.hash("ΣΟΦΊΑ"));
    try testing.expectEqual(@as(u64, 0x873586_07), fold.position(fold.bucketOf(0x873586F3), 7));
}

test "a name from dos becomes UTF-8, and goes back" {
    var into: [posfs.max_name]u8 = undefined;
    // Latin-1 is converted, UTF-8 kept.
    try testing.expectEqualStrings("Caf\u{e9}", fold.fromDos("Caf\xE9", &into).?);
    try testing.expectEqualStrings("日本", fold.fromDos("日本", &into).?);
    // 255 Latin-1 letters past 0x7F are 510 bytes of UTF-8.
    try testing.expectEqual(@as(?[]const u8, null), fold.fromDos(&([_]u8{0xE9} ** 200), &into));
    var back: [posfs.max_name]u8 = undefined;
    try testing.expectEqualStrings("Caf\xE9", fold.toDos("Caf\u{e9}", &back));
    try testing.expect(fold.acceptable("ok"));
    try testing.expect(!fold.acceptable("a/b"));
    try testing.expect(!fold.acceptable("a:b"));
    try testing.expect(!fold.acceptable(""));
    try testing.expect(!fold.acceptable("\xE9"));
}

test "a name beyond Latin-1 goes to dos as a stand-in that finds it" {
    var back: [posfs.max_name]u8 = undefined;
    const tag: u16 = @intCast(fold.hash("日本.txt") >> 16);
    try testing.expectEqual(@as(u16, 0x89B7), tag);
    const shown = fold.toDos("日本.txt", &back);
    try testing.expectEqualStrings("__=89B7.txt", shown);
    try testing.expectEqual(@as(?u16, 0x89B7), fold.tagOf(shown));
    const range = fold.tagRange(0x89B7);
    const position = fold.position(fold.bucketOf(fold.hash("日本.txt")), 3);
    try testing.expect(position >= range.first and position <= range.last);
    try testing.expectEqual(@as(?u16, null), fold.tagOf("plain.txt"));
    try testing.expectEqualStrings("_ Rechnung=", fold.toDos("€ Rechnung.pdf", &back)[0..11]);
}

test "a partition table: written for a volume, the volume found in it again" {
    const table = posfs.table;
    var block: [512]u8 = undefined;
    // 4 MiB in on a card of 8 GiB; less on a small one.
    try testing.expectEqual(@as(u64, 8192), table.firstBlockFor(16 * 1024 * 1024, 512));
    try testing.expectEqual(@as(u64, 256), table.firstBlockFor(16384, 512));
    table.writeTable(&block, 8192, 100_000, 0x1234_5678);
    const found = table.volumeIn(&block) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u32, 8192), found.first);
    try testing.expectEqual(@as(u32, 100_000), found.blocks);
    // A table of another file system's, and no table at all, hold none.
    block[sdk.dos.fat.partition_table_at + 4] = sdk.dos.fat.TYPE_FAT32_LBA;
    try testing.expectEqual(@as(?sdk.dos.fat.Partition, null), table.volumeIn(&block));
    @memset(&block, 0);
    try testing.expectEqual(@as(?sdk.dos.fat.Partition, null), table.volumeIn(&block));
    try testing.expect(!table.isLabel(&block));
}
