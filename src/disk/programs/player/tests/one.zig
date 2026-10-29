// SPDX-License-Identifier: MIT
//! Host tests of one.zig: the files a second start hands over, made into
//! full names on a RAM disk, and a start with no Player running finding
//! it is the Player. The hand-over itself waits for the Player running
//! to answer, and is seen in the system.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const DosBase = sdk.interface.dos.DosBase;
const host = @import("host_rom");
const kexec = host.exec;
const one = @import("../one.zig");

const testing = std.testing;

/// The RAM disk behind WORK:, answering the test process's packets.
const Disk = struct {
    var port: exec.MsgPort = undefined;
    var disk: host.ram.RamDisk = undefined;
    var dl: *DosBase = undefined;

    fn wait(proc: *dos.Process, sys: *sdk.interface.exec.ExecBase) callconv(.c) *exec.Message {
        const pkt = dos.DosPacket.fromMessage(sys.GetMsg(&port).?);
        const reply = disk.answer(pkt);
        dl.ReplyPkt(pkt, reply.res1, reply.res2);
        return sys.GetMsg(&proc.msg_port).?;
    }
};

/// exec, utility and dos, and a process with WORK: behind it.
const Rig = struct {
    db: *host.dos.DosBase,
    proc: dos.Process = .{},
    saved: ?*kexec.Task = null,

    fn init(rig: *Rig) !void {
        rig.* = .{ .db = try host.dos.testSetUp() };
        rig.proc.task.node.name = "test process";
        host.dos_process.initMsgPort(&rig.proc);
        rig.saved = kexec.SysBase.cpu().this_task;
        kexec.SysBase.cpu().this_task = &rig.proc.task;

        const dl = rig.dosLib();
        Disk.dl = dl;
        Disk.port = .{ .flags = exec.PA_IGNORE };
        Disk.port.msg_list.init(.message);
        Disk.disk = try host.ram.RamDisk.init(rig.db.sys_base, dl, rig.db.utility_base, &Disk.port);
        const node = dl.MakeDosEntry("WORK", dos.DLT_DEVICE).?;
        node.task = &Disk.port;
        try testing.expect(dl.AddDosEntry(node));
        rig.proc.pkt_wait = &Disk.wait;
    }

    fn sysLib(_: *Rig) *sdk.interface.exec.ExecBase {
        return kexec.SysBase.iface();
    }

    fn dosLib(rig: *Rig) *DosBase {
        return host.dos.testBase(rig.db);
    }

    fn deinit(rig: *Rig) !void {
        Disk.disk.deinit();
        kexec.SysBase.cpu().this_task = rig.saved.?;
        try host.dos.testTearDown(rig.db);
        kexec.deinit();
    }
};

test "the files handed over go by their full names, from wherever the start was" {
    var rig: Rig = undefined;
    try rig.init();
    const sys = rig.sysLib();
    const dl = rig.dosLib();

    dl.UnLock(dl.CreateDir("WORK:Music") orelse return error.NoDir);
    const fh = dl.Open("WORK:Music/Fire.mp3", dos.MODE_NEWFILE) orelse return error.NoFile;
    _ = dl.Close(fh);
    const before = dl.CurrentDir(dl.Lock("WORK:Music", dos.SHARED_LOCK));

    const files = [_]?[*:0]const u8{ "Fire.mp3", "Gone.mp3", "WORK:Music/Fire.mp3", "HTTP://radio.example/live", null };
    var made = one.names(sys, dl, &files).?;
    try testing.expectEqual(@as(u32, 4), made.count);
    const list = made.list.?;
    // A file that is there by the name of what it is - its volume's and
    // its drawers' - whichever way it was named.
    try testing.expectEqualStrings("Ram Disk:Music/Fire.mp3", std.mem.span(list[0]));
    try testing.expectEqualStrings("Ram Disk:Music/Fire.mp3", std.mem.span(list[2]));
    // One that is not there: the drawer the start was in, and the name.
    try testing.expectEqualStrings("Ram Disk:Music/Gone.mp3", std.mem.span(list[1]));
    // A station's address as it was given: never locked, which would ask
    // for a volume named HTTP.
    try testing.expectEqualStrings("HTTP://radio.example/live", std.mem.span(list[3]));

    // No Player runs: this start is the Player, and the names are its own.
    try testing.expectEqual(one.Outcome.alone, one.handOver(sys, &made, false, 80, .bars));
    try testing.expectEqual(@as(usize, 4), made.slice().len);
    made.free(sys);

    // None given are none made.
    var nothing = one.names(sys, dl, null).?;
    try testing.expectEqual(@as(u32, 0), nothing.count);
    try testing.expect(nothing.memory == null);
    try testing.expectEqual(@as(usize, 0), nothing.slice().len);
    nothing.free(sys);

    dl.UnLock(dl.CurrentDir(before));
    try rig.deinit();
}

test "what a second start asked, read back" {
    var handed = one.Handed{ .look = 0 };
    try testing.expect(handed.lookAsked() == null);
    try testing.expectEqual(@as(usize, 0), handed.nameList().len);
    handed.look = 3;
    try testing.expectEqual(@as(?@import("../visual.zig").Mode, .bars), handed.lookAsked());
    handed.look = 9;
    try testing.expect(handed.lookAsked() == null);
    const names = [_][*:0]const u8{ "WORK:a.mp3", "WORK:b.mp3" };
    handed.names = &names;
    handed.count = 2;
    try testing.expectEqualStrings("WORK:b.mp3", std.mem.span(handed.nameList()[1]));
}
