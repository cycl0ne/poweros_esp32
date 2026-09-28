// SPDX-License-Identifier: MIT
//! Host tests of `exfat/dir.zig` and `exfat/names.zig` against a volume
//! the Linux kernel wrote (`exfat/testfixture.zig`). They bring up
//! utility.library from the ROM, which a file the handler is built from
//! may not name, so they are here, where only the test build looks.

const std = @import("std");
const sdk = @import("sdk");
const fat = sdk.dos.fat;
const _fat = @import("../_fat.zig");
const TestMedia = @import("../testmedia.zig").TestMedia;
const cache_area = @import("../cache.zig");
const layout = @import("../exfat/layout.zig");
const table_area = @import("../exfat/table.zig");
const dir_area = @import("../exfat/dir.zig");
const names = @import("../exfat/names.zig");
const Upcase = @import("../exfat/upcase.zig").Upcase;
const fixture = @import("../exfat/testfixture.zig");
const UtilityBase = sdk.interface.utility.UtilityBase;
const Dir = dir_area.Dir;
const Found = dir_area.Found;
const Set = dir_area.Set;

const testing = std.testing;
const utility_library = @import("host_rom").utility;
const kexec = @import("host_rom").exec;

const Cache = cache_area.BlockCache(TestMedia);
const Table = table_area.Table(TestMedia);
const Directory = dir_area.Directory(TestMedia);

fn utf16(comptime text: []const u8) []const u16 {
    return comptime std.unicode.utf8ToUtf16LeStringLiteral(text);
}

/// The kernel's volume, its up-case table, and a directory reader over it.
const Rig = struct {
    media: TestMedia,
    cache: Cache,
    geo: layout.Geometry,
    table: Table,
    upcase: Upcase,
    dirs: Directory,
    root: Dir,
    ub: *UtilityBase,

    fn init(rig: *Rig) !void {
        const utility = try utility_library.setUp();
        rig.ub = utility.iface();
        rig.media = TestMedia.init(512, fixture.blocks());
        try fixture.load(&rig.media, 0);
        var boot: [512]u8 = undefined;
        try testing.expect(rig.media.read(0, 1, &boot));
        rig.geo = try layout.Geometry.of(&boot, 0, rig.media.blocks(), 512);
        rig.cache = try Cache.init(&rig.media, 16);
        rig.table = Table.init(&rig.cache, &rig.geo);
        rig.root = .{
            .chain = .{ .first = rig.geo.root_cluster },
            .length = (try rig.table.length(rig.geo.root_cluster)) * rig.geo.cluster_bytes,
        };
        // The up-case table comes first; the reader needs it for names.
        rig.dirs = .{ .cache = &rig.cache, .table = &rig.table, .geo = &rig.geo, .upcase = undefined, .ub = rig.ub };
        const system = try rig.dirs.system(rig.root);
        var scratch: [512]u8 = undefined;
        rig.upcase = try Upcase.load(TestMedia, &rig.media, &rig.cache, &rig.table, &rig.geo, system.upcase_first, system.upcase_length, system.upcase_checksum, &scratch);
        rig.dirs.upcase = &rig.upcase;
    }

    fn deinit(rig: *Rig) void {
        rig.upcase.deinit(TestMedia, &rig.media);
        rig.cache.deinit();
        rig.media.deinit();
        kexec.deinit();
    }

    fn find(rig: *Rig, dir: Dir, name: []const u8, found: *Found) !bool {
        var wanted: names.Wanted = undefined;
        wanted.init(name, &rig.upcase);
        return rig.dirs.find(dir, &wanted, found);
    }

    fn dirOf(found: *const Found) Dir {
        return .{ .chain = found.chain(), .length = found.size };
    }
};

test "the root's own entries: bitmap, up-case table and label" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();
    const system = try rig.dirs.system(rig.root);
    try testing.expectEqual(@as(u32, 2), system.bitmap_first);
    try testing.expectEqual(@as(u64, 448), system.bitmap_length);
    try testing.expectEqual(@as(u32, 3), system.upcase_first);
    try testing.expectEqual(@as(u64, 5836), system.upcase_length);
    try testing.expectEqualSlices(u16, utf16("POWEROS"), system.label[0..system.label_len]);
}

test "every file the kernel made is listed, and the deleted one is not" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();
    var index: u32 = 0;
    var found: Found = .{};
    var seen: u32 = 0;
    var into: [_fat.fib_name_max]u8 = undefined;
    while (try rig.dirs.next(rig.root, &index, &found)) {
        const given = names.toDos(found.name(), found.hash, &into);
        try testing.expect(!std.mem.eql(u8, given, "deleted.txt"));
        seen += 1;
    }
    // hello, Café, 日本, € Rechnung, the long name, empty, big, frag,
    // spacer, Sub Dir, Many, readonly.
    try testing.expectEqual(@as(u32, 12), seen);
}

test "the kernel's name hashes are the ones this computes" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();
    var index: u32 = 0;
    var found: Found = .{};
    while (try rig.dirs.next(rig.root, &index, &found)) {
        try testing.expectEqual(found.hash, rig.upcase.hash(found.name()));
    }
}

test "a file is found by its name in any case" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();
    var found: Found = .{};
    try testing.expect(try rig.find(rig.root, "HELLO.TXT", &found));
    try testing.expectEqual(@as(u64, 16), found.size);
    try testing.expect(try rig.find(rig.root, "caf\xc9.TXT", &found));
    try testing.expect(!try rig.find(rig.root, "nothing.txt", &found));
}

test "a name dos cannot hold is found by its stand-in" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();
    var into: [_fat.fib_name_max]u8 = undefined;
    const hash = rig.upcase.hash(utf16("日本.txt"));
    const given = names.standIn(utf16("日本.txt"), hash, &into);
    var found: Found = .{};
    try testing.expect(try rig.find(rig.root, given, &found));
    try testing.expectEqualSlices(u16, utf16("日本.txt"), found.name());
    // In small letters too, as dos compares.
    var lower: [_fat.fib_name_max]u8 = undefined;
    for (given, 0..) |char, at| lower[at] = std.ascii.toLower(char);
    try testing.expect(try rig.find(rig.root, lower[0..given.len], &found));
}

test "the long name and its stand-in" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();
    var index: u32 = 0;
    var found: Found = .{};
    var into: [_fat.fib_name_max]u8 = undefined;
    while (try rig.dirs.next(rig.root, &index, &found)) {
        if (found.name_len < 150) continue;
        try testing.expectEqual(@as(usize, 158), found.name_len);
        const given = names.toDos(found.name(), found.hash, &into);
        try testing.expectEqual(_fat.fib_name_max, given.len);
        try testing.expect(std.mem.endsWith(u8, given, ".txt"));
        var again: Found = .{};
        try testing.expect(try rig.find(rig.root, given, &again));
        try testing.expectEqual(found.index, again.index);
        return;
    }
    return error.NotFound;
}

test "what the kernel wrote about each file" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();
    var found: Found = .{};

    // Set as 2020-05-06 07:08:10 in UTC+2. The kernel stores UTC and
    // says so in the entry's time-zone byte, so what is on the medium is
    // 05:08:10 - which is what is read, the zone not applied.
    try testing.expect(try rig.find(rig.root, "hello.txt", &found));
    const stamp = dir_area.stampOf(found.modified);
    try testing.expectEqual(@as(u16, (40 << 9) | (5 << 5) | 6), stamp.date);
    try testing.expectEqual(@as(u16, (5 << 11) | (8 << 5) | 5), stamp.time);

    try testing.expect(try rig.find(rig.root, "big.bin", &found));
    try testing.expectEqual(@as(u64, 20000), found.size);
    try testing.expectEqual(@as(u64, 20000), found.valid);
    try testing.expect(found.chain().contiguous);

    // Broken up by spacer.bin: linked through the table.
    try testing.expect(try rig.find(rig.root, "frag.bin", &found));
    try testing.expectEqual(@as(u64, 8292), found.size);
    try testing.expect(!found.chain().contiguous);
    try testing.expectEqual(@as(u64, 3), try rig.table.length(found.first));

    try testing.expect(try rig.find(rig.root, "empty.dat", &found));
    try testing.expectEqual(@as(u64, 0), found.size);
    try testing.expectEqual(@as(u32, 0), found.chain().first);

    try testing.expect(try rig.find(rig.root, "readonly.txt", &found));
    try testing.expect(found.attr & _fat.ATTR_READ_ONLY != 0);

    try testing.expect(try rig.find(rig.root, "Sub Dir", &found));
    try testing.expect(found.isDir());
}

test "a directory is walked down into, and a two-cluster one read to its end" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();
    var sub: Found = .{};
    try testing.expect(try rig.find(rig.root, "Sub Dir", &sub));
    var deeper: Found = .{};
    try testing.expect(try rig.find(Rig.dirOf(&sub), "Deeper", &deeper));
    var note: Found = .{};
    try testing.expect(try rig.find(Rig.dirOf(&deeper), "note.TXT", &note));
    try testing.expectEqual(@as(u64, 10), note.size);

    var many: Found = .{};
    try testing.expect(try rig.find(rig.root, "Many", &many));
    try testing.expectEqual(@as(u64, 8192), many.size);
    var index: u32 = 0;
    var found: Found = .{};
    var count: u32 = 0;
    while (try rig.dirs.next(Rig.dirOf(&many), &index, &found)) count += 1;
    try testing.expectEqual(@as(u32, 60), count);
    try testing.expect(try rig.find(Rig.dirOf(&many), "entry_60.txt", &found));
    try testing.expect(!try rig.dirs.empty(Rig.dirOf(&many)));
}

test "a set written reads back, and erased is gone and its room reused" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();
    const name = utf16("Neu geschrieben, mit einem langen Namen.txt");
    var set: Set = .{};
    set.compose(name, rig.upcase.hash(name), _fat.ATTR_ARCHIVE, dir_area.momentOf(_fat.firstStamp()), 0);
    set.setStream(.{ .first = 900, .contiguous = true }, 5000, 8192);
    const where = try rig.dirs.room(rig.root, set.count) orelse return error.NoRoom;
    try rig.dirs.writeSet(rig.root, where, &set);

    var found: Found = .{};
    try testing.expect(try rig.find(rig.root, "NEU GESCHRIEBEN, MIT EINEM LANGEN NAMEN.TXT", &found));
    try testing.expectEqual(where, found.index);
    try testing.expectEqual(@as(u64, 5000), found.valid);
    try testing.expectEqual(@as(u64, 8192), found.size);
    try testing.expect(found.chain().contiguous);

    // Changed in place: the checksum is sealed again.
    var again: Set = .{};
    try testing.expect(try rig.dirs.readSet(rig.root, where, &again));
    again.setStream(.{ .first = 900 }, 8192, 8192);
    try rig.dirs.writeSet(rig.root, where, &again);
    try testing.expect(try rig.dirs.load(rig.root, where, &found));
    try testing.expect(!found.chain().contiguous);

    try rig.dirs.erase(rig.root, where, found.count);
    try testing.expect(!try rig.find(rig.root, "neu geschrieben, mit einem langen namen.txt", &found));
    try testing.expectEqual(@as(?u32, where), try rig.dirs.room(rig.root, set.count));
}

test "a set with a damaged checksum is passed over, the rest still read" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();
    var found: Found = .{};
    try testing.expect(try rig.find(rig.root, "big.bin", &found));
    // One byte of its stream changed behind the checksum's back.
    var place: table_area.Place = .{};
    const spot = (try rig.dirs.spotOf(rig.root, found.index + 1, &place)).?;
    const block = try rig.cache.getForWrite(spot.block);
    block[spot.at + fat.exfat_stream_data_length] ^= 1;
    try testing.expect(!try rig.find(rig.root, "big.bin", &found));
    try testing.expect(try rig.find(rig.root, "spacer.bin", &found));
}
