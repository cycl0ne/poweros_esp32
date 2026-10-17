// SPDX-License-Identifier: MIT
//! What the record-lock tests of both file systems share: two handles on
//! one file, ranges locked through each - kept apart where one of them is
//! exclusive, shared where both are shared, a handle never in its own
//! way - given back by their exact offset and length, and all of a
//! handle's given back when it is closed. `rig` is either test file's: it
//! has `fs`, `sendArgs`, `open` and `close`. Waiting is the table's own
//! (`sdk/libs/dos/record.zig`), tested through RAM:.

const std = @import("std");
const sdk = @import("sdk");
const dos = sdk.dos;
const record = dos.record;
const FileHandle = dos.FileHandle;
const DosBase = sdk.interface.dos.DosBase;
const host_rom = @import("host_rom");
const kexec = host_rom.exec;

const testing = std.testing;

/// What LOCK_RECORD answered, without waiting: 0 for the range held, else
/// the error.
fn lockRange(rig: anytype, fh: *FileHandle, offset: u64, length: u64, mode: u32) i32 {
    const answer = rig.sendArgs(.lock_record, .{ .lock_record = .{ .fh = fh, .offset = offset, .length = length, .mode = mode, .timeout = 0 } });
    return if (answer.res1 == dos.DOSFALSE) answer.res2 else 0;
}

/// What FREE_RECORD answered: 0 for the range given back, else the error.
fn unlockRange(rig: anytype, fh: *FileHandle, offset: u64, length: u64) i32 {
    const answer = rig.sendArgs(.free_record, .{ .free_record = .{ .fh = fh, .offset = offset, .length = length } });
    return if (answer.res1 == dos.DOSFALSE) answer.res2 else 0;
}

/// The course, on a fresh volume.
pub fn course(rig: anytype) !void {
    const sys = kexec.SysBase.iface();
    // dos.library, which answers the packets that wait.
    const made = kexec.InitResident(kexec.SysBase, &host_rom.dos.dos_library_tag, null) orelse return error.NoDos;
    const dl: *DosBase = @ptrCast(@alignCast(made));
    var records: record.Records = undefined;
    try testing.expect(records.init(sys, dl));
    defer records.deinit();
    const far: u64 = 0x1_0000_0000;

    var one: FileHandle = undefined;
    var two: FileHandle = undefined;
    try testing.expectEqual(dos.DOSTRUE, rig.open(&one, .findupdate, "records").res1);
    try testing.expectEqual(dos.DOSTRUE, rig.open(&two, .findupdate, "records").res1);

    // Without a table from the handler there is no memory for one.
    try testing.expectEqual(dos.ERROR_NO_FREE_STORE, lockRange(rig, &one, 0, 10, record.REC_EXCLUSIVE));
    try testing.expectEqual(dos.ERROR_RECORD_NOT_LOCKED, unlockRange(rig, &one, 0, 10));
    rig.fs.records = &records;

    try testing.expectEqual(@as(i32, 0), lockRange(rig, &one, 0, 100, record.REC_EXCLUSIVE));
    try testing.expectEqual(@as(i32, 0), lockRange(rig, &one, 10, 10, record.REC_SHARED)); // its own
    try testing.expectEqual(dos.ERROR_LOCK_COLLISION, lockRange(rig, &two, 99, 1, record.REC_SHARED_IMMED));
    try testing.expectEqual(dos.ERROR_LOCK_TIMEOUT, lockRange(rig, &two, 0, 1, record.REC_EXCLUSIVE));
    try testing.expectEqual(@as(i32, 0), lockRange(rig, &two, far, 1, record.REC_EXCLUSIVE_IMMED)); // past the end, past 4 GiB

    // Given back by the same offset and length.
    try testing.expectEqual(dos.ERROR_RECORD_NOT_LOCKED, unlockRange(rig, &one, 0, 99));
    try testing.expectEqual(dos.ERROR_RECORD_NOT_LOCKED, unlockRange(rig, &two, 0, 100));
    try testing.expectEqual(@as(i32, 0), unlockRange(rig, &one, 10, 10));
    try testing.expectEqual(@as(i32, 0), unlockRange(rig, &one, 0, 100));
    try testing.expectEqual(@as(i32, 0), lockRange(rig, &two, 50, 1, record.REC_SHARED_IMMED));
    try testing.expectEqual(@as(i32, 0), lockRange(rig, &one, 50, 1, record.REC_SHARED_IMMED)); // shared beside shared
    try testing.expectEqual(dos.ERROR_LOCK_COLLISION, lockRange(rig, &one, 50, 1, record.REC_EXCLUSIVE_IMMED));

    // Closing a handle gives back all it holds.
    try rig.close(&two);
    try testing.expectEqual(@as(i32, 0), lockRange(rig, &one, 50, 1, record.REC_EXCLUSIVE_IMMED));
    try testing.expectEqual(@as(i32, 0), lockRange(rig, &one, far, 1, record.REC_EXCLUSIVE_IMMED));
    try testing.expectEqual(dos.ERROR_INVALID_LOCK, lockRange(rig, &two, 0, 1, record.REC_EXCLUSIVE_IMMED));
    try rig.close(&one);
    try testing.expectEqual(@as(usize, 0), records.heldCount());
    rig.fs.records = null;
}
