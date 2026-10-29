// SPDX-License-Identifier: MIT
//! Host tests of the SDK's drop target (`sdk.anvil.DropTarget`) on exec
//! alone: which files of the drops waiting it hands out - the first of
//! each, or with `all` every one in turn - and when each drop is replied.
//! The names made from them are dos's, and are not looked at here.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const anvil = sdk.anvil;
const kexec = @import("host_rom").exec;

const testing = std.testing;

/// The drop target's next file, by its name; null when none waits.
fn nextName(target: *anvil.DropTarget) ?[*:0]const u8 {
    const file = target.nextFile() orelse return null;
    return file.name orelse "";
}

fn expectName(expected: []const u8, got: ?[*:0]const u8) !void {
    try testing.expectEqualStrings(expected, std.mem.span(got orelse return error.NoFile));
}

/// How many replies have come back.
fn replies(sys: anytype, port: *exec.MsgPort) usize {
    var count: usize = 0;
    while (sys.GetMsg(port)) |_| count += 1;
    return count;
}

test "DropTarget: the first file of each drop, or with all every one; each drop replied after its last" {
    try kexec.setUp();
    defer kexec.deinit();
    const sys = kexec.SysBase.iface();
    const port = sys.CreateMsgPort() orelse return error.NoPort;
    const back = sys.CreateMsgPort() orelse return error.NoPort;

    const three = [_]dos.WBArg{ .{ .name = "a.mp3" }, .{ .name = "b.mp3" }, .{ .name = "c.mp3" } };
    const one = [_]dos.WBArg{.{ .name = "d.mp3" }};
    var drops = [_]anvil.AppMessage{
        .{ .num_args = three.len, .arg_list = @constCast(&three) },
        // The desktop's word that it quits: no files.
        .{ .kind = anvil.AMTYPE_QUIT },
        .{ .num_args = one.len, .arg_list = @constCast(&one) },
    };
    for (&drops) |*drop| drop.message.reply_port = back;

    // The first of each, as a viewer wants it.
    var target: anvil.DropTarget = .{ .sys = sys, .port = port };
    for (&drops) |*drop| sys.PutMsg(port, &drop.message);
    try expectName("a.mp3", nextName(&target));
    // The drop is held while its file's name is in use.
    try testing.expectEqual(@as(usize, 0), replies(sys, back));
    try expectName("d.mp3", nextName(&target));
    try testing.expectEqual(@as(usize, 2), replies(sys, back));
    try testing.expectEqual(@as(?[*:0]const u8, null), nextName(&target));
    try testing.expectEqual(@as(usize, 1), replies(sys, back));

    // Every one, as a list wants them.
    target.all = true;
    for (&drops) |*drop| sys.PutMsg(port, &drop.message);
    try expectName("a.mp3", nextName(&target));
    try expectName("b.mp3", nextName(&target));
    try expectName("c.mp3", nextName(&target));
    try testing.expectEqual(@as(usize, 0), replies(sys, back));
    try expectName("d.mp3", nextName(&target));
    try testing.expectEqual(@as(usize, 2), replies(sys, back));
    try testing.expectEqual(@as(?[*:0]const u8, null), nextName(&target));
    try testing.expectEqual(@as(usize, 1), replies(sys, back));

    // A drop held when the target goes is replied with the rest, and the
    // target keeps saying it wants them all.
    sys.PutMsg(port, &drops[0].message);
    sys.PutMsg(port, &drops[2].message);
    try expectName("a.mp3", nextName(&target));
    target.remove();
    try testing.expectEqual(@as(usize, 2), replies(sys, back));
    try testing.expect(target.all);
    try testing.expectEqual(@as(?[*:0]const u8, null), nextName(&target));
    sys.DeleteMsgPort(back);
    try kexec.expectNoLeaks();
}
