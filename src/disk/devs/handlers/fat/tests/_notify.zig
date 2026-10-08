// SPDX-License-Identifier: MIT
//! What the notification tests of both file systems share: one course of
//! changes - names watched before they are there, a file written, its
//! protection set, renamed away and back, its directory renamed under it,
//! deleted, the card taken out and put back - and the count of what each
//! watcher was told at every step. `rig` is either test file's: it has
//! `fs`, `send`, `sendArgs`, `mkdir` and `writeFile`.

const std = @import("std");
const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const notify = dos.notify;
const MsgPort = exec.MsgPort;
const ExecBase = sdk.interface.exec.ExecBase;
const kexec = @import("host_rom").exec;

const testing = std.testing;

/// How many messages for `request` wait on `port`.
fn count(port: *MsgPort, request: *notify.NotifyRequest) usize {
    var found: usize = 0;
    var seen = port.msg_list.iterator();
    while (seen.next()) |node| {
        const message: *exec.Message = @fieldParentPtr("node", node);
        const told: *notify.NotifyMessage = @fieldParentPtr("message", message);
        if (told.request == request) found += 1;
    }
    return found;
}

/// Every message replied, and the watchers given them back.
fn drain(sys: *ExecBase, port: *MsgPort, watchers: *notify.Watchers) void {
    while (sys.GetMsg(port)) |message| sys.ReplyMsg(message);
    watchers.collect();
}

/// `volume` and `path` as a full name, in `into`.
fn fullName(into: []u8, volume: []const u8, path: []const u8) [*:0]u8 {
    @memcpy(into[0..volume.len], volume);
    into[volume.len] = ':';
    @memcpy(into[volume.len + 1 ..][0..path.len], path);
    into[volume.len + 1 + path.len] = 0;
    return @ptrCast(into.ptr);
}

fn rename(rig: anytype, from: [*:0]const u8, to: [*:0]const u8) !void {
    try testing.expectEqual(dos.DOSTRUE, rig.sendArgs(.rename_object, .{ .rename = .{ .from_lock = null, .from_name = from, .to_lock = null, .to_name = to } }).res1);
}

/// A packet whose first argument is a request.
fn notifyPacket(rig: anytype, action: dos.ActionCode, request: *notify.NotifyRequest) isize {
    return rig.send(action, .{ @bitCast(@intFromPtr(request)), 0, 0, 0 }).res1;
}

/// A packet on a name from the root: DELETE_OBJECT, SET_PROTECT.
fn namePacket(rig: anytype, action: dos.ActionCode, name: [*:0]const u8, value: isize) isize {
    return rig.send(action, .{ 0, @bitCast(@intFromPtr(name)), value, 0 }).res1;
}

/// The course, on a fresh volume, with `changes` the medium's change
/// count to take the card out and put it back.
pub fn course(rig: anytype, changes: *u32) !void {
    const sys = kexec.SysBase.iface();
    var watchers: notify.Watchers = undefined;
    try testing.expect(watchers.init(sys));
    rig.fs.watchers = &watchers;
    rig.fs.device_name = "SD0";
    const port = sys.CreateMsgPort().?;

    var names: [4][64]u8 = undefined;
    const volume = rig.fs.volumeName();
    // A file and its directory, neither there yet - the directory named
    // on the device; the root, told at once; and a file on another
    // card's volume, never told.
    var file: notify.NotifyRequest = .{ .full_name = fullName(&names[0], volume, "Dir/Sub/notes"), .flags = notify.NRF_SEND_MESSAGE, .port = port };
    var dir: notify.NotifyRequest = .{ .full_name = fullName(&names[1], "SD0", "dir/sub"), .flags = notify.NRF_SEND_MESSAGE, .port = port };
    var root: notify.NotifyRequest = .{ .full_name = fullName(&names[2], volume, ""), .flags = notify.NRF_SEND_MESSAGE | notify.NRF_NOTIFY_INITIAL, .port = port };
    var other: notify.NotifyRequest = .{ .full_name = fullName(&names[3], "Elsewhere", "Dir/Sub/notes"), .flags = notify.NRF_SEND_MESSAGE, .port = port };
    const all = [_]*notify.NotifyRequest{ &file, &dir, &root, &other };
    for (all) |request| try testing.expectEqual(dos.DOSTRUE, notifyPacket(rig, .add_notify, request));
    try testing.expectEqual(@as(usize, 1), count(port, &root));
    drain(sys, port, &watchers);

    // The directories made: the root hears of the first, the watched
    // directory of itself.
    try rig.mkdir("Dir");
    try rig.mkdir("Dir/Sub");
    try testing.expectEqual(@as(usize, 1), count(port, &root));
    try testing.expectEqual(@as(usize, 1), count(port, &dir));
    try testing.expectEqual(@as(usize, 0), count(port, &file));
    drain(sys, port, &watchers);

    // Made and written: told at the close, the file and its directory.
    try rig.writeFile("Dir/Sub/notes", "first");
    try testing.expectEqual(@as(usize, 1), count(port, &file));
    try testing.expectEqual(@as(usize, 1), count(port, &dir));
    try testing.expectEqual(@as(usize, 0), count(port, &root));
    drain(sys, port, &watchers);
    try rig.writeFile("Dir/Sub/notes", "second");
    try testing.expectEqual(@as(usize, 1), count(port, &file));
    try testing.expectEqual(@as(usize, 1), count(port, &dir));
    drain(sys, port, &watchers);

    // Its protection: the file alone.
    try testing.expectEqual(dos.DOSTRUE, namePacket(rig, .set_protect, "Dir/Sub/notes", 0));
    try testing.expectEqual(@as(usize, 1), count(port, &file));
    try testing.expectEqual(@as(usize, 0), count(port, &dir));
    drain(sys, port, &watchers);

    // Renamed away: told it went; renamed back: told it came.
    try rename(rig, "Dir/Sub/notes", "Dir/Sub/old");
    try testing.expectEqual(@as(usize, 1), count(port, &file));
    try testing.expectEqual(@as(usize, 1), count(port, &dir));
    drain(sys, port, &watchers);
    try rename(rig, "Dir/Sub/old", "Dir/Sub/notes");
    try testing.expectEqual(@as(usize, 1), count(port, &file));
    try testing.expectEqual(@as(usize, 1), count(port, &dir));
    drain(sys, port, &watchers);

    // The directory above renamed: the watches follow what they found.
    try rename(rig, "Dir", "Moved");
    try testing.expectEqual(@as(usize, 1), count(port, &root));
    drain(sys, port, &watchers);
    try rig.writeFile("Moved/Sub/notes", "third");
    try testing.expectEqual(@as(usize, 1), count(port, &file));
    try testing.expectEqual(@as(usize, 1), count(port, &dir));
    drain(sys, port, &watchers);
    try rename(rig, "Moved", "Dir");
    drain(sys, port, &watchers);

    // A watched file is not in use: deleted, told, and its name waited for.
    try testing.expectEqual(dos.DOSTRUE, namePacket(rig, .delete_object, "Dir/Sub/notes", 0));
    try testing.expectEqual(@as(usize, 1), count(port, &file));
    try testing.expectEqual(@as(usize, 1), count(port, &dir));
    drain(sys, port, &watchers);
    try rig.writeFile("Dir/Sub/notes", "fourth");
    try testing.expectEqual(@as(usize, 1), count(port, &file));
    drain(sys, port, &watchers);

    // The card out and back: every watch finds its name again and is
    // told; the other volume's still waits.
    changes.* += 1;
    try testing.expect(rig.fs.checkMedium());
    try testing.expectEqual(@as(usize, 1), count(port, &file));
    try testing.expectEqual(@as(usize, 1), count(port, &dir));
    try testing.expectEqual(@as(usize, 1), count(port, &root));
    try testing.expectEqual(@as(usize, 0), count(port, &other));
    drain(sys, port, &watchers);
    try rig.writeFile("Dir/Sub/notes", "fifth");
    try testing.expectEqual(@as(usize, 1), count(port, &file));
    drain(sys, port, &watchers);

    // Removed: nothing told after, and no key left held.
    for (all) |request| try testing.expectEqual(dos.DOSTRUE, notifyPacket(rig, .remove_notify, request));
    try rig.writeFile("Dir/Sub/notes", "sixth");
    for (all) |request| try testing.expectEqual(@as(usize, 0), count(port, request));
    try testing.expectEqual(@as(?*anyopaque, null), @as(?*anyopaque, @ptrCast(rig.fs.keys)));
    rig.fs.watchers = null;
    watchers.deinit();
    sys.DeleteMsgPort(port);
}
