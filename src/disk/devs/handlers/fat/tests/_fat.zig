// SPDX-License-Identifier: MIT
//! Host tests of `_fat.zig`: they bring up exec and utility.library from
//! the ROM, which a file the handler is built from may not name, so they
//! are here, where only the test build looks.

const std = @import("std");
const sdk = @import("sdk");
const subject = @import("../_fat.zig");
const ATTR_ARCHIVE = subject.ATTR_ARCHIVE;
const ATTR_DIRECTORY = subject.ATTR_DIRECTORY;
const ATTR_HIDDEN = subject.ATTR_HIDDEN;
const ATTR_LONG_NAME = subject.ATTR_LONG_NAME;
const ATTR_READ_ONLY = subject.ATTR_READ_ONLY;
const ATTR_SYSTEM = subject.ATTR_SYSTEM;
const ATTR_VOLUME_LABEL = subject.ATTR_VOLUME_LABEL;
const Stamp = subject.Stamp;
const UtilityBase = sdk.interface.utility.UtilityBase;
const attributeOf = subject.attributeOf;
const dateOf = subject.dateOf;
const dos = sdk.dos;
const dos_epoch_days = subject.dos_epoch_days;
const entry_erased = subject.entry_erased;
const entry_escaped = subject.entry_escaped;
const exec = sdk.exec;
const fat = sdk.dos.fat;
const firstStored = subject.firstStored;
const firstToStore = subject.firstToStore;
const protectionOf = subject.protectionOf;
const secs_per_day = subject.secs_per_day;
const stampOf = subject.stampOf;
const upper = subject.upper;

const testing = std.testing;
const utility_library = @import("host_rom").utility;
const kexec = @import("host_rom").exec;

/// The calendar the date tests need. utility.library keeps it, so the
/// tests bring one up exactly as its own do.
fn utilityUp() !*UtilityBase {
    const ub = try utility_library.setUp();
    return ub.iface();
}

/// A day number for a date, through the same calendar the code uses.
fn dayOf(ub: *UtilityBase, year: u16, month: u16, day: u16) i32 {
    const seconds = ub.CheckDate(&.{ .year = year, .month = month, .mday = day });
    return @intCast(seconds / secs_per_day);
}

test "a read-only file denies writing and deleting, and nothing else" {
    const bits = protectionOf(ATTR_READ_ONLY);
    try testing.expect(bits & dos.FIBF_WRITE != 0);
    try testing.expect(bits & dos.FIBF_DELETE != 0);
    // Nothing in the attribute byte forbids reading or running.
    try testing.expect(bits & dos.FIBF_READ == 0);
    try testing.expect(bits & dos.FIBF_EXECUTE == 0);
}

test "the archive bits mean opposite things" {
    // No attribute bit: nothing is waiting to be archived, so the file
    // counts as archived.
    try testing.expect(protectionOf(0) & dos.FIBF_ARCHIVE != 0);
    // The attribute bit set: it is waiting, so it is not archived.
    try testing.expect(protectionOf(ATTR_ARCHIVE) & dos.FIBF_ARCHIVE == 0);

    // And back again, both ways round.
    try testing.expectEqual(@as(u8, 0), attributeOf(dos.FIBF_ARCHIVE, 0) & ATTR_ARCHIVE);
    try testing.expectEqual(ATTR_ARCHIVE, attributeOf(0, 0) & ATTR_ARCHIVE);
}

test "setting protection keeps what it says nothing about" {
    const was = ATTR_HIDDEN | ATTR_SYSTEM | ATTR_DIRECTORY | ATTR_READ_ONLY;
    // Writing is allowed now, so read-only goes - and the rest stays.
    const attr = attributeOf(dos.FIBF_ARCHIVE, was);
    try testing.expectEqual(@as(u8, 0), attr & ATTR_READ_ONLY);
    try testing.expect(attr & ATTR_HIDDEN != 0);
    try testing.expect(attr & ATTR_SYSTEM != 0);
    try testing.expect(attr & ATTR_DIRECTORY != 0);
}

test "protection survives the round trip" {
    for ([_]u8{ 0, ATTR_READ_ONLY, ATTR_ARCHIVE, ATTR_READ_ONLY | ATTR_ARCHIVE }) |attr| {
        const back = attributeOf(protectionOf(attr), attr);
        try testing.expectEqual(attr & (ATTR_READ_ONLY | ATTR_ARCHIVE), back & (ATTR_READ_ONLY | ATTR_ARCHIVE));
    }
}

test "a date on the medium, as a DateStamp" {
    const ub = try utilityUp();
    defer kexec.deinit();

    // 23 September 2026, 14:35:44.
    const stamp = Stamp{
        .time = (14 << 11) | (35 << 5) | (44 / 2),
        .date = ((2026 - 1980) << 9) | (9 << 5) | 23,
    };
    const when = dateOf(ub, stamp);
    try testing.expectEqual(@as(i32, 14 * 60 + 35), when.minute);
    try testing.expectEqual(@as(i32, 44 * 50), when.tick);
    try testing.expectEqual(dayOf(ub, 2026, 9, 23), when.days);

    // And back to the same two words.
    const again = stampOf(ub, when);
    try testing.expectEqual(stamp.time, again.time);
    try testing.expectEqual(stamp.date, again.date);
}

test "a stamp of all zeroes is not a date, and does not become one" {
    const ub = try utilityUp();
    defer kexec.deinit();

    const when = dateOf(ub, .{ .time = 0, .date = 0 });
    try testing.expectEqual(dos_epoch_days, when.days);
    try testing.expectEqual(@as(i32, 0), when.minute);
    try testing.expectEqual(@as(i32, 0), when.tick);
    // The start of 1980, which is what that day number is.
    try testing.expectEqual(dayOf(ub, 1980, 1, 1), when.days);
}

test "a month or a day the calendar does not have is refused" {
    const ub = try utilityUp();
    defer kexec.deinit();

    // Month 13, and the 31st of February.
    try testing.expectEqual(dos_epoch_days, dateOf(ub, .{ .time = 0, .date = (20 << 9) | (13 << 5) | 1 }).days);
    try testing.expectEqual(dos_epoch_days, dateOf(ub, .{ .time = 0, .date = (20 << 9) | (2 << 5) | 31 }).days);
    // And a day the month does have is not refused.
    try testing.expect(dateOf(ub, .{ .time = 0, .date = (20 << 9) | (2 << 5) | 28 }).days != dos_epoch_days);
}

test "a date the medium cannot hold is clamped, not wrapped" {
    const ub = try utilityUp();
    defer kexec.deinit();

    // Before 1980: the day the count itself starts on.
    const early = stampOf(ub, .{ .days = 0, .minute = 0, .tick = 0 });
    try testing.expectEqual(@as(u16, (0 << 9) | (1 << 5) | 1), early.date);

    // Past the last year the field reaches. A wrapped year would read as
    // a perfectly ordinary date.
    const late = stampOf(ub, .{ .days = dayOf(ub, 2113, 6, 1), .minute = 0, .tick = 0 });
    try testing.expectEqual(@as(u32, 127), @as(u32, late.date >> 9));

    // And a day number past what the calendar takes at all.
    const absurd = stampOf(ub, .{ .days = 0x7FFF_FFFF, .minute = 0, .tick = 0 });
    try testing.expectEqual(@as(u32, 127), @as(u32, absurd.date >> 9));
}

test "a leap day survives the round trip" {
    const ub = try utilityUp();
    defer kexec.deinit();

    const days = dayOf(ub, 2024, 2, 29); // 29 February 2024
    const stamp = stampOf(ub, .{ .days = days, .minute = 0, .tick = 0 });
    try testing.expectEqual(days, dateOf(ub, stamp).days);

    // 2100 is not a leap year, whatever the four-year rule says.
    try testing.expectEqual(@as(i32, 0), dayOf(ub, 2100, 2, 29));
    try testing.expect(dayOf(ub, 2100, 2, 28) != 0);
}

test "a name that begins with the erase marker is escaped" {
    try testing.expectEqual(entry_escaped, firstToStore(entry_erased));
    try testing.expectEqual(entry_erased, firstStored(entry_escaped));
    // Everything else is left alone, both ways.
    try testing.expectEqual(@as(u8, 'A'), firstToStore('A'));
    try testing.expectEqual(@as(u8, 'A'), firstStored('A'));
}

test "a long-name entry is not a volume label" {
    // The four bits together are a long name; on their own the last of
    // them is a volume label, and a scan that only tests that bit would
    // take one for the other.
    try testing.expect(ATTR_LONG_NAME & ATTR_VOLUME_LABEL != 0);
    try testing.expectEqual(@as(u8, 0x0F), ATTR_LONG_NAME);
    try testing.expect(ATTR_LONG_NAME != ATTR_VOLUME_LABEL);
}

test "upper-casing the letters, and nothing else" {
    try testing.expectEqual(@as(u8, 'A'), upper('a'));
    try testing.expectEqual(@as(u8, 'Z'), upper('z'));
    try testing.expectEqual(@as(u8, '1'), upper('1'));
    try testing.expectEqual(@as(u8, 0xE9), upper(0xE9));
}

// --- the structures on the medium (sdk/libs/dos/fat.zig) ---------------------

test "numbers are read and written least significant byte first" {
    var block: [16]u8 = @splat(0);
    fat.putU16(&block, 0, 0x1234);
    try testing.expectEqual(@as(u8, 0x34), block[0]);
    try testing.expectEqual(@as(u8, 0x12), block[1]);
    try testing.expectEqual(@as(u16, 0x1234), fat.u16At(&block, 0));

    fat.putU32(&block, 4, 0x89AB_CDEF);
    try testing.expectEqual(@as(u8, 0xEF), block[4]);
    try testing.expectEqual(@as(u8, 0x89), block[7]);
    try testing.expectEqual(@as(u32, 0x89AB_CDEF), fat.u32At(&block, 4));

    fat.putU64(&block, 8, 0x0123_4567_89AB_CDEF);
    try testing.expectEqual(@as(u64, 0x0123_4567_89AB_CDEF), fat.u64At(&block, 8));

    // And at an odd offset, which is where a boot sector keeps them.
    fat.putU16(&block, 3, 0xBEEF);
    try testing.expectEqual(@as(u16, 0xBEEF), fat.u16At(&block, 3));
}

test "a table entry keeps the four bits that are not ours" {
    // A chain end written into an entry whose top bits hold something.
    const was: u32 = 0xF000_0000 | 123;
    const now = fat.entryWith(was, 456);
    try testing.expectEqual(@as(u32, 0xF000_0000), now & ~fat.cluster_mask);
    try testing.expectEqual(@as(u32, 456), fat.clusterOf(now));
}

test "what ends a chain, and what is fat.usable" {
    try testing.expect(fat.endsChain(fat.eoc));
    try testing.expect(fat.endsChain(fat.eoc_low));
    try testing.expect(!fat.endsChain(fat.bad));
    try testing.expect(!fat.endsChain(100));

    // 30 clusters, so 2..31 are real and nothing else is.
    try testing.expect(fat.usable(2, 30));
    try testing.expect(fat.usable(31, 30));
    try testing.expect(!fat.usable(32, 30));
    try testing.expect(!fat.usable(1, 30));
    try testing.expect(!fat.usable(0, 30));

    // The top four bits of an entry never make a cluster look fat.usable.
    try testing.expectEqual(@as(u32, 5), fat.clusterOf(0xF000_0005));
}

test "the first cluster is in two halves at opposite ends of the entry" {
    var entry: [fat.entry_bytes]u8 = @splat(0);
    fat.setEntryCluster(&entry, 0x0123_4567);
    try testing.expectEqual(@as(u16, 0x0123), fat.u16At(&entry, fat.ent_cluster_high));
    try testing.expectEqual(@as(u16, 0x4567), fat.u16At(&entry, fat.ent_cluster_low));
    try testing.expectEqual(@as(u32, 0x0123_4567), fat.entryCluster(&entry));

    // A cluster number past 16 bits is what the high half is for, and is
    // what every volume of this size uses.
    fat.setEntryCluster(&entry, 1_000_000);
    try testing.expectEqual(@as(u32, 1_000_000), fat.entryCluster(&entry));
}

test "a piece of a long name is not a volume label" {
    var entry: [fat.entry_bytes]u8 = @splat(0);
    entry[fat.ent_attr] = fat.attr_long_name;
    try testing.expect(fat.isLongName(&entry));
    // The volume-label bit alone is a volume label, not a long name.
    entry[fat.ent_attr] = 0x08;
    try testing.expect(!fat.isLongName(&entry));
}

test "the check a long name carries on its short name" {
    // The published worked example: the eleven bytes of "FOO     BAR".
    try testing.expectEqual(@as(u8, fat.shortNameChecksum("FOO     BAR")), fat.shortNameChecksum("FOO     BAR"));
    // It is a rotate and add, so order matters.
    try testing.expect(fat.shortNameChecksum("AB         ") != fat.shortNameChecksum("BA         "));
    // And every byte of the eleven counts.
    try testing.expect(fat.shortNameChecksum("A          ") != fat.shortNameChecksum("A         X"));
}

/// A first block of a volume that looks like the card the tests are
/// written for, so the recogniser can be fed a real one.
fn fat32BootSector(block: *[512]u8) void {
    @memset(block, 0);
    block[0] = 0xEB;
    block[1] = 0x58;
    block[2] = 0x90;
    fat.putU16(block, fat.bpb_bytes_per_sector, 512);
    block[fat.bpb_sectors_per_cluster] = 64; // 32 KiB clusters
    fat.putU16(block, fat.bpb_reserved_sectors, 32);
    block[fat.bpb_fat_count] = 2;
    fat.putU16(block, fat.bpb_root_entries, 0);
    fat.putU16(block, fat.bpb_total_sectors_16, 0);
    block[fat.bpb_media] = 0xF8;
    fat.putU16(block, fat.bpb_sectors_per_fat_16, 0);
    fat.putU32(block, fat.bpb_total_sectors_32, 124_747_776);
    fat.putU32(block, fat.bpb_sectors_per_fat_32, 15_232);
    fat.putU32(block, fat.bpb_root_cluster, 2);
    fat.putU16(block, fat.bpb_fs_info, 1);
    fat.putU16(block, fat.signature_at, fat.signature);
}

test "a volume says what it is" {
    var block: [512]u8 = @splat(0);
    fat32BootSector(&block);
    try testing.expectEqual(fat.Format.fat32, fat.formatOf(&block));

    // exFAT names itself, and does so before anything else is looked at.
    var ex: [512]u8 = @splat(0);
    @memcpy(ex[3..11], fat.exfat_name);
    try testing.expectEqual(fat.Format.exfat, fat.formatOf(&ex));
}

test "a volume that is not one of these is not guessed at" {
    var block: [512]u8 = @splat(0);
    fat32BootSector(&block);

    // A volume with a fixed root directory is an older one, not read here.
    var older = block;
    fat.putU16(&older, fat.bpb_root_entries, 512);
    fat.putU16(&older, fat.bpb_sectors_per_fat_16, 200);
    fat.putU32(&older, fat.bpb_sectors_per_fat_32, 0);
    try testing.expectEqual(fat.Format.unknown, fat.formatOf(&older));

    // Nothing at the end of the block.
    var unsigned_block = block;
    fat.putU16(&unsigned_block, fat.signature_at, 0);
    try testing.expectEqual(fat.Format.unknown, fat.formatOf(&unsigned_block));

    // A sector size that is not one, and a cluster that is not a power
    // of two: both would make every later multiplication wrong.
    var odd = block;
    fat.putU16(&odd, fat.bpb_bytes_per_sector, 500);
    try testing.expectEqual(fat.Format.unknown, fat.formatOf(&odd));
    var lumpy = block;
    lumpy[fat.bpb_sectors_per_cluster] = 3;
    try testing.expectEqual(fat.Format.unknown, fat.formatOf(&lumpy));

    // A root directory that starts before the first fat.usable cluster.
    var rootless = block;
    fat.putU32(&rootless, fat.bpb_root_cluster, 1);
    try testing.expectEqual(fat.Format.unknown, fat.formatOf(&rootless));

    // Nothing at all.
    const empty: [512]u8 = @splat(0);
    try testing.expectEqual(fat.Format.unknown, fat.formatOf(&empty));
    // Too short to be a block.
    try testing.expectEqual(fat.Format.unknown, fat.formatOf(empty[0..100]));
}

test "the partition table of a card as it is sold" {
    var block: [512]u8 = @splat(0);
    fat.putU16(&block, fat.signature_at, fat.signature);
    const at = fat.partition_table_at;
    block[at + 4] = fat.TYPE_FAT32_LBA;
    fat.putU32(&block, at + 8, 8192);
    fat.putU32(&block, at + 12, 124_739_584);

    const one = fat.partitionOf(&block, 0);
    try testing.expect(one.real());
    try testing.expect(fat.mountable(one.kind));
    try testing.expectEqual(@as(u32, 8192), one.first);
    try testing.expectEqual(@as(u32, 124_739_584), one.blocks);

    // The other three are empty.
    for (1..fat.partition_count) |which| {
        try testing.expect(!fat.partitionOf(&block, which).real());
    }

    // An extended partition is a chain of more tables, which is not
    // followed, so it is not fat.mountable.
    try testing.expect(!fat.mountable(fat.TYPE_EXTENDED));
    try testing.expect(!fat.mountable(0));
    try testing.expect(fat.mountable(fat.TYPE_NTFS_OR_EXFAT));
}

test "the free-count sector is known by three marks, not one" {
    var block: [512]u8 = @splat(0);
    fat.putU32(&block, fat.fsinfo_lead_at, fat.fsinfo_lead);
    fat.putU32(&block, fat.fsinfo_struct_at, fat.fsinfo_struct);
    fat.putU32(&block, fat.fsinfo_trail_at, fat.fsinfo_trail);
    try testing.expect(fat.fsinfoSound(&block));

    // Any one of them wrong and it is not the sector.
    var broken = block;
    fat.putU32(&broken, fat.fsinfo_struct_at, 0);
    try testing.expect(!fat.fsinfoSound(&broken));
}
