// SPDX-License-Identifier: MPL-2.0
//! posfs's Recycled through its packets: deletes moved there and given
//! back, what in it stays as it is, its limits and a full volume, the
//! switch, and the orphans a big delete leaves - each after a cut too, the
//! check clean after each.

const std = @import("std");
const testing = std.testing;
const sdk = @import("sdk");
const dos = sdk.dos;
const posfs = dos.posfs;
const layout = posfs.layout;
const packets = posfs.packets;
const fs_core = @import("../fs.zig");
const checkpoint = @import("../checkpoint.zig");
const objects = @import("../objects.zig");
const helpers = @import("fs.zig");
const FileSystem = fs_core.FileSystem;
const FileHandle = dos.FileHandle;
const Setup = helpers.Setup;
const send = helpers.send;
const sendArgs = helpers.sendArgs;
const sendOwn = helpers.sendOwn;
const arg = helpers.arg;
const writeFile = helpers.writeFile;
const readFile = helpers.readFile;
const openFile = helpers.openFile;
const writeTo = helpers.writeTo;
const closeFile = helpers.closeFile;
const expectClean = helpers.expectClean;
const pattern = helpers.pattern;
const infoOf = helpers.infoOf;
const blocksOf = helpers.blocksOf;

/// Recycled switched, with its limits: the answer's error, 0 for done.
fn switchRecycled(fs: *FileSystem, on: bool, max_count: u32, max_bytes: u64) i32 {
    var settings: packets.Settings = .{
        .mask = packets.SET_RECYCLED,
        .settings = if (on) packets.SET_RECYCLED else 0,
        .recycled_max_count = max_count,
        .recycled_max_bytes = max_bytes,
    };
    const reply = sendOwn(fs, packets.ACTION_POSFS_SETTINGS, &settings);
    return if (reply.res1 == dos.DOSTRUE) 0 else reply.res2;
}

fn delete(fs: *FileSystem, name: [*:0]const u8) i32 {
    const reply = send(fs, .delete_object, .{ 0, arg(name), 0, 0 });
    return if (reply.res1 == dos.DOSTRUE) 0 else reply.res2;
}

fn undelete(fs: *FileSystem, name: [*:0]const u8, to: ?[*:0]const u8) i32 {
    var args: packets.UndeleteArgs = .{ .name = name, .to = to };
    const reply = sendOwn(fs, packets.ACTION_POSFS_UNDELETE, &args);
    return if (reply.res1 == dos.DOSTRUE) 0 else reply.res2;
}

fn emptyRecycled(fs: *FileSystem) i32 {
    var pkt = dos.DosPacket.init(@enumFromInt(packets.ACTION_POSFS_EMPTY_RECYCLED), .{ .raw = @splat(0) });
    const reply = fs.answer(&pkt);
    return if (reply.res1 == dos.DOSTRUE) 0 else reply.res2;
}

fn rename(fs: *FileSystem, from: [*:0]const u8, to: [*:0]const u8) i32 {
    const reply = sendArgs(fs, .rename_object, .{ .rename = .{ .from_lock = null, .from_name = from, .to_lock = null, .to_name = to } });
    return if (reply.res1 == dos.DOSTRUE) 0 else reply.res2;
}

fn exists(fs: *FileSystem, name: [*:0]const u8) bool {
    const lock = send(fs, .locate_object, .{ 0, arg(name), dos.SHARED_LOCK, 0 });
    if (lock.res1 == 0) return false;
    _ = send(fs, .free_lock, .{ lock.res1, 0, 0, 0 });
    return true;
}

/// What Recycled holds, by INFO; the blocks add up every time.
fn recycledCount(fs: *FileSystem) !u64 {
    const info = try infoOf(fs);
    try testing.expectEqual(info.blocks, info.live + info.snapshots + info.recycled + info.pending + info.reserve + info.free);
    return info.recycled_count;
}

test "Recycled: a delete moves the name there, an undelete and a rename out give it back" {
    for (helpers.kinds) |kind| {
        var setup: Setup = undefined;
        try setup.init(kind, 1024 * 1024, 4096);
        defer setup.deinit();
        var fs = &setup.fs;
        try testing.expectEqual(@as(i32, 0), switchRecycled(fs, true, 0, 0));
        try testing.expectEqual(packets.SET_CHECKSUMS | packets.SET_RECYCLED, (try infoOf(fs)).settings);
        try testing.expectEqual(dos.ST_USERDIR, try helpers.listedType(fs, "Recycled"));
        const drawer = send(fs, .create_dir, .{ 0, arg("Drawer"), 0, 0 });
        _ = send(fs, .free_lock, .{ drawer.res1, 0, 0, 0 });
        var letter: [20_000]u8 = undefined;
        try writeFile(fs, "Drawer/Letter", pattern(5, &letter));
        const blocks = try blocksOf(fs, "Drawer/Letter");
        try expectClean(fs);

        try testing.expectEqual(@as(i32, 0), delete(fs, "Drawer/Letter"));
        try testing.expect(!exists(fs, "Drawer/Letter"));
        var back: [30_000]u8 = undefined;
        try testing.expectEqualSlices(u8, &letter, back[0..try readFile(fs, "Recycled/Letter", &back)]);
        try testing.expectEqual(@as(u64, 1), try recycledCount(fs));
        try testing.expectEqual(blocks, (try infoOf(fs)).recycled);
        try expectClean(fs);

        // Where it came from, and when.
        var path: [64]u8 = undefined;
        var origin: packets.OriginArgs = .{ .name = "Letter", .path = &path, .path_size = path.len };
        try testing.expectEqual(dos.DOSTRUE, sendOwn(fs, packets.ACTION_POSFS_ORIGIN, &origin).res1);
        try testing.expectEqualStrings("Drawer/Letter", std.mem.sliceTo(&path, 0));
        try testing.expect(origin.deleted != 0);
        var short: packets.OriginArgs = .{ .name = "Letter", .path = &path, .path_size = 5 };
        try testing.expectEqual(dos.ERROR_BUFFER_OVERFLOW, sendOwn(fs, packets.ACTION_POSFS_ORIGIN, &short).res2);
        var none: packets.OriginArgs = .{ .name = "Nothing", .path = &path, .path_size = path.len };
        try testing.expectEqual(dos.ERROR_OBJECT_NOT_FOUND, sendOwn(fs, packets.ACTION_POSFS_ORIGIN, &none).res2);

        // The same name again: a number behind it there.
        try writeFile(fs, "Drawer/Letter", "the second");
        try testing.expectEqual(@as(i32, 0), delete(fs, "Drawer/Letter"));
        try testing.expectEqualStrings("the second", back[0..try readFile(fs, "Recycled/Letter.1", &back)]);
        try testing.expectEqual(@as(u64, 2), try recycledCount(fs));

        // Back where it came from; to a name of its own where one is in
        // the way; into a directory a path names.
        try writeFile(fs, "Drawer/Letter", "in the way");
        try testing.expectEqual(dos.ERROR_OBJECT_EXISTS, undelete(fs, "Letter", null));
        try testing.expectEqual(@as(i32, 0), undelete(fs, "Letter", "Work:Drawer/Old"));
        try testing.expectEqualSlices(u8, &letter, back[0..try readFile(fs, "Drawer/Old", &back)]);
        try testing.expectEqual(@as(i32, 0), delete(fs, "Drawer/Letter"));
        try testing.expectEqual(@as(i32, 0), undelete(fs, "Letter.1", null));
        try testing.expectEqualStrings("the second", back[0..try readFile(fs, "Drawer/Letter", &back)]);
        try testing.expectEqual(@as(i32, 0), undelete(fs, "Letter", "Work:"));
        try testing.expectEqualStrings("in the way", back[0..try readFile(fs, "Letter", &back)]);
        try testing.expectEqual(dos.ERROR_OBJECT_NOT_FOUND, undelete(fs, "Letter", null));
        try testing.expectEqual(@as(u64, 0), try recycledCount(fs));
        try expectClean(fs);

        // A rename out of it is an undelete too; the power gone after it
        // and after a delete keeps both.
        try testing.expectEqual(@as(i32, 0), delete(fs, "Drawer/Old"));
        try testing.expectEqual(@as(i32, 0), rename(fs, "Recycled/Old", "Kept"));
        try testing.expectEqual(@as(i32, 0), delete(fs, "Letter"));
        try setup.crash();
        fs = &setup.fs;
        try testing.expectEqualSlices(u8, &letter, back[0..try readFile(fs, "Kept", &back)]);
        try testing.expectEqualStrings("in the way", back[0..try readFile(fs, "Recycled/Letter", &back)]);
        try testing.expectEqual(@as(u64, 1), try recycledCount(fs));

        // The directory it came from gone: it goes back only where it is
        // told.
        try testing.expectEqual(@as(i32, 0), delete(fs, "Drawer/Letter"));
        try testing.expectEqual(@as(i32, 0), delete(fs, "Drawer"));
        try testing.expectEqual(@as(i32, 0), delete(fs, "Recycled/Drawer"));
        try testing.expectEqual(dos.ERROR_DIR_NOT_FOUND, undelete(fs, "Letter.1", null));
        origin = .{ .name = "Letter.1", .path = &path, .path_size = path.len };
        try testing.expectEqual(dos.ERROR_DIR_NOT_FOUND, sendOwn(fs, packets.ACTION_POSFS_ORIGIN, &origin).res2);
        try testing.expect(origin.deleted != 0);
        try testing.expectEqual(@as(i32, 0), undelete(fs, "Letter.1", "Second"));
        try testing.expectEqualStrings("the second", back[0..try readFile(fs, "Second", &back)]);
        try setup.remount();
    }
}

test "Recycled: what is in it is as it was, Recycled itself stays, the rest deletes as before" {
    var setup: Setup = undefined;
    try setup.init(.sd, 1024 * 1024, 4096);
    defer setup.deinit();
    const fs = &setup.fs;
    try testing.expectEqual(@as(i32, 0), switchRecycled(fs, true, 0, 0));
    try writeFile(fs, "a", "some bytes");
    try writeFile(fs, "b", "other bytes");
    try testing.expectEqual(@as(i32, 0), delete(fs, "a"));

    // Read, yes; written, changed, moved within or into it, no.
    var back: [64]u8 = undefined;
    try testing.expectEqualStrings("some bytes", back[0..try readFile(fs, "Recycled/a", &back)]);
    var fh: FileHandle = .{};
    try testing.expectEqual(dos.ERROR_WRITE_PROTECTED, openFile(fs, &fh, .findoutput, "Recycled/a").res2);
    try testing.expectEqual(dos.ERROR_WRITE_PROTECTED, openFile(fs, &fh, .findupdate, "Recycled/a").res2);
    try testing.expectEqual(dos.ERROR_WRITE_PROTECTED, openFile(fs, &fh, .findoutput, "Recycled/new").res2);
    try testing.expectEqual(dos.DOSTRUE, openFile(fs, &fh, .findinput, "Recycled/a").res1);
    try testing.expectEqual(dos.ERROR_WRITE_PROTECTED, writeTo(fs, &fh, "x").res2);
    try testing.expectEqual(dos.DOSTRUE, closeFile(fs, &fh).res1);
    try testing.expectEqual(dos.ERROR_WRITE_PROTECTED, send(fs, .create_dir, .{ 0, arg("Recycled/Drawer"), 0, 0 }).res2);
    try testing.expectEqual(dos.ERROR_WRITE_PROTECTED, sendArgs(fs, .set_protect, .{ .property = .{ .lock = null, .name = "Recycled/a", .value = dos.FIBF_READ } }).res2);
    try testing.expectEqual(dos.ERROR_WRITE_PROTECTED, sendArgs(fs, .set_comment, .{ .property = .{ .lock = null, .name = "Recycled", .value = arg("note") } }).res2);
    try testing.expectEqual(dos.ERROR_WRITE_PROTECTED, rename(fs, "Recycled/a", "Recycled/c"));
    try testing.expectEqual(dos.ERROR_WRITE_PROTECTED, rename(fs, "b", "Recycled/b"));
    try testing.expectEqual(dos.ERROR_WRITE_PROTECTED, rename(fs, "Recycled", "Bin"));
    try testing.expectEqual(dos.ERROR_WRITE_PROTECTED, delete(fs, "Recycled"));
    try testing.expectEqual(dos.ERROR_WRITE_PROTECTED, send(fs, .make_link, .{ 0, arg("Recycled/l"), arg("b"), dos.LINK_SOFT }).res2);
    const held = send(fs, .locate_object, .{ 0, arg("Recycled/a"), dos.SHARED_LOCK, 0 });
    try testing.expect(held.res1 != 0);
    try testing.expectEqual(dos.ERROR_WRITE_PROTECTED, send(fs, .make_link, .{ 0, arg("hard"), held.res1, dos.LINK_HARD }).res2);
    // A delete there, while a lock is on it, is refused; and it stays
    // when Recycled is emptied.
    try testing.expectEqual(dos.ERROR_OBJECT_IN_USE, delete(fs, "Recycled/a"));
    try testing.expectEqual(@as(i32, 0), delete(fs, "b"));
    try testing.expectEqual(dos.ERROR_OBJECT_IN_USE, emptyRecycled(fs));
    try testing.expect(!exists(fs, "Recycled/b"));
    try testing.expectEqual(dos.DOSTRUE, send(fs, .free_lock, .{ held.res1, 0, 0, 0 }).res1);
    try testing.expectEqual(@as(i32, 0), delete(fs, "Recycled/a"));
    try testing.expectEqual(@as(u64, 0), try recycledCount(fs));
    try expectClean(fs);

    // An empty directory and a soft link go there too; a full directory
    // is refused as ever; a file with two names loses one, and goes with
    // its last.
    const drawer = send(fs, .create_dir, .{ 0, arg("Drawer"), 0, 0 });
    _ = send(fs, .free_lock, .{ drawer.res1, 0, 0, 0 });
    try writeFile(fs, "Drawer/in", "in it");
    try testing.expectEqual(dos.ERROR_DIRECTORY_NOT_EMPTY, delete(fs, "Drawer"));
    try testing.expectEqual(dos.DOSTRUE, send(fs, .make_link, .{ 0, arg("link"), arg("Drawer/in"), dos.LINK_SOFT }).res1);
    try testing.expectEqual(@as(i32, 0), delete(fs, "link"));
    try testing.expectEqual(dos.ST_SOFTLINK, try listedIn(fs, "Recycled", "link"));
    const file = send(fs, .locate_object, .{ 0, arg("Drawer/in"), dos.SHARED_LOCK, 0 });
    try testing.expectEqual(dos.DOSTRUE, send(fs, .make_link, .{ 0, arg("second"), file.res1, dos.LINK_HARD }).res1);
    _ = send(fs, .free_lock, .{ file.res1, 0, 0, 0 });
    try testing.expectEqual(@as(i32, 0), delete(fs, "Drawer/in"));
    try testing.expectEqual(@as(u64, 1), try recycledCount(fs));
    try testing.expectEqual(@as(i32, 0), delete(fs, "Drawer"));
    try testing.expectEqual(dos.ST_USERDIR, try listedIn(fs, "Recycled", "Drawer"));
    try testing.expectEqual(@as(i32, 0), delete(fs, "second"));
    try testing.expectEqualStrings("in it", back[0..try readFile(fs, "Recycled/second", &back)]);
    try testing.expectEqual(@as(u64, 3), try recycledCount(fs));
    try expectClean(fs);
    try testing.expectEqual(@as(i32, 0), emptyRecycled(fs));
    try testing.expectEqual(@as(u64, 0), try recycledCount(fs));
    try setup.crash();
    try testing.expectEqual(@as(u64, 0), try recycledCount(&setup.fs));
}

/// The type `name` is listed with in the directory `dir`.
fn listedIn(fs: *FileSystem, dir: [*:0]const u8, name: []const u8) !i32 {
    const lock = send(fs, .locate_object, .{ 0, arg(dir), dos.SHARED_LOCK, 0 });
    try testing.expect(lock.res1 != 0);
    defer _ = send(fs, .free_lock, .{ lock.res1, 0, 0, 0 });
    var fib: dos.FileInfoBlock = undefined;
    const lock_ptr = helpers.lockOf(lock);
    try testing.expectEqual(dos.DOSTRUE, sendArgs(fs, .examine_object, .{ .examine = .{ .lock = lock_ptr, .fib = &fib } }).res1);
    while (sendArgs(fs, .examine_next, .{ .examine = .{ .lock = lock_ptr, .fib = &fib } }).res1 == dos.DOSTRUE) {
        if (std.mem.eql(u8, std.mem.sliceTo(&fib.file_name, 0), name)) return fib.dir_entry_type;
    }
    return error.NotListed;
}

test "Recycled: kept to its limits, and emptied, the oldest first, for a full volume" {
    var setup: Setup = undefined;
    try setup.init(.sd, 512 * 1024, 4096);
    defer setup.deinit();
    const fs = &setup.fs;
    var data: [100_000]u8 = undefined;
    try testing.expectEqual(@as(i32, 0), switchRecycled(fs, true, 2, 0));
    try writeFile(fs, "a", pattern(1, data[0..5000]));
    try writeFile(fs, "b", pattern(2, data[0..5000]));
    try writeFile(fs, "c", pattern(3, data[0..5000]));
    for ([_][*:0]const u8{ "a", "b", "c" }) |name| try testing.expectEqual(@as(i32, 0), delete(fs, name));
    try testing.expectEqual(@as(u64, 2), try recycledCount(fs));
    try testing.expect(!exists(fs, "Recycled/a") and exists(fs, "Recycled/b") and exists(fs, "Recycled/c"));

    // Fewer bytes allowed: the oldest goes at once; a file bigger than all
    // that is allowed is deleted for good.
    try testing.expectEqual(@as(i32, 0), switchRecycled(fs, true, 0, 3 * 4096));
    try testing.expectEqual(@as(u64, 1), try recycledCount(fs));
    try testing.expect(exists(fs, "Recycled/c"));
    try writeFile(fs, "d", pattern(4, data[0..16_000]));
    try testing.expectEqual(@as(i32, 0), delete(fs, "d"));
    try testing.expect(!exists(fs, "Recycled/d"));
    try testing.expectEqual(@as(u64, 1), try recycledCount(fs));
    try expectClean(fs);

    // No limits; Recycled full of old files, and a write that needs their
    // room. One held open stays.
    try testing.expectEqual(@as(i32, 0), switchRecycled(fs, true, 0, 0));
    try writeFile(fs, "old1", pattern(5, &data));
    try writeFile(fs, "old2", pattern(6, &data));
    try writeFile(fs, "kept", pattern(7, data[0..8000]));
    for ([_][*:0]const u8{ "old1", "old2", "kept" }) |name| try testing.expectEqual(@as(i32, 0), delete(fs, name));
    var reader: FileHandle = .{};
    try testing.expectEqual(dos.DOSTRUE, openFile(fs, &reader, .findinput, "Recycled/kept").res1);
    try checkpoint.write(&fs.vol, 0);
    try checkpoint.write(&fs.vol, 0);
    const free_before = (try infoOf(fs)).free;
    var fh: FileHandle = .{};
    try testing.expectEqual(dos.DOSTRUE, openFile(fs, &fh, .findoutput, "fill").res1);
    var written: u64 = 0;
    while (true) {
        const reply = writeTo(fs, &fh, data[0..8192]);
        if (reply.res1 != 8192) {
            try testing.expectEqual(dos.ERROR_DISK_FULL, reply.res2);
            break;
        }
        written += 8192;
        try testing.expect(written < 600 * 1024);
    }
    try testing.expectEqual(dos.DOSTRUE, closeFile(fs, &fh).res1);
    try testing.expect(written / 4096 > free_before + 40);
    try testing.expect(!exists(fs, "Recycled/old1") and !exists(fs, "Recycled/old2"));
    try testing.expectEqual(dos.DOSTRUE, closeFile(fs, &reader).res1);
    try testing.expect(exists(fs, "Recycled/kept"));
    try expectClean(fs);
    try setup.remount();
}

test "Recycled: switched on only with the name free, off only with nothing in it used" {
    var setup: Setup = undefined;
    try setup.init(.flash, 1024 * 1024, 4096);
    defer setup.deinit();
    var fs = &setup.fs;
    try writeFile(fs, "Recycled", "a file of that name");
    try testing.expectEqual(dos.ERROR_OBJECT_EXISTS, switchRecycled(fs, true, 0, 0));
    try testing.expectEqual(@as(u32, packets.SET_CHECKSUMS), (try infoOf(fs)).settings);
    try testing.expectEqual(@as(i32, 0), delete(fs, "Recycled"));
    try testing.expectEqual(@as(i32, 0), switchRecycled(fs, true, 0, 0));
    try writeFile(fs, "x", "x");
    try testing.expectEqual(@as(i32, 0), delete(fs, "x"));

    // The power gone after a delete, once the journal is written: it is in
    // Recycled after replay.
    try writeFile(fs, "y", "y");
    try testing.expectEqual(@as(i32, 0), delete(fs, "y"));
    try setup.crash();
    fs = &setup.fs;
    try testing.expectEqual(@as(u64, 2), try recycledCount(fs));
    try testing.expect(exists(fs, "Recycled/y"));

    // Off: refused while Recycled is locked, then emptied and gone.
    const lock = send(fs, .locate_object, .{ 0, arg("Recycled"), dos.SHARED_LOCK, 0 });
    try testing.expectEqual(dos.ERROR_OBJECT_IN_USE, switchRecycled(fs, false, 0, 0));
    _ = send(fs, .free_lock, .{ lock.res1, 0, 0, 0 });
    try testing.expectEqual(@as(i32, 0), switchRecycled(fs, false, 0, 0));
    try testing.expectError(error.NotListed, helpers.listedType(fs, "Recycled"));
    try testing.expectEqual(@as(u64, 0), try recycledCount(fs));
    try testing.expectEqual(dos.ERROR_OBJECT_NOT_FOUND, undelete(fs, "x", null));
    try testing.expectEqual(dos.ERROR_OBJECT_NOT_FOUND, emptyRecycled(fs));
    try expectClean(fs);
    // A delete is for good now, and the name is free again.
    try writeFile(fs, "z", "z");
    try testing.expectEqual(@as(i32, 0), delete(fs, "z"));
    try writeFile(fs, "Recycled", "a file again");
    try setup.crash();
    try testing.expectEqual(@as(u32, packets.SET_CHECKSUMS), (try infoOf(&setup.fs)).settings);
    try testing.expectEqual(dos.ST_FILE, try helpers.listedType(&setup.fs, "Recycled"));
}

/// A file written a piece at a time, each piece committed in a
/// generation of its own: an extent each.
fn writeInPieces(fs: *FileSystem, name: [*:0]const u8, bytes: []const u8, piece: usize) !void {
    try writeFile(fs, name, bytes[0..piece]);
    var at = piece;
    while (at < bytes.len) : (at += piece) {
        try checkpoint.write(&fs.vol, 0);
        var fh: FileHandle = .{};
        try testing.expectEqual(dos.DOSTRUE, openFile(fs, &fh, .findupdate, name).res1);
        _ = helpers.sendSeek(fs, .seek, &fh, 0, dos.OFFSET_END);
        try testing.expectEqual(@as(isize, @intCast(piece)), writeTo(fs, &fh, bytes[at..][0..piece]).res1);
        try testing.expectEqual(dos.DOSTRUE, closeFile(fs, &fh).res1);
    }
}

/// The orphans on the volume.
fn orphanCount(fs: *FileSystem) !u32 {
    var count: u32 = 0;
    var oid: u64 = posfs.first_user_oid;
    while (oid < fs.vol.next_oid) : (oid += 1) {
        const node = try objects.inode(&fs.vol, oid) orelse continue;
        if (node.flags & layout.INODE_ORPHAN != 0) count += 1;
    }
    return count;
}

test "orphans: a big file's delete goes as a job, its blocks given back step by step, after a cut too" {
    for (helpers.kinds) |kind| {
        var setup: Setup = undefined;
        try setup.init(kind, 1024 * 1024, 4096);
        defer setup.deinit();
        var fs = &setup.fs;
        fs.job_blocks = 4;
        fs.check_slice = 0;
        try checkpoint.write(&fs.vol, 0);
        try checkpoint.write(&fs.vol, 0);
        const free_before = (try infoOf(fs)).free;
        var data: [40 * 4096]u8 = undefined;
        try writeInPieces(fs, "big", pattern(8, &data), 4 * 4096);
        var back: [40 * 4096]u8 = undefined;
        try testing.expectEqualSlices(u8, &data, back[0..try readFile(fs, "big", &back)]);
        try testing.expectEqual(@as(i32, 0), delete(fs, "big"));
        try testing.expect(!exists(fs, "big"));
        try testing.expectEqual(@as(u32, 1), try orphanCount(fs));
        try testing.expect(fs.pending());
        try expectClean(fs);

        // The cut before any step: the job is there after replay.
        try setup.crash();
        fs = &setup.fs;
        fs.job_blocks = 4;
        fs.check_slice = 0;
        try testing.expect(fs.orphans);
        try fs.idle();
        try fs.idle();
        try expectClean(fs);
        // And a cut halfway, after a checkpoint: it goes on from there.
        try checkpoint.write(&fs.vol, 0);
        try setup.crash();
        fs = &setup.fs;
        fs.job_blocks = 4;
        fs.check_slice = 0;
        try testing.expect(fs.orphans);
        var steps: u32 = 0;
        while (fs.orphans) : (steps += 1) {
            try fs.idle();
            try expectClean(fs);
            try testing.expect(steps < 64);
        }
        try testing.expect(steps > 2);
        try testing.expectEqual(@as(u32, 0), try orphanCount(fs));
        try checkpoint.write(&fs.vol, 0);
        try checkpoint.write(&fs.vol, 0);
        try testing.expectEqual(free_before, (try infoOf(fs)).free);

        // Through Recycled: a purge of a big one is a job too.
        try testing.expectEqual(@as(i32, 0), switchRecycled(fs, true, 0, 0));
        try writeInPieces(fs, "big", pattern(9, &data), 4 * 4096);
        try testing.expectEqual(@as(i32, 0), delete(fs, "big"));
        try testing.expectEqual(@as(u32, 0), try orphanCount(fs));
        try testing.expectEqual(@as(i32, 0), emptyRecycled(fs));
        try testing.expectEqual(@as(u32, 1), try orphanCount(fs));
        try expectClean(fs);
        try setup.remount();
        fs = &setup.fs;
        fs.check_slice = 0;
        while (fs.orphans) try fs.idle();
        try expectClean(fs);
        try testing.expectEqual(@as(u32, 0), try orphanCount(fs));
    }
}
