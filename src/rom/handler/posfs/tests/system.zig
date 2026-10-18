// SPDX-License-Identifier: MPL-2.0
//! posfs with the system brought up: ExAll through utility.library's
//! pattern and hook calls, notification's watchers and the record locks,
//! each on a test medium. A file of its own because the core is built
//! into the host's mkfs too, which has no exec.

const std = @import("std");
const testing = std.testing;
const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const notify = dos.notify;
const record = dos.record;
const Hook = sdk.utility.Hook;
const FileHandle = dos.FileHandle;
const FileInfoBlock = dos.FileInfoBlock;
const FileLock = dos.FileLock;
const ExAllControl = dos.ExAllControl;
const ExAllData = dos.ExAllData;
const MsgPort = exec.MsgPort;
const testmedia = @import("../testmedia.zig");
const TestMedia = testmedia.TestMedia;
const fs_core = @import("../fs.zig");
const handler = @import("../posfs.zig");
const helpers = @import("fs.zig");
const kexec = @import("../../../libs/exec/exec.zig");
const kdos = @import("../../../libs/dos/dos.zig");
const FileSystem = fs_core.FileSystem;
const Answer = fs_core.Answer;
const send = helpers.send;
const sendArgs = helpers.sendArgs;
const arg = helpers.arg;
const writeFile = helpers.writeFile;

/// A medium and a fresh volume on it, of 4 KiB blocks.
const Setup = struct {
    m: TestMedia,
    fs: FileSystem,

    fn init(setup: *Setup, kind: testmedia.Kind) !void {
        setup.m = try TestMedia.init(kind, 1024 * 1024, 1);
        setup.fs = FileSystem.init(setup.m.device());
        try setup.fs.format(.{ .block_size = 4096, .name = "Work" });
    }

    fn deinit(setup: *Setup) void {
        setup.fs.deinit();
        testing.expectEqual(@as(usize, 0), setup.m.live) catch {};
        setup.m.deinit();
    }
};

fn lockOf(answer: Answer) ?*FileLock {
    return @ptrFromInt(@as(usize, @bitCast(answer.res1)));
}

fn nameOf(text: []const u8) []const u8 {
    return std.mem.sliceTo(text, 0);
}

/// One EXAMINE_ALL.
fn exAll(fs: *FileSystem, lock: ?*FileLock, buffer: []u8, level: i32, control: *ExAllControl) Answer {
    return sendArgs(fs, .examine_all, .{ .examine_all = .{ .lock = lock, .buffer = buffer.ptr, .size = @intCast(buffer.len), .data_type = level, .control = control } });
}

/// The directory as ExNext gives it.
fn exNextAll(fs: *FileSystem, lock: ?*FileLock, into: []FileInfoBlock) !usize {
    var fib: FileInfoBlock = .{};
    try testing.expectEqual(dos.DOSTRUE, sendArgs(fs, .examine_object, .{ .examine = .{ .lock = lock, .fib = &fib } }).res1);
    var count: usize = 0;
    while (sendArgs(fs, .examine_next, .{ .examine = .{ .lock = lock, .fib = &fib } }).res1 == dos.DOSTRUE) : (count += 1) {
        into[count] = fib;
    }
    return count;
}

/// A record and the FileInfoBlock of its entry agree, field by field.
fn expectSame(rec: *const ExAllData, fib: *const FileInfoBlock) !void {
    try testing.expectEqualStrings(nameOf(&fib.file_name), std.mem.span(rec.name.?));
    try testing.expectEqual(fib.dir_entry_type, rec.type);
    try testing.expectEqual(fib.size, rec.size);
    try testing.expectEqual(fib.protection, rec.prot);
    try testing.expectEqual(fib.date.days, rec.days);
    try testing.expectEqual(fib.date.minute, rec.minute);
    try testing.expectEqual(fib.date.tick, rec.ticks);
    try testing.expectEqualStrings(nameOf(&fib.comment), std.mem.span(rec.comment.?));
    try testing.expectEqual(fib.owner_uid, rec.owner_uid);
    try testing.expectEqual(fib.owner_gid, rec.owner_gid);
}

/// The MatchFunc of the tests: counts its calls in the hook's data, and
/// leaves out every directory.
fn noDrawers(hook: *Hook, object: ?*anyopaque, message: ?*anyopaque) callconv(.c) usize {
    const level: *const i32 = @ptrCast(@alignCast(object.?));
    const rec: *const ExAllData = @ptrCast(@alignCast(message.?));
    const calls: *u32 = @ptrCast(@alignCast(hook.data.?));
    calls.* += 1;
    if (level.* < dos.ED_TYPE) return 1;
    return if (rec.type > 0) 0 else 1;
}

test "ExAll: every entry once, in ExNext's order, a buffer at a time, through the pattern and the hook" {
    const db = try kdos.testSetUp();
    defer kexec.deinit();
    const ub = db.utility_base;
    var setup: Setup = undefined;
    try setup.init(.sd);
    var live = true;
    errdefer if (live) setup.deinit();
    const fs = &setup.fs;

    var name_buffer: [16]u8 = undefined;
    const content: [30]u8 = @splat('z');
    var index: u32 = 0;
    while (index < 30) : (index += 1) {
        const name = try std.fmt.bufPrintZ(&name_buffer, "file{d:0>2}{s}", .{ index, if (index % 3 == 0) ".info" else "" });
        try writeFile(fs, name, content[0 .. index + 1]);
        if (index % 4 == 0) {
            try testing.expectEqual(dos.DOSTRUE, sendArgs(fs, .set_comment, .{ .property = .{ .lock = null, .name = name, .value = arg("noted") } }).res1);
        }
    }
    for ([_][*:0]const u8{ "Drawer", "Other.info" }) |dir| {
        const made = send(fs, .create_dir, .{ 0, arg(dir), 0, 0 });
        try testing.expect(made.res1 != 0);
        _ = send(fs, .free_lock, .{ made.res1, 0, 0, 0 });
    }
    try testing.expectEqual(dos.DOSTRUE, sendArgs(fs, .set_owner, .{ .property = .{ .lock = null, .name = "file05", .value = (3 << 16) | 4 } }).res1);

    var control: ExAllControl = .{};
    var buffer: [300]u8 align(8) = undefined;

    // Without the system's tests it is dos's to do.
    try testing.expectEqual(dos.ERROR_ACTION_NOT_KNOWN, exAll(fs, null, &buffer, dos.ED_NAME, &control).res2);
    const matcher = handler.utilityMatcher(@ptrCast(ub));
    fs.matcher = &matcher;

    const fibs = try testing.allocator.alloc(FileInfoBlock, 40);
    defer testing.allocator.free(fibs);
    const total = try exNextAll(fs, null, fibs);
    try testing.expectEqual(@as(usize, 32), total);

    // The whole directory, a few records a call.
    var seen: usize = 0;
    var calls: u32 = 0;
    while (true) {
        const answer = exAll(fs, null, &buffer, dos.ED_OWNER, &control);
        calls += 1;
        var rec: ?*ExAllData = if (control.entries != 0) @ptrCast(@alignCast(&buffer)) else null;
        var count: u32 = 0;
        while (rec) |it| : (rec = it.next) {
            try expectSame(it, &fibs[seen]);
            seen += 1;
            count += 1;
        }
        try testing.expectEqual(control.entries, count);
        if (answer.res1 == dos.DOSFALSE) {
            try testing.expectEqual(dos.ERROR_NO_MORE_ENTRIES, answer.res2);
            break;
        }
        try testing.expect(control.entries != 0);
    }
    try testing.expectEqual(total, seen);
    try testing.expect(calls > 3);
    try testing.expectEqual(@as(usize, 0), control.last_key);

    // A buffer too small for one record: the fields alone fill it.
    var tiny: [@sizeOf(usize) * 2]u8 align(8) = undefined;
    const overflow = exAll(fs, null, &tiny, dos.ED_NAME, &control);
    try testing.expectEqual(dos.ERROR_BUFFER_OVERFLOW, overflow.res2);
    try testing.expectEqual(@as(usize, 0), control.last_key);

    // The pattern: only the .info names, drawers among them; the hook
    // then leaves the drawer out.
    var parsed: [64]u8 = undefined;
    try testing.expect(ub.ParsePatternNoCase("#?.INFO", &parsed, parsed.len) >= 0);
    control.match_string = @ptrCast(&parsed);
    var big: [4096]u8 align(8) = undefined;
    try testing.expectEqual(dos.ERROR_NO_MORE_ENTRIES, exAll(fs, null, &big, dos.ED_TYPE, &control).res2);
    try testing.expectEqual(@as(u32, 11), control.entries);
    var hook_calls: u32 = 0;
    var hook: Hook = .{ .entry = &noDrawers, .data = &hook_calls };
    control.match_func = &hook;
    try testing.expectEqual(dos.ERROR_NO_MORE_ENTRIES, exAll(fs, null, &big, dos.ED_TYPE, &control).res2);
    try testing.expectEqual(@as(u32, 10), control.entries);
    try testing.expectEqual(@as(u32, 11), hook_calls);
    var rec: ?*ExAllData = @ptrCast(@alignCast(&big));
    while (rec) |it| : (rec = it.next) {
        try testing.expect(std.mem.endsWith(u8, std.mem.span(it.name.?), ".info"));
        try testing.expect(it.type < 0);
    }
    control.match_string = null;
    control.match_func = null;

    // Entries that come and go between calls: none given twice, the new
    // one past the place given once at most, the deleted one not after.
    try testing.expectEqual(dos.DOSTRUE, exAll(fs, null, &buffer, dos.ED_NAME, &control).res1);
    var names: [64][16]u8 = undefined;
    var name_count: usize = 0;
    rec = @ptrCast(@alignCast(&buffer));
    while (rec) |it| : (rec = it.next) {
        @memset(&names[name_count], 0);
        const name = std.mem.span(it.name.?);
        @memcpy(names[name_count][0..name.len], name);
        name_count += 1;
    }
    try writeFile(fs, "late", "x");
    var gone: ?[]const u8 = null;
    for (fibs[0..total]) |*fib| {
        const name = nameOf(&fib.file_name);
        var listed = false;
        for (names[0..name_count]) |*have| {
            if (std.mem.eql(u8, nameOf(have), name)) listed = true;
        }
        if (!listed and fib.dir_entry_type < 0) {
            try testing.expectEqual(dos.DOSTRUE, send(fs, .delete_object, .{ 0, arg(@as([*:0]const u8, @ptrCast(&fib.file_name))), 0, 0 }).res1);
            gone = name;
            break;
        }
    }
    try testing.expect(gone != null);
    while (true) {
        const answer = exAll(fs, null, &buffer, dos.ED_NAME, &control);
        rec = if (control.entries != 0) @ptrCast(@alignCast(&buffer)) else null;
        while (rec) |it| : (rec = it.next) {
            const name = std.mem.span(it.name.?);
            try testing.expect(!std.mem.eql(u8, name, gone.?));
            for (names[0..name_count]) |*have| try testing.expect(!std.mem.eql(u8, nameOf(have), name));
            @memset(&names[name_count], 0);
            @memcpy(names[name_count][0..name.len], name);
            name_count += 1;
        }
        if (answer.res1 == dos.DOSFALSE) break;
    }
    try testing.expect(name_count == total or name_count == total - 1);

    // ExAllEnd in the middle of a listing starts the next one afresh.
    try testing.expectEqual(dos.DOSTRUE, exAll(fs, null, &buffer, dos.ED_NAME, &control).res1);
    try testing.expect(control.last_key != 0);
    try testing.expectEqual(dos.DOSTRUE, sendArgs(fs, .examine_all_end, .{ .examine_all = .{ .lock = null, .buffer = &buffer, .size = buffer.len, .data_type = dos.ED_NAME, .control = &control } }).res1);
    try testing.expectEqual(@as(usize, 0), control.last_key);

    // A file is not a directory; a level past ED_OWNER is not a level.
    const file_lock = send(fs, .locate_object, .{ 0, arg("file01"), dos.SHARED_LOCK, 0 });
    try testing.expect(file_lock.res1 != 0);
    try testing.expectEqual(dos.ERROR_OBJECT_WRONG_TYPE, exAll(fs, lockOf(file_lock), &buffer, dos.ED_NAME, &control).res2);
    try testing.expectEqual(dos.ERROR_BAD_NUMBER, exAll(fs, null, &buffer, dos.ED_OWNER + 1, &control).res2);
    _ = send(fs, .free_lock, .{ file_lock.res1, 0, 0, 0 });

    // A drawer's own listing.
    try writeFile(fs, "Drawer/inside", "y");
    const drawer = send(fs, .locate_object, .{ 0, arg("Drawer"), dos.SHARED_LOCK, 0 });
    try testing.expectEqual(dos.ERROR_NO_MORE_ENTRIES, exAll(fs, lockOf(drawer), &big, dos.ED_SIZE, &control).res2);
    try testing.expectEqual(@as(u32, 1), control.entries);
    const inside: *const ExAllData = @ptrCast(@alignCast(&big));
    try testing.expectEqualStrings("inside", std.mem.span(inside.name.?));
    try testing.expectEqual(@as(u64, 1), inside.size);
    _ = send(fs, .free_lock, .{ drawer.res1, 0, 0, 0 });

    setup.deinit();
    live = false;
    try kdos.testTearDown(db);
}

test "MORE_CACHE: a disk's cache grows and shrinks; the flash keeps none" {
    for ([_]testmedia.Kind{ .sd, .flash }) |kind| {
        var setup: Setup = undefined;
        try setup.init(kind);
        defer setup.deinit();
        const fs = &setup.fs;
        const now = sendArgs(fs, .more_cache, .{ .cache = .{ .number = 0 } });
        if (kind == .flash) {
            try testing.expectEqual(dos.ERROR_ACTION_NOT_KNOWN, now.res2);
            continue;
        }
        try testing.expectEqual(@as(isize, 256), now.res1);
        try testing.expectEqual(@as(isize, 300), sendArgs(fs, .more_cache, .{ .cache = .{ .number = 44 } }).res1);
        try writeFile(fs, "after", "the cache changed");
        try testing.expectEqual(@as(isize, 32), sendArgs(fs, .more_cache, .{ .cache = .{ .number = -1000 } }).res1);
        var back: [32]u8 = undefined;
        try testing.expectEqualStrings("the cache changed", back[0..try helpers.readFile(fs, "after", &back)]);
    }
}

test "notification: a watcher of a name not there yet, told at the close, on a rename, a delete and a format" {
    try kexec.setUp();
    defer kexec.deinit();
    const sys = kexec.SysBase.iface();
    var setup: Setup = undefined;
    try setup.init(.flash);
    var live = true;
    errdefer if (live) setup.deinit();
    const fs = &setup.fs;
    var watchers: notify.Watchers = undefined;
    try testing.expect(watchers.init(sys));
    fs.watchers = &watchers;
    const port = sys.CreateMsgPort().?;
    var watch: notify.NotifyRequest = .{ .full_name = @constCast("DH0:Prefs/Env-Archive/Sys/net/hostname"), .flags = notify.NRF_SEND_MESSAGE, .port = port };
    var dir_watch: notify.NotifyRequest = .{ .full_name = @constCast("Work:prefs/env-archive/sys/net"), .flags = notify.NRF_SEND_MESSAGE, .port = port };
    try testing.expectEqual(dos.DOSTRUE, send(fs, .add_notify, .{ arg(&watch), 0, 0, 0 }).res1);
    try testing.expectEqual(dos.DOSTRUE, send(fs, .add_notify, .{ arg(&dir_watch), 0, 0, 0 }).res1);

    const Count = struct {
        fn of(on: *MsgPort, request: *notify.NotifyRequest) usize {
            var count: usize = 0;
            var seen = on.msg_list.iterator();
            while (seen.next()) |node| {
                const message: *exec.Message = @fieldParentPtr("node", node);
                const told: *notify.NotifyMessage = @fieldParentPtr("message", message);
                if (told.request == request) count += 1;
            }
            return count;
        }
        fn drain(system: anytype, on: *MsgPort, all: *notify.Watchers) void {
            while (system.GetMsg(on)) |message| system.ReplyMsg(message);
            all.collect();
        }
    };
    for ([_][*:0]const u8{ "Prefs", "Prefs/Env-Archive", "Prefs/Env-Archive/Sys", "Prefs/Env-Archive/Sys/net" }) |dir| {
        const made = send(fs, .create_dir, .{ 0, arg(dir), 0, 0 });
        try testing.expect(made.res1 != 0);
        _ = send(fs, .free_lock, .{ made.res1, 0, 0, 0 });
    }
    // The directory's watcher heard it appear; the file's nothing yet.
    try testing.expectEqual(@as(usize, 1), Count.of(port, &dir_watch));
    try testing.expectEqual(@as(usize, 0), Count.of(port, &watch));
    Count.drain(sys, port, &watchers);

    try writeFile(fs, "Prefs/Env-Archive/Sys/net/hostname", "board");
    try testing.expectEqual(@as(usize, 1), Count.of(port, &watch));
    try testing.expectEqual(@as(usize, 1), Count.of(port, &dir_watch));
    Count.drain(sys, port, &watchers);

    // Renamed away and back.
    try testing.expectEqual(dos.DOSTRUE, sendArgs(fs, .rename_object, .{ .rename = .{ .from_lock = null, .from_name = "Prefs/Env-Archive/Sys/net/hostname", .to_lock = null, .to_name = "Prefs/Env-Archive/Sys/net/old" } }).res1);
    try testing.expectEqual(@as(usize, 1), Count.of(port, &watch));
    Count.drain(sys, port, &watchers);
    try testing.expectEqual(dos.DOSTRUE, sendArgs(fs, .rename_object, .{ .rename = .{ .from_lock = null, .from_name = "Prefs/Env-Archive/Sys/net/old", .to_lock = null, .to_name = "Prefs/Env-Archive/Sys/net/hostname" } }).res1);
    try testing.expectEqual(@as(usize, 1), Count.of(port, &watch));
    Count.drain(sys, port, &watchers);

    // Deleted: told. The volume formatted: every watch waits for its name
    // again, and the new volume's objects - whose ids start over - are
    // not taken for the old ones.
    try testing.expectEqual(dos.DOSTRUE, send(fs, .delete_object, .{ 0, arg("Prefs/Env-Archive/Sys/net/hostname"), 0, 0 }).res1);
    try testing.expectEqual(@as(usize, 1), Count.of(port, &watch));
    Count.drain(sys, port, &watchers);
    try writeFile(fs, "Prefs/Env-Archive/Sys/net/hostname", "again");
    Count.drain(sys, port, &watchers);
    try fs.format(.{ .block_size = 4096, .name = "Work" });
    for ([_][*:0]const u8{ "a", "b", "c", "d", "e", "f", "g", "h" }) |name| try writeFile(fs, name, "x");
    try testing.expectEqual(@as(usize, 0), Count.of(port, &watch));
    try testing.expectEqual(@as(usize, 0), Count.of(port, &dir_watch));

    try testing.expectEqual(dos.DOSTRUE, send(fs, .remove_notify, .{ arg(&watch), 0, 0, 0 }).res1);
    try testing.expectEqual(dos.DOSTRUE, send(fs, .remove_notify, .{ arg(&dir_watch), 0, 0, 0 }).res1);
    watchers.deinit();
    sys.DeleteMsgPort(port);
    setup.deinit();
    live = false;
    try kexec.expectNoLeaks();
}

/// What LOCK_RECORD answered, without waiting: 0 for the range held, else
/// the error.
fn lockRange(fs: *FileSystem, fh: *FileHandle, offset: u64, length: u64, mode: u32) i32 {
    const answer = sendArgs(fs, .lock_record, .{ .lock_record = .{ .fh = fh, .offset = offset, .length = length, .mode = mode, .timeout = 0 } });
    return if (answer.res1 == dos.DOSFALSE) answer.res2 else 0;
}

/// What FREE_RECORD answered: 0 for the range given back, else the error.
fn unlockRange(fs: *FileSystem, fh: *FileHandle, offset: u64, length: u64) i32 {
    const answer = sendArgs(fs, .free_record, .{ .free_record = .{ .fh = fh, .offset = offset, .length = length } });
    return if (answer.res1 == dos.DOSFALSE) answer.res2 else 0;
}

test "record locks: kept apart, shared, given back exactly and at the close" {
    const db = try kdos.testSetUp();
    defer kexec.deinit();
    var records: record.Records = undefined;
    try testing.expect(records.init(db.sys_base, kdos.testBase(db)));
    var setup: Setup = undefined;
    try setup.init(.usb);
    var live = true;
    errdefer if (live) setup.deinit();
    const fs = &setup.fs;
    var one: FileHandle = .{};
    var two: FileHandle = .{};
    try testing.expectEqual(dos.DOSTRUE, sendArgs(fs, .findupdate, .{ .find = .{ .fh = &one, .lock = null, .name = "base" } }).res1);
    try testing.expectEqual(dos.DOSTRUE, sendArgs(fs, .findupdate, .{ .find = .{ .fh = &two, .lock = null, .name = "base" } }).res1);

    // Without a table from the handler there is no memory for one.
    try testing.expectEqual(dos.ERROR_NO_FREE_STORE, lockRange(fs, &one, 0, 10, record.REC_EXCLUSIVE));
    fs.records = &records;

    try testing.expectEqual(@as(i32, 0), lockRange(fs, &one, 0, 100, record.REC_EXCLUSIVE));
    try testing.expectEqual(@as(i32, 0), lockRange(fs, &one, 10, 10, record.REC_SHARED)); // its own
    try testing.expectEqual(dos.ERROR_LOCK_COLLISION, lockRange(fs, &two, 99, 1, record.REC_SHARED_IMMED));
    try testing.expectEqual(@as(i32, 0), lockRange(fs, &two, 0x1_0000_0000, 1, record.REC_EXCLUSIVE_IMMED));
    try testing.expectEqual(dos.ERROR_RECORD_NOT_LOCKED, unlockRange(fs, &one, 0, 99));
    try testing.expectEqual(@as(i32, 0), unlockRange(fs, &one, 0, 100));
    try testing.expectEqual(dos.ERROR_LOCK_COLLISION, lockRange(fs, &two, 15, 1, record.REC_EXCLUSIVE_IMMED)); // one's shared [10, 20)

    // Closing a handle gives back all it holds; so does a format, which
    // lets every handle go.
    try testing.expectEqual(dos.DOSTRUE, sendArgs(fs, .end, .{ .file = .{ .fh = &one } }).res1);
    try testing.expectEqual(@as(i32, 0), lockRange(fs, &two, 15, 1, record.REC_EXCLUSIVE_IMMED));
    try testing.expect(records.heldCount() != 0);
    try fs.format(.{ .block_size = 4096, .name = "Work" });
    try testing.expectEqual(@as(usize, 0), records.heldCount());

    records.deinit();
    setup.deinit();
    live = false;
    try kdos.testTearDown(db);
}

test "a medium that goes and comes back: locks parked and working again, handles lost, watches on their own volume" {
    try kexec.setUp();
    defer kexec.deinit();
    const sys = kexec.SysBase.iface();
    // Two cards: Alpha in the drive, Beta made aside.
    var setup: Setup = undefined;
    try setup.init(.sd);
    var live = true;
    errdefer if (live) setup.deinit();
    const fs = &setup.fs;
    try fs.relabel("Alpha");
    try testing.expect(dos.posfs.table.isLabel(setup.m.bytes));
    var beta_medium = try TestMedia.init(.sd, setup.m.bytes.len, 2);
    defer beta_medium.deinit();
    {
        var beta = FileSystem.init(beta_medium.device());
        try beta.format(.{ .block_size = 4096, .name = "Beta" });
        try writeFile(&beta, "a", "on beta");
        try beta.unmount();
        beta.deinit();
    }
    var watchers: notify.Watchers = undefined;
    try testing.expect(watchers.init(sys));
    fs.watchers = &watchers;
    const port = sys.CreateMsgPort().?;
    var watch: notify.NotifyRequest = .{ .full_name = @constCast("Alpha:a"), .flags = notify.NRF_SEND_MESSAGE, .port = port };
    try testing.expectEqual(dos.DOSTRUE, send(fs, .add_notify, .{ arg(&watch), 0, 0, 0 }).res1);

    var alpha_node: dos.DosList = .{};
    var beta_node: dos.DosList = .{};
    fs.volume_node = &alpha_node;
    try writeFile(fs, "a", "on alpha");
    while (sys.GetMsg(port)) |message| sys.ReplyMsg(message);
    watchers.collect();
    const kept = send(fs, .locate_object, .{ 0, arg("a"), dos.SHARED_LOCK, 0 });
    try testing.expect(kept.res1 != 0);
    var writing: FileHandle = .{};
    try testing.expectEqual(dos.DOSTRUE, helpers.openFile(fs, &writing, .findoutput, "new").res1);
    try testing.expectEqual(@as(isize, 7), helpers.writeTo(fs, &writing, "partial").res1);
    var reading: FileHandle = .{};
    try testing.expectEqual(dos.DOSTRUE, helpers.openFile(fs, &reading, .findinput, "a").res1);

    // Alpha taken out: its locks parked, and not good for anything yet.
    fs.retire();
    fs.volume_node = null;
    try testing.expectEqual(@as(u32, 3), fs.locksOn(&alpha_node));
    var fib: FileInfoBlock = .{};
    try testing.expectEqual(dos.ERROR_DEVICE_NOT_MOUNTED, sendArgs(fs, .examine_object, .{ .examine = .{ .lock = lockOf(kept), .fib = &fib } }).res2);

    // Beta in: its own "a", which Alpha's watch is not about.
    std.mem.swap([]u8, &setup.m.bytes, &beta_medium.bytes);
    try fs.mount();
    fs.volume_node = &beta_node;
    try testing.expectEqual(@as(?*exec.Message, null), sys.GetMsg(port));
    var back: [16]u8 = undefined;
    try testing.expectEqualStrings("on beta", back[0..try helpers.readFile(fs, "a", &back)]);
    try testing.expectEqual(dos.ERROR_DEVICE_NOT_MOUNTED, sendArgs(fs, .examine_object, .{ .examine = .{ .lock = lockOf(kept), .fib = &fib } }).res2);
    try testing.expectEqual(dos.ERROR_INVALID_LOCK, helpers.readFrom(fs, &reading, &back).res2);

    // Alpha back: the watch finds its name and is told, the lock works,
    // the handles are lost - the writer's bytes with it.
    fs.retire();
    std.mem.swap([]u8, &setup.m.bytes, &beta_medium.bytes);
    try fs.mount();
    fs.revive(&alpha_node);
    fs.volume_node = &alpha_node;
    const told = sys.GetMsg(port) orelse return error.TestUnexpectedResult;
    sys.ReplyMsg(told);
    try testing.expectEqual(dos.DOSTRUE, sendArgs(fs, .examine_object, .{ .examine = .{ .lock = lockOf(kept), .fib = &fib } }).res1);
    try testing.expectEqualStrings("a", std.mem.sliceTo(&fib.file_name, 0));
    try testing.expectEqual(@as(u32, 2), fs.locksOn(&alpha_node));
    try testing.expectEqual(dos.ERROR_DEVICE_NOT_MOUNTED, helpers.closeFile(fs, &writing).res2);
    try testing.expectEqual(dos.DOSTRUE, helpers.closeFile(fs, &reading).res1);
    try testing.expectEqual(@as(u32, 0), fs.locksOn(&alpha_node));
    try testing.expectEqual(@as(usize, 0), try helpers.readFile(fs, "new", &back));
    try testing.expectEqualStrings("on alpha", back[0..try helpers.readFile(fs, "a", &back)]);
    _ = send(fs, .free_lock, .{ kept.res1, 0, 0, 0 });

    // A lock parked when its card goes is still given back while it is out.
    const stray = send(fs, .locate_object, .{ 0, arg("a"), dos.SHARED_LOCK, 0 });
    fs.retire();
    try testing.expectEqual(dos.DOSTRUE, send(fs, .free_lock, .{ stray.res1, 0, 0, 0 }).res1);
    try testing.expect(fs.parked == null);
    try fs.mount();
    try helpers.expectClean(fs);

    while (sys.GetMsg(port)) |message| sys.ReplyMsg(message);
    try testing.expectEqual(dos.DOSTRUE, send(fs, .remove_notify, .{ arg(&watch), 0, 0, 0 }).res1);
    watchers.deinit();
    sys.DeleteMsgPort(port);
    setup.deinit();
    live = false;
    try kexec.expectNoLeaks();
}
