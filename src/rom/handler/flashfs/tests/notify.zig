// SPDX-License-Identifier: MPL-2.0
//! Host tests of the flash file system's notification: its tree on memory
//! that behaves like flash (`memmedia.zig`), exec brought up for the
//! watchers' messages. A file of its own because `disk.zig` is built into
//! the host's mkfs too, which has no exec.

const std = @import("std");
const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const notify = dos.notify;
const DosPacket = dos.DosPacket;
const FileHandle = dos.FileHandle;
const MsgPort = exec.MsgPort;
const disk = @import("../disk.zig");
const MemMedia = @import("../memmedia.zig").MemMedia;
const kexec = @import("../../../libs/exec/exec.zig");

const testing = std.testing;
const TestFs = disk.FileSystem(MemMedia);
const Answer = disk.Answer;

const test_sectors = 24;
const test_sector = 512;
const test_page = 64;

fn send(fs: *TestFs, action: dos.ActionCode, args: [4]isize) Answer {
    var pkt = DosPacket.init(action, .{ .raw = args ++ [3]isize{ 0, 0, 0 } });
    return fs.answer(&pkt);
}

fn sendArgs(fs: *TestFs, action: dos.ActionCode, args: dos.PacketArgs) Answer {
    var pkt = DosPacket.init(action, args);
    return fs.answer(&pkt);
}

fn writeFile(fs: *TestFs, name: [*:0]const u8, text: []const u8) !void {
    var fh: FileHandle = .{};
    try testing.expectEqual(dos.DOSTRUE, sendArgs(fs, .findoutput, .{ .find = .{ .fh = &fh, .lock = null, .name = name } }).res1);
    const count = sendArgs(fs, .write, .{ .io = .{ .fh = &fh, .buffer = @constCast(text.ptr), .length = @intCast(text.len) } });
    try testing.expectEqual(@as(isize, @intCast(text.len)), count.res1);
    try testing.expectEqual(dos.DOSTRUE, sendArgs(fs, .end, .{ .file = .{ .fh = &fh } }).res1);
}

test "notification: a watcher of a name not there yet, told at the close, on a rename, a delete and a format" {
    try kexec.setUp();
    defer kexec.deinit();
    const sys = kexec.SysBase.iface();
    var store: [test_sectors * test_sector]u8 = undefined;
    var media = MemMedia.init(&store, test_sector, test_page);
    var fs = TestFs.init(&media, null);
    try fs.format("System");
    var watchers: notify.Watchers = undefined;
    try testing.expect(watchers.init(sys));
    fs.watchers = &watchers;
    const port = sys.CreateMsgPort().?;
    var watch: notify.NotifyRequest = .{ .full_name = @constCast("DH0:Prefs/Env-Archive/Sys/net/hostname"), .flags = notify.NRF_SEND_MESSAGE, .port = port };
    var dir_watch: notify.NotifyRequest = .{ .full_name = @constCast("System:prefs/env-archive/sys/net"), .flags = notify.NRF_SEND_MESSAGE, .port = port };
    try testing.expectEqual(dos.DOSTRUE, send(&fs, .add_notify, .{ @bitCast(@intFromPtr(&watch)), 0, 0, 0 }).res1);
    try testing.expectEqual(dos.DOSTRUE, send(&fs, .add_notify, .{ @bitCast(@intFromPtr(&dir_watch)), 0, 0, 0 }).res1);

    const Count = struct {
        fn of(system: anytype, on: *MsgPort, request: *notify.NotifyRequest) usize {
            var count: usize = 0;
            var seen = on.msg_list.iterator();
            while (seen.next()) |node| {
                const message: *exec.Message = @fieldParentPtr("node", node);
                const told: *notify.NotifyMessage = @fieldParentPtr("message", message);
                if (told.request == request) count += 1;
            }
            _ = system;
            return count;
        }
        fn drain(system: anytype, on: *MsgPort, all: *notify.Watchers) void {
            while (system.GetMsg(on)) |message| system.ReplyMsg(message);
            all.collect();
        }
    };
    for ([_][*:0]const u8{ "Prefs", "Prefs/Env-Archive", "Prefs/Env-Archive/Sys", "Prefs/Env-Archive/Sys/net" }) |dir| {
        const made = send(&fs, .create_dir, .{ 0, @bitCast(@intFromPtr(dir)), 0, 0 });
        try testing.expect(made.res1 != 0);
        _ = send(&fs, .free_lock, .{ made.res1, 0, 0, 0 });
    }
    // The directory's watcher heard it appear; the file's nothing yet.
    try testing.expectEqual(@as(usize, 1), Count.of(sys, port, &dir_watch));
    try testing.expectEqual(@as(usize, 0), Count.of(sys, port, &watch));
    Count.drain(sys, port, &watchers);

    try writeFile(&fs, "Prefs/Env-Archive/Sys/net/hostname", "board");
    try testing.expectEqual(@as(usize, 1), Count.of(sys, port, &watch));
    try testing.expectEqual(@as(usize, 1), Count.of(sys, port, &dir_watch));
    Count.drain(sys, port, &watchers);

    // Renamed away and back.
    try testing.expectEqual(dos.DOSTRUE, sendArgs(&fs, .rename_object, .{ .rename = .{ .from_lock = null, .from_name = "Prefs/Env-Archive/Sys/net/hostname", .to_lock = null, .to_name = "Prefs/Env-Archive/Sys/net/old" } }).res1);
    try testing.expectEqual(@as(usize, 1), Count.of(sys, port, &watch));
    Count.drain(sys, port, &watchers);
    try testing.expectEqual(dos.DOSTRUE, sendArgs(&fs, .rename_object, .{ .rename = .{ .from_lock = null, .from_name = "Prefs/Env-Archive/Sys/net/old", .to_lock = null, .to_name = "Prefs/Env-Archive/Sys/net/hostname" } }).res1);
    try testing.expectEqual(@as(usize, 1), Count.of(sys, port, &watch));
    Count.drain(sys, port, &watchers);

    // Deleted: told; the volume formatted: everything let go, and a file
    // of the name made again is told of.
    try testing.expectEqual(dos.DOSTRUE, send(&fs, .delete_object, .{ 0, @bitCast(@intFromPtr("Prefs/Env-Archive/Sys/net/hostname")), 0, 0 }).res1);
    try testing.expectEqual(@as(usize, 1), Count.of(sys, port, &watch));
    Count.drain(sys, port, &watchers);
    try writeFile(&fs, "Prefs/Env-Archive/Sys/net/hostname", "again");
    Count.drain(sys, port, &watchers);
    try fs.reformat("System");
    try writeFile(&fs, "nothing", "x");
    try testing.expectEqual(@as(usize, 0), Count.of(sys, port, &watch));

    try testing.expectEqual(dos.DOSTRUE, send(&fs, .remove_notify, .{ @bitCast(@intFromPtr(&watch)), 0, 0, 0 }).res1);
    try testing.expectEqual(dos.DOSTRUE, send(&fs, .remove_notify, .{ @bitCast(@intFromPtr(&dir_watch)), 0, 0, 0 }).res1);
    watchers.deinit();
    sys.DeleteMsgPort(port);
    fs.deinit();
    try testing.expectEqual(@as(usize, 0), media.live);
}
