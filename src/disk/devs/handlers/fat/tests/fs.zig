// SPDX-License-Identifier: MIT
//! Host tests of `fat32/fs.zig`: they bring up exec and utility.library from
//! the ROM, which a file the handler is built from may not name, so they
//! are here, where only the test build looks.

const std = @import("std");
const sdk = @import("sdk");
const subject = @import("../fat32/fs.zig");
const Answer = @import("../_fat.zig").Answer;
const DosPacket = sdk.dos.DosPacket;
const FileHandle = sdk.dos.FileHandle;
const FileInfoBlock = sdk.dos.FileInfoBlock;
const FileLock = sdk.dos.FileLock;
const FileSystem = subject.FileSystem;
const UtilityBase = sdk.interface.utility.UtilityBase;
const dos = sdk.dos;
const exec = sdk.exec;

const testing = std.testing;

/// A lock as a packet argument.
fn lockValue(held: ?*FileLock) isize {
    return @bitCast(@intFromPtr(held));
}
const TestMedia = @import("../testmedia.zig").TestMedia;
const testvolume = @import("../fat32/testvolume.zig");
const utility_library = @import("host_rom").utility;
const kexec = @import("host_rom").exec;
const TestFs = FileSystem(TestMedia);

/// A volume and the file system mounted on it. Made in place: the file
/// system holds pointers into itself once it is mounted.
const Rig = struct {
    volume: *testvolume.Volume,
    ub: *UtilityBase,
    fs: TestFs,

    fn init(rig: *Rig, options: testvolume.Options) !void {
        const utility = try utility_library.setUp();
        rig.ub = utility.iface();
        rig.volume = try testvolume.Volume.init(options);
        rig.fs = TestFs.init(&rig.volume.media, rig.ub, null);
        try rig.fs.mount();
    }

    /// The file system taken down and mounted again, as after a restart.
    fn remount(rig: *Rig) !void {
        rig.fs.deinit();
        rig.fs = TestFs.init(&rig.volume.media, rig.ub, null);
        try rig.fs.mount();
    }

    fn deinit(rig: *Rig) void {
        rig.fs.deinit();
        rig.volume.deinit();
        kexec.deinit();
    }

    fn send(rig: *Rig, action: dos.ActionCode, args: [4]isize) Answer {
        var pkt = DosPacket.init(action, .{ .raw = args ++ [3]isize{ 0, 0, 0 } });
        return rig.fs.answer(&pkt);
    }

    fn sendArgs(rig: *Rig, action: dos.ActionCode, args: dos.PacketArgs) Answer {
        var pkt = DosPacket.init(action, args);
        return rig.fs.answer(&pkt);
    }

    fn lock(rig: *Rig, name: [*:0]const u8, access: i32) ?*FileLock {
        const got = rig.send(.locate_object, .{ 0, @bitCast(@intFromPtr(name)), access, 0 });
        return @ptrFromInt(@as(usize, @bitCast(got.res1)));
    }

    fn unlock(rig: *Rig, held: ?*FileLock) void {
        _ = rig.send(.free_lock, .{ lockValue(held), 0, 0, 0 });
    }

    fn mkdir(rig: *Rig, name: [*:0]const u8) !void {
        const made = rig.send(.create_dir, .{ 0, @bitCast(@intFromPtr(name)), dos.EXCLUSIVE_LOCK, 0 });
        try testing.expect(made.res1 != 0);
        _ = rig.send(.free_lock, .{ made.res1, 0, 0, 0 });
    }

    fn open(rig: *Rig, fh: *FileHandle, action: dos.ActionCode, name: [*:0]const u8) Answer {
        fh.* = .{};
        return rig.sendArgs(action, .{ .find = .{ .fh = fh, .lock = null, .name = name } });
    }

    fn write(rig: *Rig, fh: *FileHandle, bytes: []const u8) isize {
        return rig.sendArgs(.write, .{ .io = .{ .fh = fh, .buffer = @constCast(bytes.ptr), .length = @intCast(bytes.len) } }).res1;
    }

    fn read(rig: *Rig, fh: *FileHandle, into: []u8) isize {
        return rig.sendArgs(.read, .{ .io = .{ .fh = fh, .buffer = into.ptr, .length = @intCast(into.len) } }).res1;
    }

    fn close(rig: *Rig, fh: *FileHandle) !void {
        try testing.expectEqual(dos.DOSTRUE, rig.sendArgs(.end, .{ .file = .{ .fh = fh } }).res1);
    }

    fn writeFile(rig: *Rig, name: [*:0]const u8, bytes: []const u8) !void {
        var fh: FileHandle = undefined;
        try testing.expectEqual(dos.DOSTRUE, rig.open(&fh, .findoutput, name).res1);
        try testing.expectEqual(@as(isize, @intCast(bytes.len)), rig.write(&fh, bytes));
        try rig.close(&fh);
    }

    fn readFile(rig: *Rig, name: [*:0]const u8, into: []u8) !usize {
        var fh: FileHandle = undefined;
        try testing.expectEqual(dos.DOSTRUE, rig.open(&fh, .findinput, name).res1);
        const count = rig.read(&fh, into);
        try rig.close(&fh);
        if (count < 0) return error.ReadFailed;
        return @intCast(count);
    }

    fn examine(rig: *Rig, held: ?*FileLock, fib: *FileInfoBlock) Answer {
        return rig.sendArgs(.examine_object, .{ .examine = .{ .lock = held, .fib = fib } });
    }

    fn examineNext(rig: *Rig, held: ?*FileLock, fib: *FileInfoBlock) Answer {
        return rig.sendArgs(.examine_next, .{ .examine = .{ .lock = held, .fib = fib } });
    }

    fn freeClusters(rig: *Rig) !u64 {
        var data: dos.InfoData = .{};
        try testing.expectEqual(dos.DOSTRUE, rig.send(.disk_info, .{ @bitCast(@intFromPtr(&data)), 0, 0, 0 }).res1);
        return data.num_blocks - data.num_blocks_used;
    }
};

fn fibName(fib: *const FileInfoBlock) []const u8 {
    var len: usize = 0;
    while (fib.file_name[len] != 0) len += 1;
    return fib.file_name[0..len];
}

/// Bytes that say where they are, so a piece read from the wrong place
/// shows.
fn pattern(into: []u8, seed: u8) void {
    for (into, 0..) |*byte, at| byte.* = @truncate(at * 7 + seed + at / 509);
}

test "the volume is found behind its partition table and named" {
    var rig: Rig = undefined;
    try rig.init(.{});
    defer rig.deinit();
    try testing.expectEqual(@as(u64, 8192), rig.fs.geo.first);
    // No label anywhere: it goes by its serial number.
    try testing.expectEqualStrings("1234-ABCD", rig.fs.volumeName());

    var fib: FileInfoBlock = undefined;
    try testing.expectEqual(dos.DOSTRUE, rig.examine(null, &fib).res1);
    try testing.expectEqual(dos.ST_ROOT, fib.dir_entry_type);
    try testing.expectEqualStrings("1234-ABCD", fibName(&fib));
    try testing.expectEqual(dos.DOSFALSE, rig.examineNext(null, &fib).res1);
    try testing.expectEqual(dos.ERROR_NO_MORE_ENTRIES, rig.examineNext(null, &fib).res2);
}

test "a label in the root directory names the volume" {
    var rig: Rig = undefined;
    try rig.init(.{ .label = "HOLIDAY" });
    defer rig.deinit();
    try testing.expectEqualStrings("HOLIDAY", rig.fs.volumeName());
}

test "files and directories come back after mounting again" {
    var rig: Rig = undefined;
    try rig.init(.{});
    defer rig.deinit();
    try rig.mkdir("Pictures");
    try rig.writeFile("Pictures/A long file name.txt", "one two three");
    try rig.writeFile("readme.txt", "hello");
    try rig.remount();

    var buffer: [32]u8 = undefined;
    const count = try rig.readFile("pictures/a long FILE name.txt", &buffer);
    try testing.expectEqualStrings("one two three", buffer[0..count]);
    try testing.expectEqualStrings("hello", buffer[0..try rig.readFile("README.TXT", &buffer)]);

    // The directory lists what is in it, under the names it was given.
    const held = rig.lock("Pictures", dos.SHARED_LOCK);
    defer rig.unlock(held);
    var fib: FileInfoBlock = undefined;
    try testing.expectEqual(dos.DOSTRUE, rig.examine(held, &fib).res1);
    try testing.expectEqualStrings("Pictures", fibName(&fib));
    try testing.expectEqual(dos.ST_USERDIR, fib.dir_entry_type);
    try testing.expectEqual(dos.DOSTRUE, rig.examineNext(held, &fib).res1);
    try testing.expectEqualStrings("A long file name.txt", fibName(&fib));
    try testing.expectEqual(@as(u64, 13), fib.size);
    try testing.expectEqual(dos.ST_FILE, fib.dir_entry_type);
    try testing.expectEqual(dos.DOSFALSE, rig.examineNext(held, &fib).res1);
}

test "a large file in odd pieces, across clusters, read back in others" {
    var rig: Rig = undefined;
    try rig.init(.{});
    defer rig.deinit();
    const size = 150_001; // four clusters and a bit, ending mid-sector
    const out = try testing.allocator.alloc(u8, size);
    defer testing.allocator.free(out);
    pattern(out, 3);

    var fh: FileHandle = undefined;
    try testing.expectEqual(dos.DOSTRUE, rig.open(&fh, .findoutput, "big").res1);
    var done: usize = 0;
    var piece: usize = 1;
    while (done < size) : (piece = piece * 3 + 1) {
        const count = @min(piece % 40_000 + 1, size - done);
        try testing.expectEqual(@as(isize, @intCast(count)), rig.write(&fh, out[done..][0..count]));
        done += count;
    }
    try rig.close(&fh);
    try rig.remount();

    const back = try testing.allocator.alloc(u8, size + 100);
    defer testing.allocator.free(back);
    try testing.expectEqual(dos.DOSTRUE, rig.open(&fh, .findinput, "big").res1);
    done = 0;
    piece = 5;
    while (true) : (piece = piece * 5 + 2) {
        const got = rig.read(&fh, back[done..][0..@min(piece % 50_000 + 1, back.len - done)]);
        try testing.expect(got >= 0);
        if (got == 0) break;
        done += @intCast(got);
    }
    try rig.close(&fh);
    try testing.expectEqual(@as(usize, size), done);
    try testing.expectEqualSlices(u8, out, back[0..size]);
}

test "a file read whole goes to the medium in few commands" {
    var rig: Rig = undefined;
    try rig.init(.{});
    defer rig.deinit();
    const size = 4 * 32 * 1024; // four clusters, one after another
    const out = try testing.allocator.alloc(u8, size);
    defer testing.allocator.free(out);
    pattern(out, 9);
    try rig.writeFile("contiguous", out);

    const back = try testing.allocator.alloc(u8, size);
    defer testing.allocator.free(back);
    var fh: FileHandle = undefined;
    try testing.expectEqual(dos.DOSTRUE, rig.open(&fh, .findinput, "contiguous").res1);
    const reads_before = rig.volume.media.reads;
    try testing.expectEqual(@as(isize, size), rig.read(&fh, back));
    // One run for the data, and a few blocks of table to see that the
    // clusters follow each other.
    try testing.expect(rig.volume.media.reads - reads_before <= 3);
    try rig.close(&fh);
    try testing.expectEqualSlices(u8, out, back);
}

test "writing over the middle of a file, and past its end" {
    var rig: Rig = undefined;
    try rig.init(.{});
    defer rig.deinit();
    try rig.writeFile("f", "aaaaaaaaaa");

    var fh: FileHandle = undefined;
    try testing.expectEqual(dos.DOSTRUE, rig.open(&fh, .findupdate, "f").res1);
    try testing.expectEqual(@as(isize, 0), rig.sendArgs(.seek, .{ .seek = .{ .fh = &fh, .position = 3, .mode = dos.OFFSET_BEGINNING } }).res1);
    try testing.expectEqual(@as(isize, 4), rig.write(&fh, "bbbb"));
    try testing.expectEqual(@as(isize, 7), rig.sendArgs(.seek, .{ .seek = .{ .fh = &fh, .position = 0, .mode = dos.OFFSET_END } }).res1);
    try testing.expectEqual(@as(isize, 3), rig.write(&fh, "ccc"));
    // Past the end is not somewhere a seek goes.
    try testing.expectEqual(@as(isize, -1), rig.sendArgs(.seek, .{ .seek = .{ .fh = &fh, .position = 1, .mode = dos.OFFSET_END } }).res1);
    try rig.close(&fh);

    var buffer: [32]u8 = undefined;
    try testing.expectEqualStrings("aaabbbbaaaccc", buffer[0..try rig.readFile("f", &buffer)]);
}

test "a file cut short gives clusters back, and grows with zeroes" {
    var rig: Rig = undefined;
    try rig.init(.{});
    defer rig.deinit();
    const before = try rig.freeClusters();
    const out = try testing.allocator.alloc(u8, 100_000);
    defer testing.allocator.free(out);
    pattern(out, 1);
    try rig.writeFile("f", out);
    try testing.expectEqual(before - 4, try rig.freeClusters());

    var fh: FileHandle = undefined;
    try testing.expectEqual(dos.DOSTRUE, rig.open(&fh, .findupdate, "f").res1);
    try testing.expectEqual(@as(isize, 40_000), rig.sendArgs(.set_file_size, .{ .seek = .{ .fh = &fh, .position = 40_000, .mode = dos.OFFSET_BEGINNING } }).res1);
    try testing.expectEqual(before - 2, try rig.freeClusters());
    try testing.expectEqual(@as(isize, 41_000), rig.sendArgs(.set_file_size, .{ .seek = .{ .fh = &fh, .position = 41_000, .mode = dos.OFFSET_BEGINNING } }).res1);
    try rig.close(&fh);

    const back = try testing.allocator.alloc(u8, 50_000);
    defer testing.allocator.free(back);
    try testing.expectEqual(@as(usize, 41_000), try rig.readFile("f", back));
    try testing.expectEqualSlices(u8, out[0..40_000], back[0..40_000]);
    for (back[40_000..41_000]) |byte| try testing.expectEqual(@as(u8, 0), byte);

    // Opened for output it is emptied, and every cluster comes back.
    try rig.writeFile("f", "");
    try testing.expectEqual(before, try rig.freeClusters());
}

test "deleting: a file, an empty directory, and what may not be deleted" {
    var rig: Rig = undefined;
    try rig.init(.{});
    defer rig.deinit();
    const before = try rig.freeClusters();
    try rig.mkdir("dir");
    try rig.writeFile("dir/file", "x" ** 1000);

    const name_dir: [*:0]const u8 = "dir";
    const name_file: [*:0]const u8 = "dir/file";
    // Not while there is something in it.
    const full = rig.send(.delete_object, .{ 0, @bitCast(@intFromPtr(name_dir)), 0, 0 });
    try testing.expectEqual(dos.ERROR_DIRECTORY_NOT_EMPTY, full.res2);
    // Not while it is locked.
    const held = rig.lock(name_file, dos.SHARED_LOCK);
    try testing.expectEqual(dos.ERROR_OBJECT_IN_USE, rig.send(.delete_object, .{ 0, @bitCast(@intFromPtr(name_file)), 0, 0 }).res2);
    rig.unlock(held);
    // Not while it is protected from it.
    try testing.expectEqual(dos.DOSTRUE, rig.sendArgs(.set_protect, .{ .property = .{ .lock = null, .name = name_file, .value = dos.FIBF_DELETE } }).res1);
    try testing.expectEqual(dos.ERROR_DELETE_PROTECTED, rig.send(.delete_object, .{ 0, @bitCast(@intFromPtr(name_file)), 0, 0 }).res2);
    try testing.expectEqual(dos.DOSTRUE, rig.sendArgs(.set_protect, .{ .property = .{ .lock = null, .name = name_file, .value = 0 } }).res1);

    try testing.expectEqual(dos.DOSTRUE, rig.send(.delete_object, .{ 0, @bitCast(@intFromPtr(name_file)), 0, 0 }).res1);
    try testing.expectEqual(dos.DOSTRUE, rig.send(.delete_object, .{ 0, @bitCast(@intFromPtr(name_dir)), 0, 0 }).res1);
    try testing.expectEqual(before, try rig.freeClusters());
    try testing.expectEqual(@as(?*FileLock, null), rig.lock("dir", dos.SHARED_LOCK));
}

test "renaming in place, to a long name, and into another directory" {
    var rig: Rig = undefined;
    try rig.init(.{});
    defer rig.deinit();
    try rig.writeFile("old.txt", "contents");
    try rig.mkdir("Archive");
    try rig.mkdir("Moving");
    try rig.writeFile("Moving/inside", "deep");

    const renames = [_][2][*:0]const u8{
        .{ "old.txt", "A much longer name.txt" },
        .{ "A much longer name.txt", "Archive/Filed away.txt" },
        .{ "Moving", "Archive/Moved" },
        .{ "Archive/Filed away.txt", "Archive/FILED AWAY.TXT" },
    };
    for (renames) |pair| {
        const renamed = rig.sendArgs(.rename_object, .{ .rename = .{ .from_lock = null, .from_name = pair[0], .to_lock = null, .to_name = pair[1] } });
        try testing.expectEqual(dos.DOSTRUE, renamed.res1);
    }
    try rig.remount();
    var buffer: [16]u8 = undefined;
    try testing.expectEqualStrings("contents", buffer[0..try rig.readFile("Archive/FILED AWAY.TXT", &buffer)]);
    try testing.expectEqualStrings("deep", buffer[0..try rig.readFile("Archive/Moved/inside", &buffer)]);
    try testing.expectEqual(@as(?*FileLock, null), rig.lock("old.txt", dos.SHARED_LOCK));
    try testing.expectEqual(@as(?*FileLock, null), rig.lock("Moving", dos.SHARED_LOCK));

    // The moved directory's way back up leads to its new parent.
    const moved = rig.lock("Archive/Moved", dos.SHARED_LOCK);
    defer rig.unlock(moved);
    const up = rig.send(.parent, .{ lockValue(moved), 0, 0, 0 });
    try testing.expect(up.res1 != 0);
    var fib: FileInfoBlock = undefined;
    try testing.expectEqual(dos.DOSTRUE, rig.examine(@ptrFromInt(@as(usize, @bitCast(up.res1))), &fib).res1);
    try testing.expectEqualStrings("Archive", fibName(&fib));
    rig.unlock(@ptrFromInt(@as(usize, @bitCast(up.res1))));

    // A directory does not go inside itself, and a name that is taken
    // stays taken.
    const into_itself = rig.sendArgs(.rename_object, .{ .rename = .{ .from_lock = null, .from_name = "Archive", .to_lock = null, .to_name = "Archive/Moved/Archive" } });
    try testing.expectEqual(dos.ERROR_OBJECT_IN_USE, into_itself.res2);
    try rig.writeFile("taken", "x");
    const clash = rig.sendArgs(.rename_object, .{ .rename = .{ .from_lock = null, .from_name = "taken", .to_lock = null, .to_name = "Archive" } });
    try testing.expectEqual(dos.ERROR_OBJECT_EXISTS, clash.res2);
}

test "locks: shared ones go together, an exclusive one wants it alone" {
    var rig: Rig = undefined;
    try rig.init(.{});
    defer rig.deinit();
    try rig.writeFile("f", "x");
    const one = rig.lock("f", dos.SHARED_LOCK);
    const two = rig.lock("F", dos.SHARED_LOCK);
    try testing.expect(one != null and two != null);
    try testing.expectEqual(dos.DOSTRUE, rig.send(.same_lock, .{ lockValue(one), lockValue(two), 0, 0 }).res1);
    try testing.expectEqual(@as(?*FileLock, null), rig.lock("f", dos.EXCLUSIVE_LOCK));
    rig.unlock(one);
    rig.unlock(two);
    const alone = rig.lock("f", dos.EXCLUSIVE_LOCK);
    try testing.expect(alone != null);
    try testing.expectEqual(@as(?*FileLock, null), rig.lock("f", dos.SHARED_LOCK));
    rig.unlock(alone);
}

test "a directory listing goes on correctly across a delete" {
    var rig: Rig = undefined;
    try rig.init(.{});
    defer rig.deinit();
    const files = [_][*:0]const u8{ "one", "Two with a long name", "three", "four" };
    for (files) |name| try rig.writeFile(name, "x");

    var fib: FileInfoBlock = undefined;
    try testing.expectEqual(dos.DOSTRUE, rig.examine(null, &fib).res1);
    try testing.expectEqual(dos.DOSTRUE, rig.examineNext(null, &fib).res1);
    try testing.expectEqualStrings("one", fibName(&fib));
    // Deleted behind the walk and in front of it.
    const name_one: [*:0]const u8 = "one";
    const name_three: [*:0]const u8 = "three";
    _ = rig.send(.delete_object, .{ 0, @bitCast(@intFromPtr(name_one)), 0, 0 });
    _ = rig.send(.delete_object, .{ 0, @bitCast(@intFromPtr(name_three)), 0, 0 });
    try testing.expectEqual(dos.DOSTRUE, rig.examineNext(null, &fib).res1);
    try testing.expectEqualStrings("Two with a long name", fibName(&fib));
    try testing.expectEqual(dos.DOSTRUE, rig.examineNext(null, &fib).res1);
    try testing.expectEqualStrings("four", fibName(&fib));
    try testing.expectEqual(dos.DOSFALSE, rig.examineNext(null, &fib).res1);
}

test "a card that will not be written is read and not written" {
    var rig: Rig = undefined;
    try rig.init(.{});
    defer rig.deinit();
    try rig.writeFile("kept", "still here");
    rig.volume.media.read_only = true;

    var fh: FileHandle = undefined;
    try testing.expectEqual(dos.ERROR_DISK_WRITE_PROTECTED, rig.open(&fh, .findoutput, "new").res2);
    try testing.expectEqual(dos.ERROR_DISK_WRITE_PROTECTED, rig.open(&fh, .findoutput, "kept").res2);
    var buffer: [16]u8 = undefined;
    try testing.expectEqualStrings("still here", buffer[0..try rig.readFile("kept", &buffer)]);
    var data: dos.InfoData = .{};
    _ = rig.send(.disk_info, .{ @bitCast(@intFromPtr(&data)), 0, 0, 0 });
    try testing.expectEqual(dos.ID_WRITE_PROTECTED, data.disk_state);
}

test "a card changed under a lock leaves the lock no good, and mounts the new one" {
    var rig: Rig = undefined;
    try rig.init(.{});
    defer rig.deinit();
    try rig.writeFile("f", "x");
    const held = rig.lock("f", dos.SHARED_LOCK);

    rig.volume.media.changes += 1;
    try testing.expect(rig.fs.checkMedium());
    try testing.expect(rig.fs.mounted);
    var fib: FileInfoBlock = undefined;
    try testing.expectEqual(dos.ERROR_INVALID_LOCK, rig.examine(held, &fib).res2);
    // It can still be given back.
    rig.unlock(held);
    try testing.expect(!rig.fs.checkMedium());
    // And the volume is there to be used.
    var buffer: [4]u8 = undefined;
    try testing.expectEqualStrings("x", buffer[0..try rig.readFile("f", &buffer)]);
}

test "clusters past the 4 GiB mark of a 64 GB card" {
    var rig: Rig = undefined;
    try rig.init(.{});
    defer rig.deinit();
    // The search starts three clusters from the end: the file runs off it
    // and wraps round to the front.
    rig.fs.table.next_free = rig.fs.geo.cluster_count - 1;
    const out = try testing.allocator.alloc(u8, 5 * 32 * 1024);
    defer testing.allocator.free(out);
    pattern(out, 77);
    try rig.writeFile("far", out);
    try rig.remount();
    const back = try testing.allocator.alloc(u8, out.len);
    defer testing.allocator.free(back);
    try testing.expectEqual(out.len, try rig.readFile("far", back));
    try testing.expectEqualSlices(u8, out, back);
}
