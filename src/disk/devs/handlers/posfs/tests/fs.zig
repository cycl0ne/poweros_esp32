// SPDX-License-Identifier: MPL-2.0
//! posfs through its packets: files, directories, names, attributes and
//! what comes back after a mount and after replay, on every medium, the
//! check clean after each.

const std = @import("std");
const testing = std.testing;
const sdk = @import("sdk");
const dos = sdk.dos;
const posfs = dos.posfs;
const layout = posfs.layout;
const testmedia = @import("../testmedia.zig");
const TestMedia = testmedia.TestMedia;
const fs_core = @import("../fs.zig");
const check = @import("../check.zig");
const checkpoint = @import("../checkpoint.zig");
const FileSystem = fs_core.FileSystem;
const Answer = fs_core.Answer;
const FileHandle = dos.FileHandle;
const FileInfoBlock = dos.FileInfoBlock;
const DosPacket = dos.DosPacket;

pub fn send(fs: *FileSystem, action: dos.ActionCode, args: [4]isize) Answer {
    var pkt = DosPacket.init(action, .{ .raw = args ++ [3]isize{ 0, 0, 0 } });
    return fs.answer(&pkt);
}

pub fn sendArgs(fs: *FileSystem, action: dos.ActionCode, args: dos.PacketArgs) Answer {
    var pkt = DosPacket.init(action, args);
    return fs.answer(&pkt);
}

pub fn arg(value: anytype) isize {
    return @bitCast(@intFromPtr(value));
}

pub const Moved = struct { reply: Answer, answer: i64 };

pub fn sendSeek(fs: *FileSystem, action: dos.ActionCode, fh: *FileHandle, position: i64, mode: i32) Moved {
    var pkt = DosPacket.init(action, .{ .seek = .{ .fh = fh, .position = position, .mode = mode } });
    const reply = fs.answer(&pkt);
    return .{ .reply = reply, .answer = pkt.args.seek.answer };
}

pub fn openFile(fs: *FileSystem, fh: *FileHandle, action: dos.ActionCode, name: [*:0]const u8) Answer {
    return sendArgs(fs, action, .{ .find = .{ .fh = fh, .lock = null, .name = name } });
}

pub fn writeTo(fs: *FileSystem, fh: *FileHandle, bytes: []const u8) Answer {
    return sendArgs(fs, .write, .{ .io = .{ .fh = fh, .buffer = @constCast(bytes.ptr), .length = @intCast(bytes.len) } });
}

pub fn readFrom(fs: *FileSystem, fh: *FileHandle, into: []u8) Answer {
    return sendArgs(fs, .read, .{ .io = .{ .fh = fh, .buffer = into.ptr, .length = @intCast(into.len) } });
}

pub fn closeFile(fs: *FileSystem, fh: *FileHandle) Answer {
    return sendArgs(fs, .end, .{ .file = .{ .fh = fh } });
}

/// A file written from nothing, as Open/Write/Close send it.
pub fn writeFile(fs: *FileSystem, name: [*:0]const u8, bytes: []const u8) !void {
    var fh: FileHandle = .{};
    try testing.expectEqual(dos.DOSTRUE, openFile(fs, &fh, .findoutput, name).res1);
    try testing.expectEqual(@as(isize, @intCast(bytes.len)), writeTo(fs, &fh, bytes).res1);
    try testing.expectEqual(dos.DOSTRUE, closeFile(fs, &fh).res1);
}

/// What a file holds, read back.
pub fn readFile(fs: *FileSystem, name: [*:0]const u8, into: []u8) !usize {
    var fh: FileHandle = .{};
    const opened = openFile(fs, &fh, .findinput, name);
    if (opened.res1 != dos.DOSTRUE) return error.NotThere;
    const count = readFrom(fs, &fh, into);
    try testing.expectEqual(dos.DOSTRUE, closeFile(fs, &fh).res1);
    if (count.res1 < 0) return error.ReadFailed;
    return @intCast(count.res1);
}

pub fn expectClean(fs: *FileSystem) !void {
    var report: check.Report = .{};
    try check.check(&fs.vol, &report);
    if (report.errors != 0) {
        std.debug.print("check: {d} errors, first: {s} at {d}\n", .{ report.errors, report.message, report.where });
        return error.TestUnexpectedResult;
    }
}

fn nameOf(fib: *const FileInfoBlock) []const u8 {
    return std.mem.sliceTo(&fib.file_name, 0);
}

/// Bytes that say where they are, so a misplaced block shows.
pub fn pattern(seed: u64, into: []u8) []u8 {
    for (into, 0..) |*byte, index| byte.* = @truncate((index *% 7) +% (index >> 8) +% seed *% 13);
    return into;
}

pub const Setup = struct {
    m: TestMedia,
    fs: FileSystem,

    pub fn init(setup: *Setup, kind: testmedia.Kind, size: usize, block_size: u32) !void {
        try setup.initWith(kind, size, block_size, layout.VT_CHECKSUMS);
    }

    /// With the switches `settings` (VT_*) on.
    pub fn initWith(setup: *Setup, kind: testmedia.Kind, size: usize, block_size: u32, settings: u32) !void {
        setup.m = try TestMedia.init(kind, size, 1);
        setup.fs = FileSystem.init(setup.m.device());
        try setup.fs.format(.{ .block_size = block_size, .name = "Work", .settings = settings });
    }

    /// Put away and mounted again.
    pub fn remount(setup: *Setup) !void {
        try setup.fs.unmount();
        try setup.fs.mount();
        try expectClean(&setup.fs);
    }

    /// The power gone once the journal timer has run, and the medium
    /// mounted as it is: replay.
    pub fn crash(setup: *Setup) !void {
        try setup.fs.writeJournal();
        try setup.crashNow();
    }

    /// The power gone now, with what the journal holds in memory, and the
    /// medium mounted as it is: replay.
    pub fn crashNow(setup: *Setup) !void {
        setup.m.cut();
        const copy = try setup.m.image(2);
        setup.fs.deinit();
        try testing.expectEqual(@as(usize, 0), setup.m.live);
        setup.m.deinit();
        setup.m = copy;
        setup.fs = FileSystem.init(setup.m.device());
        try setup.fs.mount();
        try expectClean(&setup.fs);
    }

    pub fn deinit(setup: *Setup) void {
        setup.fs.deinit();
        testing.expectEqual(@as(usize, 0), setup.m.live) catch {};
        setup.m.deinit();
    }
};

pub const kinds = [_]testmedia.Kind{ .flash, .sd, .usb };

test "a formatted volume has an empty root with its name" {
    for (kinds) |kind| {
        var setup: Setup = undefined;
        try setup.init(kind, 1024 * 1024, 4096);
        defer setup.deinit();
        const fs = &setup.fs;
        var fib: FileInfoBlock = undefined;
        try testing.expectEqual(dos.DOSTRUE, sendArgs(fs, .examine_object, .{ .examine = .{ .lock = null, .fib = &fib } }).res1);
        try testing.expectEqualStrings("Work", nameOf(&fib));
        try testing.expectEqual(dos.ST_ROOT, fib.dir_entry_type);
        try testing.expectEqual(dos.DOSFALSE, sendArgs(fs, .examine_next, .{ .examine = .{ .lock = null, .fib = &fib } }).res1);
        try expectClean(fs);
    }
}

test "files come back after a mount, and after replay" {
    for (kinds) |kind| {
        var setup: Setup = undefined;
        try setup.init(kind, 2 * 1024 * 1024, 4096);
        defer setup.deinit();
        var big: [100_000]u8 = undefined;
        try writeFile(&setup.fs, "small", "hello");
        try writeFile(&setup.fs, "big", pattern(1, &big));
        try writeFile(&setup.fs, "empty", "");
        try expectClean(&setup.fs);
        try setup.remount();
        var back: [120_000]u8 = undefined;
        try testing.expectEqualStrings("hello", back[0..try readFile(&setup.fs, "small", &back)]);
        try testing.expectEqualSlices(u8, &big, back[0..try readFile(&setup.fs, "big", &back)]);
        try testing.expectEqual(@as(usize, 0), try readFile(&setup.fs, "empty", &back));
        // Changed and not put away: what was answered comes back.
        try writeFile(&setup.fs, "after", "replayed");
        try testing.expectEqual(dos.DOSTRUE, send(&setup.fs, .delete_object, .{ 0, arg("small"), 0, 0 }).res1);
        try setup.crash();
        try testing.expect(setup.fs.vol.replayed.records > 0);
        try testing.expectEqualStrings("replayed", back[0..try readFile(&setup.fs, "after", &back)]);
        try testing.expectError(error.NotThere, readFile(&setup.fs, "small", &back));
        try testing.expectEqualSlices(u8, &big, back[0..try readFile(&setup.fs, "big", &back)]);
        // And replayed once only: mounted again, the same.
        try setup.remount();
        try testing.expectEqualStrings("replayed", back[0..try readFile(&setup.fs, "after", &back)]);
    }
}

test "the changes of a moment go down under one barrier, and a cut takes back only those" {
    for (kinds) |kind| {
        var setup: Setup = undefined;
        try setup.init(kind, 2 * 1024 * 1024, 4096);
        defer setup.deinit();
        var data: [6000]u8 = undefined;
        var back: [8000]u8 = undefined;
        try writeFile(&setup.fs, "first", pattern(1, &data));
        try setup.fs.writeJournal();
        // Twenty files, each a create and a commit, and a directory: a
        // barrier only where the journal goes on in its next block, and
        // two when it is written - the data's, then the records'.
        const before = setup.m.updates;
        var name: [4:0]u8 = .{ 'f', 0, 0, 0 };
        for (0..20) |index| {
            name[1] = 'a' + @as(u8, @intCast(index));
            try writeFile(&setup.fs, &name, pattern(index + 2, &data));
        }
        const dir = send(&setup.fs, .create_dir, .{ 0, arg("Drawer"), 0, 0 });
        try testing.expect(dir.res1 != 0);
        _ = send(&setup.fs, .free_lock, .{ dir.res1, 0, 0, 0 });
        try testing.expect(setup.fs.journalWaits());
        try setup.fs.writeJournal();
        try testing.expect(!setup.fs.journalWaits());
        try testing.expect(setup.m.updates - before <= 4);
        // Answered and not yet written: a cut takes back those, and only
        // those.
        try writeFile(&setup.fs, "late", "lost");
        try testing.expectEqual(dos.DOSTRUE, send(&setup.fs, .delete_object, .{ 0, arg("first"), 0, 0 }).res1);
        try setup.crashNow();
        try testing.expectError(error.NotThere, readFile(&setup.fs, "late", &back));
        try testing.expectEqualSlices(u8, pattern(1, &data), back[0..try readFile(&setup.fs, "first", &back)]);
        for (0..20) |index| {
            name[1] = 'a' + @as(u8, @intCast(index));
            try testing.expectEqualSlices(u8, pattern(index + 2, &data), back[0..try readFile(&setup.fs, &name, &back)]);
        }
        try testing.expectEqual(dos.ST_USERDIR, try listedType(&setup.fs, "Drawer"));
    }
}

test "a write over the middle, a cut and a growth read right, and survive" {
    for (kinds) |kind| {
        var setup: Setup = undefined;
        try setup.init(kind, 2 * 1024 * 1024, 4096);
        defer setup.deinit();
        const fs = &setup.fs;
        var model: [50_000]u8 = undefined;
        _ = pattern(3, &model);
        try writeFile(fs, "file", &model);
        var fh: FileHandle = .{};
        try testing.expectEqual(dos.DOSTRUE, openFile(fs, &fh, .findupdate, "file").res1);
        try testing.expectEqual(dos.DOSTRUE, sendSeek(fs, .seek, &fh, 10_000, dos.OFFSET_BEGINNING).reply.res1);
        const middle = "the middle of it";
        try testing.expectEqual(@as(isize, middle.len), writeTo(fs, &fh, middle).res1);
        @memcpy(model[10_000..][0..middle.len], middle);
        // Seen by a read through the same file before it is closed.
        var back: [60_000]u8 = undefined;
        try testing.expectEqual(dos.DOSTRUE, sendSeek(fs, .seek, &fh, 0, dos.OFFSET_BEGINNING).reply.res1);
        try testing.expectEqual(@as(isize, model.len), readFrom(fs, &fh, &back).res1);
        try testing.expectEqualSlices(u8, &model, back[0..model.len]);
        // Cut inside a block, then grown: zeros past the cut.
        try testing.expectEqual(@as(i64, 20_001), sendSeek(fs, .set_file_size, &fh, 20_001, dos.OFFSET_BEGINNING).answer);
        try testing.expectEqual(@as(i64, 30_000), sendSeek(fs, .set_file_size, &fh, 30_000, dos.OFFSET_BEGINNING).answer);
        @memset(model[20_001..30_000], 0);
        try testing.expectEqual(dos.DOSTRUE, closeFile(fs, &fh).res1);
        try expectClean(fs);
        try testing.expectEqual(@as(usize, 30_000), try readFile(fs, "file", &back));
        try testing.expectEqualSlices(u8, model[0..30_000], back[0..30_000]);
        try setup.remount();
        try testing.expectEqual(@as(usize, 30_000), try readFile(&setup.fs, "file", &back));
        try testing.expectEqualSlices(u8, model[0..30_000], back[0..30_000]);
    }
}

test "a file grows past inline and shrinks back into it" {
    var setup: Setup = undefined;
    try setup.init(.sd, 1024 * 1024, 4096);
    defer setup.deinit();
    const fs = &setup.fs;
    try writeFile(fs, "grow", "tiny");
    var fh: FileHandle = .{};
    try testing.expectEqual(dos.DOSTRUE, openFile(fs, &fh, .findupdate, "grow").res1);
    try testing.expectEqual(dos.DOSTRUE, sendSeek(fs, .seek, &fh, 0, dos.OFFSET_END).reply.res1);
    var more: [9000]u8 = undefined;
    _ = pattern(5, &more);
    try testing.expectEqual(@as(isize, more.len), writeTo(fs, &fh, &more).res1);
    try testing.expectEqual(dos.DOSTRUE, closeFile(fs, &fh).res1);
    try expectClean(fs);
    var back: [10_000]u8 = undefined;
    try testing.expectEqual(@as(usize, 9004), try readFile(fs, "grow", &back));
    try testing.expectEqualStrings("tiny", back[0..4]);
    try testing.expectEqualSlices(u8, &more, back[4..9004]);
    // Cut to fit inline again.
    try testing.expectEqual(dos.DOSTRUE, openFile(fs, &fh, .findupdate, "grow").res1);
    try testing.expectEqual(@as(i64, 100), sendSeek(fs, .set_file_size, &fh, 100, dos.OFFSET_BEGINNING).answer);
    try testing.expectEqual(dos.DOSTRUE, closeFile(fs, &fh).res1);
    try expectClean(fs);
    try testing.expectEqual(@as(usize, 100), try readFile(fs, "grow", &back));
    try testing.expectEqualStrings("tiny", back[0..4]);
    try testing.expectEqualSlices(u8, more[0..96], back[4..100]);
    try setup.remount();
}

test "MODE_NEWFILE keeps the old file until it is closed" {
    var setup: Setup = undefined;
    try setup.init(.sd, 1024 * 1024, 4096);
    defer setup.deinit();
    var old: [20_000]u8 = undefined;
    try writeFile(&setup.fs, "file", pattern(7, &old));
    var fh: FileHandle = .{};
    try testing.expectEqual(dos.DOSTRUE, openFile(&setup.fs, &fh, .findoutput, "file").res1);
    try testing.expectEqual(@as(isize, 3), writeTo(&setup.fs, &fh, "new").res1);
    // The power goes with the file still open.
    try setup.crash();
    var back: [30_000]u8 = undefined;
    try testing.expectEqualSlices(u8, &old, back[0..try readFile(&setup.fs, "file", &back)]);
}

test "directories: made, walked, renamed and deleted by the rules" {
    for (kinds) |kind| {
        var setup: Setup = undefined;
        try setup.init(kind, 1024 * 1024, 4096);
        defer setup.deinit();
        const fs = &setup.fs;
        const dir = send(fs, .create_dir, .{ 0, arg("Drawer"), 0, 0 });
        try testing.expect(dir.res1 != 0);
        try testing.expectEqual(dos.ERROR_OBJECT_EXISTS, send(fs, .create_dir, .{ 0, arg("drawer"), 0, 0 }).res2);
        try testing.expectEqual(dos.DOSTRUE, send(fs, .free_lock, .{ dir.res1, 0, 0, 0 }).res1);
        try writeFile(fs, "Drawer/one", "1");
        try writeFile(fs, "drawer/Two", "22");
        const sub = send(fs, .create_dir, .{ 0, arg("Drawer/Sub"), 0, 0 });
        try testing.expectEqual(dos.DOSTRUE, send(fs, .free_lock, .{ sub.res1, 0, 0, 0 }).res1);
        // Listed: each name once.
        const lock = send(fs, .locate_object, .{ 0, arg("Drawer"), dos.SHARED_LOCK, 0 });
        var fib: FileInfoBlock = undefined;
        try testing.expectEqual(dos.DOSTRUE, sendArgs(fs, .examine_object, .{ .examine = .{ .lock = @ptrFromInt(@as(usize, @bitCast(lock.res1))), .fib = &fib } }).res1);
        try testing.expectEqualStrings("Drawer", nameOf(&fib));
        var seen: u32 = 0;
        while (sendArgs(fs, .examine_next, .{ .examine = .{ .lock = @ptrFromInt(@as(usize, @bitCast(lock.res1))), .fib = &fib } }).res1 == dos.DOSTRUE) seen += 1;
        try testing.expectEqual(@as(u32, 3), seen);
        // Not deleted while locked, nor while it has names in it.
        try testing.expectEqual(dos.ERROR_DIRECTORY_NOT_EMPTY, send(fs, .delete_object, .{ 0, arg("Drawer"), 0, 0 }).res2);
        try testing.expectEqual(dos.DOSTRUE, send(fs, .free_lock, .{ lock.res1, 0, 0, 0 }).res1);
        // Not into itself.
        try testing.expectEqual(dos.ERROR_OBJECT_IN_USE, sendArgs(fs, .rename_object, .{ .rename = .{ .from_lock = null, .from_name = "Drawer", .to_lock = null, .to_name = "Drawer/Sub/In" } }).res2);
        // Moved, and renamed in case only.
        try testing.expectEqual(dos.DOSTRUE, sendArgs(fs, .rename_object, .{ .rename = .{ .from_lock = null, .from_name = "Drawer/one", .to_lock = null, .to_name = "Drawer/Sub/One" } }).res1);
        try testing.expectEqual(dos.DOSTRUE, sendArgs(fs, .rename_object, .{ .rename = .{ .from_lock = null, .from_name = "Drawer/two", .to_lock = null, .to_name = "Drawer/TWO" } }).res1);
        try expectClean(fs);
        try setup.remount();
        var back: [8]u8 = undefined;
        try testing.expectEqualStrings("1", back[0..try readFile(&setup.fs, "drawer/sub/one", &back)]);
        try testing.expectEqualStrings("22", back[0..try readFile(&setup.fs, "Drawer/two", &back)]);
        try testing.expectEqual(dos.DOSTRUE, send(&setup.fs, .delete_object, .{ 0, arg("Drawer/Sub/One"), 0, 0 }).res1);
        try testing.expectEqual(dos.DOSTRUE, send(&setup.fs, .delete_object, .{ 0, arg("Drawer/Sub"), 0, 0 }).res1);
        try testing.expectEqual(dos.DOSTRUE, send(&setup.fs, .delete_object, .{ 0, arg("Drawer/TWO"), 0, 0 }).res1);
        try testing.expectEqual(dos.DOSTRUE, send(&setup.fs, .delete_object, .{ 0, arg("Drawer"), 0, 0 }).res1);
        try expectClean(&setup.fs);
        try setup.crash();
    }
}

test "the protection bits are kept to, and attributes come back" {
    var setup: Setup = undefined;
    try setup.init(.flash, 1024 * 1024, 4096);
    defer setup.deinit();
    const fs = &setup.fs;
    try writeFile(fs, "file", "text");
    const prop = struct {
        fn set(target: *FileSystem, action: dos.ActionCode, value: isize) Answer {
            return sendArgs(target, action, .{ .property = .{ .lock = null, .name = "file", .value = value } });
        }
    };
    try testing.expectEqual(dos.DOSTRUE, prop.set(fs, .set_protect, dos.FIBF_DELETE | dos.FIBF_READ).res1);
    try testing.expectEqual(dos.ERROR_DELETE_PROTECTED, send(fs, .delete_object, .{ 0, arg("file"), 0, 0 }).res2);
    var back: [8]u8 = undefined;
    var fh: FileHandle = .{};
    try testing.expectEqual(dos.DOSTRUE, openFile(fs, &fh, .findinput, "file").res1);
    try testing.expectEqual(dos.ERROR_READ_PROTECTED, readFrom(fs, &fh, &back).res2);
    try testing.expectEqual(dos.DOSTRUE, closeFile(fs, &fh).res1);
    try testing.expectEqual(dos.ERROR_DELETE_PROTECTED, openFile(fs, &fh, .findoutput, "file").res2);
    try testing.expectEqual(dos.DOSTRUE, prop.set(fs, .set_comment, arg("a note, gr\xfcn")).res1);
    const long = "x" ** 80;
    try testing.expectEqual(dos.ERROR_COMMENT_TOO_BIG, prop.set(fs, .set_comment, arg(long)).res2);
    var date: dos.DateStamp = .{ .days = 17000, .minute = 600, .tick = 25 };
    try testing.expectEqual(dos.DOSTRUE, prop.set(fs, .set_date, arg(&date)).res1);
    try testing.expectEqual(dos.DOSTRUE, prop.set(fs, .set_owner, (7 << 16) | 9).res1);
    try setup.crash();
    const lock = send(&setup.fs, .locate_object, .{ 0, arg("file"), dos.SHARED_LOCK, 0 });
    var fib: FileInfoBlock = undefined;
    try testing.expectEqual(dos.DOSTRUE, sendArgs(&setup.fs, .examine_object, .{ .examine = .{ .lock = @ptrFromInt(@as(usize, @bitCast(lock.res1))), .fib = &fib } }).res1);
    try testing.expectEqual(dos.FIBF_DELETE | dos.FIBF_READ, fib.protection);
    try testing.expectEqualStrings("a note, gr\xfcn", std.mem.sliceTo(&fib.comment, 0));
    try testing.expect(fib.date.eql(date));
    try testing.expectEqual(@as(u16, 7), fib.owner_uid);
    try testing.expectEqual(@as(u16, 9), fib.owner_gid);
    try testing.expectEqual(dos.DOSTRUE, send(&setup.fs, .free_lock, .{ lock.res1, 0, 0, 0 }).res1);
}

test "names: Latin-1 from dos, UTF-8 kept, folded without case, stand-ins found" {
    var setup: Setup = undefined;
    try setup.init(.sd, 1024 * 1024, 4096);
    defer setup.deinit();
    const fs = &setup.fs;
    // Latin-1 as dos has it now, stored as UTF-8 and given back as Latin-1.
    try writeFile(fs, "B\xe4r", "bear");
    var back: [8]u8 = undefined;
    try testing.expectEqualStrings("bear", back[0..try readFile(fs, "B\xc4R", &back)]);
    // UTF-8 from dos taken as it is; dos sees its stand-in, which finds it.
    try writeFile(fs, "\xe6\x97\xa5\xe6\x9c\xac.txt", "japan");
    const root = send(fs, .locate_object, .{ 0, arg(""), dos.SHARED_LOCK, 0 });
    var fib: FileInfoBlock = undefined;
    const root_lock: ?*dos.FileLock = @ptrFromInt(@as(usize, @bitCast(root.res1)));
    try testing.expectEqual(dos.DOSTRUE, sendArgs(fs, .examine_object, .{ .examine = .{ .lock = root_lock, .fib = &fib } }).res1);
    var stand_in: [dos.name_max + 1]u8 = @splat(0);
    var found_latin = false;
    while (sendArgs(fs, .examine_next, .{ .examine = .{ .lock = root_lock, .fib = &fib } }).res1 == dos.DOSTRUE) {
        const name = nameOf(&fib);
        if (std.mem.eql(u8, name, "B\xe4r")) found_latin = true;
        if (std.mem.endsWith(u8, name, ".txt")) @memcpy(stand_in[0..name.len], name);
    }
    try testing.expectEqual(dos.DOSTRUE, send(fs, .free_lock, .{ root.res1, 0, 0, 0 }).res1);
    try testing.expect(found_latin);
    try testing.expect(std.mem.indexOfScalar(u8, &stand_in, '=') != null);
    try testing.expectEqualStrings("japan", back[0..try readFile(fs, @ptrCast(&stand_in), &back)]);
    // Names posfs keeps, and ones that are none.
    try testing.expectEqual(dos.ERROR_INVALID_COMPONENT_NAME, send(fs, .create_dir, .{ 0, arg(".snapshots"), 0, 0 }).res2);
    try testing.expectEqual(dos.ERROR_INVALID_COMPONENT_NAME, send(fs, .create_dir, .{ 0, arg("a\x01b"), 0, 0 }).res2);
    try expectClean(fs);
}

test "ExNext goes on while entries come and go" {
    var setup: Setup = undefined;
    try setup.init(.sd, 2 * 1024 * 1024, 1024);
    defer setup.deinit();
    const fs = &setup.fs;
    var name_buffer: [16:0]u8 = undefined;
    for (0..200) |index| {
        const name = try std.fmt.bufPrintZ(&name_buffer, "file{d}", .{index});
        try writeFile(fs, name.ptr, "x");
    }
    try expectClean(fs);
    var fib: FileInfoBlock = undefined;
    try testing.expectEqual(dos.DOSTRUE, sendArgs(fs, .examine_object, .{ .examine = .{ .lock = null, .fib = &fib } }).res1);
    var seen = std.StringHashMap(void).init(testing.allocator);
    defer {
        var it = seen.keyIterator();
        while (it.next()) |key| testing.allocator.free(key.*);
        seen.deinit();
    }
    var step: u32 = 0;
    while (sendArgs(fs, .examine_next, .{ .examine = .{ .lock = null, .fib = &fib } }).res1 == dos.DOSTRUE) : (step += 1) {
        const copy = try testing.allocator.dupe(u8, nameOf(&fib));
        const had = try seen.fetchPut(copy, {});
        if (had != null) testing.allocator.free(copy);
        try testing.expect(had == null);
        // Meanwhile: one deleted, one made.
        const gone = try std.fmt.bufPrintZ(&name_buffer, "file{d}", .{step * 3 % 200});
        _ = send(fs, .delete_object, .{ 0, arg(gone.ptr), 0, 0 });
        const made = try std.fmt.bufPrintZ(&name_buffer, "new{d}", .{step});
        try writeFile(fs, made.ptr, "y");
    }
    try testing.expect(seen.count() >= 100);
    try expectClean(fs);
    try setup.remount();
}

test "a full volume says so at the write, and deletes free it again" {
    var setup: Setup = undefined;
    try setup.init(.sd, 512 * 1024, 4096);
    defer setup.deinit();
    const fs = &setup.fs;
    var chunk: [8192]u8 = undefined;
    _ = pattern(9, &chunk);
    var fh: FileHandle = .{};
    try testing.expectEqual(dos.DOSTRUE, openFile(fs, &fh, .findoutput, "fill").res1);
    var written: usize = 0;
    while (true) {
        const reply = writeTo(fs, &fh, &chunk);
        if (reply.res1 != chunk.len) {
            try testing.expectEqual(dos.ERROR_DISK_FULL, reply.res2);
            if (reply.res1 > 0) written += @intCast(reply.res1);
            break;
        }
        written += chunk.len;
        try testing.expect(written < 600 * 1024);
    }
    try testing.expectEqual(dos.DOSTRUE, closeFile(fs, &fh).res1);
    try expectClean(fs);
    // What went in is the file, the end of it the bytes written last.
    var back: [600 * 1024]u8 = undefined;
    try testing.expectEqual(written, try readFile(fs, "fill", &back));
    try testing.expectEqualSlices(u8, chunk[0 .. written % chunk.len], back[written - written % chunk.len .. written]);
    try testing.expectEqual(dos.DOSTRUE, send(fs, .delete_object, .{ 0, arg("fill"), 0, 0 }).res1);
    try expectClean(fs);
    // Two checkpoints later the space is back.
    try checkpoint.write(&fs.vol, 0);
    try checkpoint.write(&fs.vol, 0);
    try writeFile(fs, "again", chunk[0..4096]);
    try expectClean(fs);
    try setup.remount();
}

test "a stream of writes takes its blocks' buffers again, and gives them back when idle" {
    var setup: Setup = undefined;
    try setup.init(.sd, 4 * 1024 * 1024, 4096);
    defer setup.deinit();
    const fs = &setup.fs;
    var chunk: [64 * 1024]u8 = undefined;
    var fh: FileHandle = .{};
    try testing.expectEqual(dos.DOSTRUE, openFile(fs, &fh, .findoutput, "stream").res1);
    const before = setup.m.allocs;
    for (0..32) |index| try testing.expectEqual(@as(isize, chunk.len), writeTo(fs, &fh, pattern(index, &chunk)).res1);
    try testing.expectEqual(dos.DOSTRUE, closeFile(fs, &fh).res1);
    // 2 MiB is 512 blocks; their buffers came from at most 256 KiB's worth.
    try testing.expect(setup.m.allocs - before < 128);
    try testing.expect(fs.vol.spare_count > 0 and fs.vol.spare_count * 4096 <= 256 * 1024);
    // An idle handler gives them back (and `deinit` finds none out).
    try testing.expect(fs.pending());
    try fs.idle();
    try testing.expectEqual(@as(u32, 0), fs.vol.spare_count);
    try expectClean(fs);
    // Every block holds its own bytes, not a buffer's earlier ones.
    try setup.remount();
    var back: [64 * 1024]u8 = undefined;
    try testing.expectEqual(dos.DOSTRUE, openFile(&setup.fs, &fh, .findinput, "stream").res1);
    for (0..32) |index| {
        try testing.expectEqual(@as(isize, back.len), readFrom(&setup.fs, &fh, &back).res1);
        try testing.expectEqualSlices(u8, pattern(index, &chunk), &back);
    }
    try testing.expectEqual(dos.DOSTRUE, closeFile(&setup.fs, &fh).res1);
}

test "a file past 4 GiB: a hole, and bytes at its far end" {
    for (kinds) |kind| {
        var setup: Setup = undefined;
        try setup.init(kind, 1024 * 1024, 4096);
        defer setup.deinit();
        const far: i64 = 5 << 30;
        const tail = "the far end of a big hole";
        var fh: FileHandle = .{};
        try testing.expectEqual(dos.DOSTRUE, openFile(&setup.fs, &fh, .findoutput, "sparse").res1);
        try testing.expectEqual(far, sendSeek(&setup.fs, .set_file_size, &fh, far, dos.OFFSET_BEGINNING).answer);
        try testing.expectEqual(dos.DOSTRUE, sendSeek(&setup.fs, .seek, &fh, 0, dos.OFFSET_END).reply.res1);
        try testing.expectEqual(@as(isize, tail.len), writeTo(&setup.fs, &fh, tail).res1);
        try testing.expectEqual(dos.DOSTRUE, closeFile(&setup.fs, &fh).res1);
        try expectClean(&setup.fs);
        var round: u32 = 0;
        while (round < 3) : (round += 1) {
            const fs = &setup.fs;
            var fib: FileInfoBlock = undefined;
            const lock = send(fs, .locate_object, .{ 0, arg("sparse"), dos.SHARED_LOCK, 0 });
            try testing.expect(lock.res1 != 0);
            try testing.expectEqual(dos.DOSTRUE, sendArgs(fs, .examine_object, .{ .examine = .{ .lock = @ptrFromInt(@as(usize, @bitCast(lock.res1))), .fib = &fib } }).res1);
            _ = send(fs, .free_lock, .{ lock.res1, 0, 0, 0 });
            try testing.expectEqual(@as(u64, @intCast(far)) + tail.len, fib.size);
            try testing.expect(fib.num_blocks <= 2);
            var back: [4096]u8 = undefined;
            try testing.expectEqual(dos.DOSTRUE, openFile(fs, &fh, .findinput, "sparse").res1);
            try testing.expectEqual(dos.DOSTRUE, sendSeek(fs, .seek, &fh, far - 10, dos.OFFSET_BEGINNING).reply.res1);
            try testing.expectEqual(@as(isize, 10 + tail.len), readFrom(fs, &fh, &back).res1);
            try testing.expectEqualSlices(u8, &@as([10]u8, @splat(0)), back[0..10]);
            try testing.expectEqualStrings(tail, back[10..][0..tail.len]);
            // The hole reads as zeros, at 4 GiB as anywhere.
            try testing.expectEqual(dos.DOSTRUE, sendSeek(fs, .seek, &fh, 1 << 32, dos.OFFSET_BEGINNING).reply.res1);
            try testing.expectEqual(@as(isize, back.len), readFrom(fs, &fh, &back).res1);
            try testing.expect(std.mem.allEqual(u8, &back, 0));
            try testing.expectEqual(dos.DOSTRUE, closeFile(fs, &fh).res1);
            switch (round) {
                0 => try setup.remount(),
                1 => {
                    // A write at its far end, then the power gone.
                    try testing.expectEqual(dos.DOSTRUE, openFile(fs, &fh, .findupdate, "sparse").res1);
                    try testing.expectEqual(dos.DOSTRUE, sendSeek(fs, .seek, &fh, far, dos.OFFSET_BEGINNING).reply.res1);
                    try testing.expectEqual(@as(isize, tail.len), writeTo(fs, &fh, tail).res1);
                    try testing.expectEqual(dos.DOSTRUE, closeFile(fs, &fh).res1);
                    try setup.crash();
                },
                else => {},
            }
        }
        try testing.expectEqual(dos.DOSTRUE, send(&setup.fs, .delete_object, .{ 0, arg("sparse"), 0, 0 }).res1);
        try expectClean(&setup.fs);
        try setup.remount();
    }
}

pub fn lockOf(answer: Answer) ?*dos.FileLock {
    return @ptrFromInt(@as(usize, @bitCast(answer.res1)));
}

test "locks and handles: parents, copies, the same lock, a handle from a lock, a change of mode" {
    var setup: Setup = undefined;
    try setup.init(.sd, 1024 * 1024, 4096);
    defer setup.deinit();
    const fs = &setup.fs;
    const made = send(fs, .create_dir, .{ 0, arg("Drawer"), 0, 0 });
    try testing.expect(made.res1 != 0);
    _ = send(fs, .free_lock, .{ made.res1, 0, 0, 0 });
    try writeFile(fs, "Drawer/file", "content");
    try writeFile(fs, "alone", "x");

    // PARENT: a file's drawer, the drawer's root, and above the root none.
    const file = send(fs, .locate_object, .{ 0, arg("Drawer/file"), dos.SHARED_LOCK, 0 });
    try testing.expect(file.res1 != 0);
    const drawer = send(fs, .parent, .{ file.res1, 0, 0, 0 });
    const by_name = send(fs, .locate_object, .{ 0, arg("Drawer"), dos.SHARED_LOCK, 0 });
    try testing.expectEqual(dos.DOSTRUE, send(fs, .same_lock, .{ drawer.res1, by_name.res1, 0, 0 }).res1);
    try testing.expectEqual(dos.DOSFALSE, send(fs, .same_lock, .{ drawer.res1, file.res1, 0, 0 }).res1);
    const root = send(fs, .parent, .{ drawer.res1, 0, 0, 0 });
    var fib: FileInfoBlock = undefined;
    try testing.expectEqual(dos.DOSTRUE, sendArgs(fs, .examine_object, .{ .examine = .{ .lock = lockOf(root), .fib = &fib } }).res1);
    try testing.expectEqual(dos.ST_ROOT, fib.dir_entry_type);
    const above = send(fs, .parent, .{ root.res1, 0, 0, 0 });
    try testing.expectEqual(@as(isize, 0), above.res1);
    try testing.expectEqual(@as(i32, 0), above.res2);

    // COPY_DIR: another shared lock on the same object, and examined the
    // same; none of an exclusive one.
    const copy = send(fs, .copy_dir, .{ file.res1, 0, 0, 0 });
    try testing.expectEqual(dos.DOSTRUE, send(fs, .same_lock, .{ copy.res1, file.res1, 0, 0 }).res1);
    try testing.expectEqual(dos.DOSTRUE, sendArgs(fs, .examine_object, .{ .examine = .{ .lock = lockOf(copy), .fib = &fib } }).res1);
    try testing.expectEqualStrings("file", nameOf(&fib));
    const sole = send(fs, .locate_object, .{ 0, arg("alone"), dos.EXCLUSIVE_LOCK, 0 });
    try testing.expect(sole.res1 != 0);
    try testing.expectEqual(dos.ERROR_OBJECT_IN_USE, send(fs, .copy_dir, .{ sole.res1, 0, 0, 0 }).res2);

    // CHANGE_MODE on a lock: exclusive only while no other lock is on it.
    const change: dos.ActionCode = .change_mode;
    try testing.expectEqual(dos.ERROR_OBJECT_IN_USE, sendArgs(fs, change, .{ .change_mode = .{ .kind = dos.CHANGE_LOCK, .object = lockOf(file), .mode = dos.EXCLUSIVE_LOCK } }).res2);
    _ = send(fs, .free_lock, .{ copy.res1, 0, 0, 0 });
    try testing.expectEqual(dos.DOSTRUE, sendArgs(fs, change, .{ .change_mode = .{ .kind = dos.CHANGE_LOCK, .object = lockOf(file), .mode = dos.EXCLUSIVE_LOCK } }).res1);
    try testing.expectEqual(dos.ERROR_OBJECT_IN_USE, send(fs, .locate_object, .{ 0, arg("Drawer/file"), dos.SHARED_LOCK, 0 }).res2);
    try testing.expectEqual(dos.DOSTRUE, sendArgs(fs, change, .{ .change_mode = .{ .kind = dos.CHANGE_LOCK, .object = lockOf(file), .mode = dos.SHARED_LOCK } }).res1);
    const again = send(fs, .locate_object, .{ 0, arg("Drawer/file"), dos.SHARED_LOCK, 0 });
    try testing.expect(again.res1 != 0);
    _ = send(fs, .free_lock, .{ again.res1, 0, 0, 0 });

    // FH_FROM_LOCK: the lock becomes the handle's; a drawer's cannot.
    var fh: FileHandle = .{};
    try testing.expectEqual(dos.ERROR_OBJECT_WRONG_TYPE, sendArgs(fs, .fh_from_lock, .{ .fh_from_lock = .{ .fh = &fh, .lock = lockOf(by_name) } }).res2);
    try testing.expectEqual(dos.DOSTRUE, sendArgs(fs, .fh_from_lock, .{ .fh_from_lock = .{ .fh = &fh, .lock = lockOf(file) } }).res1);
    var back: [16]u8 = undefined;
    try testing.expectEqual(@as(isize, 7), readFrom(fs, &fh, &back).res1);
    try testing.expectEqualStrings("content", back[0..7]);
    // EXAMINE_FH, PARENT_FH and COPY_DIR_FH through the handle.
    try testing.expectEqual(dos.DOSTRUE, sendArgs(fs, .examine_fh, .{ .examine_fh = .{ .fh = &fh, .fib = &fib } }).res1);
    try testing.expectEqualStrings("file", nameOf(&fib));
    try testing.expectEqual(@as(u64, 7), fib.size);
    const up = sendArgs(fs, .parent_fh, .{ .file = .{ .fh = &fh } });
    try testing.expectEqual(dos.DOSTRUE, send(fs, .same_lock, .{ up.res1, by_name.res1, 0, 0 }).res1);
    const twin = sendArgs(fs, .copy_dir_fh, .{ .file = .{ .fh = &fh } });
    try testing.expectEqual(dos.DOSTRUE, sendArgs(fs, .examine_object, .{ .examine = .{ .lock = lockOf(twin), .fib = &fib } }).res1);
    try testing.expectEqualStrings("file", nameOf(&fib));
    // The handle's own lock is not given back as a lock while it is open.
    try testing.expectEqual(dos.ERROR_INVALID_LOCK, send(fs, .free_lock, .{ file.res1, 0, 0, 0 }).res2);

    // CHANGE_MODE on a handle: MODE_NEWFILE only while it is the only one.
    try testing.expectEqual(dos.ERROR_OBJECT_IN_USE, sendArgs(fs, change, .{ .change_mode = .{ .kind = dos.CHANGE_FH, .object = &fh, .mode = dos.MODE_NEWFILE } }).res2);
    _ = send(fs, .free_lock, .{ twin.res1, 0, 0, 0 });
    try testing.expectEqual(dos.DOSTRUE, sendArgs(fs, change, .{ .change_mode = .{ .kind = dos.CHANGE_FH, .object = &fh, .mode = dos.MODE_NEWFILE } }).res1);
    var other: FileHandle = .{};
    try testing.expectEqual(dos.ERROR_OBJECT_IN_USE, openFile(fs, &other, .findinput, "Drawer/file").res2);
    try testing.expectEqual(dos.DOSTRUE, closeFile(fs, &fh).res1);
    try testing.expectEqual(dos.DOSTRUE, openFile(fs, &other, .findinput, "Drawer/file").res1);
    try testing.expectEqual(dos.DOSTRUE, closeFile(fs, &other).res1);

    for ([_]Answer{ drawer, by_name, root, up, sole }) |held| _ = send(fs, .free_lock, .{ held.res1, 0, 0, 0 });
    try testing.expect(fs.locks == null);
    try expectClean(fs);
}

fn readLink(fs: *FileSystem, path: [*:0]const u8, into: []u8) Answer {
    return send(fs, .read_link, .{ 0, arg(path), arg(into.ptr), @intCast(into.len) });
}

fn softLink(fs: *FileSystem, name: [*:0]const u8, target: [*:0]const u8) Answer {
    return send(fs, .make_link, .{ 0, arg(name), arg(target), dos.LINK_SOFT });
}

/// The type the root's entry `name` is listed with.
pub fn listedType(fs: *FileSystem, name: []const u8) !i32 {
    var fib: FileInfoBlock = undefined;
    try testing.expectEqual(dos.DOSTRUE, sendArgs(fs, .examine_object, .{ .examine = .{ .lock = null, .fib = &fib } }).res1);
    while (sendArgs(fs, .examine_next, .{ .examine = .{ .lock = null, .fib = &fib } }).res1 == dos.DOSTRUE) {
        if (std.mem.eql(u8, nameOf(&fib), name)) return fib.dir_entry_type;
    }
    return error.NotListed;
}

test "soft links: met in a path, resolved by READ_LINK, acted on themselves" {
    for (kinds) |kind| {
        var setup: Setup = undefined;
        try setup.init(kind, 1024 * 1024, 4096);
        defer setup.deinit();
        const fs = &setup.fs;
        const dir = send(fs, .create_dir, .{ 0, arg("Drawer"), 0, 0 });
        try testing.expectEqual(dos.DOSTRUE, send(fs, .free_lock, .{ dir.res1, 0, 0, 0 }).res1);
        const sub = send(fs, .create_dir, .{ 0, arg("Drawer/Sub"), 0, 0 });
        try testing.expectEqual(dos.DOSTRUE, send(fs, .free_lock, .{ sub.res1, 0, 0, 0 }).res1);
        try writeFile(fs, "Drawer/file", "content");
        try writeFile(fs, "Drawer/\xce\xa9", "omega");
        try testing.expectEqual(dos.DOSTRUE, softLink(fs, "lnk", "Drawer").res1);
        try testing.expectEqual(dos.DOSTRUE, softLink(fs, "abs", "Work:Drawer/file").res1);
        try testing.expectEqual(dos.DOSTRUE, softLink(fs, "top", ":Drawer").res1);
        try testing.expectEqual(dos.DOSTRUE, softLink(fs, "Drawer/Sub/up", "/file").res1);
        try testing.expectEqual(dos.DOSTRUE, softLink(fs, "lat", "Drawer/\xe9t\xe9").res1);
        try testing.expectEqual(dos.DOSTRUE, softLink(fs, "om", "Drawer/\xce\xa9").res1);
        try testing.expectEqual(dos.ERROR_OBJECT_EXISTS, softLink(fs, "LNK", "elsewhere").res2);
        try testing.expectEqual(dos.ERROR_INVALID_COMPONENT_NAME, softLink(fs, "empty", "").res2);
        try testing.expectEqual(dos.ST_SOFTLINK, try listedType(fs, "lnk"));
        try expectClean(fs);

        // A lock, an open and a path through it answer IS_SOFT_LINK.
        try testing.expectEqual(dos.ERROR_IS_SOFT_LINK, send(fs, .locate_object, .{ 0, arg("lnk"), dos.SHARED_LOCK, 0 }).res2);
        try testing.expectEqual(dos.ERROR_IS_SOFT_LINK, send(fs, .locate_object, .{ 0, arg("lnk/file"), dos.SHARED_LOCK, 0 }).res2);
        var fh: FileHandle = .{};
        try testing.expectEqual(dos.ERROR_IS_SOFT_LINK, openFile(fs, &fh, .findinput, "abs").res2);
        try testing.expectEqual(dos.ERROR_IS_SOFT_LINK, openFile(fs, &fh, .findoutput, "lnk/new").res2);
        try testing.expectEqual(dos.ERROR_IS_SOFT_LINK, send(fs, .create_dir, .{ 0, arg("lnk/Made"), 0, 0 }).res2);

        // READ_LINK: the name again, from the same place.
        var path: [dos.path_max + 1]u8 = undefined;
        try testing.expectEqual(@as(isize, 11), readLink(fs, "lnk/file", &path).res1);
        try testing.expectEqualStrings("Drawer/file", std.mem.sliceTo(&path, 0));
        try testing.expectEqual(@as(isize, 16), readLink(fs, "DH1:abs", &path).res1);
        try testing.expectEqualStrings("Work:Drawer/file", std.mem.sliceTo(&path, 0));
        _ = readLink(fs, "top/file", &path);
        try testing.expectEqualStrings(":Drawer/file", std.mem.sliceTo(&path, 0));
        _ = readLink(fs, "Drawer/Sub/up", &path);
        try testing.expectEqualStrings("Drawer/Sub//file", std.mem.sliceTo(&path, 0));
        _ = readLink(fs, "lat", &path);
        try testing.expectEqualStrings("Drawer/\xe9t\xe9", std.mem.sliceTo(&path, 0));
        var back: [16]u8 = undefined;
        _ = readLink(fs, "lnk/file", &path);
        try testing.expectEqualStrings("content", back[0..try readFile(fs, @ptrCast(&path), &back)]);
        _ = readLink(fs, "Drawer/Sub/up", &path);
        try testing.expectEqualStrings("content", back[0..try readFile(fs, @ptrCast(&path), &back)]);
        // A name past Latin-1 comes back as its stand-in, which opens it.
        _ = readLink(fs, "om", &path);
        try testing.expectEqualStrings("omega", back[0..try readFile(fs, @ptrCast(&path), &back)]);
        // No link on the way, a missing name, a buffer too small.
        const plain = readLink(fs, "Drawer/file", &path);
        try testing.expectEqual(@as(isize, -1), plain.res1);
        try testing.expectEqual(dos.ERROR_OBJECT_WRONG_TYPE, plain.res2);
        try testing.expectEqual(dos.ERROR_OBJECT_NOT_FOUND, readLink(fs, "none/lnk", &path).res2);
        const small = readLink(fs, "lnk/file", path[0..11]);
        try testing.expectEqual(@as(isize, -2), small.res1);
        try testing.expectEqual(dos.ERROR_BUFFER_OVERFLOW, small.res2);

        // Rename, protect and delete act on the link itself.
        try testing.expectEqual(dos.DOSTRUE, sendArgs(fs, .rename_object, .{ .rename = .{ .from_lock = null, .from_name = "lnk", .to_lock = null, .to_name = "Link" } }).res1);
        try testing.expectEqual(dos.DOSTRUE, send(fs, .set_protect, .{ 0, arg("top"), dos.FIBF_WRITE, 0 }).res1);
        try testing.expectEqual(dos.DOSTRUE, send(fs, .delete_object, .{ 0, arg("abs"), 0, 0 }).res1);
        try testing.expectEqualStrings("content", back[0..try readFile(fs, "Drawer/file", &back)]);
        try expectClean(fs);

        // They come back after replay and after a mount.
        try setup.crash();
        _ = readLink(&setup.fs, "Link/file", &path);
        try testing.expectEqualStrings("Drawer/file", std.mem.sliceTo(&path, 0));
        try testing.expectEqual(dos.ERROR_OBJECT_NOT_FOUND, readLink(&setup.fs, "abs", &path).res2);
        try setup.remount();
        _ = readLink(&setup.fs, "top", &path);
        try testing.expectEqualStrings(":Drawer", std.mem.sliceTo(&path, 0));
    }
}

test "hard links: another name for a file, gone with its last name, none for a directory" {
    for (kinds) |kind| {
        var setup: Setup = undefined;
        try setup.init(kind, 1024 * 1024, 4096);
        defer setup.deinit();
        const fs = &setup.fs;
        var big: [9000]u8 = undefined;
        try writeFile(fs, "a", pattern(3, &big));
        const dir = send(fs, .create_dir, .{ 0, arg("Drawer"), 0, 0 });
        try testing.expectEqual(dos.DOSTRUE, send(fs, .free_lock, .{ dir.res1, 0, 0, 0 }).res1);

        const file = send(fs, .locate_object, .{ 0, arg("a"), dos.SHARED_LOCK, 0 });
        try testing.expect(file.res1 != 0);
        try testing.expectEqual(dos.DOSTRUE, send(fs, .make_link, .{ 0, arg("Drawer/b"), file.res1, dos.LINK_HARD }).res1);
        try testing.expectEqual(dos.ERROR_OBJECT_EXISTS, send(fs, .make_link, .{ 0, arg("a"), file.res1, dos.LINK_HARD }).res2);
        try testing.expectEqual(dos.DOSTRUE, send(fs, .free_lock, .{ file.res1, 0, 0, 0 }).res1);
        const drawer = send(fs, .locate_object, .{ 0, arg("Drawer"), dos.SHARED_LOCK, 0 });
        try testing.expectEqual(dos.ERROR_OBJECT_WRONG_TYPE, send(fs, .make_link, .{ 0, arg("d"), drawer.res1, dos.LINK_HARD }).res2);
        try testing.expectEqual(dos.DOSTRUE, send(fs, .free_lock, .{ drawer.res1, 0, 0, 0 }).res1);
        try testing.expectEqual(dos.ERROR_INVALID_LOCK, send(fs, .make_link, .{ 0, arg("z"), 0, dos.LINK_HARD }).res2);
        try testing.expectEqual(dos.ST_FILE, try listedType(fs, "a"));
        try expectClean(fs);

        // Either name opens it; a write through one is seen through the other.
        var back: [10_000]u8 = undefined;
        try testing.expectEqualSlices(u8, &big, back[0..try readFile(fs, "Drawer/b", &back)]);
        try writeFile(fs, "Drawer/b", "bye");
        try testing.expectEqualStrings("bye", back[0..try readFile(fs, "a", &back)]);

        // A name a lock came through stays; another goes, and the object
        // with its last name.
        const held = send(fs, .locate_object, .{ 0, arg("Drawer/b"), dos.SHARED_LOCK, 0 });
        try testing.expectEqual(dos.ERROR_OBJECT_IN_USE, send(fs, .delete_object, .{ 0, arg("Drawer/b"), 0, 0 }).res2);
        try testing.expectEqual(dos.DOSTRUE, send(fs, .delete_object, .{ 0, arg("a"), 0, 0 }).res1);
        try expectClean(fs);
        try testing.expectEqual(dos.DOSTRUE, send(fs, .free_lock, .{ held.res1, 0, 0, 0 }).res1);
        try testing.expectEqualStrings("bye", back[0..try readFile(fs, "Drawer/b", &back)]);

        // A new name, then the power gone: both after replay.
        const again = send(fs, .locate_object, .{ 0, arg("Drawer/b"), dos.SHARED_LOCK, 0 });
        try testing.expectEqual(dos.DOSTRUE, send(fs, .make_link, .{ 0, arg("c"), again.res1, dos.LINK_HARD }).res1);
        try testing.expectEqual(dos.DOSTRUE, send(fs, .free_lock, .{ again.res1, 0, 0, 0 }).res1);
        try setup.crash();
        try testing.expectEqualStrings("bye", back[0..try readFile(&setup.fs, "c", &back)]);
        try testing.expectEqualStrings("bye", back[0..try readFile(&setup.fs, "Drawer/b", &back)]);
        try testing.expectEqual(dos.DOSTRUE, send(&setup.fs, .delete_object, .{ 0, arg("Drawer/b"), 0, 0 }).res1);
        try testing.expectEqual(dos.DOSTRUE, send(&setup.fs, .delete_object, .{ 0, arg("c"), 0, 0 }).res1);
        try expectClean(&setup.fs);
        try setup.remount();
        try testing.expectError(error.NotThere, readFile(&setup.fs, "c", &back));
    }
}

/// The blocks a file takes, as Examine says.
pub fn blocksOf(fs: *FileSystem, name: [*:0]const u8) !u64 {
    const lock = send(fs, .locate_object, .{ 0, arg(name), dos.SHARED_LOCK, 0 });
    try testing.expect(lock.res1 != 0);
    defer _ = send(fs, .free_lock, .{ lock.res1, 0, 0, 0 });
    var fib: FileInfoBlock = undefined;
    try testing.expectEqual(dos.DOSTRUE, sendArgs(fs, .examine_object, .{ .examine = .{ .lock = @ptrFromInt(@as(usize, @bitCast(lock.res1))), .fib = &fib } }).res1);
    return fib.num_blocks;
}

test "checksums: a block changed on the medium is ERROR_BAD_CHECKSUM, never its bytes" {
    const marker = "posfs: damage me";
    for (kinds) |kind| {
        var setup: Setup = undefined;
        try setup.init(kind, 1024 * 1024, 4096);
        defer setup.deinit();
        var data: [20_000]u8 = undefined;
        _ = pattern(5, &data);
        @memcpy(data[4096..][0..marker.len], marker);
        try writeFile(&setup.fs, "file", &data);
        try setup.fs.writeJournal();
        // The file's second block, found on the medium by what it holds.
        const at = std.mem.indexOf(u8, setup.m.bytes, marker) orelse return error.TestUnexpectedResult;
        setup.m.bytes[at + 100] ^= 0x10;
        var back: [20_000]u8 = undefined;
        var fh: FileHandle = .{};
        try testing.expectEqual(dos.DOSTRUE, openFile(&setup.fs, &fh, .findinput, "file").res1);
        try testing.expectEqual(@as(isize, 4096), readFrom(&setup.fs, &fh, back[0..4096]).res1);
        // Neither a part of it nor all of it.
        const part = readFrom(&setup.fs, &fh, back[0..10]);
        try testing.expectEqual(@as(isize, -1), part.res1);
        try testing.expectEqual(dos.ERROR_BAD_CHECKSUM, part.res2);
        try testing.expectEqual(@as(isize, -1), readFrom(&setup.fs, &fh, back[0..8192]).res1);
        try testing.expectEqual(dos.DOSTRUE, closeFile(&setup.fs, &fh).res1);
        // Put right, it reads again.
        setup.m.bytes[at + 100] ^= 0x10;
        try testing.expectEqualSlices(u8, &data, back[0..try readFile(&setup.fs, "file", &back)]);
        try expectClean(&setup.fs);
    }
}

test "checksums on the other cores: a long run's worked out beside its write, a long read checked in parts, a block changed found" {
    const marker = "posfs: damage me";
    for (kinds) |kind| {
        var setup: Setup = undefined;
        try setup.init(kind, 2 * 1024 * 1024, 4096);
        defer setup.deinit();
        const data = try testing.allocator.alloc(u8, 300_000);
        defer testing.allocator.free(data);
        const back = try testing.allocator.alloc(u8, 300_000);
        defer testing.allocator.free(back);
        _ = pattern(11, data);
        @memcpy(data[40 * 4096 ..][0..marker.len], marker);
        try writeFile(&setup.fs, "long", data);
        // The runs went to the medium with their crcs worked out in parts.
        const written = setup.m.works;
        try testing.expect(written != 0);
        try setup.fs.writeJournal();
        const at = std.mem.indexOf(u8, setup.m.bytes, marker) orelse return error.TestUnexpectedResult;
        setup.m.bytes[at + 100] ^= 0x10;
        try testing.expectError(error.ReadFailed, readFile(&setup.fs, "long", back));
        setup.m.bytes[at + 100] ^= 0x10;
        try testing.expectEqualSlices(u8, data, back[0..try readFile(&setup.fs, "long", back)]);
        // Read through the device, not as memory: checked in parts.
        if (!setup.m.direct) try testing.expect(setup.m.works > written);
        try setup.remount();
        try testing.expectEqualSlices(u8, data, back[0..try readFile(&setup.fs, "long", back)]);
        try expectClean(&setup.fs);
    }
}

test "without checksums: data written and read the same, and the switch on later" {
    var setup: Setup = undefined;
    try setup.initWith(.sd, 1024 * 1024, 4096, 0);
    defer setup.deinit();
    const fs = &setup.fs;
    var data: [30_000]u8 = undefined;
    try writeFile(fs, "plain", pattern(9, &data));
    fs.vol.voltab.flags |= layout.VT_CHECKSUMS;
    try writeFile(fs, "summed", pattern(10, &data));
    try expectClean(fs);
    try setup.remount();
    var back: [30_000]u8 = undefined;
    try testing.expectEqualSlices(u8, pattern(9, &data), back[0..try readFile(&setup.fs, "plain", &back)]);
    try testing.expectEqualSlices(u8, pattern(10, &data), back[0..try readFile(&setup.fs, "summed", &back)]);
}

test "compression: chunks in fewer blocks, written over in part, cut, grown, and back after replay" {
    const text = "the quick brown fox jumps over the lazy dog. ";
    for (kinds) |kind| {
        var setup: Setup = undefined;
        try setup.initWith(kind, 2 * 1024 * 1024, 4096, layout.VT_CHECKSUMS | layout.VT_COMPRESS);
        defer setup.deinit();
        const fs = &setup.fs;
        var model: [200_000]u8 = undefined;
        for (&model, 0..) |*byte, index| byte.* = text[index % text.len];
        try writeFile(fs, "text", &model);
        // Three whole chunks in a block each, and the last block as it is.
        try testing.expectEqual(@as(u64, 4), try blocksOf(fs, "text"));
        try expectClean(fs);
        var back: [200_000]u8 = undefined;
        try testing.expectEqualSlices(u8, &model, back[0..try readFile(fs, "text", &back)]);

        // A few bytes in the second chunk, and the file cut inside the third.
        var fh: FileHandle = .{};
        try testing.expectEqual(dos.DOSTRUE, openFile(fs, &fh, .findupdate, "text").res1);
        try testing.expectEqual(dos.DOSTRUE, sendSeek(fs, .seek, &fh, 70_000, dos.OFFSET_BEGINNING).reply.res1);
        try testing.expectEqual(@as(isize, 7), writeTo(fs, &fh, "CHANGED").res1);
        try testing.expectEqual(@as(i64, 150_000), sendSeek(fs, .set_file_size, &fh, 150_000, dos.OFFSET_BEGINNING).answer);
        // Read through the handle before the close: the overlay's chunk.
        try testing.expectEqual(dos.DOSTRUE, sendSeek(fs, .seek, &fh, 69_990, dos.OFFSET_BEGINNING).reply.res1);
        try testing.expectEqual(@as(isize, 30), readFrom(fs, &fh, back[0..30]).res1);
        @memcpy(model[70_000..][0..7], "CHANGED");
        try testing.expectEqualSlices(u8, model[69_990..70_020], back[0..30]);
        try testing.expectEqual(dos.DOSTRUE, closeFile(fs, &fh).res1);
        try testing.expectEqual(@as(usize, 150_000), try readFile(fs, "text", &back));
        try testing.expectEqualSlices(u8, model[0..150_000], back[0..150_000]);
        try expectClean(fs);

        // Grown again: zeros where it was cut.
        try testing.expectEqual(dos.DOSTRUE, openFile(fs, &fh, .findupdate, "text").res1);
        try testing.expectEqual(@as(i64, 160_000), sendSeek(fs, .set_file_size, &fh, 160_000, dos.OFFSET_BEGINNING).answer);
        try testing.expectEqual(dos.DOSTRUE, closeFile(fs, &fh).res1);
        @memset(model[150_000..160_000], 0);
        try testing.expectEqualSlices(u8, model[0..160_000], back[0..try readFile(fs, "text", &back)]);

        try setup.crash();
        try testing.expectEqualSlices(u8, model[0..160_000], back[0..try readFile(&setup.fs, "text", &back)]);
        try setup.remount();

        // Data that does not compress is stored as it is.
        var prng = std.Random.DefaultPrng.init(77);
        var noise: [100_000]u8 = undefined;
        prng.random().bytes(&noise);
        try writeFile(&setup.fs, "noise", &noise);
        try testing.expectEqual(@as(u64, 25), try blocksOf(&setup.fs, "noise"));
        try testing.expectEqualSlices(u8, &noise, back[0..try readFile(&setup.fs, "noise", &back)]);
        try expectClean(&setup.fs);
    }
}

// --- posfs's own packets ---------------------------------------------------------------

const packets = posfs.packets;
const space = @import("../space.zig");

pub fn sendOwn(fs: *FileSystem, action: i32, structure: anytype) Answer {
    var pkt = DosPacket.init(@enumFromInt(action), .{ .raw = .{ arg(structure), 0, 0, 0, 0, 0, 0 } });
    return fs.answer(&pkt);
}

pub fn infoOf(fs: *FileSystem) !packets.Info {
    var info: packets.Info = .{};
    try testing.expectEqual(dos.DOSTRUE, sendOwn(fs, packets.ACTION_POSFS_INFO, &info).res1);
    return info;
}

/// A whole check, a slice at a time, `between` called after each slice
/// that leaves more: the last answer, and the slices it took.
fn checkAll(fs: *FileSystem, flags: u32, context: anytype, comptime between: ?fn (@TypeOf(context), *FileSystem) anyerror!void) !struct { args: packets.CheckArgs, slices: u32 } {
    var args: packets.CheckArgs = .{ .flags = flags };
    var slices: u32 = 0;
    while (true) {
        const reply = sendOwn(fs, packets.ACTION_POSFS_CHECK, &args);
        if (reply.res1 != dos.DOSTRUE) {
            std.debug.print("check: refused, {d}\n", .{reply.res2});
            return error.TestUnexpectedResult;
        }
        slices += 1;
        if (args.cursor == 0) return .{ .args = args, .slices = slices };
        if (between) |call| try call(context, fs);
    }
}

test "posfs INFO: the format, the switches, and blocks that add up" {
    for (kinds) |kind| {
        var setup: Setup = undefined;
        try setup.init(kind, 1024 * 1024, 4096);
        defer setup.deinit();
        const fs = &setup.fs;
        var data: [50_000]u8 = undefined;
        try writeFile(fs, "file", pattern(3, &data));
        const info = try infoOf(fs);
        try testing.expectEqual(@as(u32, 4096), info.block_size);
        try testing.expectEqual(layout.format_version, info.version);
        try testing.expectEqual(packets.SET_CHECKSUMS, info.settings);
        try testing.expectEqual(fs.vol.block_count, info.blocks);
        try testing.expectEqual(info.blocks, info.live + info.snapshots + info.recycled + info.pending + info.reserve + info.free);
        try testing.expectEqual(@as(u64, 0), info.last_check);
        try testing.expect(info.gen != 0 and info.journal_limit != 0);
        if (kind != .flash) try testing.expectEqual(@as(u32, 0), info.erased);

        // A structure shorter than this one's: only what it holds is
        // filled, its size kept.
        var short: packets.Info = .{ .size = 12 };
        try testing.expectEqual(dos.DOSTRUE, sendOwn(fs, packets.ACTION_POSFS_INFO, &short).res1);
        try testing.expectEqual(@as(u32, 12), short.size);
        try testing.expectEqual(layout.format_version, short.version);
        try testing.expectEqual(@as(u32, 4096), short.block_size);
        try testing.expectEqual(@as(u32, 0), short.write_unit);
        var none: packets.Info = .{ .size = 0 };
        try testing.expectEqual(dos.ERROR_INVALID_ARGUMENT, sendOwn(fs, packets.ACTION_POSFS_INFO, &none).res2);

        // An action of no one's.
        try testing.expectEqual(dos.ERROR_ACTION_NOT_KNOWN, sendOwn(fs, packets.ACTION_POSFS_CHECK + 100, &none).res2);
    }
}

test "posfs SETTINGS: durable when answered, followed by what is written after" {
    var setup: Setup = undefined;
    try setup.init(.sd, 2 * 1024 * 1024, 4096);
    defer setup.deinit();
    const fs = &setup.fs;
    const text = "the quick brown fox jumps over the lazy dog. ";
    var model: [100_000]u8 = undefined;
    for (&model, 0..) |*byte, index| byte.* = text[index % text.len];
    try writeFile(fs, "before", &model);
    try testing.expectEqual(@as(u64, 25), try blocksOf(fs, "before"));

    var on: packets.Settings = .{ .mask = packets.SET_COMPRESS, .settings = packets.SET_COMPRESS };
    try testing.expectEqual(dos.DOSTRUE, sendOwn(fs, packets.ACTION_POSFS_SETTINGS, &on).res1);
    try testing.expectEqual(packets.SET_CHECKSUMS | packets.SET_COMPRESS, (try infoOf(fs)).settings);
    // Durable at once: the power gone right after keeps it.
    try setup.crashNow();
    try testing.expectEqual(packets.SET_CHECKSUMS | packets.SET_COMPRESS, (try infoOf(&setup.fs)).settings);
    try writeFile(&setup.fs, "after", &model);
    try testing.expect(try blocksOf(&setup.fs, "after") < 4);
    try testing.expectEqual(@as(u64, 25), try blocksOf(&setup.fs, "before"));

    // Checksums off: the other switch as it was.
    var off: packets.Settings = .{ .mask = packets.SET_CHECKSUMS, .settings = 0 };
    try testing.expectEqual(dos.DOSTRUE, sendOwn(&setup.fs, packets.ACTION_POSFS_SETTINGS, &off).res1);
    try setup.remount();
    try testing.expectEqual(packets.SET_COMPRESS, (try infoOf(&setup.fs)).settings);
    var back: [100_000]u8 = undefined;
    try testing.expectEqualSlices(u8, &model, back[0..try readFile(&setup.fs, "before", &back)]);
    try testing.expectEqualSlices(u8, &model, back[0..try readFile(&setup.fs, "after", &back)]);

    var unknown: packets.Settings = .{ .mask = 1 << 9, .settings = 1 << 9 };
    try testing.expectEqual(dos.ERROR_INVALID_ARGUMENT, sendOwn(&setup.fs, packets.ACTION_POSFS_SETTINGS, &unknown).res2);
}

/// Between check slices: files deleted and written and checkpoints
/// written, the allocator sent back to the volume's start each time, so
/// the blocks the checked checkpoint names would be handed out again at
/// once but for the pin.
const Churn = struct {
    round: u32 = 0,
    data: [40_000]u8 = undefined,

    fn between(churn: *Churn, fs: *FileSystem) !void {
        churn.round += 1;
        if (churn.round == 1) _ = send(fs, .delete_object, .{ 0, arg("big"), 0, 0 });
        var name_buffer: [16]u8 = undefined;
        const name = try std.fmt.bufPrintZ(&name_buffer, "churn{d}", .{churn.round % 4});
        _ = send(fs, .delete_object, .{ 0, arg(name.ptr), 0, 0 });
        try writeFile(fs, name.ptr, pattern(churn.round, &churn.data));
        try checkpoint.write(&fs.vol, 0);
        try checkpoint.write(&fs.vol, 0);
        fs.vol.space.cursor = 0;
    }
};

test "posfs CHECK: in slices while the volume changes, the checkpoint it reads kept whole" {
    for (kinds) |kind| {
        var setup: Setup = undefined;
        try setup.init(kind, 2 * 1024 * 1024, 4096);
        defer setup.deinit();
        const fs = &setup.fs;
        var data: [120_000]u8 = undefined;
        try writeFile(fs, "big", pattern(1, &data));
        for (0..12) |index| {
            var name_buffer: [16]u8 = undefined;
            const name = try std.fmt.bufPrintZ(&name_buffer, "file{d}", .{index});
            try writeFile(fs, name.ptr, pattern(index, data[0 .. 3000 * index + 10]));
        }
        _ = send(fs, .create_dir, .{ 0, arg("dir"), 0, 0 });

        // Slices of a few steps each.
        fs.check_slice = 10_000;
        var churn: Churn = .{};
        const result = try checkAll(fs, packets.CHECK_DATA, &churn, Churn.between);
        if (result.args.errors != 0) std.debug.print("check: {s}\n", .{std.mem.sliceTo(&result.args.message, 0)});
        try testing.expectEqual(@as(u32, 0), result.args.errors);
        try testing.expect(result.slices > 2);
        try testing.expect(result.args.objects >= 14 and result.args.nodes > 0);
        try testing.expect(result.args.data_blocks >= 30);
        // Done: the pin let go, the time kept.
        try testing.expect(!fs.vol.space.pin and fs.vol.space.pinned.len == 0 and fs.checking == null);
        try testing.expect((try infoOf(fs)).last_check != 0);
        try expectClean(fs);
        try setup.remount();
        try testing.expect((try infoOf(&setup.fs)).last_check != 0);
    }
}

test "posfs CHECK DATA: a block changed on the medium is found, by the data pass only" {
    const marker = "posfs: damage me";
    for (kinds) |kind| {
        var setup: Setup = undefined;
        try setup.init(kind, 1024 * 1024, 4096);
        defer setup.deinit();
        const fs = &setup.fs;
        var data: [20_000]u8 = undefined;
        _ = pattern(5, &data);
        @memcpy(data[4096..][0..marker.len], marker);
        try writeFile(fs, "file", &data);
        try fs.writeJournal();
        const at = std.mem.indexOf(u8, setup.m.bytes, marker) orelse return error.TestUnexpectedResult;
        setup.m.bytes[at + 100] ^= 0x10;
        const quick = try checkAll(fs, 0, {}, null);
        try testing.expectEqual(@as(u32, 0), quick.args.errors);
        const full = try checkAll(fs, packets.CHECK_DATA, {}, null);
        try testing.expectEqual(@as(u32, 1), full.args.errors);
        try testing.expect(std.mem.startsWith(u8, &full.args.message, "a block of a file's data is not what was written: "));
        setup.m.bytes[at + 100] ^= 0x10;
    }
}

test "posfs CHECK: stopped, taken over, timed out, and given up for room" {
    var setup: Setup = undefined;
    try setup.init(.sd, 512 * 1024, 4096);
    defer setup.deinit();
    const fs = &setup.fs;
    fs.check_slice = 3000;
    var data: [300_000]u8 = undefined;
    try writeFile(fs, "a", pattern(1, &data));

    // Stopped: the pin let go.
    var args: packets.CheckArgs = .{};
    try testing.expectEqual(dos.DOSTRUE, sendOwn(fs, packets.ACTION_POSFS_CHECK, &args).res1);
    try testing.expect(args.cursor != 0 and fs.vol.space.pin);
    const first = args.cursor;
    args.flags = packets.CHECK_STOP;
    try testing.expectEqual(dos.DOSTRUE, sendOwn(fs, packets.ACTION_POSFS_CHECK, &args).res1);
    try testing.expect(args.cursor == 0 and !fs.vol.space.pin and fs.checking == null);
    // A cursor no longer known.
    args = .{ .cursor = first };
    try testing.expectEqual(dos.ERROR_INVALID_ARGUMENT, sendOwn(fs, packets.ACTION_POSFS_CHECK, &args).res2);

    // A second start takes over from the first.
    args = .{};
    try testing.expectEqual(dos.DOSTRUE, sendOwn(fs, packets.ACTION_POSFS_CHECK, &args).res1);
    const older = args.cursor;
    args = .{};
    try testing.expectEqual(dos.DOSTRUE, sendOwn(fs, packets.ACTION_POSFS_CHECK, &args).res1);
    var stale: packets.CheckArgs = .{ .cursor = older };
    try testing.expectEqual(dos.ERROR_INVALID_ARGUMENT, sendOwn(fs, packets.ACTION_POSFS_CHECK, &stale).res2);

    // No slice for a while: the idle handler ends it.
    try testing.expect(fs.pending());
    setup.m.clock += 20_000_000;
    try fs.idle();
    try testing.expect(fs.checking == null and !fs.vol.space.pin);
    try testing.expectEqual(dos.ERROR_INVALID_ARGUMENT, sendOwn(fs, packets.ACTION_POSFS_CHECK, &args).res2);

    // The blocks a check holds, wanted by a write: the write gets them,
    // the check stops.
    args = .{};
    try testing.expectEqual(dos.DOSTRUE, sendOwn(fs, packets.ACTION_POSFS_CHECK, &args).res1);
    try testing.expectEqual(dos.DOSTRUE, send(fs, .delete_object, .{ 0, arg("a"), 0, 0 }).res1);
    try checkpoint.write(&fs.vol, 0);
    try checkpoint.write(&fs.vol, 0);
    try checkpoint.write(&fs.vol, 0);
    try testing.expect(fs.vol.space.pinned.len != 0);
    try writeFile(fs, "b", &data);
    try testing.expect(!fs.vol.space.pin);
    try testing.expectEqual(dos.ERROR_DISK_FULL, sendOwn(fs, packets.ACTION_POSFS_CHECK, &args).res2);
    try testing.expect(fs.checking == null);
    try expectClean(fs);
}
