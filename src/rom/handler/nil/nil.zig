// SPDX-License-Identifier: MPL-2.0
//! The NIL: handler: a process that swallows what is
//! written and reads as empty, in the ROM as its own resident module
//! ("nil-handler"). dos.library's init adds the "NIL" device node that
//! names it; GetDeviceProc("NIL:") finds the tag with FindResident and
//! starts the handler on first use. It builds against the SDK only.
//!
//! The tag is a ResidentHandler: rt_Type NT_HANDLER, no start
//! flags and no rt_Init (so InitCode and InitResident leave it alone), the
//! entry in a field of its own. STARTUP and WRITE are answered with
//! res1, res2 in that order.

const std = @import("std");
const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const DosPacket = dos.DosPacket;
const Process = dos.Process;

pub const HANDLER_NAME = "nil-handler";
const HANDLER_VERSION = 1;
const HANDLER_REVISION = 0;
const BUILD_DATE = "15.9.2026";
const HANDLER_VERSION_STRING =
    "\x00$VER: " ++ HANDLER_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ HANDLER_VERSION, HANDLER_REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

pub const Answer = struct { res1: isize, res2: i32 };

/// NIL:'s answer to a packet: EOF for reads, the whole length for writes,
/// yes for opening and closing, and "not known" for the rest.
pub fn nilAnswer(pkt: *const DosPacket) Answer {
    return switch (pkt.getAction()) {
        .read, .seek => .{ .res1 = 0, .res2 = 0 },
        .write => .{ .res1 = pkt.args.raw[2], .res2 = 0 }, // dp_Arg3: the length
        .findinput, .findoutput, .findupdate, .end => .{ .res1 = dos.DOSTRUE, .res2 = 0 },
        .is_filesystem => .{ .res1 = dos.DOSFALSE, .res2 = 0 },
        else => .{ .res1 = dos.DOSFALSE, .res2 = dos.ERROR_ACTION_NOT_KNOWN },
    };
}

/// The handler process: ACTION_STARTUP first (its node gets the process's
/// port), then packets until the system goes down.
pub fn nilHandler(sb: *ExecBase) callconv(.c) void {
    const lib = sb.OpenLibrary(dos.DOSNAME, 0) orelse return;
    defer sb.CloseLibrary(lib);
    const dl: *sdk.interface.dos.DosBase = @ptrCast(lib);
    const startup = dl.WaitPkt() orelse return;
    if (startup.getAction() != .startup) {
        dl.ReplyPkt(startup, dos.DOSFALSE, dos.ERROR_ACTION_NOT_KNOWN);
        return;
    }
    const me: *Process = @fieldParentPtr("task", sb.FindTask(null).?);
    const node: ?*dos.DosList = @ptrFromInt(@as(usize, @bitCast(startup.args.raw[2])));
    if (node) |n| n.task = &me.msg_port;
    dl.ReplyPkt(startup, dos.DOSTRUE, 0);
    while (dl.WaitPkt()) |pkt| {
        const answer = nilAnswer(pkt);
        dl.ReplyPkt(pkt, answer.res1, answer.res2);
    }
}

export const nil_handler_tag: exec.ResidentHandler linksection(".resident") = .{
    .resident = .{
        .match_tag = &nil_handler_tag.resident,
        .version = HANDLER_VERSION,
        .type = .handler,
        .pri = -120,
        .name = HANDLER_NAME,
        .id_string = HANDLER_VERSION_STRING[1..], // past the NUL: a C string
    },
    .handler = &nilHandler,
};

// --- tests (host: ./zig build test) -----------------------------------------

const testing = std.testing;

test "the ROM tag: a handler's, which InitCode and InitResident leave alone" {
    const tag = &nil_handler_tag;
    try testing.expectEqual(&tag.resident, tag.resident.match_tag);
    try testing.expectEqual(exec.NodeType.handler, tag.resident.type);
    try testing.expectEqual(@as(u8, 0), tag.resident.flags);
    try testing.expect(tag.resident.init == null);
    try testing.expectEqual(@as(exec.TaskFn, &nilHandler), tag.handler);
    try testing.expectEqualStrings(HANDLER_NAME, std.mem.span(tag.resident.name));
}

test "NIL: reads as empty, takes every write, knows little else" {
    var pkt = DosPacket.init(.write, .{ .raw = .{ 0, 0, 5, 0, 0, 0, 0 } });
    try testing.expectEqual(Answer{ .res1 = 5, .res2 = 0 }, nilAnswer(&pkt));
    pkt.action = @intFromEnum(dos.ActionCode.read);
    try testing.expectEqual(Answer{ .res1 = 0, .res2 = 0 }, nilAnswer(&pkt));
    pkt.action = @intFromEnum(dos.ActionCode.findinput);
    try testing.expectEqual(Answer{ .res1 = dos.DOSTRUE, .res2 = 0 }, nilAnswer(&pkt));
    pkt.action = @intFromEnum(dos.ActionCode.end);
    try testing.expectEqual(Answer{ .res1 = dos.DOSTRUE, .res2 = 0 }, nilAnswer(&pkt));
    pkt.action = @intFromEnum(dos.ActionCode.is_filesystem);
    try testing.expectEqual(Answer{ .res1 = dos.DOSFALSE, .res2 = 0 }, nilAnswer(&pkt));
    pkt.action = @intFromEnum(dos.ActionCode.die);
    try testing.expectEqual(Answer{ .res1 = dos.DOSFALSE, .res2 = dos.ERROR_ACTION_NOT_KNOWN }, nilAnswer(&pkt));
}
