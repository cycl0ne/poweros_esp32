// SPDX-License-Identifier: MIT
//! ACTION_FORMAT's work: a fresh volume over the drive's area, laid out as
//! the drive's DosType says the area is, and in the format it names.
//!
//! **Where.** An area that is the volume itself (`MSD`) gets the volume
//! from its first block. One that holds a partition table (`MSH`) gets a
//! new table with a single partition, from the first `boundary` on to the
//! end - or as far as the table's 32-bit count reaches - and the volume in
//! it. The table is written after the volume.
//!
//! **Which.** The DosType's last byte names FAT32 or exFAT; with neither
//! (`FORMAT_BY_SIZE`), an area of up to 32 GiB is FAT32 and a larger one
//! exFAT, which is how a card is sold - and so is one too small for
//! FAT32's clusters, which exFAT has no least count of.
//!
//! **The boundary** is the card's unit of writing that the layout keeps
//! clusters inside: 4 MiB up to 32 GiB, 16 MiB up to 512 GiB and 32 MiB
//! past that, as cards are made, but never more than a 64th of the area,
//! so a small one gives little of itself to it.
//!
//! Everything that can be refused is refused before the first write: a
//! label the format cannot hold, a format the area cannot have.

const std = @import("std");
const sdk = @import("sdk");
const dos = sdk.dos;
const fat = dos.fat;
const UtilityBase = sdk.interface.utility.UtilityBase;
const _fat = @import("_fat.zig");
const fat32_format = @import("fat32/format.zig");
const exfat_format = @import("exfat/format.zig");
const Error = _fat.Error;

const mib: u64 = 1024 * 1024;
const gib: u64 = 1024 * mib;

/// The largest area FAT32 is chosen for when the DosType leaves it open.
const fat32_most: u64 = 32 * gib;

/// The volume worked out, in one of the two formats.
const Made = union(enum) {
    fat32: fat32_format.Plan,
    exfat: exfat_format.Plan,
};

/// A fresh volume on the medium, which is the drive's area: in the format
/// `dos_type` names and where it says, labelled `name` (null or empty for
/// none). The medium is duck-typed as the file systems' is; `ub` dates
/// the label.
pub fn format(media: anytype, ub: *UtilityBase, dos_type: u32, name: ?[]const u8) Error!void {
    const sector_bytes = media.blockSize();
    const sectors = media.blocks();
    if (sectors == 0) return error.MediumFailed;
    const boundary = boundaryFor(sectors * sector_bytes, sector_bytes);
    const table = media.partitioned();
    const first: u64 = if (table) boundary else 0;
    if (first >= sectors) return error.Unsuitable;
    // A table counts a partition's blocks in 32 bits.
    const volume_sectors = if (table) @min(sectors - first, std.math.maxInt(u32)) else sectors - first;

    const made = try choose(fat.formatOfType(dos_type), first, volume_sectors, sector_bytes, boundary);
    const label: ?[]const u8 = if (name) |given| (if (given.len == 0) null else given) else null;
    const when = media.now();
    const serial = serialOf(when);
    switch (made) {
        .fat32 => |plan| {
            const short: ?[fat.bpb_volume_label_bytes]u8 = if (label) |given| try _fat.shortLabel(given) else null;
            try fat32_format.write(media, plan, short, serial, _fat.stampOf(ub, when));
        },
        .exfat => |plan| {
            if (label) |given| if (given.len > fat.exfat_label_max or !dos.volumename.valid(given)) return error.InvalidName;
            try exfat_format.write(media, plan, label, serial);
        },
    }
    if (!table) return;
    const block = media.alloc(sector_bytes) orelse return error.NoMemory;
    defer media.free(block);
    const kind: u8 = switch (made) {
        .fat32 => fat.TYPE_FAT32_LBA,
        .exfat => fat.TYPE_NTFS_OR_EXFAT,
    };
    try _fat.writeTable(media, @intCast(first), @intCast(volume_sectors), kind, serial, block);
}

/// The volume for the format `which` (`FORMAT_*`) asks for.
fn choose(which: u8, first: u64, sectors: u64, sector_bytes: u32, boundary: u32) Error!Made {
    switch (which) {
        fat.FORMAT_FAT32 => return .{ .fat32 = fat32_format.plan(first, sectors, sector_bytes, boundary) orelse return error.Unsuitable },
        fat.FORMAT_EXFAT => return .{ .exfat = exfat_format.plan(first, sectors, sector_bytes, boundary) orelse return error.Unsuitable },
        fat.FORMAT_BY_SIZE => {
            if (sectors * sector_bytes <= fat32_most) {
                if (fat32_format.plan(first, sectors, sector_bytes, boundary)) |plan| return .{ .fat32 = plan };
            }
            return .{ .exfat = exfat_format.plan(first, sectors, sector_bytes, boundary) orelse return error.Unsuitable };
        },
        else => return error.Unsuitable,
    }
}

/// The boundary for an area of `bytes`, in sectors.
fn boundaryFor(bytes: u64, sector_bytes: u32) u32 {
    var unit: u64 = if (bytes <= fat32_most) 4 * mib else if (bytes <= 512 * gib) 16 * mib else 32 * mib;
    while (unit > sector_bytes and unit * 64 > bytes) unit /= 2;
    return @intCast(@max(unit / sector_bytes, 1));
}

/// A volume's serial number: the moment it was made, in ticks, which is
/// what tells two volumes made the same way apart.
fn serialOf(when: dos.DateStamp) u32 {
    const days: u64 = @intCast(@max(when.days, 0));
    const minutes = days * 24 * 60 + @as(u64, @intCast(@max(when.minute, 0)));
    return @truncate(minutes * 60 * 50 + @as(u64, @intCast(@max(when.tick, 0))));
}

// --- tests -------------------------------------------------------------------

const testing = std.testing;

test "the boundary is the card's unit, but never more than a 64th of the area" {
    try testing.expectEqual(@as(u32, 8192), boundaryFor(16 * gib, 512));
    try testing.expectEqual(@as(u32, 32768), boundaryFor(64 * gib, 512));
    try testing.expectEqual(@as(u32, 65536), boundaryFor(1024 * gib, 512));
    // 32 MiB: half a MiB.
    try testing.expectEqual(@as(u32, 1024), boundaryFor(32 * mib, 512));
}

test "by size: FAT32 up to 32 GiB, exFAT past it and below FAT32's least" {
    try testing.expect(try choose(fat.FORMAT_BY_SIZE, 8192, 30_000_000, 512, 8192) == .fat32);
    try testing.expect(try choose(fat.FORMAT_BY_SIZE, 32768, 124_000_000, 512, 32768) == .exfat);
    try testing.expect(try choose(fat.FORMAT_BY_SIZE, 0, 16384, 512, 128) == .exfat);
    try testing.expect(try choose(fat.FORMAT_EXFAT, 8192, 30_000_000, 512, 8192) == .exfat);
    try testing.expectError(error.Unsuitable, choose(fat.FORMAT_FAT32, 0, 16384, 512, 128));
    try testing.expectError(error.Unsuitable, choose(7, 8192, 30_000_000, 512, 8192));
}
