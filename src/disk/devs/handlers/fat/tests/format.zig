// SPDX-License-Identifier: MIT
//! Host tests of `format.zig`: a volume formatted onto the sparse test
//! medium and mounted by the body of its format, which then takes files.
//! They bring up exec and utility.library from the ROM, which a file the
//! handler is built from may not name, so they are here, where only the
//! test build looks.
//!
//! Two tests write the volumes they made to the files `FAT32_FORMAT_IMAGE`
//! and `EXFAT_FORMAT_IMAGE` name, if they name any, for `fsck.vfat -n` and
//! `fsck.exfat -n` to judge.

const std = @import("std");
const sdk = @import("sdk");
const subject = @import("../format.zig");
const _fat = @import("../_fat.zig");
const fat32_fs = @import("../fat32/fs.zig");
const exfat_fs = @import("../exfat/fs.zig");
const fat32_testvolume = @import("../fat32/testvolume.zig");
const TestMedia = @import("../testmedia.zig").TestMedia;
const utility_library = @import("host_rom").utility;
const kexec = @import("host_rom").exec;
const DosPacket = sdk.dos.DosPacket;
const FileHandle = sdk.dos.FileHandle;
const UtilityBase = sdk.interface.utility.UtilityBase;
const dos = sdk.dos;
const fat = dos.fat;

const testing = std.testing;

const Fat32 = fat32_fs.FileSystem(TestMedia);
const Exfat = exfat_fs.FileSystem(TestMedia);

const mib_blocks: u64 = 1024 * 1024 / 512;

fn send(fs: anytype, action: dos.ActionCode, args: dos.PacketArgs) _fat.Answer {
    var pkt = DosPacket.init(action, args);
    return fs.answer(&pkt);
}

/// A file written through the packets, and read back.
fn roundTrip(fs: anytype, name: [*:0]const u8, bytes: []const u8) !void {
    var fh: FileHandle = .{};
    try testing.expectEqual(dos.DOSTRUE, send(fs, .findoutput, .{ .find = .{ .fh = &fh, .lock = null, .name = name } }).res1);
    try testing.expectEqual(@as(isize, @intCast(bytes.len)), send(fs, .write, .{ .io = .{ .fh = &fh, .buffer = @constCast(bytes.ptr), .length = @intCast(bytes.len) } }).res1);
    try testing.expectEqual(dos.DOSTRUE, send(fs, .end, .{ .file = .{ .fh = &fh } }).res1);
    var back: [64]u8 = undefined;
    fh = .{};
    try testing.expectEqual(dos.DOSTRUE, send(fs, .findinput, .{ .find = .{ .fh = &fh, .lock = null, .name = name } }).res1);
    const got = send(fs, .read, .{ .io = .{ .fh = &fh, .buffer = &back, .length = back.len } }).res1;
    try testing.expectEqual(dos.DOSTRUE, send(fs, .end, .{ .file = .{ .fh = &fh } }).res1);
    try testing.expectEqualStrings(bytes, back[0..@intCast(got)]);
}

/// Whether `name` is on the volume.
fn there(fs: anytype, name: [*:0]const u8) bool {
    var raw: [7]isize = @splat(0);
    raw[1] = @bitCast(@intFromPtr(name));
    raw[2] = dos.SHARED_LOCK;
    var pkt = DosPacket.init(.locate_object, .{ .raw = raw });
    const got = fs.answer(&pkt);
    if (got.res1 == 0) return false;
    raw = @splat(0);
    raw[0] = got.res1;
    pkt = DosPacket.init(.free_lock, .{ .raw = raw });
    _ = fs.answer(&pkt);
    return true;
}

test "a card's area formatted by size: a table, a FAT32 volume in it, named, empty, and it takes files" {
    const ub = (try utility_library.setUp()).iface();
    defer kexec.deinit();
    var media = TestMedia.init(512, 2048 * mib_blocks);
    defer media.deinit();
    media.table = true;
    try subject.format(&media, ub, dos.ID_MSDOS_DISK_HD, "Photos");
    try testing.expectEqual(@as(usize, 0), media.live);

    var block: [512]u8 = undefined;
    try testing.expect(media.read(0, 1, &block));
    try testing.expect(fat.signed(&block));
    const partition = fat.partitionOf(&block, 0);
    try testing.expectEqual(fat.TYPE_FAT32_LBA, partition.kind);
    try testing.expectEqual(@as(u32, 8192), partition.first);
    try testing.expectEqual(@as(u32, @intCast(media.blocks() - 8192)), partition.blocks);
    try testing.expect(!fat.partitionOf(&block, 1).real());

    var fs = Fat32.init(&media, ub, null);
    defer fs.deinit();
    try fs.mount();
    try testing.expectEqualStrings("PHOTOS", fs.volumeName());
    // The first cluster on the 4 MiB boundary, 4 KiB clusters.
    try testing.expectEqual(@as(u32, 8), fs.geo.sectors_per_cluster);
    try testing.expectEqual(@as(u64, 0), (fs.geo.first + fs.geo.data_first) % 8192);
    try testing.expect(!there(&fs, "anything"));
    try roundTrip(&fs, "first file", "on a volume made here");
}

test "exFAT asked for, on an area that is the volume itself: no table, the volume from block 0" {
    const ub = (try utility_library.setUp()).iface();
    defer kexec.deinit();
    var media = TestMedia.init(512, 256 * mib_blocks);
    defer media.deinit();
    try subject.format(&media, ub, fat.typeWithFormat(dos.ID_MSDOS_DISK, fat.FORMAT_EXFAT), "Card");

    var block: [512]u8 = undefined;
    try testing.expect(media.read(0, 1, &block));
    try testing.expectEqual(fat.Format.exfat, fat.formatOf(&block));

    // The FAT32 body has no volume there.
    var other = Fat32.init(&media, ub, null);
    defer other.deinit();
    try testing.expectError(error.NotImplemented, other.mount());

    var fs = Exfat.init(&media, ub, null);
    defer fs.deinit();
    try fs.mount();
    try testing.expectEqualStrings("Card", fs.volumeName());
    try testing.expectEqual(@as(u64, 0), fs.geo.first);
    try roundTrip(&fs, "first file", "on an exFAT volume made here");
}

test "a 64 GB card by size is exFAT, laid out as one is sold" {
    const ub = (try utility_library.setUp()).iface();
    defer kexec.deinit();
    var media = TestMedia.init(512, 124_997_632);
    defer media.deinit();
    media.table = true;
    try subject.format(&media, ub, dos.ID_MSDOS_DISK_HD, null);

    var block: [512]u8 = undefined;
    try testing.expect(media.read(0, 1, &block));
    const partition = fat.partitionOf(&block, 0);
    try testing.expectEqual(fat.TYPE_NTFS_OR_EXFAT, partition.kind);
    try testing.expectEqual(@as(u32, 32768), partition.first);

    var fs = Exfat.init(&media, ub, null);
    defer fs.deinit();
    try fs.mount();
    try testing.expectEqual(@as(u64, 32768), fs.geo.first);
    try testing.expectEqual(@as(u32, 16384), fs.geo.fat_first);
    try testing.expectEqual(@as(u32, 32768), fs.geo.heap_first);
    try testing.expectEqual(@as(u5, 8), fs.geo.cluster_shift);
    try testing.expectEqual(@as(u32, 488_016), fs.geo.cluster_count);
    try roundTrip(&fs, "big card", "past the 4 GiB mark, laid out as sold");
}

test "refused before anything is written: a label too long, a format the area cannot have, a format there is none of" {
    const ub = (try utility_library.setUp()).iface();
    defer kexec.deinit();
    // Labels: eleven characters at most, and FAT32 takes no dot.
    var card = TestMedia.init(512, 64 * mib_blocks);
    defer card.deinit();
    try testing.expectError(error.InvalidName, subject.format(&card, ub, dos.ID_MSDOS_DISK, "Twelve chars"));
    try testing.expectError(error.InvalidName, subject.format(&card, ub, fat.typeWithFormat(dos.ID_MSDOS_DISK, fat.FORMAT_FAT32), "a.b"));
    try testing.expectError(error.InvalidName, subject.format(&card, ub, fat.typeWithFormat(dos.ID_MSDOS_DISK, fat.FORMAT_EXFAT), "a/b"));
    try testing.expectError(error.Unsuitable, subject.format(&card, ub, fat.typeWithFormat(dos.ID_MSDOS_DISK, 9), "Card"));
    try testing.expectEqual(@as(u32, 0), card.writes);

    // FAT32 on an area too small for its clusters.
    var media = TestMedia.init(512, 16 * mib_blocks);
    defer media.deinit();
    try testing.expectError(error.Unsuitable, subject.format(&media, ub, fat.typeWithFormat(dos.ID_MSDOS_DISK, fat.FORMAT_FAT32), "Small"));
    try testing.expectEqual(@as(u32, 0), media.writes);
    try testing.expectEqual(@as(usize, 0), media.live);
    // The same area by size: too small for FAT32, so exFAT.
    try subject.format(&media, ub, dos.ID_MSDOS_DISK, "Small");
    var fs = Exfat.init(&media, ub, null);
    defer fs.deinit();
    try fs.mount();
    try testing.expectEqualStrings("Small", fs.volumeName());
}

test "an area laid out otherwise than its drive says is not a volume there" {
    const ub = (try utility_library.setUp()).iface();
    defer kexec.deinit();
    var media = TestMedia.init(512, 64 * mib_blocks);
    defer media.deinit();
    try subject.format(&media, ub, dos.ID_MSDOS_DISK, "Whole");
    media.table = true;
    var fs = Fat32.init(&media, ub, null);
    defer fs.deinit();
    try testing.expectError(error.MediumFailed, fs.mount());
    // And a table where the drive says the area is the volume.
    try subject.format(&media, ub, dos.ID_MSDOS_DISK_HD, "Parted");
    media.table = false;
    try testing.expectError(error.MediumFailed, fs.mount());
    media.table = true;
    try fs.mount();
    try testing.expectEqualStrings("PARTED", fs.volumeName());
}

test "formatted over a volume with files on it: what was there is gone" {
    const ub = (try utility_library.setUp()).iface();
    defer kexec.deinit();
    const volume = try fat32_testvolume.Volume.init(.{ .clusters = 70_000, .sectors_per_cluster = 1, .first = 8192 });
    defer volume.deinit();
    {
        var fs = Fat32.init(&volume.media, ub, null);
        defer fs.deinit();
        try fs.mount();
        try roundTrip(&fs, "old file", "goes with the format");
    }
    try subject.format(&volume.media, ub, dos.ID_MSDOS_DISK_HD, "Fresh");
    var fs = Fat32.init(&volume.media, ub, null);
    defer fs.deinit();
    try fs.mount();
    try testing.expectEqualStrings("FRESH", fs.volumeName());
    try testing.expect(!there(&fs, "old file"));
}

// --- for fsck.vfat and fsck.exfat ------------------------------------------------

/// The medium's blocks written to `path`, whole.
fn writeImage(media: *TestMedia, path: []const u8) !void {
    const blocks: usize = @intCast(media.blocks());
    const image = try testing.allocator.alloc(u8, blocks * 512);
    defer testing.allocator.free(image);
    for (0..blocks) |at| try testing.expect(media.read(at, 1, image[at * 512 ..][0..512]));
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = image });
}

/// A volume formatted the way `dos_type` says, a file and a directory
/// put on it, and the area written out.
fn imageFor(dos_type: u32, label: []const u8, path: []const u8) !void {
    const ub = (try utility_library.setUp()).iface();
    defer kexec.deinit();
    var media = TestMedia.init(512, 64 * mib_blocks);
    defer media.deinit();
    try subject.format(&media, ub, dos_type, label);
    switch (fat.formatOfType(dos_type)) {
        fat.FORMAT_EXFAT => {
            var fs = Exfat.init(&media, ub, null);
            defer fs.deinit();
            try fs.mount();
            try roundTrip(&fs, "a file", "for the checker");
        },
        else => {
            var fs = Fat32.init(&media, ub, null);
            defer fs.deinit();
            try fs.mount();
            try roundTrip(&fs, "a file", "for the checker");
        },
    }
    try writeImage(&media, path);
}

test "a FAT32 volume formatted here, written out for fsck.vfat if asked" {
    const path = std.testing.environ.getPosix("FAT32_FORMAT_IMAGE") orelse return;
    try imageFor(fat.typeWithFormat(dos.ID_MSDOS_DISK, fat.FORMAT_FAT32), "Checked", path);
}

test "an exFAT volume formatted here, written out for fsck.exfat if asked" {
    const path = std.testing.environ.getPosix("EXFAT_FORMAT_IMAGE") orelse return;
    try imageFor(fat.typeWithFormat(dos.ID_MSDOS_DISK, fat.FORMAT_EXFAT), "Checked", path);
}
