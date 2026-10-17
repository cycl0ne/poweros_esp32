// SPDX-License-Identifier: MPL-2.0
//! Host tests of the flash file system's record locks: its tree on memory
//! that behaves like flash (`memmedia.zig`), exec and dos brought up for
//! the table the handler keeps. A file of its own because `disk.zig` is
//! built into the host's mkfs too, which has no exec. Waiting is the
//! table's own (`sdk/libs/dos/record.zig`), tested through RAM:.

const std = @import("std");
const sdk = @import("sdk");
const dos = sdk.dos;
const record = dos.record;
const DosPacket = dos.DosPacket;
const FileHandle = dos.FileHandle;
const disk = @import("../disk.zig");
const MemMedia = @import("../memmedia.zig").MemMedia;
const kexec = @import("../../../libs/exec/exec.zig");
const kdos = @import("../../../libs/dos/dos.zig");

const testing = std.testing;
const TestFs = disk.FileSystem(MemMedia);
const Answer = disk.Answer;

const test_sectors = 24;
const test_sector = 512;
const test_page = 64;

fn sendArgs(fs: *TestFs, action: dos.ActionCode, args: dos.PacketArgs) Answer {
    var pkt = DosPacket.init(action, args);
    return fs.answer(&pkt);
}

/// What LOCK_RECORD answered, without waiting: 0 for the range held, else
/// the error.
fn lockRange(fs: *TestFs, fh: *FileHandle, offset: u64, length: u64, mode: u32) i32 {
    const answer = sendArgs(fs, .lock_record, .{ .lock_record = .{ .fh = fh, .offset = offset, .length = length, .mode = mode, .timeout = 0 } });
    return if (answer.res1 == dos.DOSFALSE) answer.res2 else 0;
}

/// What FREE_RECORD answered: 0 for the range given back, else the error.
fn unlockRange(fs: *TestFs, fh: *FileHandle, offset: u64, length: u64) i32 {
    const answer = sendArgs(fs, .free_record, .{ .free_record = .{ .fh = fh, .offset = offset, .length = length } });
    return if (answer.res1 == dos.DOSFALSE) answer.res2 else 0;
}

test "record locks: kept apart, shared, given back exactly and at the close" {
    const db = try kdos.testSetUp();
    defer kexec.deinit();
    var records: record.Records = undefined;
    try testing.expect(records.init(db.sys_base, kdos.testBase(db)));
    var store: [test_sectors * test_sector]u8 = undefined;
    var media = MemMedia.init(&store, test_sector, test_page);
    var fs = TestFs.init(&media, null);
    try fs.format("System");
    var one: FileHandle = .{};
    var two: FileHandle = .{};
    try testing.expectEqual(dos.DOSTRUE, sendArgs(&fs, .findupdate, .{ .find = .{ .fh = &one, .lock = null, .name = "base" } }).res1);
    try testing.expectEqual(dos.DOSTRUE, sendArgs(&fs, .findupdate, .{ .find = .{ .fh = &two, .lock = null, .name = "base" } }).res1);

    // Without a table from the handler there is no memory for one.
    try testing.expectEqual(dos.ERROR_NO_FREE_STORE, lockRange(&fs, &one, 0, 10, record.REC_EXCLUSIVE));
    fs.records = &records;

    try testing.expectEqual(@as(i32, 0), lockRange(&fs, &one, 0, 100, record.REC_EXCLUSIVE));
    try testing.expectEqual(@as(i32, 0), lockRange(&fs, &one, 10, 10, record.REC_SHARED)); // its own
    try testing.expectEqual(dos.ERROR_LOCK_COLLISION, lockRange(&fs, &two, 99, 1, record.REC_SHARED_IMMED));
    try testing.expectEqual(@as(i32, 0), lockRange(&fs, &two, 0x1_0000_0000, 1, record.REC_EXCLUSIVE_IMMED));
    try testing.expectEqual(dos.ERROR_RECORD_NOT_LOCKED, unlockRange(&fs, &one, 0, 99));
    try testing.expectEqual(@as(i32, 0), unlockRange(&fs, &one, 0, 100));
    try testing.expectEqual(dos.ERROR_LOCK_COLLISION, lockRange(&fs, &two, 15, 1, record.REC_EXCLUSIVE_IMMED)); // one's shared [10, 20)

    // Closing a handle gives back all it holds.
    try testing.expectEqual(dos.DOSTRUE, sendArgs(&fs, .end, .{ .file = .{ .fh = &one } }).res1);
    try testing.expectEqual(@as(i32, 0), lockRange(&fs, &two, 15, 1, record.REC_EXCLUSIVE_IMMED));
    try testing.expectEqual(dos.DOSTRUE, sendArgs(&fs, .end, .{ .file = .{ .fh = &two } }).res1);
    try testing.expectEqual(@as(usize, 0), records.heldCount());

    records.deinit();
    fs.deinit();
    try kdos.testTearDown(db);
}
