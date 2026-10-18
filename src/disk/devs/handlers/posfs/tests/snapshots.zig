// SPDX-License-Identifier: MPL-2.0
//! posfs's snapshots through their packets: made and read under
//! `.snapshots`, kept as they were while the volume changes, never
//! written, deleted in any order, and the volume rolled back to the
//! newest - the space they held free again after, the check clean after
//! each step, a cut, a mount and a durable check.

const std = @import("std");
const testing = std.testing;
const sdk = @import("sdk");
const dos = sdk.dos;
const posfs = dos.posfs;
const packets = posfs.packets;
const fs_core = @import("../fs.zig");
const checkpoint = @import("../checkpoint.zig");
const helpers = @import("fs.zig");
const FileSystem = fs_core.FileSystem;
const FileHandle = dos.FileHandle;
const FileInfoBlock = dos.FileInfoBlock;
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
const lockOf = helpers.lockOf;

fn snapshotAction(fs: *FileSystem, action: i32, name: [*:0]const u8) i32 {
    var args: packets.SnapshotArgs = .{ .name = name };
    const reply = sendOwn(fs, action, &args);
    return if (reply.res1 == dos.DOSTRUE) 0 else reply.res2;
}

fn make(fs: *FileSystem, name: [*:0]const u8) i32 {
    return snapshotAction(fs, packets.ACTION_POSFS_MAKE_SNAPSHOT, name);
}

fn drop(fs: *FileSystem, name: [*:0]const u8) i32 {
    return snapshotAction(fs, packets.ACTION_POSFS_DELETE_SNAPSHOT, name);
}

fn rollback(fs: *FileSystem, name: [*:0]const u8) i32 {
    return snapshotAction(fs, packets.ACTION_POSFS_ROLLBACK, name);
}

fn delete(fs: *FileSystem, name: [*:0]const u8) i32 {
    const reply = send(fs, .delete_object, .{ 0, arg(name), 0, 0 });
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

fn makeDir(fs: *FileSystem, name: [*:0]const u8) !void {
    const lock = send(fs, .create_dir, .{ 0, arg(name), 0, 0 });
    try testing.expect(lock.res1 != 0);
    _ = send(fs, .free_lock, .{ lock.res1, 0, 0, 0 });
}

/// What a file holds, compared.
fn expectFile(fs: *FileSystem, name: [*:0]const u8, bytes: []const u8) !void {
    var back: [70_000]u8 = undefined;
    try testing.expectEqualSlices(u8, bytes, back[0..try readFile(fs, name, &back)]);
}

/// The blocks the snapshots hold, by INFO; the blocks add up every time.
fn heldBlocks(fs: *FileSystem) !u64 {
    const info = try infoOf(fs);
    try testing.expectEqual(info.blocks, info.live + info.snapshots + info.recycled + info.pending + info.reserve + info.free);
    return info.snapshots;
}

/// What the blocks hold once two checkpoints have let go of what waits:
/// the live volume's, and the rest - free, or on its way back.
const Use = struct { live: u64, unused: u64 };

fn settledUse(fs: *FileSystem) !Use {
    try checkpoint.write(&fs.vol, 0);
    try checkpoint.write(&fs.vol, 0);
    const info = try infoOf(fs);
    try testing.expectEqual(@as(u64, 0), info.snapshots);
    return .{ .live = info.live, .unused = info.free + info.pending };
}

/// A whole durable check, a slice at a time: clean.
fn checkDurable(fs: *FileSystem) !void {
    var args: packets.CheckArgs = .{};
    var slices: u32 = 0;
    while (true) : (slices += 1) {
        try testing.expectEqual(dos.DOSTRUE, sendOwn(fs, packets.ACTION_POSFS_CHECK, &args).res1);
        if (args.errors != 0) {
            std.debug.print("durable check: {s}\n", .{std.mem.sliceTo(&args.message, 0)});
            return error.TestUnexpectedResult;
        }
        if (args.cursor == 0) return;
        try testing.expect(slices < 100_000);
    }
}

/// The names in a directory, in the order Examine gives them - for
/// `.snapshots` the order they were made in - joined by spaces into
/// `into`.
fn listing(fs: *FileSystem, dir: [*:0]const u8, into: []u8) ![]const u8 {
    const lock = send(fs, .locate_object, .{ 0, arg(dir), dos.SHARED_LOCK, 0 });
    try testing.expect(lock.res1 != 0);
    defer _ = send(fs, .free_lock, .{ lock.res1, 0, 0, 0 });
    var fib: FileInfoBlock = undefined;
    try testing.expectEqual(dos.DOSTRUE, sendArgs(fs, .examine_object, .{ .examine = .{ .lock = lockOf(lock), .fib = &fib } }).res1);
    var len: usize = 0;
    while (sendArgs(fs, .examine_next, .{ .examine = .{ .lock = lockOf(lock), .fib = &fib } }).res1 == dos.DOSTRUE) {
        const name = std.mem.sliceTo(&fib.file_name, 0);
        if (len != 0) {
            into[len] = ' ';
            len += 1;
        }
        @memcpy(into[len..][0..name.len], name);
        len += name.len;
    }
    return into[0..len];
}

test "snapshots: made, read under .snapshots, kept as they were while the volume changes" {
    for (helpers.kinds) |kind| {
        var setup: Setup = undefined;
        try setup.init(kind, 1024 * 1024, 4096);
        defer setup.deinit();
        var fs = &setup.fs;
        var first: [20_000]u8 = undefined;
        var second: [30_000]u8 = undefined;
        _ = pattern(1, &first);
        _ = pattern(2, &second);
        try makeDir(fs, "Drawer");
        try writeFile(fs, "a", &first);
        try writeFile(fs, "Drawer/b", "small");
        try testing.expectEqual(dos.DOSTRUE, sendArgs(fs, .set_comment, .{ .property = .{ .lock = null, .name = "a", .value = arg("noted") } }).res1);
        try testing.expectEqual(@as(i32, 0), make(fs, "One"));
        try testing.expectEqual(@as(u32, 1), (try infoOf(fs)).snapshot_count);
        try testing.expectEqual(@as(u64, 0), try heldBlocks(fs));
        try expectClean(fs);

        // The volume changes; the snapshot does not.
        try writeFile(fs, "a", &second);
        try testing.expectEqual(@as(i32, 0), delete(fs, "Drawer/b"));
        try writeFile(fs, "c", "new");
        try expectFile(fs, "a", &second);
        try expectFile(fs, ".snapshots/One/a", &first);
        try expectFile(fs, ".SNAPSHOTS/one/Drawer/b", "small");
        try testing.expect(!exists(fs, ".snapshots/One/c"));
        try testing.expect(!exists(fs, "Drawer/b"));
        try testing.expect(try heldBlocks(fs) >= 5);
        try expectClean(fs);
        var fib: FileInfoBlock = undefined;
        const lock = send(fs, .locate_object, .{ 0, arg(".snapshots/One/a"), dos.SHARED_LOCK, 0 });
        try testing.expectEqual(dos.DOSTRUE, sendArgs(fs, .examine_object, .{ .examine = .{ .lock = lockOf(lock), .fib = &fib } }).res1);
        try testing.expectEqualStrings("noted", std.mem.sliceTo(&fib.comment, 0));
        try testing.expectEqual(@as(u64, first.len), fib.size);
        _ = send(fs, .free_lock, .{ lock.res1, 0, 0, 0 });

        // On the lists at a checkpoint; after a cut, a mount, and a check
        // of what is on the medium.
        try checkpoint.write(&fs.vol, 0);
        try expectClean(fs);
        try checkDurable(fs);
        try writeFile(fs, "a", "third");
        try setup.crash();
        fs = &setup.fs;
        try expectFile(fs, "a", "third");
        try expectFile(fs, ".snapshots/One/a", &first);
        try setup.remount();
        fs = &setup.fs;
        try expectFile(fs, ".snapshots/One/Drawer/b", "small");
        try checkDurable(fs);
    }
}

test "snapshots: listed only in .snapshots, which the root does not show, and never written" {
    var setup: Setup = undefined;
    try setup.init(.sd, 1024 * 1024, 4096);
    defer setup.deinit();
    const fs = &setup.fs;
    try makeDir(fs, "Drawer");
    try writeFile(fs, "a", "first");
    try testing.expectEqual(@as(i32, 0), make(fs, "One"));
    try writeFile(fs, "b", "second");
    try testing.expectEqual(@as(i32, 0), make(fs, "Two"));

    var text: [200]u8 = undefined;
    try testing.expectEqual(@as(usize, "Drawer a b".len), (try listing(fs, "", &text)).len);
    try testing.expectError(error.NotListed, helpers.listedType(fs, ".snapshots"));
    try testing.expectEqualStrings("One Two", try listing(fs, ".snapshots", &text));
    try testing.expectEqual(@as(usize, "Drawer a".len), (try listing(fs, ".snapshots/One", &text)).len);

    // The way up: from a snapshot's root to .snapshots, and to the root.
    const inner = send(fs, .locate_object, .{ 0, arg(".snapshots/One/Drawer"), dos.SHARED_LOCK, 0 });
    const up = send(fs, .parent, .{ inner.res1, 0, 0, 0 });
    var fib: FileInfoBlock = undefined;
    try testing.expectEqual(dos.DOSTRUE, sendArgs(fs, .examine_object, .{ .examine = .{ .lock = lockOf(up), .fib = &fib } }).res1);
    try testing.expectEqualStrings("One", std.mem.sliceTo(&fib.file_name, 0));
    try testing.expectEqual(dos.ST_USERDIR, fib.dir_entry_type);
    try testing.expect(fib.protection & dos.FIBF_WRITE != 0);
    const dir = send(fs, .parent, .{ up.res1, 0, 0, 0 });
    try testing.expectEqual(dos.DOSTRUE, sendArgs(fs, .examine_object, .{ .examine = .{ .lock = lockOf(dir), .fib = &fib } }).res1);
    try testing.expectEqualStrings(".snapshots", std.mem.sliceTo(&fib.file_name, 0));
    const root = send(fs, .parent, .{ dir.res1, 0, 0, 0 });
    try testing.expectEqual(dos.DOSTRUE, sendArgs(fs, .examine_object, .{ .examine = .{ .lock = lockOf(root), .fib = &fib } }).res1);
    try testing.expectEqualStrings("Work", std.mem.sliceTo(&fib.file_name, 0));
    for ([_]isize{ inner.res1, up.res1, dir.res1, root.res1 }) |each| _ = send(fs, .free_lock, .{ each, 0, 0, 0 });
    const live = send(fs, .locate_object, .{ 0, arg("a"), dos.SHARED_LOCK, 0 });
    const kept = send(fs, .locate_object, .{ 0, arg(".snapshots/One/a"), dos.SHARED_LOCK, 0 });
    try testing.expectEqual(dos.DOSFALSE, send(fs, .same_lock, .{ live.res1, kept.res1, 0, 0 }).res1);
    // An exclusive lock on the live file is no lock on the snapshot's.
    _ = send(fs, .free_lock, .{ live.res1, 0, 0, 0 });
    const only = send(fs, .locate_object, .{ 0, arg("a"), dos.EXCLUSIVE_LOCK, 0 });
    try testing.expect(only.res1 != 0);
    _ = send(fs, .free_lock, .{ only.res1, 0, 0, 0 });

    // Nothing in a snapshot changes.
    const protected = dos.ERROR_DISK_WRITE_PROTECTED;
    var fh: FileHandle = .{};
    try testing.expectEqual(protected, openFile(fs, &fh, .findoutput, ".snapshots/One/a").res2);
    try testing.expectEqual(protected, openFile(fs, &fh, .findupdate, ".snapshots/One/a").res2);
    try testing.expectEqual(protected, openFile(fs, &fh, .findoutput, ".snapshots/One/new").res2);
    try testing.expectEqual(protected, openFile(fs, &fh, .findoutput, ".snapshots/new").res2);
    try testing.expectEqual(dos.DOSTRUE, openFile(fs, &fh, .findinput, ".snapshots/One/a").res1);
    try testing.expectEqual(protected, writeTo(fs, &fh, "x").res2);
    try testing.expectEqual(protected, helpers.sendSeek(fs, .set_file_size, &fh, 0, dos.OFFSET_BEGINNING).reply.res2);
    try testing.expectEqual(dos.DOSTRUE, closeFile(fs, &fh).res1);
    try testing.expectEqual(protected, send(fs, .create_dir, .{ 0, arg(".snapshots/One/Sub"), 0, 0 }).res2);
    try testing.expectEqual(protected, delete(fs, ".snapshots/One/a"));
    try testing.expectEqual(protected, delete(fs, ".snapshots/One"));
    try testing.expectEqual(protected, delete(fs, ".snapshots"));
    try testing.expectEqual(protected, rename(fs, ".snapshots/One/a", "restored"));
    try testing.expectEqual(protected, rename(fs, "a", ".snapshots/One/a2"));
    try testing.expectEqual(protected, rename(fs, ".snapshots", "Snaps"));
    try testing.expectEqual(protected, sendArgs(fs, .set_protect, .{ .property = .{ .lock = null, .name = ".snapshots/One/a", .value = 0 } }).res2);
    try testing.expectEqual(protected, sendArgs(fs, .set_comment, .{ .property = .{ .lock = null, .name = ".snapshots/One", .value = arg("x") } }).res2);
    try testing.expectEqual(protected, send(fs, .make_link, .{ 0, arg(".snapshots/One/l"), arg("a"), dos.LINK_SOFT }).res2);
    try testing.expectEqual(protected, send(fs, .make_link, .{ 0, arg("hard"), kept.res1, dos.LINK_HARD }).res2);
    try testing.expectEqual(dos.ERROR_INVALID_COMPONENT_NAME, send(fs, .create_dir, .{ 0, arg(".Snapshots"), 0, 0 }).res2);
    try testing.expectEqual(dos.ERROR_INVALID_COMPONENT_NAME, rename(fs, "a", ".snapshots"));
    // What is copied out of one is the live volume's.
    var back: [16]u8 = undefined;
    try writeFile(fs, "restored", back[0..try readFile(fs, ".snapshots/One/a", &back)]);
    try expectFile(fs, "restored", "first");

    // The names a snapshot may have, and one in use.
    try testing.expectEqual(dos.ERROR_OBJECT_EXISTS, make(fs, "one"));
    try testing.expectEqual(dos.ERROR_INVALID_COMPONENT_NAME, make(fs, ""));
    try testing.expectEqual(dos.ERROR_INVALID_COMPONENT_NAME, make(fs, "a/b"));
    try testing.expectEqual(dos.ERROR_INVALID_COMPONENT_NAME, make(fs, "thirty-two bytes is one too many"));
    try testing.expectEqual(@as(i32, 0), make(fs, "\xe9t\xe9"));
    try expectFile(fs, ".snapshots/\xe9T\xc9/a", "first");
    try testing.expectEqual(dos.ERROR_OBJECT_IN_USE, drop(fs, "One"));
    _ = send(fs, .free_lock, .{ kept.res1, 0, 0, 0 });
    try testing.expectEqual(@as(i32, 0), drop(fs, "One"));
    try testing.expectEqual(dos.ERROR_OBJECT_NOT_FOUND, drop(fs, "One"));
    try testing.expectEqualStrings("Two \xe9t\xe9", try listing(fs, ".snapshots", &text));
    try expectClean(fs);
    try setup.remount();
}

test "snapshots: deleted in any order, each keeping what the others hold, the space free after" {
    for (helpers.kinds) |kind| {
        var setup: Setup = undefined;
        try setup.init(kind, 1024 * 1024, 4096);
        defer setup.deinit();
        var fs = &setup.fs;
        var versions: [4][24_000]u8 = undefined;
        for (&versions, 0..) |*version, index| _ = pattern(10 + index, version);
        try makeDir(fs, "Drawer");
        try writeFile(fs, "a", &versions[0]);
        try writeFile(fs, "Drawer/keep", &versions[3]);
        const before = try settledUse(fs);
        try testing.expectEqual(@as(i32, 0), make(fs, "s1"));
        try writeFile(fs, "a", &versions[1]);
        try testing.expectEqual(@as(i32, 0), make(fs, "s2"));
        try writeFile(fs, "a", &versions[2]);
        try testing.expectEqual(@as(i32, 0), make(fs, "s3"));
        try writeFile(fs, "a", &versions[3]);
        try testing.expectEqual(@as(i32, 0), delete(fs, "Drawer/keep"));
        try expectFile(fs, ".snapshots/s1/a", &versions[0]);
        try expectFile(fs, ".snapshots/s2/a", &versions[1]);
        try expectFile(fs, ".snapshots/s3/a", &versions[2]);
        try expectFile(fs, ".snapshots/s1/Drawer/keep", &versions[3]);
        try expectClean(fs);
        const held = try heldBlocks(fs);

        // The middle one: what only it held goes, the rest stays.
        try testing.expectEqual(@as(i32, 0), drop(fs, "s2"));
        try testing.expect(try heldBlocks(fs) < held);
        try expectFile(fs, ".snapshots/s1/a", &versions[0]);
        try expectFile(fs, ".snapshots/s3/a", &versions[2]);
        try expectFile(fs, ".snapshots/s3/Drawer/keep", &versions[3]);
        try expectClean(fs);
        try checkDurable(fs);
        try setup.crash();
        fs = &setup.fs;
        try expectFile(fs, ".snapshots/s3/a", &versions[2]);

        // The newest, with entries still waiting for its list.
        try writeFile(fs, "a", "short");
        try testing.expectEqual(@as(i32, 0), drop(fs, "s3"));
        try expectFile(fs, ".snapshots/s1/a", &versions[0]);
        try expectFile(fs, ".snapshots/s1/Drawer/keep", &versions[3]);
        try testing.expect(!exists(fs, ".snapshots/s3"));
        try expectClean(fs);
        try setup.remount();
        fs = &setup.fs;

        // The last: the volume as if there had been none.
        try writeFile(fs, "a", &versions[0]);
        try makeDir(fs, "Drawer2");
        try testing.expectEqual(@as(i32, 0), drop(fs, "s1"));
        try testing.expectEqual(@as(u64, 0), try heldBlocks(fs));
        try testing.expectEqual(@as(u32, 0), (try infoOf(fs)).snapshot_count);
        try testing.expectEqual(@as(u32, 0), (try infoOf(fs)).ro_compat & posfs.layout.RO_COMPAT_SNAPSHOTS);
        try testing.expectEqual(@as(i32, 0), delete(fs, "Drawer2"));
        try writeFile(fs, "Drawer/keep", &versions[3]);
        try testing.expectEqual(before, try settledUse(fs));
        try expectClean(fs);
        try checkDurable(fs);
    }
}

test "rollback: to the newest snapshot only, with nothing in use, what came after it freed" {
    for (helpers.kinds) |kind| {
        var setup: Setup = undefined;
        try setup.init(kind, 1024 * 1024, 4096);
        defer setup.deinit();
        var fs = &setup.fs;
        var first: [20_000]u8 = undefined;
        var second: [26_000]u8 = undefined;
        _ = pattern(3, &first);
        _ = pattern(4, &second);
        try makeDir(fs, "Drawer");
        try writeFile(fs, "a", &first);
        try writeFile(fs, "Drawer/x", "x");
        const before = try settledUse(fs);
        try testing.expectEqual(@as(i32, 0), make(fs, "s1"));
        try writeFile(fs, "a", &second);
        try testing.expectEqual(@as(i32, 0), delete(fs, "Drawer/x"));
        try writeFile(fs, "y", "y");
        try testing.expectEqual(@as(i32, 0), make(fs, "s2"));
        try writeFile(fs, "a", "third");
        try makeDir(fs, "Z");

        // Not past a newer one, not while something is in use.
        try testing.expectEqual(dos.ERROR_OBJECT_EXISTS, rollback(fs, "s1"));
        try testing.expectEqual(dos.ERROR_OBJECT_NOT_FOUND, rollback(fs, "s9"));
        const lock = send(fs, .locate_object, .{ 0, arg("Z"), dos.SHARED_LOCK, 0 });
        try testing.expectEqual(dos.ERROR_OBJECT_IN_USE, rollback(fs, "s2"));
        _ = send(fs, .free_lock, .{ lock.res1, 0, 0, 0 });

        try testing.expectEqual(@as(i32, 0), rollback(fs, "s2"));
        try expectFile(fs, "a", &second);
        try expectFile(fs, "y", "y");
        try testing.expect(!exists(fs, "Drawer/x") and !exists(fs, "Z"));
        try expectFile(fs, ".snapshots/s2/a", &second);
        try expectFile(fs, ".snapshots/s1/a", &first);
        try expectClean(fs);
        try checkDurable(fs);
        try setup.crash();
        fs = &setup.fs;
        try expectFile(fs, "a", &second);

        // Changes after a rollback, and one more to the snapshot before.
        try writeFile(fs, "a", "fourth");
        try testing.expectEqual(@as(i32, 0), drop(fs, "s2"));
        try testing.expectEqual(@as(i32, 0), rollback(fs, "s1"));
        try expectFile(fs, "a", &first);
        try expectFile(fs, "Drawer/x", "x");
        try testing.expect(!exists(fs, "y"));
        try expectClean(fs);
        try setup.remount();
        fs = &setup.fs;
        try expectFile(fs, "a", &first);
        // The live tree is the snapshot's: with it gone, the space is as
        // it was before it.
        try testing.expectEqual(@as(i32, 0), drop(fs, "s1"));
        try testing.expectEqual(before, try settledUse(fs));
        try expectClean(fs);
    }
}

test "rollback: Recycled as the snapshot had it" {
    var setup: Setup = undefined;
    try setup.init(.flash, 1024 * 1024, 4096);
    defer setup.deinit();
    var fs = &setup.fs;
    try writeFile(fs, "a", "kept");
    try testing.expectEqual(@as(i32, 0), make(fs, "before"));
    var on: packets.Settings = .{ .mask = packets.SET_RECYCLED, .settings = packets.SET_RECYCLED };
    try testing.expectEqual(dos.DOSTRUE, sendOwn(fs, packets.ACTION_POSFS_SETTINGS, &on).res1);
    try testing.expectEqual(@as(i32, 0), delete(fs, "a"));
    try expectFile(fs, "Recycled/a", "kept");
    try testing.expectEqual(@as(i32, 0), make(fs, "with"));
    try testing.expectEqual(@as(i32, 0), drop(fs, "with"));
    try testing.expectEqual(@as(i32, 0), rollback(fs, "before"));
    try expectFile(fs, "a", "kept");
    try testing.expectEqual(@as(u32, packets.SET_CHECKSUMS), (try infoOf(fs)).settings);
    try testing.expectError(error.NotListed, helpers.listedType(fs, "Recycled"));
    try testing.expectEqual(@as(i32, 0), delete(fs, "a"));
    try testing.expect(!exists(fs, "Recycled/a"));
    try expectClean(fs);
    try setup.crash();
    fs = &setup.fs;
    try testing.expect(!exists(fs, "a"));
    try expectFile(fs, ".snapshots/before/a", "kept");
}

test "snapshots: as many as the table holds, and the volume full of what they hold" {
    var setup: Setup = undefined;
    try setup.init(.sd, 512 * 1024, 4096);
    defer setup.deinit();
    const fs = &setup.fs;
    var name: [8:0]u8 = @splat(0);
    var index: u32 = 0;
    while (index < posfs.max_snapshots) : (index += 1) {
        _ = std.fmt.bufPrint(&name, "s{d}", .{index}) catch unreachable;
        try testing.expectEqual(@as(i32, 0), make(fs, &name));
    }
    try testing.expectEqual(dos.ERROR_DISK_FULL, make(fs, "more"));
    try testing.expectEqual(@as(u32, posfs.max_snapshots), (try infoOf(fs)).snapshot_count);
    try expectClean(fs);
    while (index > 0) {
        index -= 1;
        name = @splat(0);
        _ = std.fmt.bufPrint(&name, "s{d}", .{index}) catch unreachable;
        if (index != 1) try testing.expectEqual(@as(i32, 0), drop(fs, &name));
    }

    // The volume filled while a snapshot holds a big file: a write runs
    // into ERROR_DISK_FULL, and the delete of the snapshot gives the room
    // back.
    var data: [8192]u8 = undefined;
    _ = pattern(9, &data);
    var fh: FileHandle = .{};
    try testing.expectEqual(dos.DOSTRUE, openFile(fs, &fh, .findoutput, "big").res1);
    var written: u64 = 0;
    while (writeTo(fs, &fh, &data).res1 == data.len) written += data.len;
    try testing.expectEqual(dos.DOSTRUE, closeFile(fs, &fh).res1);
    try testing.expectEqual(@as(i32, 0), make(fs, "full"));
    try testing.expectEqual(@as(i32, 0), delete(fs, "big"));
    try testing.expectEqual(dos.ERROR_DISK_FULL, openFile(fs, &fh, .findoutput, "again").res2);
    try expectClean(fs);
    try testing.expectEqual(@as(i32, 0), drop(fs, "full"));
    try checkpoint.write(&fs.vol, 0);
    try checkpoint.write(&fs.vol, 0);
    try testing.expectEqual(dos.DOSTRUE, openFile(fs, &fh, .findoutput, "again").res1);
    var room: u64 = 0;
    while (writeTo(fs, &fh, &data).res1 == data.len) room += data.len;
    try testing.expectEqual(dos.DOSTRUE, closeFile(fs, &fh).res1);
    try testing.expect(room + 4 * data.len >= written);
    try expectClean(fs);
}
