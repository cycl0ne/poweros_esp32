// SPDX-License-Identifier: MIT
//! Host tests of `fat32/dir.zig`: they bring up exec and utility.library from
//! the ROM, which a file the handler is built from may not name, so they
//! are here, where only the test build looks.

const std = @import("std");
const sdk = @import("sdk");
const subject = @import("../fat32/dir.zig");
const Cursor = subject.Cursor;
const Directory = subject.Directory;
const Found = subject.Found;
const _fat = @import("../_fat.zig");
const dos = sdk.dos;
const exec = sdk.exec;
const table_area = @import("../fat32/table.zig");

const testing = std.testing;
const TestMedia = @import("../testmedia.zig").TestMedia;
const testvolume = @import("../fat32/testvolume.zig");
const utility_library = @import("host_rom").utility;
const kexec = @import("host_rom").exec;
const TestDir = Directory(TestMedia);
const TestTable = table_area.Table(TestMedia);

const moment: _fat.Stamp = .{ .time = (12 << 11), .date = (46 << 9) | (9 << 5) | 23 };

/// A volume, its table and a directory layer over it.
const Rig = struct {
    volume: *testvolume.Volume,
    table: TestTable,
    dir: TestDir,

    fn init(rig: *Rig, options: testvolume.Options) !void {
        const ub = try utility_library.setUp();
        rig.volume = try testvolume.Volume.init(options);
        rig.table = TestTable.init(&rig.volume.cache, &rig.volume.geo);
        try rig.table.loadHints();
        rig.dir = .{ .cache = &rig.volume.cache, .table = &rig.table, .geo = &rig.volume.geo, .ub = ub.iface() };
    }

    fn deinit(rig: *Rig) void {
        rig.volume.deinit();
        kexec.deinit();
    }

    fn file(rig: *Rig, parent: u32, name: []const u8) !Found {
        var found: Found = .{};
        try rig.dir.create(parent, name, .{ .attr = _fat.ATTR_ARCHIVE, .stamp = moment }, &found);
        return found;
    }
};

test "a short name alone, and a long name with its pieces" {
    var rig: Rig = undefined;
    try rig.init(.{});
    defer rig.deinit();
    const root = rig.volume.geo.root_cluster;

    const plain = try rig.file(root, "readme.txt");
    try testing.expectEqualStrings("readme.txt", plain.name());
    // No pieces: the entry is the first slot.
    try testing.expectEqual(plain.index, plain.first_index);
    try testing.expectEqualSlices(u8, "README  TXT", &plain.short);

    const long = try rig.file(root, "A Long File Name.jpeg");
    try testing.expectEqualStrings("A Long File Name.jpeg", long.name());
    // 21 characters, two pieces before the entry.
    try testing.expectEqual(long.first_index + 2, long.index);
    try testing.expectEqualSlices(u8, "ALONGF~1JPE", &long.short);

    // Both are found by either of their names, in any case.
    var found: Found = .{};
    try testing.expect(try rig.dir.find(root, "README.TXT", &found));
    try testing.expectEqual(plain.index, found.index);
    try testing.expect(try rig.dir.find(root, "a long file name.JPEG", &found));
    try testing.expectEqual(long.index, found.index);
    try testing.expect(try rig.dir.find(root, "alongf~1.jpe", &found));
    try testing.expect(!try rig.dir.find(root, "missing", &found));
}

test "a second long name with the same start gets the next number" {
    var rig: Rig = undefined;
    try rig.init(.{});
    defer rig.deinit();
    const root = rig.volume.geo.root_cluster;
    const one = try rig.file(root, "Holiday photo 1.jpg");
    const two = try rig.file(root, "Holiday photo 2.jpg");
    try testing.expectEqualSlices(u8, "HOLIDA~1JPG", &one.short);
    try testing.expectEqualSlices(u8, "HOLIDA~2JPG", &two.short);
}

test "a scan gives every entry once, and skips what is erased" {
    var rig: Rig = undefined;
    try rig.init(.{ .label = "CARD" });
    defer rig.deinit();
    const root = rig.volume.geo.root_cluster;
    _ = try rig.file(root, "one");
    const two = try rig.file(root, "Second file");
    _ = try rig.file(root, "three");
    try rig.dir.erase(root, &two);

    var cursor = Cursor.at(root);
    var index: u32 = 0;
    var found: Found = .{};
    var seen: [4][]const u8 = undefined;
    var buffers: [4][16]u8 = undefined;
    var count: usize = 0;
    while (try rig.dir.next(&cursor, &index, &found)) {
        @memcpy(buffers[count][0..found.name_len], found.name());
        seen[count] = buffers[count][0..found.name_len];
        count += 1;
    }
    // The label is not a file, the erased one is gone.
    try testing.expectEqual(@as(usize, 2), count);
    try testing.expectEqualStrings("one", seen[0]);
    try testing.expectEqualStrings("three", seen[1]);

    // Its slots are free again: a name that needs as many takes them.
    const again = try rig.file(root, "Second name");
    try testing.expectEqual(two.first_index, again.first_index);

    var label_buf: [11]u8 = undefined;
    try testing.expectEqualStrings("CARD", try rig.dir.label(&label_buf));
}

test "a full directory grows by a cluster, zeroed" {
    // One-sector clusters: sixteen entries fill one.
    var rig: Rig = undefined;
    try rig.init(.{ .clusters = 64, .sectors_per_cluster = 1 });
    defer rig.deinit();
    const root = rig.volume.geo.root_cluster;
    var name_buf: [8]u8 = undefined;
    for (0..20) |n| {
        const name = try std.fmt.bufPrint(&name_buf, "F{d}", .{n});
        _ = try rig.file(root, name);
    }
    try testing.expectEqual(@as(u32, 2), try rig.table.length(root));

    // All twenty are there to be found, the ones in the new cluster too.
    var found: Found = .{};
    try testing.expect(try rig.dir.find(root, "F0", &found));
    try testing.expect(try rig.dir.find(root, "F19", &found));
    try testing.expectEqual(@as(u32, 19), found.index);
}

test "a directory knows its parent, and is empty when made" {
    var rig: Rig = undefined;
    try rig.init(.{});
    defer rig.deinit();
    const root = rig.volume.geo.root_cluster;

    const sub_cluster = try rig.table.allocate(null);
    try rig.dir.initDirectory(sub_cluster, root, moment);
    var sub: Found = .{};
    try rig.dir.create(root, "Sub", .{ .attr = _fat.ATTR_DIRECTORY, .cluster = sub_cluster, .stamp = moment }, &sub);
    try testing.expect(try rig.dir.empty(sub_cluster));
    try testing.expectEqual(root, try rig.dir.parentOf(sub_cluster));

    const deeper = try rig.table.allocate(null);
    try rig.dir.initDirectory(deeper, sub_cluster, moment);
    var inner: Found = .{};
    try rig.dir.create(sub_cluster, "Inner", .{ .attr = _fat.ATTR_DIRECTORY, .cluster = deeper, .stamp = moment }, &inner);
    try testing.expect(!try rig.dir.empty(sub_cluster));
    try testing.expectEqual(sub_cluster, try rig.dir.parentOf(deeper));

    // And the parent's entry for it is found by its cluster.
    var found: Found = .{};
    try testing.expect(try rig.dir.findCluster(root, sub_cluster, &found));
    try testing.expectEqualStrings("Sub", found.name());
}

test "an entry is found again by where it is" {
    var rig: Rig = undefined;
    try rig.init(.{});
    defer rig.deinit();
    const root = rig.volume.geo.root_cluster;
    _ = try rig.file(root, "first");
    const long = try rig.file(root, "A name of some length");
    var found: Found = .{};
    try testing.expect(try rig.dir.at(root, long.index, &found));
    try testing.expectEqualStrings("A name of some length", found.name());
    try testing.expect(!try rig.dir.at(root, long.index + 1, &found));
}

test "a long name dos cannot hold is given as the short one" {
    var rig: Rig = undefined;
    try rig.init(.{});
    defer rig.deinit();
    const root = rig.volume.geo.root_cluster;
    const long_name = "x" ** 120;
    const made = try rig.file(root, long_name);
    try testing.expectEqualStrings("XXXXXX~1", made.name());
    // It is still found by its long name.
    var found: Found = .{};
    try testing.expect(try rig.dir.find(root, long_name, &found));
}
