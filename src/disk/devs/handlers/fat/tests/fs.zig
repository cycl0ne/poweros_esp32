// SPDX-License-Identifier: MIT
//! Host tests of `fat32/fs.zig`: they bring up exec and utility.library from
//! the ROM, which a file the handler is built from may not name, so they
//! are here, where only the test build looks.

const std = @import("std");
const sdk = @import("sdk");
const subject = @import("../fat32/fs.zig");
const Answer = @import("../_fat.zig").Answer;
const dir_area = @import("../fat32/dir.zig");
const DosPacket = sdk.dos.DosPacket;
const FileHandle = sdk.dos.FileHandle;
const FileInfoBlock = sdk.dos.FileInfoBlock;
const FileLock = sdk.dos.FileLock;
const FileSystem = subject.FileSystem;
const UtilityBase = sdk.interface.utility.UtilityBase;
const dos = sdk.dos;
const exec = sdk.exec;
const fat = dos.fat;

const testing = std.testing;

/// What a SEEK or SET_FILE_SIZE came back with: dp_Res1 and dp_Res2, and
/// the handler's answer in the packet.
const Moved = struct { reply: Answer, answer: i64 };

/// A SEEK or SET_FILE_SIZE answered DOSTRUE with `answer`.
fn answered(answer: i64) Moved {
    return .{ .reply = .{ .res1 = dos.DOSTRUE, .res2 = 0 }, .answer = answer };
}
const notify_course = @import("_notify.zig");
const records_course = @import("_records.zig");
const cut_course = @import("_cut.zig");

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

    pub fn init(rig: *Rig, options: testvolume.Options) !void {
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

    pub fn deinit(rig: *Rig) void {
        rig.fs.deinit();
        rig.volume.deinit();
        kexec.deinit();
    }

    pub fn send(rig: *Rig, action: dos.ActionCode, args: [4]isize) Answer {
        var pkt = DosPacket.init(action, .{ .raw = args ++ [3]isize{ 0, 0, 0 } });
        return rig.fs.answer(&pkt);
    }

    pub fn sendArgs(rig: *Rig, action: dos.ActionCode, args: dos.PacketArgs) Answer {
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

    pub fn mkdir(rig: *Rig, name: [*:0]const u8) !void {
        const made = rig.send(.create_dir, .{ 0, @bitCast(@intFromPtr(name)), dos.EXCLUSIVE_LOCK, 0 });
        try testing.expect(made.res1 != 0);
        _ = rig.send(.free_lock, .{ made.res1, 0, 0, 0 });
    }

    pub fn open(rig: *Rig, fh: *FileHandle, action: dos.ActionCode, name: [*:0]const u8) Answer {
        fh.* = .{};
        return rig.sendArgs(action, .{ .find = .{ .fh = fh, .lock = null, .name = name } });
    }

    fn write(rig: *Rig, fh: *FileHandle, bytes: []const u8) isize {
        return rig.sendArgs(.write, .{ .io = .{ .fh = fh, .buffer = @constCast(bytes.ptr), .length = @intCast(bytes.len) } }).res1;
    }

    pub fn read(rig: *Rig, fh: *FileHandle, into: []u8) isize {
        return rig.sendArgs(.read, .{ .io = .{ .fh = fh, .buffer = into.ptr, .length = @intCast(into.len) } }).res1;
    }

    /// SEEK or SET_FILE_SIZE through the packet's SeekArgs.
    fn sendSeek(rig: *Rig, action: dos.ActionCode, fh: *FileHandle, position: i64, mode: i32) Moved {
        var pkt = DosPacket.init(action, .{ .seek = .{ .fh = fh, .position = position, .mode = mode } });
        const reply = rig.fs.answer(&pkt);
        return .{ .reply = reply, .answer = pkt.args.seek.answer };
    }

    pub fn seek(rig: *Rig, fh: *FileHandle, position: i64, mode: i32) Moved {
        return rig.sendSeek(.seek, fh, position, mode);
    }

    pub fn setSize(rig: *Rig, fh: *FileHandle, size: i64) Moved {
        return rig.sendSeek(.set_file_size, fh, size, dos.OFFSET_BEGINNING);
    }

    pub fn close(rig: *Rig, fh: *FileHandle) !void {
        try testing.expectEqual(dos.DOSTRUE, rig.sendArgs(.end, .{ .file = .{ .fh = fh } }).res1);
    }

    pub fn writeFile(rig: *Rig, name: [*:0]const u8, bytes: []const u8) !void {
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

    /// The size `name`'s entry has on the medium itself, as another mount
    /// of it reads it: what a card pulled now would show.
    fn sizeOnMedium(rig: *Rig, name: [*:0]const u8) !u64 {
        var other = TestFs.init(&rig.volume.media, rig.ub, null);
        defer other.deinit();
        try other.mount();
        var locate = DosPacket.init(.locate_object, .{ .raw = .{ 0, @bitCast(@intFromPtr(name)), dos.SHARED_LOCK, 0, 0, 0, 0 } });
        const held = other.answer(&locate).res1;
        try testing.expect(held != 0);
        defer {
            var free = DosPacket.init(.free_lock, .{ .raw = .{ held, 0, 0, 0, 0, 0, 0 } });
            _ = other.answer(&free);
        }
        var fib: FileInfoBlock = undefined;
        var asked = DosPacket.init(.examine_object, .{ .raw = .{ held, @bitCast(@intFromPtr(&fib)), 0, 0, 0, 0, 0 } });
        try testing.expectEqual(dos.DOSTRUE, other.answer(&asked).res1);
        return fib.size;
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

    pub fn rename(rig: *Rig, from: [*:0]const u8, to: [*:0]const u8) Answer {
        return rig.sendArgs(.rename_object, .{ .rename = .{ .from_lock = null, .from_name = from, .to_lock = null, .to_name = to } });
    }

    pub fn delete(rig: *Rig, name: [*:0]const u8) Answer {
        return rig.send(.delete_object, .{ 0, @bitCast(@intFromPtr(name)), 0, 0 });
    }

    /// The volume's flags entry as each copy of the table on the medium
    /// has it.
    fn flagsOnMedium(rig: *Rig) ![2]u32 {
        var flags: [2]u32 = undefined;
        var block: [512]u8 = undefined;
        for (&flags, 0..) |*flag, copy| {
            const spot = rig.fs.geo.entrySpot(@intCast(copy), fat.flags_entry);
            try testing.expect(rig.volume.media.read(spot.block, 1, &block));
            flag.* = fat.u32At(&block, spot.at);
        }
        return flags;
    }

    // --- what the power-cut tests ask of it (`_cut.zig`) ---------------

    /// The dot entries and fourteen more fill a cluster of one sector.
    pub const full_dir_files = 14;

    pub fn testMedia(rig: *Rig) *TestMedia {
        return &rig.volume.media;
    }

    /// Every free cluster's sectors filled with bytes that read as
    /// entries naming no cluster there is. The table is read from the
    /// medium, so the cache holds what it held.
    pub fn fillFree(rig: *Rig) !void {
        const junk: [512]u8 = @splat('A');
        const geo = &rig.fs.geo;
        var table: [512]u8 = undefined;
        var table_block: ?u64 = null;
        var cluster: u32 = fat.first_cluster;
        while (cluster < fat.first_cluster + geo.cluster_count) : (cluster += 1) {
            const spot = geo.entrySpot(geo.readCopy(), cluster);
            if (table_block == null or table_block.? != spot.block) {
                try testing.expect(rig.volume.media.read(spot.block, 1, &table));
                table_block = spot.block;
            }
            if (fat.clusterOf(fat.u32At(&table, spot.at)) != fat.free_cluster) continue;
            for (0..geo.sectors_per_cluster) |sector| try rig.volume.media.place(geo.clusterBlock(cluster) + sector, &junk);
        }
    }

    /// The next cluster taken from the table's third sector, which
    /// nothing has needed yet.
    pub fn startAllocationFar(rig: *Rig) void {
        rig.fs.table.next_free = 300;
    }

    pub fn cleanOnMedium(rig: *Rig) !bool {
        for (try rig.flagsOnMedium()) |flags| if (flags & fat.clean_flag == 0) return false;
        return true;
    }

    /// The card gone with whatever the file system still held, and the
    /// volume mounted again from what reached it.
    pub fn restartAfterCut(rig: *Rig) !void {
        rig.volume.media.budget = 0;
        rig.fs.deinit();
        rig.volume.media.budget = null;
        rig.fs = TestFs.init(&rig.volume.media, rig.ub, null);
        try rig.fs.mount();
    }

    /// The whole tree, as a checker would judge it, short of clusters
    /// taken that nothing names: every entry's chain runs through
    /// clusters the table holds taken, each named by that entry alone,
    /// and is long enough for its size. With `named_twice` a chain may be
    /// named by two entries, as a rename cut short leaves it.
    pub fn checkTree(rig: *Rig, named_twice: bool) !void {
        var taken = std.AutoHashMap(u32, void).init(testing.allocator);
        defer taken.deinit();
        try rig.checkChain(&taken, rig.fs.geo.root_cluster, null);
        try rig.checkDir(&taken, rig.fs.geo.root_cluster, named_twice);
    }

    fn checkDir(rig: *Rig, taken: *std.AutoHashMap(u32, void), first: u32, named_twice: bool) !void {
        var cursor = dir_area.Cursor.at(first);
        var index: u32 = 0;
        var found: dir_area.Found = .{};
        while (try rig.fs.dirs.next(&cursor, &index, &found)) {
            if (found.cluster == 0) {
                try testing.expectEqual(@as(u32, 0), found.size);
                continue;
            }
            if (named_twice and taken.contains(found.cluster)) continue;
            try rig.checkChain(taken, found.cluster, if (found.isDir()) null else found.size);
            if (found.isDir()) try rig.checkDir(taken, found.cluster, named_twice);
        }
    }

    fn checkChain(rig: *Rig, taken: *std.AutoHashMap(u32, void), first: u32, bytes: ?u32) !void {
        var cluster = first;
        var count: u32 = 0;
        while (true) {
            try testing.expect(rig.fs.geo.usable(cluster));
            const following = try rig.fs.table.entry(cluster);
            try testing.expect(following != fat.free_cluster);
            try testing.expect(!(try taken.getOrPut(cluster)).found_existing);
            count += 1;
            if (fat.endsChain(following)) break;
            cluster = following;
        }
        const cluster_bytes = rig.fs.geo.cluster_bytes;
        if (bytes) |size| try testing.expect(count >= (size + cluster_bytes - 1) / cluster_bytes);
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

test "a volume renamed: the label entry made, upper case, kept when mounted again" {
    var rig: Rig = undefined;
    try rig.init(.{});
    defer rig.deinit();
    try testing.expectEqual(dos.DOSTRUE, rig.send(.rename_disk, .{ @bitCast(@intFromPtr("Photos")), 0, 0, 0 }).res1);
    try testing.expectEqualStrings("PHOTOS", rig.fs.volumeName());
    try rig.remount();
    try testing.expectEqualStrings("PHOTOS", rig.fs.volumeName());
    // Written over the second time, and what a label cannot be refused.
    try testing.expectEqual(dos.DOSTRUE, rig.send(.rename_disk, .{ @bitCast(@intFromPtr("Holiday 26")), 0, 0, 0 }).res1);
    try rig.remount();
    try testing.expectEqualStrings("HOLIDAY 26", rig.fs.volumeName());
    try testing.expectEqual(dos.ERROR_INVALID_COMPONENT_NAME, rig.send(.rename_disk, .{ @bitCast(@intFromPtr("Twelve chars")), 0, 0, 0 }).res2);
    try testing.expectEqual(dos.ERROR_INVALID_COMPONENT_NAME, rig.send(.rename_disk, .{ @bitCast(@intFromPtr("a.b")), 0, 0, 0 }).res2);
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
    try testing.expectEqual(answered(0), rig.seek(&fh, 3, dos.OFFSET_BEGINNING));
    try testing.expectEqual(@as(isize, 4), rig.write(&fh, "bbbb"));
    try testing.expectEqual(answered(7), rig.seek(&fh, 0, dos.OFFSET_END));
    try testing.expectEqual(@as(isize, 3), rig.write(&fh, "ccc"));
    // Past the end is not somewhere a seek goes.
    const refused: Moved = .{ .reply = .{ .res1 = dos.DOSFALSE, .res2 = dos.ERROR_SEEK_ERROR }, .answer = 0 };
    try testing.expectEqual(refused, rig.seek(&fh, 1, dos.OFFSET_END));
    try testing.expectEqual(refused, rig.seek(&fh, std.math.maxInt(i64), dos.OFFSET_CURRENT));
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
    try testing.expectEqual(answered(40_000), rig.setSize(&fh, 40_000));
    try testing.expectEqual(before - 2, try rig.freeClusters());
    try testing.expectEqual(answered(41_000), rig.setSize(&fh, 41_000));
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

test "notification: names watched before they are there, told of each change, through a card taken out and back" {
    var rig: Rig = undefined;
    try rig.init(.{});
    defer rig.deinit();
    try notify_course.course(&rig, &rig.volume.media.changes);
}

test "record locks: kept apart, shared, given back exactly and at the close" {
    var rig: Rig = undefined;
    try rig.init(.{});
    defer rig.deinit();
    try records_course.course(&rig);
}

test "the volume is marked dirty while a file is being written, clean after, in both tables" {
    var rig: Rig = undefined;
    try rig.init(.{});
    defer rig.deinit();
    for (try rig.flagsOnMedium()) |flags| try testing.expect(flags & fat.clean_flag != 0);
    var fh: FileHandle = undefined;
    try testing.expectEqual(dos.DOSTRUE, rig.open(&fh, .findoutput, "open.txt").res1);
    _ = rig.write(&fh, "some");
    for (try rig.flagsOnMedium()) |flags| try testing.expectEqual(@as(u32, 0), flags & fat.clean_flag);
    try rig.close(&fh);
    for (try rig.flagsOnMedium()) |flags| try testing.expect(flags & fat.clean_flag != 0);
    // A change that is whole in one packet leaves it clean at once, and
    // the rest of the entry as it was.
    try rig.mkdir("D");
    for (try rig.flagsOnMedium()) |flags| try testing.expectEqual(@as(u32, 0x0FFF_FFFF), flags);
}

test "a volume found dirty is left dirty, for a checker to look at" {
    var rig: Rig = undefined;
    try rig.init(.{});
    defer rig.deinit();
    var block: [512]u8 = undefined;
    for (0..2) |copy| {
        const spot = rig.fs.geo.entrySpot(@intCast(copy), fat.flags_entry);
        try testing.expect(rig.volume.media.read(spot.block, 1, &block));
        fat.putU32(&block, spot.at, 0x0FFF_FFFF & ~fat.clean_flag);
        try rig.volume.media.place(spot.block, &block);
    }
    try rig.remount();
    try rig.writeFile("f", "x");
    for (try rig.flagsOnMedium()) |flags| try testing.expectEqual(@as(u32, 0), flags & fat.clean_flag);
}

test "a file closed has the device put what it holds on the medium; one only read does not" {
    var rig: Rig = undefined;
    try rig.init(.{});
    defer rig.deinit();
    const media = &rig.volume.media;
    var fh: FileHandle = undefined;
    try testing.expectEqual(dos.DOSTRUE, rig.open(&fh, .findoutput, "f").res1);
    _ = rig.write(&fh, "contents");
    const before_close = media.updates;
    try rig.close(&fh);
    try testing.expectEqual(before_close + 1, media.updates);

    // The clean mark the close wrote goes with the next packet that asks;
    // after that, a file only read asks nothing.
    var buffer: [16]u8 = undefined;
    try testing.expectEqualStrings("contents", buffer[0..try rig.readFile("f", &buffer)]);
    const before_read = media.updates;
    try testing.expectEqualStrings("contents", buffer[0..try rig.readFile("f", &buffer)]);
    try testing.expectEqual(before_read, media.updates);
}

/// A small volume of one-sector clusters, so every block of a step is a
/// place a cut can fall.
const cut_volume: testvolume.Options = .{ .clusters = 512, .sectors_per_cluster = 1 };

test "a power cut at any block of a file written leaves the volume whole" {
    try cut_course.everywhere(Rig, cut_volume, .write);
}

test "a power cut at any block of a delete leaves the volume whole" {
    try cut_course.everywhere(Rig, cut_volume, .delete);
}

test "a power cut at any block of a file opened over and rewritten leaves the volume whole" {
    try cut_course.everywhere(Rig, cut_volume, .empty);
}

test "a power cut at any block of a file cut short leaves the volume whole" {
    try cut_course.everywhere(Rig, cut_volume, .shorten);
}

test "a power cut at any block of a file made longer leaves the volume whole" {
    try cut_course.everywhere(Rig, cut_volume, .extend);
}

test "a power cut at any block of a rename leaves the file under one name or both" {
    try cut_course.everywhere(Rig, cut_volume, .rename);
}

test "a power cut at any block of a directory growing leaves no stray entries in it" {
    try cut_course.everywhere(Rig, cut_volume, .grow);
}

test "a power cut at any block of a directory made leaves the volume whole" {
    try cut_course.everywhere(Rig, cut_volume, .mkdir);
}

test "a write that only moves the size writes its sector alone, read no more; the entry follows at a new cluster, a FLUSH or the close" {
    var rig: Rig = undefined;
    try rig.init(.{});
    defer rig.deinit();
    const media = &rig.volume.media;
    var piece: [100]u8 = undefined;
    pattern(&piece, 7);
    var fh: FileHandle = undefined;
    try testing.expectEqual(dos.DOSTRUE, rig.open(&fh, .findoutput, "f").res1);
    // The first write takes the file's first cluster: the entry goes down
    // with it.
    try testing.expectEqual(@as(isize, 100), rig.write(&fh, &piece));
    try testing.expectEqual(@as(u64, 100), try rig.sizeOnMedium("f"));

    // The next moves the size only: its sector, held from the first, is
    // written and not read again, and the entry waits.
    const written = media.blocks_written;
    const read = media.blocks_read;
    try testing.expectEqual(@as(isize, 100), rig.write(&fh, &piece));
    try testing.expectEqual(written + 1, media.blocks_written);
    try testing.expectEqual(read, media.blocks_read);
    try testing.expectEqual(@as(u64, 100), try rig.sizeOnMedium("f"));
    // Examined, it has its size all the same.
    var fib: FileInfoBlock = undefined;
    var asked = DosPacket.init(.examine_fh, .{ .raw = .{ @bitCast(@intFromPtr(&fh)), @bitCast(@intFromPtr(&fib)), 0, 0, 0, 0, 0 } });
    try testing.expectEqual(dos.DOSTRUE, rig.fs.answer(&asked).res1);
    try testing.expectEqual(@as(u64, 200), fib.size);

    // A FLUSH catches the entry up.
    try testing.expectEqual(dos.DOSTRUE, rig.send(.flush, .{ 0, 0, 0, 0 }).res1);
    try testing.expectEqual(@as(u64, 200), try rig.sizeOnMedium("f"));
    // So does a write that takes a cluster.
    var cluster: [64 * 512]u8 = undefined;
    pattern(&cluster, 3);
    try testing.expectEqual(@as(isize, cluster.len), rig.write(&fh, &cluster));
    try testing.expectEqual(@as(u64, 200 + cluster.len), try rig.sizeOnMedium("f"));
    // And the close.
    try testing.expectEqual(@as(isize, 100), rig.write(&fh, &piece));
    try rig.close(&fh);
    try testing.expectEqual(@as(u64, 300 + cluster.len), try rig.sizeOnMedium("f"));
    var back: [300 + 64 * 512]u8 = undefined;
    try testing.expectEqual(back.len, try rig.readFile("f", &back));
    try testing.expectEqualSlices(u8, &piece, back[0..100]);
    try testing.expectEqualSlices(u8, &piece, back[100..200]);
    try testing.expectEqualSlices(u8, &cluster, back[200..][0..cluster.len]);
    try testing.expectEqualSlices(u8, &piece, back[200 + cluster.len ..]);
}
