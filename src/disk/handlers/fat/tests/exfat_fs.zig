// SPDX-License-Identifier: MIT
//! Host tests of `exfat/fs.zig`, through the packets dos sends: on a fresh
//! volume laid down by `exfat/testvolume.zig` - by default the 64 GB card
//! the 7B was tested with - and on the volume the Linux kernel wrote
//! (`exfat/testfixture.zig`). They bring up exec and utility.library from
//! the ROM, which a file the handler is built from may not name, so they
//! are here, where only the test build looks.
//!
//! One test writes the volume it made to the file `EXFAT_IMAGE` names, if
//! it names one, for `fsck.exfat -n` to judge.

const std = @import("std");
const sdk = @import("sdk");
const subject = @import("../exfat/fs.zig");
const Answer = @import("../_fat.zig").Answer;
const _fat = @import("../_fat.zig");
const DosPacket = sdk.dos.DosPacket;
const FileHandle = sdk.dos.FileHandle;
const FileInfoBlock = sdk.dos.FileInfoBlock;
const FileLock = sdk.dos.FileLock;
const UtilityBase = sdk.interface.utility.UtilityBase;
const dos = sdk.dos;
const fat = dos.fat;

const testing = std.testing;
const TestMedia = @import("../testmedia.zig").TestMedia;
const testvolume = @import("../exfat/testvolume.zig");
const fixture = @import("../exfat/testfixture.zig");
const names = @import("../exfat/names.zig");
const utility_library = @import("host_rom").utility;
const kexec = @import("host_rom").exec;
const TestFs = subject.FileSystem(TestMedia);

fn lockValue(held: ?*FileLock) isize {
    return @bitCast(@intFromPtr(held));
}

/// A medium and the file system mounted on it. Made in place: the file
/// system holds pointers into itself once it is mounted.
const Rig = struct {
    volume: ?*testvolume.Volume = null,
    /// The kernel's volume, when the rig is on that one.
    own_media: TestMedia = undefined,
    media: *TestMedia,
    ub: *UtilityBase,
    fs: TestFs,

    fn init(rig: *Rig, options: testvolume.Options) !void {
        const utility = try utility_library.setUp();
        rig.ub = utility.iface();
        const volume = try testvolume.Volume.init(options);
        rig.volume = volume;
        rig.media = &volume.media;
        rig.fs = TestFs.init(rig.media, rig.ub, null);
        try rig.fs.mount();
    }

    /// On the volume the kernel wrote, which has no partition table.
    fn initKernel(rig: *Rig) !void {
        const utility = try utility_library.setUp();
        rig.ub = utility.iface();
        rig.volume = null;
        rig.own_media = TestMedia.init(512, fixture.blocks());
        try fixture.load(&rig.own_media, 0);
        rig.media = &rig.own_media;
        rig.fs = TestFs.init(rig.media, rig.ub, null);
        try rig.fs.mount();
    }

    fn remount(rig: *Rig) !void {
        rig.fs.deinit();
        rig.fs = TestFs.init(rig.media, rig.ub, null);
        try rig.fs.mount();
    }

    /// Everything given back: the file system freed all it took.
    fn deinit(rig: *Rig) void {
        rig.fs.deinit();
        const left = rig.media.live;
        if (rig.volume) |volume| volume.deinit() else rig.own_media.deinit();
        kexec.deinit();
        testing.expectEqual(@as(usize, 0), left) catch @panic("the file system did not give back all it took");
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

    fn seek(rig: *Rig, fh: *FileHandle, position: isize, mode: i32) Answer {
        return rig.sendArgs(.seek, .{ .seek = .{ .fh = fh, .position = position, .mode = mode } });
    }

    fn setSize(rig: *Rig, fh: *FileHandle, size: isize) Answer {
        return rig.sendArgs(.set_file_size, .{ .seek = .{ .fh = fh, .position = size, .mode = dos.OFFSET_BEGINNING } });
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

    fn rename(rig: *Rig, from: [*:0]const u8, to: [*:0]const u8) Answer {
        return rig.sendArgs(.rename_object, .{ .rename = .{ .from_lock = null, .from_name = from, .to_lock = null, .to_name = to } });
    }

    fn delete(rig: *Rig, name: [*:0]const u8) Answer {
        return rig.send(.delete_object, .{ 0, @bitCast(@intFromPtr(name)), 0, 0 });
    }

    /// Every name in a directory, as dos is given them, in order.
    fn list(rig: *Rig, held: ?*FileLock, into: [][]const u8, store: []u8) !usize {
        var fib: FileInfoBlock = undefined;
        try testing.expectEqual(dos.DOSTRUE, rig.examine(held, &fib).res1);
        var count: usize = 0;
        var used: usize = 0;
        while (rig.examineNext(held, &fib).res1 == dos.DOSTRUE) {
            const name = fibName(&fib);
            @memcpy(store[used..][0..name.len], name);
            into[count] = store[used..][0..name.len];
            used += name.len;
            count += 1;
        }
        return count;
    }

    /// The boot sector's VolumeFlags as they are on the medium now.
    fn flagsOnMedium(rig: *Rig) !u16 {
        var boot: [512]u8 = undefined;
        try testing.expect(rig.media.read(rig.fs.geo.first, 1, &boot));
        return fat.u16At(&boot, fat.exfat_volume_flags);
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

// --- a fresh volume ----------------------------------------------------------

test "the volume is found behind its partition table and named" {
    var rig: Rig = undefined;
    try rig.init(.{});
    defer rig.deinit();
    try testing.expectEqual(@as(u64, 32768), rig.fs.geo.first);
    try testing.expectEqualStrings("1234-ABCD", rig.fs.volumeName());
    var fib: FileInfoBlock = undefined;
    try testing.expectEqual(dos.DOSTRUE, rig.examine(null, &fib).res1);
    try testing.expectEqual(dos.ST_ROOT, fib.dir_entry_type);
    try testing.expectEqual(dos.DOSFALSE, rig.examineNext(null, &fib).res1);
    try testing.expectEqual(dos.ERROR_NO_MORE_ENTRIES, rig.examineNext(null, &fib).res2);
    // The whole card less its three first clusters.
    try testing.expectEqual(@as(u64, 488_016 - 3), try rig.freeClusters());
}

test "a label names the volume" {
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
    try rig.writeFile("Pictures/A long file name, longer than fifteen.txt", "one two three");
    try rig.writeFile("readme.txt", "hello");
    try rig.remount();

    var into: [64]u8 = undefined;
    const got = try rig.readFile("pictures/A LONG FILE NAME, LONGER THAN FIFTEEN.TXT", &into);
    try testing.expectEqualStrings("one two three", into[0..got]);
    const got2 = try rig.readFile("README.TXT", &into);
    try testing.expectEqualStrings("hello", into[0..got2]);

    var listed: [8][]const u8 = undefined;
    var store: [256]u8 = undefined;
    try testing.expectEqual(@as(usize, 2), try rig.list(null, &listed, &store));
    try testing.expectEqualStrings("Pictures", listed[0]);
    try testing.expectEqualStrings("readme.txt", listed[1]);
}

test "a large file in odd pieces, across clusters, read back in others" {
    var rig: Rig = undefined;
    try rig.init(.{});
    defer rig.deinit();
    const size = 3 * 131072 + 4321;
    const data = try testing.allocator.alloc(u8, size);
    defer testing.allocator.free(data);
    pattern(data, 11);
    var fh: FileHandle = undefined;
    try testing.expectEqual(dos.DOSTRUE, rig.open(&fh, .findoutput, "big.bin").res1);
    var at: usize = 0;
    var piece: usize = 1;
    while (at < size) : (piece = piece * 3 + 17) {
        const n = @min(piece % 70000 + 1, size - at);
        try testing.expectEqual(@as(isize, @intCast(n)), rig.write(&fh, data[at..][0..n]));
        at += n;
    }
    try rig.close(&fh);
    try rig.remount();

    const back = try testing.allocator.alloc(u8, size);
    defer testing.allocator.free(back);
    try testing.expectEqual(dos.DOSTRUE, rig.open(&fh, .findinput, "big.bin").res1);
    at = 0;
    piece = 5;
    while (at < size) : (piece = piece * 5 + 3) {
        const n = @min(piece % 90000 + 1, size - at);
        try testing.expectEqual(@as(isize, @intCast(n)), rig.read(&fh, back[at..][0..n]));
        at += n;
    }
    try testing.expectEqual(@as(isize, 0), rig.read(&fh, back[0..10]));
    try rig.close(&fh);
    try testing.expectEqualSlices(u8, data, back);
}

test "writing over the middle of a file, and past its end" {
    var rig: Rig = undefined;
    try rig.init(.{});
    defer rig.deinit();
    try rig.writeFile("f.txt", "0123456789");
    var fh: FileHandle = undefined;
    try testing.expectEqual(dos.DOSTRUE, rig.open(&fh, .findupdate, "f.txt").res1);
    _ = rig.seek(&fh, 4, dos.OFFSET_BEGINNING);
    try testing.expectEqual(@as(isize, 3), rig.write(&fh, "abc"));
    _ = rig.seek(&fh, 0, dos.OFFSET_END);
    try testing.expectEqual(@as(isize, 2), rig.write(&fh, "XY"));
    try rig.close(&fh);
    var into: [32]u8 = undefined;
    const got = try rig.readFile("f.txt", &into);
    try testing.expectEqualStrings("0123abc789XY", into[0..got]);
}

test "a file cut short gives clusters back, and grown reads as zeroes" {
    var rig: Rig = undefined;
    try rig.init(.{});
    defer rig.deinit();
    const free = try rig.freeClusters();
    var data: [300_000]u8 = undefined;
    pattern(&data, 3);
    try rig.writeFile("cut.bin", &data);
    try testing.expectEqual(free - 3, try rig.freeClusters());

    var fh: FileHandle = undefined;
    try testing.expectEqual(dos.DOSTRUE, rig.open(&fh, .findupdate, "cut.bin").res1);
    try testing.expectEqual(@as(isize, 1000), rig.setSize(&fh, 1000).res1);
    try testing.expectEqual(free - 1, try rig.freeClusters());
    // Grown: the size moves, the clusters are taken, and what was not
    // written reads as zeroes - also where the old bytes still lie.
    try testing.expectEqual(@as(isize, 200_000), rig.setSize(&fh, 200_000).res1);
    try testing.expectEqual(free - 2, try rig.freeClusters());
    try rig.close(&fh);

    const back = try testing.allocator.alloc(u8, 200_000);
    defer testing.allocator.free(back);
    try testing.expectEqual(@as(usize, 200_000), try rig.readFile("cut.bin", back));
    try testing.expectEqualSlices(u8, data[0..1000], back[0..1000]);
    for (back[1000..]) |byte| try testing.expectEqual(@as(u8, 0), byte);

    // Writing past what was written fills the gap with zeroes first.
    try testing.expectEqual(dos.DOSTRUE, rig.open(&fh, .findupdate, "cut.bin").res1);
    _ = rig.seek(&fh, 150_000, dos.OFFSET_BEGINNING);
    try testing.expectEqual(@as(isize, 4), rig.write(&fh, "tail"));
    try rig.close(&fh);
    try rig.remount();
    try testing.expectEqual(@as(usize, 200_000), try rig.readFile("cut.bin", back));
    try testing.expectEqualStrings("tail", back[150_000..150_004]);
    for (back[1000..150_000]) |byte| try testing.expectEqual(@as(u8, 0), byte);
}

test "a run becomes a chain when the cluster after it is taken" {
    var rig: Rig = undefined;
    try rig.init(.{ .clusters = 2048, .cluster_shift = 3 });
    defer rig.deinit();
    var one: [4096]u8 = undefined;
    pattern(&one, 1);
    try rig.writeFile("a.bin", &one);
    try rig.writeFile("b.bin", "spacer");
    var fh: FileHandle = undefined;
    try testing.expectEqual(dos.DOSTRUE, rig.open(&fh, .findupdate, "a.bin").res1);
    _ = rig.seek(&fh, 0, dos.OFFSET_END);
    var more: [9000]u8 = undefined;
    pattern(&more, 2);
    try testing.expectEqual(@as(isize, 9000), rig.write(&fh, &more));
    try rig.close(&fh);
    try rig.remount();

    var back: [13096]u8 = undefined;
    try testing.expectEqual(@as(usize, 13096), try rig.readFile("a.bin", &back));
    try testing.expectEqualSlices(u8, &one, back[0..4096]);
    try testing.expectEqualSlices(u8, &more, back[4096..]);
    var small: [16]u8 = undefined;
    try testing.expectEqualStrings("spacer", small[0..try rig.readFile("b.bin", &small)]);
}

test "a directory grows past its first cluster" {
    var rig: Rig = undefined;
    try rig.init(.{ .clusters = 2048, .cluster_shift = 3 });
    defer rig.deinit();
    try rig.mkdir("Many");
    var name_buf: [64]u8 = undefined;
    for (0..80) |at| {
        const name = try std.fmt.bufPrintZ(&name_buf, "Many/a file with a name of some length {d}.txt", .{at});
        try rig.writeFile(name, name);
    }
    // And the root, which is linked through the table.
    for (0..50) |at| {
        const name = try std.fmt.bufPrintZ(&name_buf, "root file number {d}", .{at});
        try rig.writeFile(name, "r");
    }
    try rig.remount();
    const many = rig.lock("Many", dos.SHARED_LOCK);
    defer rig.unlock(many);
    var listed: [100][]const u8 = undefined;
    var store: [8192]u8 = undefined;
    try testing.expectEqual(@as(usize, 80), try rig.list(many, &listed, &store));
    try testing.expectEqual(@as(usize, 51), try rig.list(null, &listed, &store));
    var into: [64]u8 = undefined;
    const got = try rig.readFile("Many/A FILE WITH A NAME OF SOME LENGTH 79.TXT", &into);
    try testing.expectEqualStrings("Many/a file with a name of some length 79.txt", into[0..got]);
}

test "deleting: a file, an empty directory, and what may not be deleted" {
    var rig: Rig = undefined;
    try rig.init(.{});
    defer rig.deinit();
    const free = try rig.freeClusters();
    try rig.mkdir("Dir");
    try rig.writeFile("Dir/inside", "x");
    try rig.writeFile("file", "y" ** 200_000);
    try testing.expectEqual(dos.ERROR_DIRECTORY_NOT_EMPTY, rig.delete("Dir").res2);
    try testing.expectEqual(dos.DOSTRUE, rig.delete("Dir/inside").res1);
    try testing.expectEqual(dos.DOSTRUE, rig.delete("Dir").res1);
    const held = rig.lock("file", dos.SHARED_LOCK);
    try testing.expectEqual(dos.ERROR_OBJECT_IN_USE, rig.delete("file").res2);
    rig.unlock(held);
    try testing.expectEqual(dos.DOSTRUE, rig.send(.set_protect, .{ 0, @bitCast(@intFromPtr("file")), dos.FIBF_DELETE, 0 }).res1);
    try testing.expectEqual(dos.ERROR_DELETE_PROTECTED, rig.delete("file").res2);
    try testing.expectEqual(dos.DOSTRUE, rig.send(.set_protect, .{ 0, @bitCast(@intFromPtr("file")), 0, 0 }).res1);
    try testing.expectEqual(dos.DOSTRUE, rig.delete("file").res1);
    try testing.expectEqual(free, try rig.freeClusters());
    try testing.expectEqual(dos.ERROR_OBJECT_NOT_FOUND, rig.delete("file").res2);
}

test "renaming in place, to a long name, and into another directory" {
    var rig: Rig = undefined;
    try rig.init(.{});
    defer rig.deinit();
    try rig.mkdir("From");
    try rig.mkdir("To");
    try rig.writeFile("From/note", "moved");
    const held = rig.lock("From/note", dos.SHARED_LOCK);
    try testing.expectEqual(dos.DOSTRUE, rig.rename("From/note", "From/NOTE").res1);
    try testing.expectEqual(dos.DOSTRUE, rig.rename("From/NOTE", "From/A much longer name than the one before.txt").res1);
    try testing.expectEqual(dos.DOSTRUE, rig.rename("From/A much longer name than the one before.txt", "To/Here now").res1);
    // The lock followed the file.
    var fib: FileInfoBlock = undefined;
    try testing.expectEqual(dos.DOSTRUE, rig.examine(held, &fib).res1);
    try testing.expectEqualStrings("Here now", fibName(&fib));
    const up = rig.send(.parent, .{ lockValue(held), 0, 0, 0 });
    try testing.expect(up.res1 != 0);
    const up_lock: ?*FileLock = @ptrFromInt(@as(usize, @bitCast(up.res1)));
    try testing.expectEqual(dos.DOSTRUE, rig.examine(up_lock, &fib).res1);
    try testing.expectEqualStrings("To", fibName(&fib));
    rig.unlock(up_lock);
    rig.unlock(held);

    var into: [16]u8 = undefined;
    try testing.expectEqualStrings("moved", into[0..try rig.readFile("To/here NOW", &into)]);
    try testing.expectEqual(@as(?*FileLock, null), rig.lock("From/note", dos.SHARED_LOCK));
    // A directory is not moved into itself.
    try rig.mkdir("From/Inner");
    try testing.expectEqual(dos.ERROR_OBJECT_IN_USE, rig.rename("From", "From/Inner/From").res2);
    try testing.expectEqual(dos.ERROR_OBJECT_EXISTS, rig.rename("From", "To").res2);
    try rig.remount();
    try testing.expectEqualStrings("moved", into[0..try rig.readFile("To/Here now", &into)]);
}

test "paths go up with a leading slash, and PARENT climbs keys" {
    var rig: Rig = undefined;
    try rig.init(.{});
    defer rig.deinit();
    try rig.mkdir("A");
    try rig.mkdir("A/B");
    try rig.writeFile("A/top.txt", "top");
    const b = rig.lock("A/B", dos.SHARED_LOCK);
    defer rig.unlock(b);
    var fh: FileHandle = .{};
    try testing.expectEqual(dos.DOSTRUE, rig.sendArgs(.findinput, .{ .find = .{ .fh = &fh, .lock = b, .name = "/top.txt" } }).res1);
    var into: [8]u8 = undefined;
    try testing.expectEqual(@as(isize, 3), rig.read(&fh, &into));
    try rig.close(&fh);
    // Up past the root is nowhere.
    try testing.expectEqual(dos.DOSFALSE, rig.sendArgs(.findinput, .{ .find = .{ .fh = &fh, .lock = b, .name = "///x" } }).res1);
    const root_parent = rig.send(.parent, .{ 0, 0, 0, 0 });
    try testing.expectEqual(@as(isize, 0), root_parent.res1);
}

test "locks: shared ones go together, an exclusive one wants it alone" {
    var rig: Rig = undefined;
    try rig.init(.{});
    defer rig.deinit();
    try rig.writeFile("f", "x");
    const one = rig.lock("f", dos.SHARED_LOCK);
    const two = rig.lock("f", dos.SHARED_LOCK);
    try testing.expect(one != null and two != null);
    try testing.expectEqual(@as(?*FileLock, null), rig.lock("f", dos.EXCLUSIVE_LOCK));
    rig.unlock(one);
    rig.unlock(two);
    const alone = rig.lock("f", dos.EXCLUSIVE_LOCK);
    try testing.expect(alone != null);
    try testing.expectEqual(@as(?*FileLock, null), rig.lock("f", dos.SHARED_LOCK));
    rig.unlock(alone);
    // Nothing is left over once every lock is gone.
    try testing.expectEqual(@as(?*anyopaque, null), @as(?*anyopaque, @ptrCast(rig.fs.keys)));
}

test "a listing goes on correctly across a delete" {
    var rig: Rig = undefined;
    try rig.init(.{});
    defer rig.deinit();
    for ([_][*:0]const u8{ "a", "b", "c", "d" }) |name| try rig.writeFile(name, "1");
    var fib: FileInfoBlock = undefined;
    try testing.expectEqual(dos.DOSTRUE, rig.examine(null, &fib).res1);
    try testing.expectEqual(dos.DOSTRUE, rig.examineNext(null, &fib).res1);
    try testing.expectEqualStrings("a", fibName(&fib));
    try testing.expectEqual(dos.DOSTRUE, rig.delete("b").res1);
    try testing.expectEqual(dos.DOSTRUE, rig.examineNext(null, &fib).res1);
    try testing.expectEqualStrings("c", fibName(&fib));
    try testing.expectEqual(dos.DOSTRUE, rig.examineNext(null, &fib).res1);
    try testing.expectEqualStrings("d", fibName(&fib));
    try testing.expectEqual(dos.DOSFALSE, rig.examineNext(null, &fib).res1);
}

test "a card that will not be written is read and not written" {
    var rig: Rig = undefined;
    try rig.init(.{});
    defer rig.deinit();
    try rig.writeFile("kept", "still here");
    rig.media.read_only = true;
    var fh: FileHandle = undefined;
    try testing.expectEqual(dos.ERROR_DISK_WRITE_PROTECTED, rig.open(&fh, .findoutput, "new").res2);
    try testing.expectEqual(dos.ERROR_DISK_WRITE_PROTECTED, rig.delete("kept").res2);
    var into: [16]u8 = undefined;
    try testing.expectEqualStrings("still here", into[0..try rig.readFile("kept", &into)]);
}

test "a card changed under a lock leaves the lock no good, and mounts the new one" {
    var rig: Rig = undefined;
    try rig.init(.{});
    defer rig.deinit();
    try rig.writeFile("old", "1");
    const held = rig.lock("old", dos.SHARED_LOCK);
    rig.media.changes += 1;
    try testing.expect(rig.fs.checkMedium());
    var fib: FileInfoBlock = undefined;
    try testing.expectEqual(dos.ERROR_INVALID_LOCK, rig.examine(held, &fib).res2);
    rig.unlock(held);
    try testing.expectEqual(@as(?*anyopaque, null), @as(?*anyopaque, @ptrCast(rig.fs.keys)));
}

test "a file open when the card changes is still closed, and nothing is left behind" {
    var rig: Rig = undefined;
    try rig.init(.{});
    defer rig.deinit();
    var fh: FileHandle = undefined;
    try testing.expectEqual(dos.DOSTRUE, rig.open(&fh, .findoutput, "open.txt").res1);
    _ = rig.write(&fh, "some");
    rig.media.changes += 1;
    try testing.expect(rig.fs.checkMedium());
    try testing.expectEqual(dos.DOSTRUE, rig.sendArgs(.end, .{ .file = .{ .fh = &fh } }).res1);
    try testing.expectEqual(@as(?*anyopaque, null), @as(?*anyopaque, @ptrCast(rig.fs.locks)));
    try testing.expectEqual(@as(?*anyopaque, null), @as(?*anyopaque, @ptrCast(rig.fs.keys)));
}

test "the volume is marked dirty while a file is being written, clean after" {
    var rig: Rig = undefined;
    try rig.init(.{});
    defer rig.deinit();
    try testing.expectEqual(@as(u16, 0), try rig.flagsOnMedium() & fat.exfat_volume_dirty);
    var fh: FileHandle = undefined;
    try testing.expectEqual(dos.DOSTRUE, rig.open(&fh, .findoutput, "open.txt").res1);
    _ = rig.write(&fh, "some");
    try testing.expect(try rig.flagsOnMedium() & fat.exfat_volume_dirty != 0);
    try rig.close(&fh);
    try testing.expectEqual(@as(u16, 0), try rig.flagsOnMedium() & fat.exfat_volume_dirty);
    // A change that is whole in one packet leaves it clean at once.
    try rig.mkdir("D");
    try testing.expectEqual(@as(u16, 0), try rig.flagsOnMedium() & fat.exfat_volume_dirty);
}

test "a file past 4 GiB: its true size, and read at the far end" {
    var rig: Rig = undefined;
    try rig.init(.{});
    defer rig.deinit();
    try rig.writeFile("film.mp4", "start");
    // Grown to 5 GiB through its entry, with the last bytes on the medium,
    // as a camera would have written it - writing 5 GiB through the test
    // medium would hold all of it in memory.
    const five: u64 = 5 << 30;
    var object_fh: FileHandle = undefined;
    try testing.expectEqual(dos.DOSTRUE, rig.open(&object_fh, .findupdate, "film.mp4").res1);
    try rig.close(&object_fh);
    {
        var set: @import("../exfat/dir.zig").Set = .{};
        const root = rig.fs.root_key.?.dir();
        var found: @import("../exfat/dir.zig").Found = .{};
        var wanted: names.Wanted = undefined;
        wanted.init("film.mp4", &rig.fs.upcase);
        try testing.expect(try rig.fs.dirs.find(root, &wanted, &found));
        try testing.expect(try rig.fs.dirs.readSet(root, found.index, &set));
        // One run from where the file starts, long enough for 5 GiB.
        const clusters = rig.fs.geo.clustersFor(five);
        var at: u64 = 1;
        while (at < clusters) : (at += 1) try rig.fs.bitmap.mark(@intCast(found.first + at), true);
        set.setStream(.{ .first = found.first, .contiguous = true }, five, five);
        try rig.fs.dirs.writeSet(root, found.index, &set);
        _ = try rig.fs.cache.flush();
        const last_block = rig.fs.geo.clusterBlock(found.first) + (five / 512) - 1;
        var block: [512]u8 = @splat(0);
        @memcpy(block[512 - 4 ..], "END!");
        try testing.expect(rig.media.write(last_block, 1, &block));
    }
    try rig.remount();
    var fib: FileInfoBlock = undefined;
    const held = rig.lock("film.mp4", dos.SHARED_LOCK);
    try testing.expectEqual(dos.DOSTRUE, rig.examine(held, &fib).res1);
    try testing.expectEqual(five, fib.size);
    rig.unlock(held);
    var fh: FileHandle = undefined;
    try testing.expectEqual(dos.DOSTRUE, rig.open(&fh, .findinput, "film.mp4").res1);
    // To 100 bytes before the end: the old position (0) fits an isize.
    try testing.expectEqual(@as(isize, 0), rig.seek(&fh, -100, dos.OFFSET_END).res1);
    var tail: [100]u8 = undefined;
    try testing.expectEqual(@as(isize, 100), rig.read(&fh, &tail));
    try testing.expectEqualStrings("END!", tail[96..]);
    // From there, the old position is five GiB. Where an isize is 32 bits,
    // as on the machine, SEEK cannot answer it and says so; where it is 64,
    // as on the host running these tests, it answers it.
    const back = rig.seek(&fh, 0, dos.OFFSET_BEGINNING);
    if (@bitSizeOf(isize) == 32) {
        try testing.expectEqual(dos.ERROR_SEEK_ERROR, back.res2);
    } else {
        try testing.expectEqual(@as(isize, @intCast(five)), back.res1);
    }
    try rig.close(&fh);
}

// --- the kernel's volume -------------------------------------------------------

test "the kernel's volume: its files listed and read" {
    var rig: Rig = undefined;
    try rig.initKernel();
    defer rig.deinit();
    try testing.expectEqualStrings("POWEROS", rig.fs.volumeName());

    var into: [32]u8 = undefined;
    try testing.expectEqualStrings("Hello, PowerOS!\n", into[0..try rig.readFile("hello.txt", &into)]);
    try testing.expectEqualStrings("deep note\n", into[0..try rig.readFile("Sub Dir/Deeper/Note.txt", &into)]);

    const big = try testing.allocator.alloc(u8, 20000);
    defer testing.allocator.free(big);
    try testing.expectEqual(@as(usize, 20000), try rig.readFile("big.bin", big));
    for (big, 0..) |byte, at| try testing.expectEqual(@as(u8, @truncate(at * 7 + 3)), byte);

    // Broken up: its chain is in the table.
    var frag: [8292]u8 = undefined;
    try testing.expectEqual(@as(usize, 8292), try rig.readFile("frag.bin", &frag));
    for (frag[0..4096]) |byte| try testing.expectEqual(@as(u8, 0xA1), byte);
    for (frag[4096..8192]) |byte| try testing.expectEqual(@as(u8, 0xA2), byte);
    for (frag[8192..]) |byte| try testing.expectEqual(@as(u8, 0xA3), byte);

    const many = rig.lock("Many", dos.SHARED_LOCK);
    defer rig.unlock(many);
    var listed: [100][]const u8 = undefined;
    var store: [4096]u8 = undefined;
    try testing.expectEqual(@as(usize, 60), try rig.list(many, &listed, &store));
}

test "the kernel's names dos cannot hold open through their stand-ins" {
    var rig: Rig = undefined;
    try rig.initKernel();
    defer rig.deinit();
    var listed: [20][]const u8 = undefined;
    var store: [2048]u8 = undefined;
    const count = try rig.list(null, &listed, &store);
    try testing.expectEqual(@as(usize, 12), count);
    var stand_ins: u32 = 0;
    for (listed[0..count]) |name| {
        // Every name listed opens the file it came from.
        var z: [_fat.fib_name_max + 1]u8 = undefined;
        @memcpy(z[0..name.len], name);
        z[name.len] = 0;
        const held = rig.lock(@ptrCast(&z), dos.SHARED_LOCK);
        try testing.expect(held != null);
        rig.unlock(held);
        if (names.tagOf(name) != null) stand_ins += 1;
    }
    // 日本.txt, € Rechnung.pdf, and the 158-character name.
    try testing.expectEqual(@as(u32, 3), stand_ins);
}

test "the kernel's volume takes a new file, and its old ones are untouched" {
    var rig: Rig = undefined;
    try rig.initKernel();
    defer rig.deinit();
    try rig.writeFile("Sub Dir/from PowerOS.txt", "written here");
    try rig.remount();
    var into: [32]u8 = undefined;
    try testing.expectEqualStrings("written here", into[0..try rig.readFile("sub dir/FROM POWEROS.TXT", &into)]);
    try testing.expectEqualStrings("inner\n", into[0..try rig.readFile("Sub Dir/inner.txt", &into)]);
}

// --- for fsck.exfat -------------------------------------------------------------

test "a volume this made, written out for fsck.exfat if asked" {
    const path = std.testing.environ.getPosix("EXFAT_IMAGE") orelse return;
    var rig: Rig = undefined;
    try rig.init(.{ .clusters = 2048, .cluster_shift = 3, .first = 64, .label = "FSCK" });
    defer rig.deinit();
    // A bit of everything: directories, a long name, a grown directory, a
    // run turned chain, a file cut, a file deleted, a rename across.
    try rig.mkdir("Dir");
    try rig.mkdir("Dir/Inner");
    var name_buf: [64]u8 = undefined;
    for (0..40) |at| {
        const name = try std.fmt.bufPrintZ(&name_buf, "Dir/a file with a name of some length {d}.txt", .{at});
        try rig.writeFile(name, name);
    }
    var one: [4096]u8 = undefined;
    pattern(&one, 9);
    try rig.writeFile("run.bin", &one);
    try rig.writeFile("spacer", "s");
    var fh: FileHandle = undefined;
    try testing.expectEqual(dos.DOSTRUE, rig.open(&fh, .findupdate, "run.bin").res1);
    _ = rig.seek(&fh, 0, dos.OFFSET_END);
    try testing.expectEqual(@as(isize, 4096), rig.write(&fh, &one));
    try rig.close(&fh);
    var big: [50_000]u8 = undefined;
    pattern(&big, 4);
    try rig.writeFile("cut.bin", &big);
    try testing.expectEqual(dos.DOSTRUE, rig.open(&fh, .findupdate, "cut.bin").res1);
    try testing.expectEqual(@as(isize, 9000), rig.setSize(&fh, 9000).res1);
    try rig.close(&fh);
    try rig.writeFile("gone", "x");
    try testing.expectEqual(dos.DOSTRUE, rig.delete("gone").res1);
    try testing.expectEqual(dos.DOSTRUE, rig.rename("spacer", "Dir/Inner/A spacer, moved and renamed").res1);
    rig.fs.unmount();

    // The volume's blocks, from its first on.
    const volume = rig.volume.?;
    const blocks: usize = @intCast(volume.media.blocks() - volume.first);
    const image = try testing.allocator.alloc(u8, blocks * 512);
    defer testing.allocator.free(image);
    for (0..blocks) |at| {
        try testing.expect(volume.media.read(volume.first + at, 1, image[at * 512 ..][0..512]));
    }
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = image });
}
