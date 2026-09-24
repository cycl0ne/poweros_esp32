// SPDX-License-Identifier: MPL-2.0
//! dos.library: files, locks and the device list; processes and the
//! CLI; assigns, pattern searches, variables, argument parsing and the
//! loading of programs - everything a program does with the file system
//! and the shell goes through it.
//!
//! The library holds no file system itself. A name is resolved to a node
//! of the device list, and the node's handler - a process started on first
//! use - answers packets for it: dos turns each call into a packet, sends
//! it, and waits. The handlers are ROM modules of their own
//! (src/rom/handler/), found by name and kept as system segments.
//!
//! The base is opened with OpenLibrary("dos.library", 1). Its functions
//! are sdk/fd/dos_lib.fd, its types sdk/libs/dos/.
//!
//! Each call is a file of its own in the folder for its area: packet/
//! (packets and dos objects), doslist/ (the device list, GetDeviceProc,
//! assigns, the disk's partitions), lock/ (locks, examining, changing,
//! pattern searches), file/ (raw and buffered I/O), process/ (processes,
//! the CLI, variables), program/ (segments, LoadSeg, RunCommand, shells),
//! text/ (paths, ReadArgs, error texts) and date/. The jump table is
//! dos_lvo.zig, the ROM tag and init dos_init.zig, the base dos_base.zig.
//! This file holds the names the rest of the kernel reaches the library
//! by, and the tests of calls working together.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const TagItem = sdk.utility.TagItem;
const MsgPort = exec.MsgPort;
const DosPacket = dos.DosPacket;
const Process = dos.Process;
const Segment = dos.Segment;
const FileLock = dos.FileLock;
const FileHandle = dos.FileHandle;
const DosList = dos.DosList;
const DevProc = dos.DevProc;
const ExecBase = sdk.interface.exec.ExecBase;
const vec = exec.vec;

/// dos.library's base (dos_base.zig).
const dos_base = @import("dos_base.zig");
/// dos.library's ROM tag and init routines (dos_init.zig).
const dos_init = @import("dos_init.zig");
/// The jump table (dos_lvo.zig), for the tests.
const dos_lvo = @import("dos_lvo.zig");
const packets = @import("packet/_packet.zig");
const process = @import("process/_process.zig");
const doslist = @import("doslist/_doslist.zig");
const segment = @import("program/_program.zig");
const locks = @import("lock/_lock.zig");
const files = @import("file/_file.zig");
const readargs = @import("text/_text.zig");
const date = @import("date/_date.zig");

// The tag is an export in .resident, found there by its address; this
// keeps it in whatever is built from dos.library.
comptime {
    _ = &dos_init.dos_library_tag;
}

/// The library's base, for the modules that keep a pointer to it.
pub const DosBase = dos_base.DosBase;
/// How many CLIs there can be at once.
pub const max_clis = dos_base.max_clis;
/// What the library is on exec's list as.
pub const LIBRARY_NAME = dos_init.LIBRARY_NAME;
/// The ROM tag, for the host tests that make the library from it.
pub const dos_library_tag = dos_init.dos_library_tag;
/// dos.library's jump table as the SDK has it (sdk/fd/dos_lib.fd).
pub const interface = sdk.interface.dos;
pub const LVO = interface.LVO;
const vectors = dos_lvo.vectors;

// --- tests (host: ./zig build test) -----------------------------------------

const testing = std.testing;
/// The kernel's exec, to set up and tear down around the library.
const kexec = @import("../exec/exec.zig");
const kutility = @import("../utility/utility.zig");

/// exec on its test RAM, utility.library and dos.library from their tags.
fn setUp() !*DosBase {
    try kexec.setUp();
    _ = kexec.InitResident(kexec.SysBase, &kutility.utility_library_tag, null) orelse return error.NoUtility;
    const made = kexec.InitResident(kexec.SysBase, &dos_library_tag, null) orelse return error.NoDos;
    return @fieldParentPtr("lib", @as(*exec.Library, @ptrCast(@alignCast(made))));
}

/// Neither library expunges itself: close utility.library for dos, free
/// both, and check that nothing is left.
fn tearDown(db: *DosBase) !void {
    var node = db.dos_list.next;
    while (node) |n| {
        node = n.next;
        if (n.type == .late or n.type == .nonbinding) {
            if (n.misc.assign.assign_name) |text| db.sys_base.FreeVec(@ptrCast(@constCast(text)));
        }
        db.sys_base.FreeVec(n);
    }
    var seg = db.segments;
    while (seg) |s| {
        seg = s.next;
        db.sys_base.FreeVec(s);
    }
    const ub: *kutility.UtilityBase = @ptrCast(@alignCast(db.utility_base));
    _ = kexec.CloseLibrary(kexec.SysBase, &ub.lib);
    kexec.Remove(kexec.SysBase, &db.lib.node);
    kexec.freeLibraryMemory(kexec.SysBase, &db.lib);
    kutility.freeForTests(ub);
    try kexec.expectNoLeaks();
}

/// The library through the SDK's interface, the way a program calls it.
fn base(db: *DosBase) *interface.DosBase {
    return @ptrCast(db);
}

/// For the tests of dos's handlers (src/rom/handler): exec, utility and
/// dos as here, and taken down again with the leak check.
pub fn testSetUp() !*DosBase {
    return setUp();
}
pub fn testTearDown(db: *DosBase) !void {
    return tearDown(db);
}
pub fn testBase(db: *DosBase) *interface.DosBase {
    return base(db);
}

/// A Process on the test's stack, made the running task while `enter`ed:
/// exec's boot task stands in for the plain task outside.
const TestProcess = struct {
    proc: Process = .{},
    saved: ?*kexec.Task = null,

    fn enter(tp: *TestProcess) void {
        if (tp.proc.task.node.name == null) {
            tp.proc.task.node.name = "test process";
            process.initMsgPort(&tp.proc);
        }
        tp.saved = kexec.SysBase.this_task;
        kexec.SysBase.this_task = &tp.proc.task;
    }

    fn leave(tp: *TestProcess) void {
        kexec.SysBase.this_task = tp.saved.?;
    }
};

/// A handler's port that only queues: the test takes the packets itself.
fn handlerPort(port: *MsgPort) void {
    port.* = .{ .flags = exec.PA_IGNORE };
    port.msg_list.init(.message);
}

test "dos.library: made from its ROM tag, with utility.library open" {
    const db = try setUp();
    defer kexec.deinit();
    try testing.expectEqual(&db.lib.node, kexec.FindName(kexec.SysBase, &kexec.SysBase.lib_list, LIBRARY_NAME).?);
    try testing.expectEqual(@as(u16, dos_init.LIBRARY_VERSION), db.lib.version);
    try testing.expectEqualStrings(sdk.interface.utility.NAME, db.utility_base.lib().name());
    try tearDown(db);
}

test "IoErr and SetIoErr: pr_Result2 of a process; a task has none" {
    const db = try setUp();
    defer kexec.deinit();
    const dl = base(db);
    try testing.expectEqual(dos.ERROR_NO_PROCESS, dl.IoErr());
    try testing.expectEqual(@as(i32, 0), dl.SetIoErr(dos.ERROR_OBJECT_NOT_FOUND));

    var tp: TestProcess = .{};
    tp.enter();
    defer tp.leave();
    try testing.expectEqual(@as(i32, 0), dl.SetIoErr(dos.ERROR_OBJECT_NOT_FOUND));
    try testing.expectEqual(dos.ERROR_OBJECT_NOT_FOUND, dl.IoErr());
    try testing.expectEqual(dos.ERROR_OBJECT_NOT_FOUND, tp.proc.result2);
    try testing.expectEqual(dos.ERROR_OBJECT_NOT_FOUND, dl.SetIoErr(0));
    tp.leave();
    tp.enter(); // the defer leaves again
    try tearDown(db);
}

test "AllocDosObject: DOS_STDPKT is a cleared packet, DOS_RDARGS a cleared RDArgs" {
    const db = try setUp();
    defer kexec.deinit();
    const dl = base(db);
    var tp: TestProcess = .{};
    tp.enter();
    defer tp.leave();

    const pkt: *DosPacket = @ptrCast(@alignCast(dl.AllocDosObject(dos.DOS_STDPKT, null).?));
    try testing.expectEqual(@as(u16, @sizeOf(DosPacket)), pkt.msg.length);
    try testing.expectEqual(@as(?*MsgPort, null), pkt.port);
    try testing.expectEqual(@as(isize, 0), pkt.res1);
    try testing.expectEqual(@as(isize, 0), pkt.args.raw[6]);
    dl.FreeDosObject(dos.DOS_STDPKT, pkt);
    dl.FreeDosObject(dos.DOS_STDPKT, null);

    const rda: *dos.RDArgs = @ptrCast(@alignCast(dl.AllocDosObject(dos.DOS_RDARGS, null).?));
    try testing.expect(rda.buffer == null and rda.da_list == null and rda.flags == 0);
    dl.FreeDosObject(dos.DOS_RDARGS, rda);
    try testing.expectEqual(@as(?*anyopaque, null), dl.AllocDosObject(99, null));
    try tearDown(db);
}

test "SendPkt, ReplyPkt, WaitPkt: out and back, dp_Port swapped" {
    const db = try setUp();
    defer kexec.deinit();
    const dl = base(db);
    var handler: MsgPort = undefined;
    handlerPort(&handler);
    var tp: TestProcess = .{};
    tp.enter();

    var pkt = DosPacket.init(.nil, .{ .raw = .{ 7, 0, 0, 0, 0, 0, 0 } });
    dl.SendPkt(&pkt, &handler, &tp.proc.msg_port);
    try testing.expectEqual(&tp.proc.msg_port, pkt.port.?);
    try testing.expectEqual(&tp.proc.msg_port, pkt.msg.reply_port.?);

    // The handler, a plain task here, takes it and replies.
    tp.leave();
    const got = DosPacket.fromMessage(kexec.GetMsg(kexec.SysBase, &handler).?);
    try testing.expectEqual(&pkt, got);
    try testing.expectEqual(dos.ActionCode.nil, got.getAction());
    try testing.expectEqual(@as(isize, 7), got.args.raw[0]);
    dl.ReplyPkt(got, 42, dos.ERROR_ACTION_NOT_KNOWN);
    try testing.expectEqual(@as(?*MsgPort, null), pkt.port); // a task has no port to leave
    try testing.expectEqual(@as(?*DosPacket, null), dl.WaitPkt()); // nor one to wait at

    tp.enter();
    defer tp.leave();
    const back = dl.WaitPkt().?;
    try testing.expectEqual(&pkt, back);
    try testing.expectEqual(@as(isize, 42), back.res1);
    try testing.expectEqual(dos.ERROR_ACTION_NOT_KNOWN, back.res2);

    // A process's ReplyPkt leaves its own port: ping-pong.
    back.port = &handler;
    dl.ReplyPkt(back, 1, 0);
    try testing.expectEqual(&tp.proc.msg_port, pkt.port.?);
    try testing.expectEqual(&pkt.msg, kexec.GetMsg(kexec.SysBase, &handler).?);

    dl.ReplyPkt(null, 0, 0);
    dl.AbortPkt(&handler, &pkt);
    try tearDown(db);
}

/// pr_PktWait for the DoPkt tests: plays the handler, then takes the reply.
const PktWaitHandler = struct {
    var handler: MsgPort = undefined;
    var dl: *interface.DosBase = undefined;
    var seen: [5]isize = undefined;
    var stray: DosPacket = .{};

    /// Replies with the sum of the arguments and ERROR_OBJECT_EXISTS.
    fn reply(proc: *Process, sys: *ExecBase) callconv(.c) *exec.Message {
        const pkt = DosPacket.fromMessage(sys.GetMsg(&handler).?);
        seen = pkt.args.raw[0..5].*;
        var sum: isize = 0;
        for (seen) |a| sum += a;
        dl.ReplyPkt(pkt, sum, dos.ERROR_OBJECT_EXISTS);
        return sys.GetMsg(&proc.msg_port).?;
    }

    var calls: u32 = 0;
    /// Hands back a stray packet first, then answers DoPkt's.
    fn strayFirst(proc: *Process, sys: *ExecBase) callconv(.c) *exec.Message {
        calls += 1;
        if (calls == 1) return &stray.msg;
        return reply(proc, sys);
    }
};

test "DoPkt from a process: waits through pr_PktWait, res2 to IoErr, strays kept" {
    const db = try setUp();
    defer kexec.deinit();
    const dl = base(db);
    handlerPort(&PktWaitHandler.handler);
    PktWaitHandler.dl = dl;
    var tp: TestProcess = .{};
    tp.enter();
    defer tp.leave();

    tp.proc.pkt_wait = &PktWaitHandler.reply;
    try testing.expectEqual(@as(isize, 15), dl.DoPkt(&PktWaitHandler.handler, @intFromEnum(dos.ActionCode.nil), 1, 2, 3, 4, 5));
    try testing.expectEqual([5]isize{ 1, 2, 3, 4, 5 }, PktWaitHandler.seen);
    try testing.expectEqual(dos.ERROR_OBJECT_EXISTS, dl.IoErr());

    // A stray packet before its own: kept, and back on the port after.
    PktWaitHandler.calls = 0;
    tp.proc.pkt_wait = &PktWaitHandler.strayFirst;
    try testing.expectEqual(@as(isize, 3), dl.DoPkt(&PktWaitHandler.handler, @intFromEnum(dos.ActionCode.nil), 1, 2, 0, 0, 0));
    try testing.expectEqual(dos.ERROR_OBJECT_EXISTS, dl.IoErr());
    try testing.expectEqual(@as(u32, 2), PktWaitHandler.calls);
    try testing.expectEqual(&PktWaitHandler.stray.msg, kexec.GetMsg(kexec.SysBase, &tp.proc.msg_port).?);
    try testing.expectEqual(@as(?*exec.Message, null), kexec.GetMsg(kexec.SysBase, &tp.proc.msg_port));
    try tearDown(db);
}

/// NP_Entry for the CreateNewProc test.
const ProcEntry = struct {
    var ran: bool = false;
    fn run(_: *ExecBase) callconv(.c) void {
        ran = true;
    }
};

test "CreateNewProc: a process from NP_ tags, freed by RemTask" {
    const db = try setUp();
    defer kexec.deinit();
    const dl = base(db);
    var console: MsgPort = undefined;
    handlerPort(&console);
    var tp: TestProcess = .{};
    tp.proc.console_task = &console;
    tp.enter();
    defer tp.leave();

    const tags = [_]TagItem{
        .{ .tag = dos.NP_Entry, .data = @intFromPtr(&ProcEntry.run) },
        .{ .tag = dos.NP_Name, .data = @intFromPtr("worker") },
        .{ .tag = dos.NP_Priority, .data = @bitCast(@as(isize, -3)) },
        .{ .tag = dos.NP_StackSize, .data = 2000 },
        .{},
    };
    const proc = dl.CreateNewProc(&tags).?;
    try testing.expectEqual(exec.NodeType.process, proc.task.node.type); // AddTask left it
    try testing.expectEqualStrings("worker", proc.task.name());
    try testing.expectEqual(@as(i8, -3), proc.task.node.pri);
    try testing.expectEqual(exec.TaskState.ready, proc.task.state);
    try testing.expectEqual(@as(u32, 2000), proc.stack_size);
    try testing.expectEqual(@as(usize, 2000), proc.task.sp_upper - proc.task.sp_lower);
    try testing.expectEqual(proc.task.sp_upper, proc.stack_base);
    try testing.expectEqual(&console, proc.console_task.?); // from the parent
    try testing.expectEqual(@as(?*anyopaque, &proc.task), proc.msg_port.sig_task);
    try testing.expectEqual(@as(u8, exec.tasks.SIGB_DOS), proc.msg_port.sig_bit);
    try testing.expect(proc.msg_port.msg_list.isEmpty());

    ProcEntry.ran = false;
    runAs(proc);
    try testing.expect(ProcEntry.ran);
    kexec.RemTask(kexec.SysBase, &proc.task);

    try testing.expectEqual(@as(?*Process, null), dl.CreateNewProc(&[_]TagItem{.{}}));
    try testing.expectEqual(dos.ERROR_REQUIRED_ARG_MISSING, dl.IoErr());
    const no_entry: dos.SegCode = .{ .command = &TestCommand.run };
    const seglist = [_]TagItem{ .{ .tag = dos.NP_Seglist, .data = @intFromPtr(&no_entry) }, .{ .tag = dos.NP_Entry, .data = @intFromPtr(&ProcEntry.run) }, .{} };
    try testing.expectEqual(@as(?*Process, null), dl.CreateNewProc(&seglist)); // a command, no process entry
    try testing.expectEqual(dos.ERROR_OBJECT_WRONG_TYPE, dl.IoErr());
    const with_entry: dos.SegCode = .{ .entry = &ProcEntry.run };
    const from_code = dl.CreateNewProc(&[_]TagItem{ .{ .tag = dos.NP_Seglist, .data = @intFromPtr(&with_entry) }, .{} }).?;
    try testing.expectEqual(@as(?exec.TaskFn, &ProcEntry.run), from_code.task.init_pc);
    kexec.RemTask(kexec.SysBase, &from_code.task);
    try tearDown(db);
}

test "LockDosList: exactly one of READ and WRITE; the sentinel to start from" {
    const db = try setUp();
    defer kexec.deinit();
    const dl = base(db);
    try testing.expect(dl.LockDosList(dos.LDF_ALL) == null);
    try testing.expect(dl.LockDosList(dos.LDF_ALL | dos.LDF_READ | dos.LDF_WRITE) == null);
    try testing.expect(dl.LockDosList(dos.LDF_READ | 0x100) == null);
    const read = dos.LDF_ALL | dos.LDF_READ;
    try testing.expectEqual(&db.dos_list, dl.LockDosList(read).?);
    try testing.expectEqual(&db.dos_list, dl.AttemptLockDosList(read).?); // shared twice
    dl.UnLockDosList(read);
    dl.UnLockDosList(read);

    // The delete lock held by another task: no attempt gets it, and a failed
    // attempt gives back what it had taken.
    var other: kexec.Task = .{};
    db.delete_lock.owner = &other;
    db.delete_lock.queue_count = 0;
    db.delete_lock.nest_count = 1;
    try testing.expect(dl.AttemptLockDosList(dos.LDF_ALL | dos.LDF_ENTRY | dos.LDF_DELETE | dos.LDF_WRITE) == null);
    try testing.expectEqual(@as(i16, -1), db.dev_lock.queue_count);
    try testing.expectEqual(@as(i16, -1), db.entry_lock.queue_count);
    try testing.expect(dl.AttemptLockDosList(dos.LDF_DELETE | dos.LDF_READ) == null);
    db.delete_lock.owner = null;
    db.delete_lock.queue_count = -1;
    db.delete_lock.nest_count = 0;
    try tearDown(db);
}

test "AddDosEntry, FindDosEntry, NextDosEntry, RemDosEntry: the list's rules" {
    const db = try setUp();
    defer kexec.deinit();
    const dl = base(db);
    var tp: TestProcess = .{};
    tp.enter();
    defer tp.leave();

    try testing.expect(dl.MakeDosEntry("DF0", 99) == null); // no DLT_* value
    try testing.expectEqual(dos.ERROR_BAD_NUMBER, dl.IoErr());
    const df0 = dl.MakeDosEntry("DF0", dos.DLT_DEVICE).?;
    try testing.expectEqualStrings("DF0", std.mem.span(df0.name));
    try testing.expect(dl.AddDosEntry(df0));
    const dup = dl.MakeDosEntry("df0", dos.DLT_DEVICE).?;
    try testing.expect(!dl.AddDosEntry(dup)); // a device next to a device
    try testing.expectEqual(dos.ERROR_OBJECT_EXISTS, dl.IoErr());
    dl.FreeDosEntry(dup);
    const vol = dl.MakeDosEntry("DF0", dos.DLT_VOLUME).?;
    vol.misc.volume.volume_date = .{ .days = 1 };
    try testing.expect(dl.AddDosEntry(vol)); // a volume shadows a device
    const same = dl.MakeDosEntry("df0", dos.DLT_VOLUME).?;
    same.misc.volume.volume_date = .{ .days = 1 };
    try testing.expect(!dl.AddDosEntry(same)); // a volume of the same date
    dl.FreeDosEntry(same);
    const later = dl.MakeDosEntry("df0", dos.DLT_VOLUME).?;
    later.misc.volume.volume_date = .{ .days = 2 };
    try testing.expect(dl.AddDosEntry(later)); // another date
    const dev = dl.MakeDosEntry("DF0", dos.DLT_DEVICE).?;
    try testing.expect(!dl.AddDosEntry(dev)); // a device next to a volume
    dl.FreeDosEntry(dev);

    const read = dos.LDF_ALL | dos.LDF_READ;
    const start = dl.LockDosList(read).?;
    try testing.expectEqual(df0, dl.FindDosEntry(start, "df0", dos.LDF_DEVICES).?);
    try testing.expectEqual(later, dl.FindDosEntry(start, "Df0", dos.LDF_VOLUMES).?); // newest first
    try testing.expectEqual(vol, dl.FindDosEntry(later.next.?, "DF0", dos.LDF_VOLUMES).?);
    try testing.expect(dl.FindDosEntry(start, "DF1", dos.LDF_ALL) == null);
    try testing.expect(dl.FindDosEntry(start, "NIL", dos.LDF_VOLUMES) == null);
    var all: u32 = 0;
    var node = start;
    while (dl.NextDosEntry(node, dos.LDF_ALL)) |n| : (node = n) all += 1;
    try testing.expectEqual(@as(u32, 9), all); // two volumes, DF0, RAM, NIL, CON, RAW, AUX, PIPE
    var devices: u32 = 0;
    node = start;
    while (dl.NextDosEntry(node, dos.LDF_DEVICES)) |n| : (node = n) devices += 1;
    try testing.expectEqual(@as(u32, 7), devices); // DF0, RAM, NIL, CON, RAW, AUX, PIPE
    dl.UnLockDosList(read);

    const write = dos.LDF_ALL | dos.LDF_WRITE;
    _ = dl.LockDosList(write).?;
    try testing.expect(dl.RemDosEntry(vol));
    try testing.expect(!dl.RemDosEntry(vol));
    dl.UnLockDosList(write);
    dl.FreeDosEntry(vol);
    dl.FreeDosEntry(null);
    try tearDown(db);
}

test "dos's init adds NIL: as a device; its handler isn't started" {
    const db = try setUp();
    defer kexec.deinit();
    const dl = base(db);
    const read = dos.LDF_ALL | dos.LDF_READ;
    const node = dl.FindDosEntry(dl.LockDosList(read).?, "nil", dos.LDF_DEVICES).?;
    dl.UnLockDosList(read);
    try testing.expectEqual(dos.DosListType.device, node.type);
    try testing.expect(node.task == null);
    try testing.expectEqualStrings(dos_init.nil_handler_name, std.mem.span(node.misc.handler.handler.?));
    try testing.expect(node.misc.handler.entry == null); // found when first used
    try tearDown(db);
}

test "GetDeviceProc: devices, CONSOLE:, the current file system; what it refuses" {
    const db = try setUp();
    defer kexec.deinit();
    const dl = base(db);
    var console: MsgPort = undefined;
    handlerPort(&console);
    var tp: TestProcess = .{};
    tp.proc.console_task = &console;
    tp.enter();
    defer tp.leave();

    try testing.expect(dl.GetDeviceProc("FOO:bar", null) == null);
    try testing.expectEqual(dos.ERROR_DEVICE_NOT_MOUNTED, dl.IoErr());
    try testing.expect(dl.GetDeviceProc("ABCDEFGHIJKLMNOPQRSTUVWXYZabcde:", null) == null);
    try testing.expectEqual(dos.ERROR_INVALID_COMPONENT_NAME, dl.IoErr());
    try testing.expect(dl.GetDeviceProc("PROGDIR:x", null) == null); // no pr_HomeDir: a name like any
    try testing.expectEqual(dos.ERROR_DEVICE_NOT_MOUNTED, dl.IoErr());

    const con = dl.GetDeviceProc("console:", null).?;
    try testing.expectEqual(&console, con.port.?);
    try testing.expect(con.dev_node == null);
    dl.FreeDeviceProc(con);

    try testing.expect(dl.GetDeviceProc("file", null) == null); // no file system yet
    try testing.expectEqual(dos.ERROR_DEVICE_NOT_MOUNTED, dl.IoErr());
    tp.proc.file_system_task = &console;
    const fs = dl.GetDeviceProc(":dir/file", null).?;
    try testing.expectEqual(&console, fs.port.?);
    dl.FreeDeviceProc(fs);

    const tst = dl.MakeDosEntry("TST", dos.DLT_DEVICE).?;
    tst.task = &console;
    try testing.expect(dl.AddDosEntry(tst));
    const dp = dl.GetDeviceProc("tst:some/file", null).?;
    try testing.expectEqual(&console, dp.port.?);
    try testing.expectEqual(tst, dp.dev_node.?);
    try testing.expectEqual(@as(u32, 0), dp.flags);
    try testing.expect(dl.GetDeviceProc("tst:", dp) == null); // no multi-assign
    try testing.expectEqual(dos.ERROR_NO_MORE_ENTRIES, dl.IoErr());
    dl.FreeDeviceProc(dp);
    dl.FreeDeviceProc(null);
    try tearDown(db);
}

/// pr_PktWait for the handler start: plays the handler's STARTUP, then
/// takes the reply. `claim` is what the handler does with the node: a file
/// system or a serial console claims it and serves every later name from
/// the one process, a console in a window claims nothing and is started
/// again for the next one.
const StartupWait = struct {
    var dl: *interface.DosBase = undefined;
    var calls: u32 = 0;
    var action: dos.ActionCode = .nil;
    var name_arg: isize = 0;
    var node: ?*DosList = null;
    var claim: bool = true;

    /// nil-handler's entry in the test's segment; never run on the host.
    fn neverRun(_: *ExecBase) callconv(.c) void {}

    fn wait(proc: *Process, sys: *ExecBase) callconv(.c) *exec.Message {
        calls += 1;
        const handler: *Process = @fieldParentPtr("task", sys.FindTask("NIL").?);
        const pkt = DosPacket.fromMessage(sys.GetMsg(&handler.msg_port).?);
        action = pkt.getAction();
        name_arg = pkt.args.raw[0];
        node = @ptrFromInt(@as(usize, @bitCast(pkt.args.raw[2])));
        if (claim) if (node) |n| {
            n.task = &handler.msg_port;
        };
        dl.ReplyPkt(pkt, dos.DOSTRUE, 0);
        return sys.GetMsg(&proc.msg_port).?;
    }
};

test "GetDeviceProc starts a device's handler with ACTION_STARTUP, once" {
    const db = try setUp();
    defer kexec.deinit();
    const dl = base(db);
    StartupWait.dl = dl;
    StartupWait.calls = 0;
    StartupWait.claim = true;
    var tp: TestProcess = .{};
    tp.proc.pkt_wait = &StartupWait.wait;
    tp.enter();
    defer tp.leave();
    // The host scans no ROM tags: the test adds nil-handler's segment.
    try testing.expect(dl.AddSegment(dos_init.nil_handler_name, &never_code, dos.CMD_SYSTEM));

    const name: [*:0]const u8 = "nil:";
    const dp = dl.GetDeviceProc(name, null).?;
    const task = db.sys_base.FindTask("NIL").?;
    const handler: *Process = @fieldParentPtr("task", task);
    try testing.expectEqual(exec.NodeType.process, task.node.type);
    try testing.expectEqual(&handler.msg_port, dp.port.?);
    const node = dp.dev_node.?;
    try testing.expectEqual(@as(?exec.TaskFn, &StartupWait.neverRun), node.misc.handler.entry); // kept
    try testing.expectEqual(dos.ActionCode.startup, StartupWait.action);
    try testing.expectEqual(@as(isize, @bitCast(@intFromPtr(name))), StartupWait.name_arg);
    try testing.expectEqual(node, StartupWait.node.?);
    try testing.expectEqual(&handler.msg_port, node.task.?); // the handler claimed it
    dl.FreeDeviceProc(dp);

    const again = dl.GetDeviceProc("NIL:", null).?;
    try testing.expectEqual(&handler.msg_port, again.port.?);
    try testing.expectEqual(@as(u32, 1), StartupWait.calls); // nothing started again
    dl.FreeDeviceProc(again);

    kexec.RemTask(kexec.SysBase, task);
    node.task = null;
    try tearDown(db);
}

test "GetDeviceProc: a handler that claims nothing is started per name" {
    const db = try setUp();
    defer kexec.deinit();
    const dl = base(db);
    StartupWait.dl = dl;
    StartupWait.calls = 0;
    StartupWait.claim = false; // a console in a window: one Open, one window
    var tp: TestProcess = .{};
    tp.proc.pkt_wait = &StartupWait.wait;
    tp.enter();
    defer tp.leave();
    try testing.expect(dl.AddSegment(dos_init.nil_handler_name, &never_code, dos.CMD_SYSTEM));

    const dp = dl.GetDeviceProc("nil:", null).?;
    const first: *Process = @fieldParentPtr("task", db.sys_base.FindTask("NIL").?);
    try testing.expectEqual(&first.msg_port, dp.port.?);
    // The node is left as it was, so the name can be opened again.
    try testing.expectEqual(@as(?*exec.MsgPort, null), dp.dev_node.?.task);
    dl.FreeDeviceProc(dp);
    kexec.RemTask(kexec.SysBase, &first.task);

    const again = dl.GetDeviceProc("NIL:", null).?;
    const second: *Process = @fieldParentPtr("task", db.sys_base.FindTask("NIL").?);
    try testing.expectEqual(&second.msg_port, again.port.?);
    try testing.expectEqual(@as(u32, 2), StartupWait.calls); // started again
    dl.FreeDeviceProc(again);
    kexec.RemTask(kexec.SysBase, &second.task);

    StartupWait.claim = true;
    try tearDown(db);
}

test "GetDeviceProc: no segment for the handler" {
    const db = try setUp();
    defer kexec.deinit();
    const dl = base(db);
    var tp: TestProcess = .{};
    tp.enter();
    defer tp.leave();
    const node = dl.MakeDosEntry("GONE", dos.DLT_DEVICE).?;
    node.misc.handler.handler = "gone-handler";
    try testing.expect(dl.AddDosEntry(node));
    try testing.expect(dl.GetDeviceProc("GONE:", null) == null);
    try testing.expectEqual(dos.ERROR_OBJECT_NOT_FOUND, dl.IoErr());
    try testing.expect(node.task == null);
    try tearDown(db);
}

test "FilePart and PathPart: the autodocs' examples, and ways up" {
    const db = try setUp();
    defer kexec.deinit();
    const dl = base(db);
    const full: [*:0]const u8 = "xxx:yyy/zzz/qqq";
    try testing.expectEqual(full + 12, dl.FilePart(full));
    try testing.expectEqual(full + 11, dl.PathPart(full)); // the last slash
    const short: [*:0]const u8 = "xxx:yyy";
    try testing.expectEqual(short + 4, dl.FilePart(short));
    try testing.expectEqual(short + 4, dl.PathPart(short));
    const plain: [*:0]const u8 = "file";
    try testing.expectEqual(plain, dl.PathPart(plain));
    const up: [*:0]const u8 = "a//b"; // the second slash is a way up
    try testing.expectEqual(up + 3, dl.PathPart(up));
    const root: [*:0]const u8 = "dev:/x";
    try testing.expectEqual(root + 5, dl.PathPart(root));
    const trailing: [*:0]const u8 = "dir/";
    try testing.expectEqualStrings("", std.mem.span(dl.FilePart(trailing)));
    try tearDown(db);
}

fn setPath(buf: *[32:0]u8, text: []const u8) void {
    @memset(buf, 0);
    @memcpy(buf[0..text.len], text);
}

test "AddPart: slashes, colons, and nothing changed on overflow" {
    const db = try setUp();
    defer kexec.deinit();
    const dl = base(db);
    var tp: TestProcess = .{};
    tp.enter();
    defer tp.leave();
    var buf: [32:0]u8 = undefined;
    const cases = [_]struct { dir: []const u8, file: [*:0]const u8, want: []const u8 }{
        .{ .dir = "dh0:foo", .file = "bar", .want = "dh0:foo/bar" },
        .{ .dir = "dh0:", .file = "bar", .want = "dh0:bar" },
        .{ .dir = "dh0:foo/", .file = "bar", .want = "dh0:foo/bar" },
        .{ .dir = "dh0:foo", .file = ":s", .want = "dh0:s" },
        .{ .dir = "foo", .file = ":s", .want = ":s" },
        .{ .dir = "dh0:foo", .file = "ram:x", .want = "ram:x" },
        .{ .dir = "", .file = "x", .want = "x" },
        .{ .dir = "dh0:foo", .file = "/up", .want = "dh0:foo//up" },
    };
    for (cases) |c| {
        setPath(&buf, c.dir);
        try testing.expect(dl.AddPart(&buf, c.file, buf.len));
        try testing.expectEqualStrings(c.want, std.mem.span(@as([*:0]u8, &buf)));
    }
    setPath(&buf, "dh0:foo");
    try testing.expect(!dl.AddPart(&buf, "bar", 11)); // needs 12 with the NUL
    try testing.expectEqual(dos.ERROR_LINE_TOO_LONG, dl.IoErr());
    try testing.expectEqualStrings("dh0:foo", std.mem.span(@as([*:0]u8, &buf)));
    try testing.expect(dl.AddPart(&buf, "bar", 12));
    try testing.expect(!dl.AddPart(&buf, "x", 0));
    try tearDown(db);
}

test "SplitName: part by part, a long part cut, past the end" {
    const db = try setUp();
    defer kexec.deinit();
    const dl = base(db);
    var part: [8]u8 = undefined;
    const name: [*:0]const u8 = "dir/sub/file";
    try testing.expectEqual(@as(i32, 4), dl.SplitName(name, '/', &part, 0, part.len));
    try testing.expectEqualStrings("dir", std.mem.sliceTo(&part, 0));
    try testing.expectEqual(@as(i32, 8), dl.SplitName(name, '/', &part, 4, part.len));
    try testing.expectEqualStrings("sub", std.mem.sliceTo(&part, 0));
    try testing.expectEqual(@as(i32, -1), dl.SplitName(name, '/', &part, 8, part.len));
    try testing.expectEqualStrings("file", std.mem.sliceTo(&part, 0));
    try testing.expectEqual(@as(i32, 7), dl.SplitName("abcdef/x", '/', &part, 0, 3));
    try testing.expectEqualStrings("ab", std.mem.sliceTo(&part, 0));
    try testing.expectEqual(@as(i32, -1), dl.SplitName(name, '/', &part, 20, part.len));
    try testing.expectEqualStrings("", std.mem.sliceTo(&part, 0));
    try tearDown(db);
}

test "ParsePath: absolute, root, relative; device names up to 30 characters" {
    const db = try setUp();
    defer kexec.deinit();
    const dl = base(db);
    var tp: TestProcess = .{};
    tp.enter();
    defer tp.leave();
    var pp: dos.ParsedPath = .{};
    try testing.expect(dl.ParsePath("DH0:s/startup", &pp));
    try testing.expectEqual(dos.PathType.absolute, pp.path_type);
    try testing.expectEqualStrings("DH0", std.mem.sliceTo(&pp.volume, 0));
    try testing.expectEqualStrings("s/startup", std.mem.span(pp.remainder));
    try testing.expect(dl.ParsePath(":c", &pp));
    try testing.expectEqual(dos.PathType.root, pp.path_type);
    try testing.expectEqualStrings("", std.mem.sliceTo(&pp.volume, 0));
    try testing.expectEqualStrings("c", std.mem.span(pp.remainder));
    try testing.expect(dl.ParsePath("c/dir", &pp));
    try testing.expectEqual(dos.PathType.relative, pp.path_type);
    try testing.expectEqualStrings("c/dir", std.mem.span(pp.remainder));
    try testing.expect(dl.ParsePath("ABCDEFGHIJKLMNOPQRSTUVWXYZabcd:x", &pp)); // 30
    try testing.expect(!dl.ParsePath("ABCDEFGHIJKLMNOPQRSTUVWXYZabcde:x", &pp)); // 31
    try testing.expectEqual(dos.ERROR_INVALID_COMPONENT_NAME, dl.IoErr());
    try tearDown(db);
}

test "AddSegment and FindSegment: names in any case, system or not, from a start" {
    const db = try setUp();
    defer kexec.deinit();
    const dl = base(db);
    var tp: TestProcess = .{};
    tp.enter();
    defer tp.leave();
    try testing.expect(dl.AddSegment("sys-thing", &never_code, dos.CMD_SYSTEM));
    try testing.expect(dl.AddSegment("Cmd", null, 0));
    try testing.expect(dl.AddSegment("cmd", null, 0)); // a second one of the name
    try testing.expect(dl.AddSegment("off", null, dos.CMD_DISABLED));

    const first = dl.LockSegmentList(true).?;
    try testing.expectEqualStrings("off", std.mem.span(first.name)); // newest first
    const sys = dl.FindSegment("SYS-THING", null, true).?;
    try testing.expectEqual(dos.CMD_SYSTEM, sys.uc);
    try testing.expectEqual(@as(?exec.TaskFn, &StartupWait.neverRun), sys.code.entry);
    try testing.expect(dl.FindSegment("sys-thing", null, false) == null);
    try testing.expectEqual(dos.ERROR_OBJECT_NOT_FOUND, dl.IoErr());
    const cmd = dl.FindSegment("CMD", null, false).?;
    try testing.expectEqualStrings("cmd", std.mem.span(cmd.name)); // the newer
    const older = dl.FindSegment("cmd", cmd, false).?;
    try testing.expectEqualStrings("Cmd", std.mem.span(older.name));
    try testing.expect(dl.FindSegment("cmd", older, false) == null);
    try testing.expect(dl.FindSegment("cmd", null, true) == null);
    try testing.expect(dl.FindSegment("off", null, true) != null); // any count below 0
    try testing.expectEqual(first, dl.LockSegmentList(true).?); // shared twice
    dl.UnLockSegmentList();
    dl.UnLockSegmentList();
    try tearDown(db);
}

test "RemSegment: only a user segment nobody uses" {
    const db = try setUp();
    defer kexec.deinit();
    const dl = base(db);
    var tp: TestProcess = .{};
    tp.enter();
    defer tp.leave();
    try testing.expect(dl.AddSegment("cmd", null, 0));
    try testing.expect(dl.AddSegment("sys", null, dos.CMD_SYSTEM));
    _ = dl.LockSegmentList(false);
    const cmd = dl.FindSegment("cmd", null, false).?;
    const sys = dl.FindSegment("sys", null, true).?;
    cmd.uc += 1; // in use, as a shell running a resident command
    dl.UnLockSegmentList();
    try testing.expect(!dl.RemSegment(cmd));
    try testing.expectEqual(dos.ERROR_OBJECT_IN_USE, dl.IoErr());
    try testing.expect(!dl.RemSegment(sys));
    _ = dl.LockSegmentList(false);
    cmd.uc -= 1;
    dl.UnLockSegmentList();
    try testing.expect(dl.RemSegment(cmd));
    _ = dl.LockSegmentList(true);
    try testing.expect(dl.FindSegment("cmd", null, false) == null);
    dl.UnLockSegmentList();
    var stray: dos.Segment = .{ .name = "stray" };
    try testing.expect(!dl.RemSegment(&stray));
    try testing.expectEqual(dos.ERROR_OBJECT_NOT_FOUND, dl.IoErr());
    try tearDown(db);
}

/// pr_PktWait for the lock tests: plays a file system on its port, with a
/// root, a directory and a copy lock of its own.
const FakeFs = struct {
    var port: MsgPort = undefined;
    var dl: *interface.DosBase = undefined;
    var calls: u32 = 0;
    var action: dos.ActionCode = .nil;
    var args: [7]isize = @splat(0);
    /// ACTION_SAME_LOCK's answer; null: not known.
    var same: ?bool = null;
    /// READ, WRITE, SEEK and END fail.
    var io_fail: bool = false;
    var root: FileLock = .{ .key = 1, .task = &port };
    var dir: FileLock = .{ .key = 2, .task = &port };
    var copy: FileLock = .{ .key = 2, .task = &port };

    fn at(l: *FileLock) isize {
        return @bitCast(@intFromPtr(l));
    }

    /// The name in dp_Arg`index` ends in "missing".
    fn missing(pkt: *DosPacket, index: usize) bool {
        const name: [*:0]const u8 = @ptrFromInt(@as(usize, @bitCast(pkt.args.raw[index])));
        return std.mem.endsWith(u8, std.mem.span(name), "missing");
    }

    fn wait(proc: *Process, sys: *ExecBase) callconv(.c) *exec.Message {
        const pkt = DosPacket.fromMessage(sys.GetMsg(&port).?);
        calls += 1;
        action = pkt.getAction();
        args = pkt.args.raw;
        var res1: isize = 0;
        var res2: i32 = 0;
        switch (action) {
            .locate_object, .create_dir => if (missing(pkt, 1)) {
                res2 = dos.ERROR_OBJECT_NOT_FOUND;
            } else {
                res1 = at(&dir);
            },
            .delete_object => if (missing(pkt, 1)) {
                res2 = dos.ERROR_OBJECT_NOT_FOUND;
            } else {
                res1 = dos.DOSTRUE;
            },
            .free_lock => res1 = dos.DOSTRUE,
            .copy_dir => res1 = at(&copy),
            .parent => res1 = if (args[0] == 0) 0 else at(&root), // the root has none
            .same_lock => if (same) |yes| {
                res1 = if (yes) dos.DOSTRUE else dos.DOSFALSE;
            } else {
                res2 = dos.ERROR_ACTION_NOT_KNOWN;
            },
            .findinput, .findoutput, .findupdate => if (missing(pkt, 2)) {
                res2 = dos.ERROR_OBJECT_NOT_FOUND;
            } else {
                pkt.args.find.fh.?.key = &dir;
                res1 = dos.DOSTRUE;
            },
            .read, .write, .seek => if (io_fail) {
                res1 = -1;
                res2 = if (action == .seek) dos.ERROR_SEEK_ERROR else dos.ERROR_DISK_FULL;
            } else {
                res1 = switch (action) {
                    .read => 7, // bytes "read"
                    .write => args[2], // all of them
                    else => 42, // the old position
                };
            },
            .end => if (io_fail) {
                res2 = dos.ERROR_DISK_FULL;
            } else {
                res1 = dos.DOSTRUE;
            },
            .examine_all => res2 = dos.ERROR_NO_MORE_ENTRIES, // a handler that knows it: done at once
            .examine_all_end => res1 = dos.DOSTRUE,
            else => res2 = dos.ERROR_ACTION_NOT_KNOWN,
        }
        dl.ReplyPkt(pkt, res1, res2);
        return sys.GetMsg(&proc.msg_port).?;
    }

    /// The device "FS" with this file system running, and the test
    /// process waiting through it.
    fn mount(db: *DosBase, tp: *TestProcess) !void {
        dl = base(db);
        handlerPort(&port);
        calls = 0;
        same = null;
        io_fail = false;
        const node = dl.MakeDosEntry("FS", dos.DLT_DEVICE).?;
        node.task = &port;
        try testing.expect(dl.AddDosEntry(node));
        tp.proc.pkt_wait = &wait;
    }
};

test "Lock: the name's handler, its directory, the full name, the mode" {
    const db = try setUp();
    defer kexec.deinit();
    const dl = base(db);
    var tp: TestProcess = .{};
    tp.enter();
    defer tp.leave();
    try FakeFs.mount(db, &tp);

    const name: [*:0]const u8 = "FS:dir";
    try testing.expectEqual(&FakeFs.dir, dl.Lock(name, dos.EXCLUSIVE_LOCK).?);
    try testing.expectEqual(dos.ActionCode.locate_object, FakeFs.action);
    try testing.expectEqual(@as(isize, 0), FakeFs.args[0]); // the device's root
    try testing.expectEqual(@as(isize, @bitCast(@intFromPtr(name))), FakeFs.args[1]);
    try testing.expectEqual(@as(isize, dos.EXCLUSIVE_LOCK), FakeFs.args[2]);

    try testing.expect(dl.Lock("FS:missing", dos.SHARED_LOCK) == null);
    try testing.expectEqual(dos.ERROR_OBJECT_NOT_FOUND, dl.IoErr());
    try testing.expect(dl.Lock("NOPE:x", dos.SHARED_LOCK) == null);
    try testing.expectEqual(dos.ERROR_DEVICE_NOT_MOUNTED, dl.IoErr());
    const long = "FS:" ++ "x" ** 253; // 256 characters
    try testing.expect(dl.Lock(long, dos.SHARED_LOCK) == null);
    try testing.expectEqual(dos.ERROR_LINE_TOO_LONG, dl.IoErr());

    try testing.expectEqual(&FakeFs.dir, dl.CreateDir("FS:new").?);
    try testing.expectEqual(dos.ActionCode.create_dir, FakeFs.action);
    try testing.expect(dl.DeleteFile("FS:old"));
    try testing.expectEqual(dos.ActionCode.delete_object, FakeFs.action);
    try testing.expect(!dl.DeleteFile("FS:missing"));
    try testing.expectEqual(dos.ERROR_OBJECT_NOT_FOUND, dl.IoErr());
    try tearDown(db);
}

test "CurrentDir and names without a device" {
    const db = try setUp();
    defer kexec.deinit();
    const dl = base(db);
    var tp: TestProcess = .{};
    tp.enter();
    defer tp.leave();
    try FakeFs.mount(db, &tp);

    try testing.expect(dl.CurrentDir(&FakeFs.dir) == null);
    try testing.expectEqual(&FakeFs.dir, dl.Lock("sub", dos.SHARED_LOCK).?);
    try testing.expectEqual(FakeFs.at(&FakeFs.dir), FakeFs.args[0]); // from the current directory
    _ = dl.Lock(":top", dos.SHARED_LOCK).?;
    try testing.expectEqual(@as(isize, 0), FakeFs.args[0]); // from its volume's root
    const dp = dl.GetDeviceProc("sub", null).?;
    try testing.expectEqual(&FakeFs.port, dp.port.?);
    try testing.expectEqual(&FakeFs.dir, dp.lock.?);
    dl.FreeDeviceProc(dp);

    try testing.expectEqual(&FakeFs.dir, dl.CurrentDir(null).?); // cleared, and the old one back
    try testing.expect(dl.CurrentDir(null) == null);
    try testing.expect(dl.Lock("sub", dos.SHARED_LOCK) == null); // no file system yet
    try testing.expectEqual(dos.ERROR_DEVICE_NOT_MOUNTED, dl.IoErr());
    tp.leave();
    try testing.expect(dl.CurrentDir(&FakeFs.dir) == null); // a plain task has none
    tp.enter();
    try tearDown(db);
}

test "UnLock, DupLock, ParentDir: to the lock's handler, lock 0 to the file system" {
    const db = try setUp();
    defer kexec.deinit();
    const dl = base(db);
    var tp: TestProcess = .{};
    tp.enter();
    defer tp.leave();
    try FakeFs.mount(db, &tp);

    _ = dl.SetIoErr(dos.ERROR_DISK_FULL);
    dl.UnLock(&FakeFs.dir);
    try testing.expectEqual(dos.ActionCode.free_lock, FakeFs.action);
    try testing.expectEqual(FakeFs.at(&FakeFs.dir), FakeFs.args[0]);
    try testing.expectEqual(dos.ERROR_DISK_FULL, dl.IoErr()); // kept
    const calls = FakeFs.calls;
    dl.UnLock(null);
    try testing.expect(dl.DupLock(null) == null);
    try testing.expectEqual(calls, FakeFs.calls); // no packets for null

    try testing.expectEqual(&FakeFs.copy, dl.DupLock(&FakeFs.dir).?);
    try testing.expectEqual(dos.ActionCode.copy_dir, FakeFs.action);
    try testing.expectEqual(&FakeFs.root, dl.ParentDir(&FakeFs.dir).?);
    try testing.expectEqual(dos.ActionCode.parent, FakeFs.action);

    try testing.expect(dl.ParentDir(null) == null); // no file system
    try testing.expectEqual(dos.ERROR_DEVICE_NOT_MOUNTED, dl.IoErr());
    tp.proc.file_system_task = &FakeFs.port;
    try testing.expect(dl.ParentDir(null) == null); // the root has no parent
    try testing.expectEqual(@as(i32, 0), dl.IoErr());
    try testing.expectEqual(@as(isize, 0), FakeFs.args[0]);
    try tearDown(db);
}

test "SameLock: its checks and values" {
    const db = try setUp();
    defer kexec.deinit();
    const dl = base(db);
    var tp: TestProcess = .{};
    tp.enter();
    defer tp.leave();
    try FakeFs.mount(db, &tp);

    try testing.expectEqual(dos.LOCK_SAME, dl.SameLock(&FakeFs.dir, &FakeFs.dir));
    try testing.expectEqual(dos.LOCK_DIFFERENT, dl.SameLock(&FakeFs.dir, null));
    var elsewhere: FileLock = .{ .key = 2, .task = &FakeFs.port, .volume = db.dos_list.next };
    try testing.expectEqual(dos.LOCK_DIFFERENT, dl.SameLock(&FakeFs.dir, &elsewhere));
    FakeFs.same = true;
    try testing.expectEqual(dos.LOCK_SAME, dl.SameLock(&FakeFs.dir, &FakeFs.root));
    FakeFs.same = false;
    try testing.expectEqual(dos.LOCK_SAME_VOLUME, dl.SameLock(&FakeFs.dir, &FakeFs.copy));
    FakeFs.same = null; // not known: the keys tell
    try testing.expectEqual(dos.LOCK_SAME, dl.SameLock(&FakeFs.dir, &FakeFs.copy));
    try testing.expectEqual(dos.LOCK_SAME_VOLUME, dl.SameLock(&FakeFs.dir, &FakeFs.root));
    try tearDown(db);
}

test "DateStamp: days, minutes and ticks since 1978; zero without timer.device" {
    try testing.expectEqual(dos.DateStamp{ .days = 2, .minute = 61, .tick = 75 }, date.fromSysTime(2 * 86400 + 3661, 500_000));
    try testing.expectEqual(dos.DateStamp{ .days = 0, .minute = 1439, .tick = 2999 }, date.fromSysTime(86399, 999_999));
    const db = try setUp();
    defer kexec.deinit();
    const dl = base(db);
    var ds: dos.DateStamp = .{ .days = 5 };
    try testing.expectEqual(&ds, dl.DateStamp(&ds));
    try testing.expectEqual(dos.DateStamp{}, ds); // the host has no timer.device
    try tearDown(db);
}

test "Open: the FIND action for each mode, the handle, the full name" {
    const db = try setUp();
    defer kexec.deinit();
    const dl = base(db);
    var tp: TestProcess = .{};
    tp.enter();
    defer tp.leave();
    try FakeFs.mount(db, &tp);

    const name: [*:0]const u8 = "FS:file";
    const modes = [_]struct { i32, dos.ActionCode }{
        .{ dos.MODE_OLDFILE, .findinput },
        .{ dos.MODE_NEWFILE, .findoutput },
        .{ dos.MODE_READWRITE, .findupdate },
    };
    for (modes) |m| {
        const fh = dl.Open(name, m[0]).?;
        try testing.expectEqual(m[1], FakeFs.action);
        try testing.expectEqual(FakeFs.at(@ptrCast(fh)), FakeFs.args[0]);
        try testing.expectEqual(@as(isize, 0), FakeFs.args[1]); // the device's root
        try testing.expectEqual(@as(isize, @bitCast(@intFromPtr(name))), FakeFs.args[2]);
        try testing.expectEqual(&FakeFs.port, fh.task.?);
        try testing.expectEqual(@as(?*anyopaque, &FakeFs.dir), fh.key); // the handler's
        try testing.expect(dl.Close(fh));
        try testing.expectEqual(dos.ActionCode.end, FakeFs.action);
    }
    try testing.expect(dl.Open("FS:missing", dos.MODE_OLDFILE) == null);
    try testing.expectEqual(dos.ERROR_OBJECT_NOT_FOUND, dl.IoErr());
    try testing.expect(dl.Open("FS:file", 7) == null);
    try testing.expectEqual(dos.ERROR_ACTION_NOT_KNOWN, dl.IoErr());
    try testing.expect(dl.Open("NOPE:x", dos.MODE_OLDFILE) == null);
    try testing.expectEqual(dos.ERROR_DEVICE_NOT_MOUNTED, dl.IoErr());
    try testing.expect(!dl.Close(null));
    try tearDown(db); // the failed opens' handles are freed
}

test "Open(\"*\"): the console, or NIL: without one" {
    const db = try setUp();
    defer kexec.deinit();
    const dl = base(db);
    var tp: TestProcess = .{};
    tp.enter();
    defer tp.leave();
    try FakeFs.mount(db, &tp);
    const read = dos.LDF_ALL | dos.LDF_READ;
    const nil_node = dl.FindDosEntry(dl.LockDosList(read).?, "NIL", dos.LDF_DEVICES).?;
    dl.UnLockDosList(read);
    nil_node.task = &FakeFs.port; // the fake answers for NIL:

    const quiet = dl.Open("*", dos.MODE_NEWFILE).?;
    const quiet_name: [*:0]const u8 = @ptrFromInt(@as(usize, @bitCast(FakeFs.args[2])));
    try testing.expectEqualStrings("NIL:", std.mem.span(quiet_name));
    try testing.expect(dl.Close(quiet));
    tp.proc.console_task = &FakeFs.port;
    const console = dl.Open("*", dos.MODE_NEWFILE).?;
    const console_name: [*:0]const u8 = @ptrFromInt(@as(usize, @bitCast(FakeFs.args[2])));
    try testing.expectEqualStrings("CONSOLE:", std.mem.span(console_name));
    try testing.expect(dl.Close(console));
    nil_node.task = null;
    try tearDown(db);
}

test "Read, Write, Seek: the handler's answers; -1 with IoErr; Close" {
    const db = try setUp();
    defer kexec.deinit();
    const dl = base(db);
    var tp: TestProcess = .{};
    tp.enter();
    defer tp.leave();
    try FakeFs.mount(db, &tp);
    const fh = dl.Open("FS:file", dos.MODE_READWRITE).?;
    var buf: [16]u8 = undefined;

    try testing.expectEqual(@as(isize, 7), dl.Read(fh, &buf, buf.len));
    try testing.expectEqual(dos.ActionCode.read, FakeFs.action);
    try testing.expectEqual(FakeFs.at(@ptrCast(fh)), FakeFs.args[0]);
    try testing.expectEqual(@as(isize, @bitCast(@intFromPtr(&buf))), FakeFs.args[1]);
    try testing.expectEqual(@as(isize, 16), FakeFs.args[2]);
    try testing.expectEqual(@as(isize, 5), dl.Write(fh, "hello", 5));
    try testing.expectEqual(@as(isize, 42), dl.Seek(fh, 10, dos.OFFSET_BEGINNING));
    try testing.expectEqual(dos.ActionCode.seek, FakeFs.action);
    try testing.expectEqual(@as(isize, dos.OFFSET_BEGINNING), FakeFs.args[2]);

    FakeFs.io_fail = true;
    try testing.expectEqual(@as(isize, -1), dl.Write(fh, "x", 1));
    try testing.expectEqual(dos.ERROR_DISK_FULL, dl.IoErr());
    try testing.expectEqual(@as(isize, -1), dl.Seek(fh, 0, dos.OFFSET_END));
    try testing.expectEqual(dos.ERROR_SEEK_ERROR, dl.IoErr());
    try testing.expectEqual(@as(isize, -1), dl.Read(null, &buf, 1));
    try testing.expectEqual(dos.ERROR_INVALID_LOCK, dl.IoErr());
    try testing.expect(!dl.Close(fh)); // END fails; the handle is freed all the same
    try testing.expectEqual(dos.ERROR_DISK_FULL, dl.IoErr());
    try tearDown(db);
}

test "Input, Output, SelectInput, SelectOutput, IsInteractive" {
    const db = try setUp();
    defer kexec.deinit();
    const dl = base(db);
    var console: FileHandle = .{ .interactive = true };
    var file: FileHandle = .{};
    var tp: TestProcess = .{};
    tp.enter();
    try testing.expect(dl.Input() == null);
    try testing.expect(dl.SelectInput(&console) == null);
    try testing.expectEqual(&console, dl.Input().?);
    try testing.expect(dl.SelectOutput(&file) == null);
    try testing.expectEqual(&file, dl.Output().?);
    try testing.expectEqual(&file, dl.SelectOutput(null).?); // null goes too
    try testing.expect(dl.Output() == null);
    try testing.expect(dl.IsInteractive(&console));
    try testing.expect(!dl.IsInteractive(&file));
    try testing.expect(!dl.IsInteractive(null));
    tp.leave();
    try testing.expect(dl.Input() == null); // a plain task has none
    try testing.expect(dl.SelectInput(&file) == null);
    try tearDown(db);
}

const ram = @import("../../handler/ram/ram.zig");

/// pr_PktWait with a real RAM: disk behind the port: dos's packets as the
/// handler gets them.
const RamFs = struct {
    var port: MsgPort = undefined;
    var disk: ram.RamDisk = undefined;
    var dl: *interface.DosBase = undefined;

    fn wait(proc: *Process, sys: *ExecBase) callconv(.c) *exec.Message {
        const pkt = DosPacket.fromMessage(sys.GetMsg(&port).?);
        const reply = disk.answer(pkt);
        dl.ReplyPkt(pkt, reply.res1, reply.res2);
        return sys.GetMsg(&proc.msg_port).?;
    }

    /// A RAM: disk as "RAMT", the test process waiting through it.
    fn mount(db: *DosBase, tp: *TestProcess) !void {
        dl = base(db);
        handlerPort(&port);
        disk = try ram.RamDisk.init(db.sys_base, dl, db.utility_base, &port);
        const node = dl.MakeDosEntry("RAMT", dos.DLT_DEVICE).?;
        node.task = &port;
        try testing.expect(dl.AddDosEntry(node));
        tp.proc.pkt_wait = &wait;
    }
};

/// A file of `len` bytes, through Open, Write and Close.
fn makeFile(dl: *interface.DosBase, name: [*:0]const u8, len: usize) !void {
    const fh = dl.Open(name, dos.MODE_NEWFILE).?;
    var bytes: [64]u8 = @splat('x');
    try testing.expectEqual(@as(isize, @intCast(len)), dl.Write(fh, &bytes, @intCast(len)));
    try testing.expect(dl.Close(fh));
}

test "Open, Write, Seek, Read, Close on a RAM: disk" {
    const db = try setUp();
    defer kexec.deinit();
    const dl = base(db);
    var tp: TestProcess = .{};
    tp.enter();
    defer tp.leave();
    try RamFs.mount(db, &tp);

    var data: [3000]u8 = undefined;
    for (&data, 0..) |*b, i| b.* = @truncate(i * 7);
    var back: [5000]u8 = undefined;
    const out = dl.Open("RAMT:file", dos.MODE_NEWFILE).?;
    try testing.expectEqual(@as(isize, 3000), dl.Write(out, &data, data.len));
    try testing.expectEqual(@as(isize, 3000), dl.Seek(out, 0, dos.OFFSET_BEGINNING));
    try testing.expectEqual(@as(isize, 3000), dl.Read(out, &back, 3000));
    try testing.expectEqualSlices(u8, &data, back[0..3000]);
    try testing.expect(dl.Close(out));

    const in = dl.Open("ramt:FILE", dos.MODE_OLDFILE).?;
    try testing.expectEqual(@as(isize, 3000), dl.Read(in, &back, back.len));
    try testing.expectEqual(@as(isize, 0), dl.Read(in, &back, back.len)); // the end
    try testing.expectEqual(@as(isize, -1), dl.Seek(in, 1, dos.OFFSET_END));
    try testing.expectEqual(dos.ERROR_SEEK_ERROR, dl.IoErr());
    try testing.expect(dl.Close(in));
    try testing.expect(dl.Open("RAMT:none", dos.MODE_OLDFILE) == null);
    try testing.expectEqual(dos.ERROR_OBJECT_NOT_FOUND, dl.IoErr());

    RamFs.disk.deinit();
    try tearDown(db);
}

test "Examine, ExNext, ExamineFH on a RAM: disk" {
    const db = try setUp();
    defer kexec.deinit();
    const dl = base(db);
    var tp: TestProcess = .{};
    tp.enter();
    defer tp.leave();
    try RamFs.mount(db, &tp);
    dl.UnLock(dl.CreateDir("RAMT:d").?);
    for ([_][*:0]const u8{ "RAMT:d/one", "RAMT:d/two", "RAMT:d/three" }) |name| try makeFile(dl, name, 3);

    const dir = dl.Lock("RAMT:d", dos.SHARED_LOCK).?;
    var fib: dos.FileInfoBlock = .{ .owner_uid = 7 };
    try testing.expect(dl.Examine(dir, &fib));
    try testing.expectEqualStrings("d", std.mem.sliceTo(&fib.file_name, 0));
    try testing.expectEqual(dos.ST_USERDIR, fib.dir_entry_type);
    try testing.expectEqual(@as(u16, 0), fib.owner_uid); // cleared by dos
    var count: u32 = 0;
    while (dl.ExNext(dir, &fib)) {
        try testing.expectEqual(dos.ST_FILE, fib.dir_entry_type);
        try testing.expectEqual(@as(u64, 3), fib.size);
        count += 1;
    }
    try testing.expectEqual(@as(u32, 3), count);
    try testing.expectEqual(dos.ERROR_NO_MORE_ENTRIES, dl.IoErr());
    try testing.expect(!dl.ExNext(null, &fib));
    try testing.expectEqual(dos.ERROR_INVALID_LOCK, dl.IoErr());

    const fh = dl.Open("RAMT:d/two", dos.MODE_OLDFILE).?;
    try testing.expect(dl.ExamineFH(fh, &fib));
    try testing.expectEqualStrings("two", std.mem.sliceTo(&fib.file_name, 0));
    try testing.expectEqual(@as(u64, 3), fib.size);
    try testing.expect(dl.Close(fh));
    dl.UnLock(dir);
    RamFs.disk.deinit();
    try tearDown(db);
}

/// ExAll's hook for the test: leaves out the names starting with 'b'.
fn skipB(_: *sdk.utility.Hook, object: ?*anyopaque, message: ?*anyopaque) callconv(.c) usize {
    const level: *i32 = @ptrCast(@alignCast(object.?));
    const rec: *dos.ExAllData = @ptrCast(@alignCast(message.?));
    if (level.* < dos.ED_NAME) return 0;
    return if (rec.name.?[0] == 'b') 0 else 1;
}

test "ExAll, emulated for RAM:: everything, piece by piece, levels, hook, ExAllEnd" {
    const db = try setUp();
    defer kexec.deinit();
    const dl = base(db);
    var tp: TestProcess = .{};
    tp.enter();
    defer tp.leave();
    try RamFs.mount(db, &tp);
    dl.UnLock(dl.CreateDir("RAMT:d").?);
    const names = [_][*:0]const u8{ "RAMT:d/alpha", "RAMT:d/beta", "RAMT:d/bravo", "RAMT:d/charlie", "RAMT:d/delta" };
    for (names, 0..) |name, i| try makeFile(dl, name, i + 1);
    const dir = dl.Lock("RAMT:d", dos.SHARED_LOCK).?;
    const eac: *dos.ExAllControl = @ptrCast(@alignCast(dl.AllocDosObject(dos.DOS_EXALLCONTROL, null).?));
    try testing.expectEqual(@as(usize, 0), eac.last_key);

    var buf: [4096]u8 align(8) = undefined;
    try testing.expect(!dl.ExAll(dir, &buf, buf.len, dos.ED_SIZE, eac)); // all of it at once
    try testing.expectEqual(dos.ERROR_NO_MORE_ENTRIES, dl.IoErr());
    try testing.expectEqual(@as(u32, 5), eac.entries);
    try testing.expectEqual(@as(usize, 0), eac.last_key);
    var total: u64 = 0;
    var seen: u32 = 0;
    var ed: ?*dos.ExAllData = @ptrCast(@alignCast(&buf));
    while (ed) |e| : (ed = e.next) {
        try testing.expectEqual(@as(usize, 0), @intFromPtr(e) % @alignOf(dos.ExAllData));
        try testing.expectEqual(dos.ST_FILE, e.type);
        total += e.size;
        seen += 1;
    }
    try testing.expectEqual(@as(u32, 5), seen);
    try testing.expectEqual(@as(u64, 1 + 2 + 3 + 4 + 5), total);

    var small: [48]u8 align(8) = undefined; // one or two records at a time
    var calls: u32 = 0;
    var got: u32 = 0;
    while (true) {
        const more = dl.ExAll(dir, &small, small.len, dos.ED_NAME, eac);
        got += eac.entries;
        calls += 1;
        if (!more) break;
        try testing.expect(eac.last_key != 0);
    }
    try testing.expectEqual(@as(u32, 5), got);
    try testing.expect(calls > 2);
    try testing.expectEqual(dos.ERROR_NO_MORE_ENTRIES, dl.IoErr());

    // Too small for one record: the listing ends rather than answering
    // "more" with nothing, forever.
    var tiny: [8]u8 align(8) = undefined;
    try testing.expect(!dl.ExAll(dir, &tiny, tiny.len, dos.ED_NAME, eac));
    try testing.expectEqual(dos.ERROR_BUFFER_OVERFLOW, dl.IoErr());
    try testing.expectEqual(@as(usize, 0), eac.last_key);

    var hook: sdk.utility.Hook = .{ .entry = &skipB };
    eac.match_func = &hook;
    try testing.expect(!dl.ExAll(dir, &buf, buf.len, dos.ED_COMMENT, eac));
    try testing.expectEqual(@as(u32, 3), eac.entries); // not beta, not bravo
    const first: *dos.ExAllData = @ptrCast(@alignCast(&buf));
    try testing.expectEqualStrings("", std.mem.span(first.comment.?));
    eac.match_func = null;

    try testing.expect(!dl.ExAll(dir, &buf, buf.len, 0, eac));
    try testing.expectEqual(dos.ERROR_BAD_NUMBER, dl.IoErr());
    try testing.expect(!dl.ExAll(dir, &buf, buf.len, dos.ED_OWNER + 1, eac));
    var tokens: [16]u8 = undefined; // ParsePatternNoCase's, as ExAll's hook wants
    try testing.expectEqual(@as(isize, 1), db.utility_base.ParsePatternNoCase("B#?", &tokens, tokens.len));
    eac.match_string = @ptrCast(&tokens);
    try testing.expect(!dl.ExAll(dir, &buf, buf.len, dos.ED_NAME, eac));
    try testing.expectEqual(@as(u32, 2), eac.entries); // beta, bravo
    eac.match_string = null;
    const file = dl.Lock("RAMT:d/alpha", dos.SHARED_LOCK).?;
    try testing.expect(!dl.ExAll(file, &buf, buf.len, dos.ED_NAME, eac));
    try testing.expectEqual(dos.ERROR_OBJECT_WRONG_TYPE, dl.IoErr());
    dl.UnLock(file);
    try testing.expect(!dl.ExAll(null, &buf, buf.len, dos.ED_NAME, eac)); // the root of no file system
    try testing.expectEqual(dos.ERROR_DEVICE_NOT_MOUNTED, dl.IoErr());

    try testing.expect(dl.ExAll(dir, &small, small.len, dos.ED_NAME, eac)); // more to come
    try testing.expect(eac.last_key != 0);
    dl.ExAllEnd(dir, &small, small.len, dos.ED_NAME, eac);
    try testing.expectEqual(@as(usize, 0), eac.last_key); // its FIB freed (the leak check below)

    dl.FreeDosObject(dos.DOS_EXALLCONTROL, eac);
    dl.UnLock(dir);
    RamFs.disk.deinit();
    try tearDown(db);
}

test "ExAll on a handler that knows EXAMINE_ALL: its packet; ExAllEnd asks it to stop" {
    const db = try setUp();
    defer kexec.deinit();
    const dl = base(db);
    var tp: TestProcess = .{};
    tp.enter();
    defer tp.leave();
    try FakeFs.mount(db, &tp);
    var eac: dos.ExAllControl = .{};
    var buf: [64]u8 align(8) = undefined;
    try testing.expect(!dl.ExAll(&FakeFs.dir, &buf, buf.len, dos.ED_TYPE, &eac));
    try testing.expectEqual(dos.ActionCode.examine_all, FakeFs.action);
    try testing.expectEqual(FakeFs.at(&FakeFs.dir), FakeFs.args[0]);
    try testing.expectEqual(@as(isize, @bitCast(@intFromPtr(&buf))), FakeFs.args[1]);
    try testing.expectEqual(@as(isize, 64), FakeFs.args[2]);
    try testing.expectEqual(@as(isize, dos.ED_TYPE), FakeFs.args[3]);
    try testing.expectEqual(@as(isize, @bitCast(@intFromPtr(&eac))), FakeFs.args[4]);
    try testing.expectEqual(dos.ERROR_NO_MORE_ENTRIES, dl.IoErr());
    dl.ExAllEnd(&FakeFs.dir, &buf, buf.len, dos.ED_TYPE, &eac);
    try testing.expectEqual(dos.ActionCode.examine_all_end, FakeFs.action);
    try tearDown(db);
}

test "the process's context: Cli, the error stream, handlers, program dir; plain tasks" {
    const db = try setUp();
    defer kexec.deinit();
    const dl = base(db);
    const port_a: *MsgPort = @ptrFromInt(0x1000);
    const port_b: *MsgPort = @ptrFromInt(0x2000);
    const fh: *FileHandle = @ptrFromInt(0x3000);
    const lock: *FileLock = @ptrFromInt(0x4000);

    // A plain task: nothing to read, nothing changes.
    try testing.expectEqual(@as(?*dos.CommandLineInterface, null), dl.Cli());
    try testing.expectEqual(@as(?*MsgPort, null), dl.SetConsoleTask(port_a));
    try testing.expectEqual(@as(?*MsgPort, null), dl.GetConsoleTask());
    try testing.expectEqual(@as(?*FileHandle, null), dl.SelectError(fh));
    try testing.expectEqual(@as(?*FileHandle, null), dl.ErrorOutput());

    var tp: TestProcess = .{};
    tp.enter();
    defer tp.leave();
    try testing.expectEqual(@as(?*dos.CommandLineInterface, null), dl.Cli()); // not a CLI
    try testing.expectEqual(@as(?*FileHandle, null), dl.SelectError(fh));
    try testing.expectEqual(@as(?*FileHandle, fh), dl.ErrorOutput());
    try testing.expectEqual(@as(?*FileHandle, fh), dl.SelectError(null));
    try testing.expectEqual(@as(?*FileHandle, null), tp.proc.ces);

    try testing.expectEqual(@as(?*MsgPort, null), dl.SetConsoleTask(port_a));
    try testing.expectEqual(@as(?*MsgPort, port_a), dl.GetConsoleTask());
    try testing.expectEqual(@as(?*MsgPort, port_a), dl.SetConsoleTask(port_b));
    try testing.expectEqual(@as(?*MsgPort, port_b), tp.proc.console_task);
    try testing.expectEqual(@as(?*MsgPort, null), dl.SetFileSysTask(port_b));
    try testing.expectEqual(@as(?*MsgPort, port_b), dl.GetFileSysTask());
    try testing.expectEqual(@as(?*MsgPort, port_b), dl.SetFileSysTask(null));
    try testing.expectEqual(@as(?*MsgPort, null), tp.proc.file_system_task);
    try testing.expectEqual(@as(?*FileLock, null), dl.SetProgramDir(lock));
    try testing.expectEqual(@as(?*FileLock, lock), dl.GetProgramDir());
    try testing.expectEqual(@as(?*FileLock, lock), dl.SetProgramDir(null));
    tp.proc.console_task = null;
    try tearDown(db);
}

test "the CLI's names: prompt, program name, directory name; too long; no CLI" {
    const db = try setUp();
    defer kexec.deinit();
    const dl = base(db);
    var tp: TestProcess = .{};
    tp.enter();
    defer tp.leave();
    var buf: [32]u8 = @splat('?');

    try testing.expect(!dl.GetPrompt(&buf, buf.len)); // no CLI
    try testing.expectEqual(@as(u8, 0), buf[0]);
    try testing.expectEqual(dos.ERROR_OBJECT_WRONG_TYPE, dl.IoErr());
    try testing.expect(!dl.SetPrompt("1> "));
    try testing.expectEqual(dos.ERROR_OBJECT_WRONG_TYPE, dl.IoErr());

    const c: *dos.CommandLineInterface = @ptrCast(@alignCast(dl.AllocDosObject(dos.DOS_CLI, null).?));
    try testing.expectEqual(dos.CLI_INITIAL_FAIL_LEVEL, c.fail_level);
    try testing.expect(c.background);
    tp.proc.cli = c;
    try testing.expectEqual(c, dl.Cli().?);
    try testing.expect(dl.GetPrompt(&buf, buf.len));
    try testing.expectEqualStrings("", std.mem.sliceTo(&buf, 0));
    try testing.expect(dl.SetPrompt("1> "));
    try testing.expect(dl.GetPrompt(&buf, buf.len));
    try testing.expectEqualStrings("1> ", std.mem.sliceTo(&buf, 0));
    try testing.expect(dl.SetProgramName("list"));
    try testing.expect(dl.GetProgramName(&buf, buf.len));
    try testing.expectEqualStrings("list", std.mem.sliceTo(&buf, 0));
    try testing.expect(dl.SetCurrentDirName("Ram Disk:d"));
    try testing.expect(dl.GetCurrentDirName(&buf, buf.len));
    try testing.expectEqualStrings("Ram Disk:d", std.mem.sliceTo(&buf, 0));

    var small: [5]u8 = undefined; // a cut copy, and false
    try testing.expect(!dl.GetCurrentDirName(&small, small.len));
    try testing.expectEqualStrings("Ram ", std.mem.sliceTo(&small, 0));
    try testing.expectEqual(dos.ERROR_LINE_TOO_LONG, dl.IoErr());
    try testing.expect(!dl.GetPrompt(&small, 0));

    var long: [dos.CLI_MAX_PROMPT + 1]u8 = @splat('p');
    long[dos.CLI_MAX_PROMPT] = 0; // no room for its NUL: refused, nothing changes
    try testing.expect(!dl.SetPrompt(@ptrCast(&long)));
    try testing.expectEqual(dos.ERROR_LINE_TOO_LONG, dl.IoErr());
    try testing.expect(dl.GetPrompt(&buf, buf.len));
    try testing.expectEqualStrings("1> ", std.mem.sliceTo(&buf, 0));
    long[dos.CLI_MAX_PROMPT - 1] = 0; // just fits
    try testing.expect(dl.SetPrompt(@ptrCast(&long)));
    try testing.expectEqual(dos.CLI_MAX_PROMPT - 1, std.mem.len(c.prompt.?));
    try testing.expect(dl.SetProgramName(c.command_name.?)); // its own buffer
    try testing.expectEqualStrings("list", std.mem.span(c.command_name.?));

    tp.proc.cli = null;
    dl.FreeDosObject(dos.DOS_CLI, c);
    try tearDown(db);
}

test "NameFromLock, and GetCurrentDirName without a CLI, on a RAM: disk" {
    const db = try setUp();
    defer kexec.deinit();
    const dl = base(db);
    var tp: TestProcess = .{};
    tp.enter();
    defer tp.leave();
    try RamFs.mount(db, &tp);
    dl.UnLock(dl.CreateDir("RAMT:d").?);
    dl.UnLock(dl.CreateDir("RAMT:d/sub").?);
    try makeFile(dl, "RAMT:d/sub/file", 1);

    var buf: [64]u8 = undefined;
    const sub = dl.Lock("RAMT:d/sub", dos.SHARED_LOCK).?;
    try testing.expect(dl.NameFromLock(sub, &buf, buf.len));
    try testing.expectEqualStrings("Ram Disk:d/sub", std.mem.sliceTo(&buf, 0));
    const file = dl.Lock("RAMT:d/sub/file", dos.SHARED_LOCK).?;
    try testing.expect(dl.NameFromLock(file, &buf, buf.len));
    try testing.expectEqualStrings("Ram Disk:d/sub/file", std.mem.sliceTo(&buf, 0));
    dl.UnLock(file);
    const root = dl.Lock("RAMT:", dos.SHARED_LOCK).?;
    try testing.expect(dl.NameFromLock(root, &buf, buf.len));
    try testing.expectEqualStrings("Ram Disk:", std.mem.sliceTo(&buf, 0));
    dl.UnLock(root);

    try testing.expect(!dl.NameFromLock(null, &buf, buf.len)); // no file system
    try testing.expectEqual(dos.ERROR_DEVICE_NOT_MOUNTED, dl.IoErr());
    tp.proc.file_system_task = &RamFs.port;
    try testing.expect(dl.NameFromLock(null, &buf, buf.len)); // its root
    try testing.expectEqualStrings("Ram Disk:", std.mem.sliceTo(&buf, 0));

    var small: [12]u8 = undefined;
    try testing.expect(!dl.NameFromLock(sub, &small, small.len));
    try testing.expectEqual(dos.ERROR_LINE_TOO_LONG, dl.IoErr());
    try testing.expectEqual(@as(u8, 0), small[0]);
    try testing.expect(!dl.NameFromLock(sub, &buf, 0));
    try testing.expectEqual(dos.ERROR_LINE_TOO_LONG, dl.IoErr());

    try testing.expectEqual(@as(?*FileLock, null), dl.CurrentDir(sub));
    try testing.expect(dl.GetCurrentDirName(&buf, buf.len)); // no CLI: NameFromLock
    try testing.expectEqualStrings("Ram Disk:d/sub", std.mem.sliceTo(&buf, 0));
    try testing.expectEqual(@as(?*FileLock, sub), dl.CurrentDir(null));
    dl.UnLock(sub);
    tp.proc.file_system_task = null;
    RamFs.disk.deinit();
    try tearDown(db);
}

test "CreateNewProc with NP_Cli: a CLI from the parent's, in the process's block" {
    const db = try setUp();
    defer kexec.deinit();
    const dl = base(db);
    var tp: TestProcess = .{};
    tp.enter();
    defer tp.leave();
    const mine: *dos.CommandLineInterface = @ptrCast(@alignCast(dl.AllocDosObject(dos.DOS_CLI, null).?));
    tp.proc.cli = mine;
    try testing.expect(dl.SetPrompt("1> "));
    try testing.expect(dl.SetProgramName("shell"));
    try testing.expect(dl.SetCurrentDirName("Ram Disk:d"));
    mine.fail_level = 20;

    const tags = [_]TagItem{
        .{ .tag = dos.NP_Entry, .data = @intFromPtr(&ProcEntry.run) },
        .{ .tag = dos.NP_Cli, .data = 1 },
        .{ .tag = dos.NP_StackSize, .data = 4096 },
        .{},
    };
    const proc = dl.CreateNewProc(&tags).?;
    const c = proc.cli.?;
    const block = @intFromPtr(proc.task.mem_block);
    try testing.expect(@intFromPtr(c) > block and @intFromPtr(c) < proc.task.sp_lower);
    try testing.expectEqualStrings("1> ", std.mem.span(c.prompt.?));
    try testing.expectEqualStrings("shell", std.mem.span(c.command_name.?));
    try testing.expectEqualStrings("Ram Disk:d", std.mem.span(c.set_name.?));
    try testing.expectEqualStrings("", std.mem.span(c.command_file.?));
    try testing.expectEqual(@as(i32, 20), c.fail_level);
    try testing.expectEqual(@as(u32, 4096), c.default_stack);
    try testing.expect(c.background);
    runAs(proc);
    kexec.RemTask(kexec.SysBase, &proc.task);

    tp.proc.cli = null; // no parent CLI: the default prompt; NP_CommandName
    const named = [_]TagItem{
        .{ .tag = dos.NP_Entry, .data = @intFromPtr(&ProcEntry.run) },
        .{ .tag = dos.NP_Cli, .data = 1 },
        .{ .tag = dos.NP_CommandName, .data = @intFromPtr("worker") },
        .{},
    };
    const other = dl.CreateNewProc(&named).?;
    try testing.expectEqualStrings(dos.CLI_DEFAULT_PROMPT, std.mem.span(other.cli.?.prompt.?));
    try testing.expectEqualStrings("worker", std.mem.span(other.cli.?.command_name.?));
    try testing.expectEqualStrings("", std.mem.span(other.cli.?.set_name.?));
    runAs(other);
    kexec.RemTask(kexec.SysBase, &other.task);

    var long: [dos.CLI_MAX_COMMAND_NAME + 1]u8 = @splat('n');
    long[dos.CLI_MAX_COMMAND_NAME] = 0;
    const too_long = [_]TagItem{
        .{ .tag = dos.NP_Entry, .data = @intFromPtr(&ProcEntry.run) },
        .{ .tag = dos.NP_Cli, .data = 1 },
        .{ .tag = dos.NP_CommandName, .data = @intFromPtr(&long) },
        .{},
    };
    try testing.expectEqual(@as(?*Process, null), dl.CreateNewProc(&too_long));
    try testing.expectEqual(dos.ERROR_LINE_TOO_LONG, dl.IoErr());
    const plain = [_]TagItem{ .{ .tag = dos.NP_Entry, .data = @intFromPtr(&ProcEntry.run) }, .{} };
    const no_cli = dl.CreateNewProc(&plain).?;
    try testing.expectEqual(@as(?*dos.CommandLineInterface, null), no_cli.cli);
    runAs(no_cli);
    kexec.RemTask(kexec.SysBase, &no_cli.task);

    dl.FreeDosObject(dos.DOS_CLI, mine);
    try tearDown(db);
}

test "AssignLock: a name for a directory; replaced, removed; what it refuses" {
    const db = try setUp();
    defer kexec.deinit();
    const dl = base(db);
    var tp: TestProcess = .{};
    tp.enter();
    defer tp.leave();
    try RamFs.mount(db, &tp);
    dl.UnLock(dl.CreateDir("RAMT:d").?);
    try makeFile(dl, "RAMT:d/f", 3);
    var buf: [64]u8 = undefined;

    const d = dl.Lock("RAMT:d", dos.SHARED_LOCK).?;
    try testing.expect(dl.AssignLock("X", d)); // dos keeps d
    const dp = dl.GetDeviceProc("x:f", null).?;
    try testing.expectEqual(d, dp.lock.?);
    try testing.expectEqual(d.task.?, dp.port.?);
    try testing.expectEqual(dos.DosListType.directory, dp.dev_node.?.type);
    try testing.expectEqual(@as(u32, 0), dp.flags);
    dl.FreeDeviceProc(dp);
    const f = dl.Lock("X:f", dos.SHARED_LOCK).?;
    try testing.expect(dl.NameFromLock(f, &buf, buf.len));
    try testing.expectEqualStrings("Ram Disk:d/f", std.mem.sliceTo(&buf, 0));
    dl.UnLock(f);

    try testing.expect(dl.AssignLock("X", dl.Lock("RAMT:", dos.SHARED_LOCK).?)); // replaced; d unlocked
    dl.UnLock(dl.Lock("X:d/f", dos.SHARED_LOCK).?);

    const spare = dl.Lock("RAMT:d", dos.SHARED_LOCK).?;
    try testing.expect(!dl.AssignLock("RAMT", spare)); // a device's name
    try testing.expectEqual(dos.ERROR_OBJECT_EXISTS, dl.IoErr());
    try testing.expect(!dl.AssignLock("ABCDEFGHIJKLMNOPQRSTUVWXYZabcde", spare));
    try testing.expectEqual(dos.ERROR_INVALID_COMPONENT_NAME, dl.IoErr());
    try testing.expect(!dl.AssignLock("", spare));
    dl.UnLock(spare); // still ours

    try testing.expect(dl.AssignLock("X", null));
    try testing.expect(dl.Lock("X:d", dos.SHARED_LOCK) == null);
    try testing.expectEqual(dos.ERROR_DEVICE_NOT_MOUNTED, dl.IoErr());
    try testing.expect(dl.AssignLock("nothere", null)); // nothing to remove
    RamFs.disk.deinit();
    try tearDown(db);
}

test "multi-assigns: AssignAdd, GetDeviceProc's next directory, RemAssignList by SameLock" {
    const db = try setUp();
    defer kexec.deinit();
    const dl = base(db);
    var tp: TestProcess = .{};
    tp.enter();
    defer tp.leave();
    try RamFs.mount(db, &tp);
    dl.UnLock(dl.CreateDir("RAMT:a").?);
    dl.UnLock(dl.CreateDir("RAMT:b").?);
    try makeFile(dl, "RAMT:a/both", 1);
    try makeFile(dl, "RAMT:b/both", 2);
    try makeFile(dl, "RAMT:b/only", 3);
    var buf: [64]u8 = undefined;

    const a = dl.Lock("RAMT:a", dos.SHARED_LOCK).?;
    const b = dl.Lock("RAMT:b", dos.SHARED_LOCK).?;
    try testing.expect(dl.AssignLock("M", a));
    try testing.expect(dl.AssignAdd("M", b));
    const only = dl.Lock("M:only", dos.SHARED_LOCK).?; // not in a: found in b
    try testing.expect(dl.NameFromLock(only, &buf, buf.len));
    try testing.expectEqualStrings("Ram Disk:b/only", std.mem.sliceTo(&buf, 0));
    dl.UnLock(only);
    const both = dl.Lock("M:both", dos.SHARED_LOCK).?; // the first directory's
    try testing.expect(dl.NameFromLock(both, &buf, buf.len));
    try testing.expectEqualStrings("Ram Disk:a/both", std.mem.sliceTo(&buf, 0));
    dl.UnLock(both);

    const dp = dl.GetDeviceProc("M:x", null).?;
    try testing.expectEqual(a, dp.lock.?);
    try testing.expectEqual(dos.DVPF_ASSIGN, dp.flags);
    try testing.expectEqual(dp, dl.GetDeviceProc("M:x", dp).?); // moved on
    try testing.expectEqual(b, dp.lock.?);
    try testing.expectEqual(@as(u32, 0), dp.flags); // b is the last
    try testing.expect(dl.GetDeviceProc("M:x", dp) == null);
    try testing.expectEqual(dos.ERROR_NO_MORE_ENTRIES, dl.IoErr());
    dl.FreeDeviceProc(dp);

    const spare = dl.Lock("RAMT:", dos.SHARED_LOCK).?;
    try testing.expect(!dl.AssignAdd("nothere", spare));
    try testing.expectEqual(dos.ERROR_OBJECT_NOT_FOUND, dl.IoErr());
    try testing.expect(!dl.RemAssignList("M", spare)); // not one of its directories
    try testing.expectEqual(dos.ERROR_OBJECT_NOT_FOUND, dl.IoErr());
    dl.UnLock(spare);

    const again_a = dl.Lock("RAMT:a", dos.SHARED_LOCK).?; // a fresh lock: SameLock finds it
    try testing.expect(dl.RemAssignList("M", again_a)); // the first: b moves up
    dl.UnLock(again_a);
    const moved = dl.GetDeviceProc("M:x", null).?;
    try testing.expectEqual(b, moved.lock.?);
    try testing.expectEqual(@as(u32, 0), moved.flags);
    dl.FreeDeviceProc(moved);
    const again_b = dl.Lock("RAMT:b", dos.SHARED_LOCK).?;
    try testing.expect(dl.RemAssignList("M", again_b)); // the last: the assign goes
    dl.UnLock(again_b);
    try testing.expect(dl.GetDeviceProc("M:x", null) == null);
    try testing.expectEqual(dos.ERROR_DEVICE_NOT_MOUNTED, dl.IoErr());

    try testing.expect(dl.AssignLate("L", "RAMT:a"));
    const c = dl.Lock("RAMT:b", dos.SHARED_LOCK).?;
    try testing.expect(!dl.AssignAdd("L", c)); // not a plain assign
    try testing.expectEqual(dos.ERROR_OBJECT_WRONG_TYPE, dl.IoErr());
    dl.UnLock(c);
    try testing.expect(dl.AssignLock("L", null));
    RamFs.disk.deinit();
    try tearDown(db);
}

test "late and non-binding assigns, PROGDIR:, an assign to itself" {
    const db = try setUp();
    defer kexec.deinit();
    const dl = base(db);
    var tp: TestProcess = .{};
    tp.enter();
    defer tp.leave();
    try RamFs.mount(db, &tp);
    dl.UnLock(dl.CreateDir("RAMT:d").?);
    try makeFile(dl, "RAMT:d/f", 3);
    var buf: [64]u8 = undefined;
    const read = dos.LDF_ALL | dos.LDF_READ;

    try testing.expect(dl.AssignLate("L", "RAMT:d"));
    const late = dl.FindDosEntry(dl.LockDosList(read).?, "L", dos.LDF_ASSIGNS).?;
    dl.UnLockDosList(read);
    try testing.expectEqual(dos.DosListType.late, late.type);
    try testing.expectEqualStrings("RAMT:d", std.mem.span(late.misc.assign.assign_name.?));
    dl.UnLock(dl.Lock("L:f", dos.SHARED_LOCK).?); // bound now
    try testing.expectEqual(dos.DosListType.directory, late.type);
    try testing.expect(late.lock != null);
    try testing.expect(late.misc.assign.assign_name == null);

    try testing.expect(dl.AssignLate("BAD", "RAMT:none"));
    try testing.expect(dl.Lock("BAD:f", dos.SHARED_LOCK) == null);
    try testing.expectEqual(dos.ERROR_OBJECT_NOT_FOUND, dl.IoErr());

    try testing.expect(dl.AssignPath("P", "RAMT:d"));
    const dp = dl.GetDeviceProc("P:f", null).?;
    try testing.expectEqual(dos.DVPF_UNLOCK, dp.flags);
    try testing.expect(dp.lock != null);
    dl.FreeDeviceProc(dp); // unlocks it
    dl.UnLock(dl.Lock("P:f", dos.SHARED_LOCK).?);

    try testing.expect(dl.AssignLate("S", "S:x"));
    try testing.expect(dl.Lock("S:x", dos.SHARED_LOCK) == null);
    try testing.expectEqual(dos.ERROR_TOO_MANY_LEVELS, dl.IoErr());
    try testing.expect(dl.AssignPath("Q", "Q:"));
    try testing.expect(dl.Lock("Q:", dos.SHARED_LOCK) == null);
    try testing.expectEqual(dos.ERROR_TOO_MANY_LEVELS, dl.IoErr());

    try testing.expect(dl.Lock("PROGDIR:f", dos.SHARED_LOCK) == null); // no pr_HomeDir
    try testing.expectEqual(dos.ERROR_DEVICE_NOT_MOUNTED, dl.IoErr());
    tp.proc.home_dir = dl.Lock("RAMT:d", dos.SHARED_LOCK).?;
    const pd = dl.Lock("PROGDIR:f", dos.SHARED_LOCK).?;
    try testing.expect(dl.NameFromLock(pd, &buf, buf.len));
    try testing.expectEqualStrings("Ram Disk:d/f", std.mem.sliceTo(&buf, 0));
    dl.UnLock(pd);
    dl.UnLock(tp.proc.home_dir);
    tp.proc.home_dir = null;

    for ([_][*:0]const u8{ "L", "BAD", "P", "S", "Q" }) |n| try testing.expect(dl.AssignLock(n, null));
    RamFs.disk.deinit();
    try tearDown(db);
}

/// An AnchorPath with room for full paths after it.
const Anchor = extern struct {
    ap: dos.AnchorPath = .{},
    buf: [96]u8 = @splat(0),

    fn path(a: *Anchor) []const u8 {
        return std.mem.sliceTo(&a.buf, 0);
    }
};

/// A whole search: each full path once, and nothing else.
fn expectFinds(dl: *interface.DosBase, a: *Anchor, pattern: [*:0]const u8, want: []const []const u8) !void {
    var seen: [8]bool = @splat(false);
    var count: usize = 0;
    var rc = dl.MatchFirst(pattern, &a.ap);
    while (rc == 0) : (rc = dl.MatchNext(&a.ap)) {
        const got = a.path();
        const i = for (want, 0..) |w, i| {
            if (std.mem.eql(u8, w, got)) break i;
        } else {
            std.debug.print("{s}: found {s}\n", .{ pattern, got });
            return error.TestUnexpectedResult;
        };
        try testing.expect(!seen[i]);
        seen[i] = true;
        count += 1;
    }
    try testing.expectEqual(dos.ERROR_NO_MORE_ENTRIES, rc);
    try testing.expectEqual(want.len, count);
    try testing.expect(a.ap.base == null); // the chain went
}

test "MatchFirst/MatchNext on a RAM: disk: patterns, levels, plain names, full paths" {
    const db = try setUp();
    defer kexec.deinit();
    const dl = base(db);
    var tp: TestProcess = .{};
    tp.enter();
    defer tp.leave();
    try RamFs.mount(db, &tp);
    dl.UnLock(dl.CreateDir("RAMT:d").?);
    dl.UnLock(dl.CreateDir("RAMT:d/sub").?);
    for ([_][*:0]const u8{ "RAMT:d/a.txt", "RAMT:d/b.txt", "RAMT:d/c.doc", "RAMT:d/sub/x.txt" }) |name| try makeFile(dl, name, 2);
    var a: Anchor = .{};
    a.ap.strlen = a.buf.len;

    try expectFinds(dl, &a, "RAMT:d/#?.txt", &.{ "RAMT:d/a.txt", "RAMT:d/b.txt" });
    try testing.expect(a.ap.flags & dos.APF_ITSWILD != 0);
    try expectFinds(dl, &a, "ramt:D/#?.TXT", &.{ "ramt:D/a.txt", "ramt:D/b.txt" }); // no case
    try expectFinds(dl, &a, "RAMT:#?/#?.txt", &.{ "RAMT:d/a.txt", "RAMT:d/b.txt" });
    try expectFinds(dl, &a, "RAMT:d/#?/x.txt", &.{"RAMT:d/sub/x.txt"});
    try expectFinds(dl, &a, "RAMT:d/#?.none", &.{});
    try expectFinds(dl, &a, "RAMT:d/c.doc", &.{"RAMT:d/c.doc"}); // its last name kept
    try testing.expect(a.ap.flags & dos.APF_ITSWILD == 0);
    try testing.expectEqualStrings("c.doc", std.mem.sliceTo(&a.ap.info.file_name, 0));
    try expectFinds(dl, &a, "RAMT:d/sub", &.{"RAMT:d/sub"});
    try testing.expectEqual(dos.ERROR_OBJECT_NOT_FOUND, dl.MatchFirst("RAMT:d/none", &a.ap));
    try testing.expectEqual(dos.ERROR_OBJECT_NOT_FOUND, dl.IoErr());
    try testing.expect(a.ap.base == null);
    try testing.expectEqual(dos.ERROR_DEVICE_NOT_MOUNTED, dl.MatchFirst("FOO:#?", &a.ap));

    const d = dl.Lock("RAMT:d", dos.SHARED_LOCK).?;
    const old = dl.CurrentDir(d);
    try expectFinds(dl, &a, "#?.txt", &.{ "a.txt", "b.txt" }); // from the current directory
    dl.UnLock(dl.CurrentDir(old));
    RamFs.disk.deinit();
    try tearDown(db);
}

test "MatchNext: DODIR and DIDDIR, a break, a full path too long, the single entry of *" {
    const db = try setUp();
    defer kexec.deinit();
    const dl = base(db);
    var tp: TestProcess = .{};
    tp.enter();
    defer tp.leave();
    try RamFs.mount(db, &tp);
    dl.UnLock(dl.CreateDir("RAMT:d").?);
    dl.UnLock(dl.CreateDir("RAMT:d/sub").?);
    try makeFile(dl, "RAMT:d/a.txt", 1);
    try makeFile(dl, "RAMT:d/sub/x.txt", 1);
    var a: Anchor = .{};
    a.ap.strlen = a.buf.len;

    var entries: u32 = 0;
    var did: u32 = 0;
    var inner = false;
    var rc = dl.MatchFirst("RAMT:d/#?", &a.ap);
    while (rc == 0) : (rc = dl.MatchNext(&a.ap)) {
        entries += 1;
        if (a.ap.flags & dos.APF_DIDDIR != 0) {
            did += 1;
            try testing.expectEqualStrings("RAMT:d/sub", a.path());
            a.ap.flags &= ~dos.APF_DIDDIR;
            continue;
        }
        if (std.mem.eql(u8, a.path(), "RAMT:d/sub/x.txt")) inner = true;
        if (a.ap.info.dir_entry_type > 0) a.ap.flags |= dos.APF_DODIR;
    }
    try testing.expectEqual(dos.ERROR_NO_MORE_ENTRIES, rc);
    try testing.expect(inner);
    try testing.expectEqual(@as(u32, 1), did);
    try testing.expectEqual(@as(u32, 4), entries); // a.txt, sub, sub/x.txt, sub again

    try testing.expectEqual(@as(i32, 0), dl.MatchFirst("RAMT:d/#?", &a.ap));
    tp.proc.task.sig_recvd |= exec.SIGBREAKF_CTRL_C;
    a.ap.break_bits = exec.SIGBREAKF_CTRL_C;
    try testing.expectEqual(dos.ERROR_BREAK, dl.MatchNext(&a.ap));
    try testing.expectEqual(exec.SIGBREAKF_CTRL_C, a.ap.found_break);
    try testing.expect(a.ap.base == null);
    a.ap.break_bits = 0;

    var small: Anchor = .{};
    small.ap.strlen = 8;
    try testing.expectEqual(dos.ERROR_BUFFER_OVERFLOW, dl.MatchFirst("RAMT:d/a.txt", &small.ap));
    try testing.expectEqualStrings("RAMT:d/", small.path()); // cut, with its NUL
    try testing.expect(small.ap.base != null);
    dl.MatchEnd(&small.ap);
    try testing.expect(small.ap.base == null and small.ap.last == null);

    try testing.expectEqual(@as(i32, 0), dl.MatchFirst("*", &a.ap)); // the console: the name itself
    try testing.expectEqualStrings("*", std.mem.sliceTo(&a.ap.info.file_name, 0));
    try testing.expectEqualStrings("*", a.path());
    try testing.expectEqual(dos.ERROR_NO_MORE_ENTRIES, dl.MatchNext(&a.ap));
    try testing.expect(a.ap.base == null);
    RamFs.disk.deinit();
    try tearDown(db);
}

test "Rename: in its directory, a new case, to another directory; what it refuses" {
    const db = try setUp();
    defer kexec.deinit();
    const dl = base(db);
    var tp: TestProcess = .{};
    tp.enter();
    defer tp.leave();
    try RamFs.mount(db, &tp);
    dl.UnLock(dl.CreateDir("RAMT:d").?);
    dl.UnLock(dl.CreateDir("RAMT:d/sub").?);
    try makeFile(dl, "RAMT:d/a", 3);
    try makeFile(dl, "RAMT:d/b", 1);
    var fib: dos.FileInfoBlock = .{};

    try testing.expect(dl.Rename("RAMT:d/a", "RAMT:d/c"));
    try testing.expect(dl.Lock("RAMT:d/a", dos.SHARED_LOCK) == null);
    try testing.expect(dl.Rename("RAMT:d/c", "RAMT:d/C")); // only its case
    const c = dl.Lock("RAMT:d/c", dos.SHARED_LOCK).?;
    try testing.expect(dl.Examine(c, &fib));
    try testing.expectEqualStrings("C", std.mem.sliceTo(&fib.file_name, 0));
    dl.UnLock(c);
    try testing.expect(dl.Rename("RAMT:d/C", "RAMT:d/sub/moved"));
    const moved = dl.Lock("RAMT:d/sub/moved", dos.SHARED_LOCK).?;
    try testing.expect(dl.Examine(moved, &fib));
    try testing.expectEqual(@as(u64, 3), fib.size);
    dl.UnLock(moved);

    try testing.expect(!dl.Rename("RAMT:d/b", "RAMT:d/sub/moved"));
    try testing.expectEqual(dos.ERROR_OBJECT_EXISTS, dl.IoErr());
    try testing.expect(!dl.Rename("RAMT:d", "RAMT:d/sub/d")); // into itself
    try testing.expectEqual(dos.ERROR_OBJECT_IN_USE, dl.IoErr());
    try testing.expect(!dl.Rename("RAMT:none", "RAMT:x"));
    try testing.expectEqual(dos.ERROR_OBJECT_NOT_FOUND, dl.IoErr());
    try testing.expect(!dl.Rename("RAMT:", "RAMT:x"));
    try testing.expectEqual(dos.ERROR_OBJECT_WRONG_TYPE, dl.IoErr());
    try testing.expect(!dl.Rename("RAMT:d/b", "RAMT:d/b:c"));
    try testing.expectEqual(dos.ERROR_INVALID_COMPONENT_NAME, dl.IoErr());
    const held = dl.Lock("RAMT:d/b", dos.EXCLUSIVE_LOCK).?;
    try testing.expect(!dl.Rename("RAMT:d/b", "RAMT:d/b2"));
    try testing.expectEqual(dos.ERROR_OBJECT_IN_USE, dl.IoErr());
    dl.UnLock(held);

    var other: MsgPort = undefined;
    handlerPort(&other);
    const node = dl.MakeDosEntry("OTHER", dos.DLT_DEVICE).?;
    node.task = &other;
    try testing.expect(dl.AddDosEntry(node));
    try testing.expect(!dl.Rename("RAMT:d/b", "OTHER:b"));
    try testing.expectEqual(dos.ERROR_RENAME_ACROSS_DEVICES, dl.IoErr());

    try testing.expect(dl.AssignLock("M", dl.Lock("RAMT:d/sub", dos.SHARED_LOCK).?));
    try testing.expect(dl.AssignAdd("M", dl.Lock("RAMT:d", dos.SHARED_LOCK).?));
    try testing.expect(dl.Rename("M:b", "RAMT:b2")); // b is in the assign's second directory
    dl.UnLock(dl.Lock("RAMT:b2", dos.SHARED_LOCK).?);
    try testing.expect(dl.AssignLock("M", null));
    RamFs.disk.deinit();
    try tearDown(db);
}

test "SetProtection, SetComment, SetFileDate, SetOwner: set, then examined; what they refuse" {
    const db = try setUp();
    defer kexec.deinit();
    const dl = base(db);
    var tp: TestProcess = .{};
    tp.enter();
    defer tp.leave();
    try RamFs.mount(db, &tp);
    try makeFile(dl, "RAMT:f", 1);
    var fib: dos.FileInfoBlock = .{};

    try testing.expect(dl.SetProtection("RAMT:f", dos.FIBF_DELETE | dos.FIBF_ARCHIVE));
    try testing.expect(dl.SetComment("RAMT:f", "a note"));
    const when: dos.DateStamp = .{ .days = 100, .minute = 5, .tick = 7 };
    try testing.expect(dl.SetFileDate("RAMT:f", &when));
    try testing.expect(dl.SetOwner("RAMT:f", (3 << 16) | 4));
    const f = dl.Lock("RAMT:f", dos.SHARED_LOCK).?;
    try testing.expect(dl.Examine(f, &fib));
    dl.UnLock(f);
    try testing.expectEqual(dos.FIBF_DELETE | dos.FIBF_ARCHIVE, fib.protection);
    try testing.expectEqualStrings("a note", std.mem.sliceTo(&fib.comment, 0));
    try testing.expect(fib.date.eql(when));
    try testing.expectEqual(@as(u16, 3), fib.owner_uid);
    try testing.expectEqual(@as(u16, 4), fib.owner_gid);
    try testing.expect(!dl.DeleteFile("RAMT:f")); // FIBF_DELETE forbids it
    try testing.expectEqual(dos.ERROR_DELETE_PROTECTED, dl.IoErr());

    try testing.expect(!dl.SetComment("RAMT:f", "c" ** 80));
    try testing.expectEqual(dos.ERROR_COMMENT_TOO_BIG, dl.IoErr());
    try testing.expect(dl.SetComment("RAMT:f", "")); // no comment again
    try testing.expect(!dl.SetProtection("RAMT:", 0));
    try testing.expectEqual(dos.ERROR_OBJECT_WRONG_TYPE, dl.IoErr());
    try testing.expect(!dl.SetProtection("RAMT:none", 0));
    try testing.expectEqual(dos.ERROR_OBJECT_NOT_FOUND, dl.IoErr());
    try testing.expect(dl.SetComment("RAMT:f", "freed with the file"));
    try testing.expect(dl.SetProtection("RAMT:f", 0));
    try testing.expect(dl.DeleteFile("RAMT:f"));
    RamFs.disk.deinit();
    try tearDown(db);
}

test "SetFileSize: grown with zeroes, cut, another handle moved back, bad sizes" {
    const db = try setUp();
    defer kexec.deinit();
    const dl = base(db);
    var tp: TestProcess = .{};
    tp.enter();
    defer tp.leave();
    try RamFs.mount(db, &tp);
    var buf: [3000]u8 = undefined;

    const fh = dl.Open("RAMT:f", dos.MODE_READWRITE).?;
    try testing.expectEqual(@as(isize, 5), dl.Write(fh, "hello", 5));
    try testing.expectEqual(@as(isize, 3000), dl.SetFileSize(fh, 3000, dos.OFFSET_BEGINNING));
    _ = dl.Seek(fh, 0, dos.OFFSET_BEGINNING);
    try testing.expectEqual(@as(isize, 3000), dl.Read(fh, &buf, buf.len));
    try testing.expectEqualStrings("hello", buf[0..5]);
    try testing.expect(std.mem.allEqual(u8, buf[5..], 0));

    const other = dl.Open("RAMT:f", dos.MODE_READWRITE).?;
    _ = dl.Seek(other, 2500, dos.OFFSET_BEGINNING);
    try testing.expectEqual(@as(isize, 2), dl.SetFileSize(fh, 2, dos.OFFSET_BEGINNING));
    try testing.expectEqual(@as(isize, 2), dl.Seek(other, 0, dos.OFFSET_CURRENT)); // moved back to the end
    try testing.expectEqual(@as(isize, 3), dl.SetFileSize(fh, 1, dos.OFFSET_END));
    _ = dl.Seek(fh, 0, dos.OFFSET_BEGINNING);
    try testing.expectEqual(@as(isize, 3), dl.Read(fh, &buf, buf.len));
    try testing.expectEqualSlices(u8, "he\x00", buf[0..3]); // the old "l" is gone
    try testing.expectEqual(@as(isize, -1), dl.SetFileSize(fh, -5, dos.OFFSET_BEGINNING));
    try testing.expectEqual(dos.ERROR_SEEK_ERROR, dl.IoErr());
    try testing.expectEqual(@as(isize, -1), dl.SetFileSize(null, 0, dos.OFFSET_BEGINNING));
    try testing.expect(dl.Close(other));
    try testing.expect(dl.Close(fh));
    RamFs.disk.deinit();
    try tearDown(db);
}

test "DupLockFromFH, ParentOfFH, NameFromFH, OpenFromLock" {
    const db = try setUp();
    defer kexec.deinit();
    const dl = base(db);
    var tp: TestProcess = .{};
    tp.enter();
    defer tp.leave();
    try RamFs.mount(db, &tp);
    dl.UnLock(dl.CreateDir("RAMT:d").?);
    try makeFile(dl, "RAMT:d/f", 5);
    var buf: [64]u8 = undefined;

    const fh = dl.Open("RAMT:d/f", dos.MODE_OLDFILE).?;
    const dup = dl.DupLockFromFH(fh).?;
    try testing.expect(dl.NameFromLock(dup, &buf, buf.len));
    try testing.expectEqualStrings("Ram Disk:d/f", std.mem.sliceTo(&buf, 0));
    dl.UnLock(dup);
    const parent = dl.ParentOfFH(fh).?;
    try testing.expect(dl.NameFromLock(parent, &buf, buf.len));
    try testing.expectEqualStrings("Ram Disk:d", std.mem.sliceTo(&buf, 0));
    dl.UnLock(parent);
    try testing.expect(dl.NameFromFH(fh, &buf, buf.len));
    try testing.expectEqualStrings("Ram Disk:d/f", std.mem.sliceTo(&buf, 0));
    try testing.expect(!dl.NameFromFH(fh, &buf, 8));
    try testing.expectEqual(dos.ERROR_LINE_TOO_LONG, dl.IoErr());
    try testing.expect(dl.Close(fh));

    const l = dl.Lock("RAMT:d/f", dos.SHARED_LOCK).?;
    const opened = dl.OpenFromLock(l).?; // the lock is the file's now
    try testing.expectEqual(@as(isize, 5), dl.Read(opened, &buf, buf.len));
    try testing.expect(dl.Close(opened)); // and goes with it
    const dir = dl.Lock("RAMT:d", dos.SHARED_LOCK).?;
    try testing.expect(dl.OpenFromLock(dir) == null);
    try testing.expectEqual(dos.ERROR_OBJECT_WRONG_TYPE, dl.IoErr());
    dl.UnLock(dir); // still ours
    try testing.expect(dl.OpenFromLock(null) == null);
    try testing.expect(dl.DupLockFromFH(null) == null);
    try testing.expectEqual(dos.ERROR_INVALID_LOCK, dl.IoErr());
    const w = dl.Open("RAMT:d/g", dos.MODE_NEWFILE).?;
    try testing.expect(dl.DupLockFromFH(w) == null); // its own lock is exclusive
    try testing.expectEqual(dos.ERROR_OBJECT_IN_USE, dl.IoErr());
    try testing.expect(dl.Close(w));
    RamFs.disk.deinit();
    try tearDown(db);
}

test "ChangeMode, Info and DISK_INFO, IsFileSystem, SameDevice" {
    const db = try setUp();
    defer kexec.deinit();
    const dl = base(db);
    var tp: TestProcess = .{};
    tp.enter();
    defer tp.leave();
    try RamFs.mount(db, &tp);
    try makeFile(dl, "RAMT:f", 1);

    const a = dl.Lock("RAMT:f", dos.SHARED_LOCK).?;
    const b = dl.Lock("RAMT:f", dos.SHARED_LOCK).?;
    try testing.expect(!dl.ChangeMode(dos.CHANGE_LOCK, a, dos.EXCLUSIVE_LOCK));
    try testing.expectEqual(dos.ERROR_OBJECT_IN_USE, dl.IoErr());
    dl.UnLock(b);
    try testing.expect(dl.ChangeMode(dos.CHANGE_LOCK, a, dos.EXCLUSIVE_LOCK));
    try testing.expect(dl.Lock("RAMT:f", dos.SHARED_LOCK) == null);
    try testing.expect(dl.ChangeMode(dos.CHANGE_LOCK, a, dos.SHARED_LOCK));
    const fh = dl.Open("RAMT:f", dos.MODE_READWRITE).?;
    try testing.expect(!dl.ChangeMode(dos.CHANGE_FH, fh, dos.MODE_NEWFILE)); // a is there too
    dl.UnLock(a);
    try testing.expect(dl.ChangeMode(dos.CHANGE_FH, fh, dos.MODE_NEWFILE));
    try testing.expect(dl.Lock("RAMT:f", dos.SHARED_LOCK) == null);
    try testing.expect(!dl.ChangeMode(7, fh, 0));
    try testing.expectEqual(dos.ERROR_OBJECT_WRONG_TYPE, dl.IoErr());
    try testing.expect(!dl.ChangeMode(dos.CHANGE_LOCK, null, dos.SHARED_LOCK));
    try testing.expectEqual(dos.ERROR_INVALID_LOCK, dl.IoErr());
    try testing.expect(dl.Close(fh));

    var id: dos.InfoData = .{};
    const root = dl.Lock("RAMT:", dos.SHARED_LOCK).?;
    try testing.expect(dl.Info(root, &id));
    try testing.expectEqual(dos.ID_VALIDATED, id.disk_state);
    try testing.expectEqual(@as(i32, -1), id.unit_number);
    try testing.expectEqual(@as(u32, 1024), id.bytes_per_block);
    try testing.expectEqual(dos.ID_DOS_DISK, id.disk_type);
    try testing.expectEqual(@as(u64, 1), id.num_blocks_used); // f's block
    try testing.expect(id.num_blocks > id.num_blocks_used); // and free memory
    try testing.expect(id.in_use != 0);
    var disk_id: dos.InfoData = .{};
    try testing.expect(dl.DoPkt(&RamFs.port, @intFromEnum(dos.ActionCode.disk_info), @bitCast(@intFromPtr(&disk_id)), 0, 0, 0, 0) != 0);
    try testing.expectEqual(id.num_blocks_used, disk_id.num_blocks_used);
    var stray: FileLock = .{ .task = &RamFs.port };
    try testing.expect(!dl.Info(&stray, &id));
    try testing.expectEqual(dos.ERROR_INVALID_LOCK, dl.IoErr());

    try testing.expect(dl.IsFileSystem("RAMT:"));
    try testing.expect(dl.IsFileSystem("relative/name"));
    try testing.expect(!dl.IsFileSystem("*"));
    try testing.expect(!dl.IsFileSystem("FOO:"));
    try testing.expectEqual(dos.ERROR_DEVICE_NOT_MOUNTED, dl.IoErr());

    const f = dl.Lock("RAMT:f", dos.SHARED_LOCK).?;
    try testing.expect(dl.SameDevice(root, f));
    try testing.expect(!dl.SameDevice(root, null));
    var elsewhere: MsgPort = undefined;
    handlerPort(&elsewhere);
    var foreign: FileLock = .{ .task = &elsewhere };
    try testing.expect(!dl.SameDevice(root, &foreign));
    dl.UnLock(f);
    dl.UnLock(root);
    RamFs.disk.deinit();
    try tearDown(db);
}

// --- Buffered I/O ---

/// A file holding `text`, through Open, Write and Close.
fn fileWith(dl: *interface.DosBase, name: [*:0]const u8, text: []const u8) !void {
    const fh = dl.Open(name, dos.MODE_NEWFILE).?;
    try testing.expectEqual(@as(isize, @intCast(text.len)), dl.Write(fh, text.ptr, @intCast(text.len)));
    try testing.expect(dl.Close(fh));
}

/// What a file holds, through Open, Read and Close.
fn expectContents(dl: *interface.DosBase, name: [*:0]const u8, want: []const u8) !void {
    const fh = dl.Open(name, dos.MODE_OLDFILE).?;
    var back: [2048]u8 = undefined;
    const n = dl.Read(fh, &back, back.len);
    try testing.expect(dl.Close(fh));
    try testing.expectEqualStrings(want, back[0..@intCast(n)]);
}

test "FGetC, UnGetC, FGets: one READ for the buffer, the end not sticky" {
    const db = try setUp();
    defer kexec.deinit();
    const dl = base(db);
    var tp: TestProcess = .{};
    tp.enter();
    defer tp.leave();
    try RamFs.mount(db, &tp);
    try fileWith(dl, "RAMT:f", "ab\ncdef");

    const fh = dl.Open("RAMT:f", dos.MODE_OLDFILE).?;
    try testing.expect(!dl.UnGetC(fh, -1)); // nothing read yet
    try testing.expectEqual(@as(i32, 'a'), dl.FGetC(fh));
    try testing.expectEqual(@as(u32, 7), fh.end); // the whole file in one READ
    try testing.expect(dl.UnGetC(fh, -1));
    try testing.expect(!dl.UnGetC(fh, -1)); // only the last one
    try testing.expectEqual(@as(i32, 'a'), dl.FGetC(fh));
    try testing.expect(dl.UnGetC(fh, 'x'));
    try testing.expect(dl.UnGetC(fh, 0));
    try testing.expectEqual(@as(i32, 0), dl.FGetC(fh));
    try testing.expectEqual(@as(i32, 'x'), dl.FGetC(fh));

    var line: [8]u8 = undefined;
    try testing.expect(dl.FGets(fh, &line, line.len) != null);
    try testing.expectEqualStrings("b\n", std.mem.sliceTo(&line, 0));
    try testing.expect(dl.FGets(fh, &line, 3) != null); // size - 1 bytes
    try testing.expectEqualStrings("cd", std.mem.sliceTo(&line, 0));
    try testing.expect(dl.FGets(fh, &line, line.len) != null); // the end without a newline
    try testing.expectEqualStrings("ef", std.mem.sliceTo(&line, 0));
    _ = dl.SetIoErr(dos.ERROR_OBJECT_NOT_FOUND);
    try testing.expect(dl.FGets(fh, &line, line.len) == null);
    try testing.expectEqual(@as(i32, 0), dl.IoErr());
    try testing.expectEqual(dos.ENDSTREAMCH, dl.FGetC(fh)); // asks again
    try testing.expect(dl.UnGetC(fh, -1)); // the end, pushed back
    _ = dl.SetIoErr(dos.ERROR_OBJECT_NOT_FOUND);
    try testing.expectEqual(dos.ENDSTREAMCH, dl.FGetC(fh));
    try testing.expectEqual(@as(i32, 0), dl.IoErr()); // an end, not an error
    for (0..dos.stdio.UNGET_MAX) |_| try testing.expect(dl.UnGetC(fh, 'q'));
    try testing.expect(!dl.UnGetC(fh, 'q'));
    try testing.expect(dl.Close(fh));

    // A character the file never gave has no place in it: at the start of
    // the file, a flush does not seek back before the first byte.
    const fresh = dl.Open("RAMT:f", dos.MODE_OLDFILE).?;
    try testing.expect(dl.UnGetC(fresh, 'z'));
    try testing.expect(dl.Flush(fresh));
    try testing.expectEqual(@as(isize, 0), dl.Seek(fresh, 0, dos.OFFSET_CURRENT));
    try testing.expect(dl.Close(fresh));

    RamFs.disk.deinit();
    try tearDown(db);
}

test "FPutC, FPuts, FPrintf, FWrite: waiting until Flush or Close; big writes go straight" {
    const db = try setUp();
    defer kexec.deinit();
    const dl = base(db);
    var tp: TestProcess = .{};
    tp.enter();
    defer tp.leave();
    try RamFs.mount(db, &tp);

    const fh = dl.Open("RAMT:w", dos.MODE_NEWFILE).?;
    try testing.expect(fh.buf == null); // allocated on first use
    try testing.expectEqual(@as(i32, 'h'), dl.FPutC(fh, 'h'));
    try testing.expectEqual(@as(i32, 0), dl.FPuts(fh, "ello\n"));
    try testing.expectEqual(@as(u32, 6), fh.pos); // a file isn't line buffered
    var fib: dos.FileInfoBlock = .{};
    try testing.expect(dl.ExamineFH(fh, &fib)); // flushes first
    try testing.expectEqual(@as(u64, 6), fib.size);
    try testing.expectEqual(@as(i32, 7), dos.stdio.FPrintf(dl, fh, "%s=%d\n", .{ "abc", @as(u32, 42) }));
    try testing.expectEqual(@as(i32, 3), dos.stdio.FPrintf(dl, fh, "a%cb", .{@as(u32, 0)})); // a %c of 0 stays
    var big: [1500]u8 = @splat('z');
    try testing.expectEqual(@as(isize, 1500), dl.FWrite(fh, &big, big.len)); // after the waiting bytes
    try testing.expectEqual(@as(u32, 0), fh.pos);
    try testing.expectEqual(@as(isize, 2), dl.FWrite(fh, "yy", 2));
    try testing.expect(dl.Flush(fh));
    try testing.expectEqual(@as(isize, 3), dl.FWrite(fh, "end", 3));
    try testing.expect(dl.Close(fh)); // writes "end"
    try expectContents(dl, "RAMT:w", "hello\nabc=42\na\x00b" ++ "z" ** 1500 ++ "yyend");
    try testing.expect(!dl.Flush(null));

    RamFs.disk.deinit();
    try tearDown(db);
}

test "buffered and unbuffered calls mix on one handle" {
    const db = try setUp();
    defer kexec.deinit();
    const dl = base(db);
    var tp: TestProcess = .{};
    tp.enter();
    defer tp.leave();
    try RamFs.mount(db, &tp);
    try fileWith(dl, "RAMT:m", "0123456789");

    const fh = dl.Open("RAMT:m", dos.MODE_READWRITE).?;
    try testing.expectEqual(@as(i32, '0'), dl.FGetC(fh));
    var three: [3]u8 = undefined;
    try testing.expectEqual(@as(isize, 3), dl.Read(fh, &three, 3)); // from the read-ahead
    try testing.expectEqualStrings("123", &three);
    try testing.expectEqual(@as(i32, '4'), dl.FGetC(fh));
    try testing.expectEqual(@as(isize, 5), dl.Seek(fh, 0, dos.OFFSET_CURRENT)); // read-ahead given back
    try testing.expectEqual(@as(i32, '5'), dl.FGetC(fh));
    try testing.expectEqual(@as(isize, 1), dl.Write(fh, "X", 1)); // at 6
    try testing.expectEqual(@as(i32, '7'), dl.FGetC(fh));
    try testing.expectEqual(@as(i32, 'Y'), dl.FPutC(fh, 'Y')); // at 8
    try testing.expectEqual(@as(i32, '9'), dl.FGetC(fh)); // 'Y' written first
    try testing.expect(dl.UnGetC(fh, -1));
    try testing.expect(dl.UnGetC(fh, 'q'));
    // '9' came from the file and goes back; 'q' is the caller's own.
    try testing.expectEqual(@as(isize, 9), dl.Seek(fh, 0, dos.OFFSET_CURRENT));
    try testing.expectEqual(@as(isize, 9), dl.Seek(fh, 0, dos.OFFSET_BEGINNING));
    var all: [16]u8 = undefined;
    try testing.expectEqual(@as(isize, 10), dl.FRead(fh, &all, all.len));
    try testing.expectEqualStrings("012345X7Y9", all[0..10]);
    try testing.expectEqual(@as(isize, 0), dl.FRead(fh, &all, all.len));
    try testing.expect(dl.Close(fh));

    RamFs.disk.deinit();
    try tearDown(db);
}

test "SetVBuf: modes, the caller's buffer, line buffering on consoles" {
    const db = try setUp();
    defer kexec.deinit();
    const dl = base(db);
    var tp: TestProcess = .{};
    tp.enter();
    defer tp.leave();
    try RamFs.mount(db, &tp);

    const fh = dl.Open("RAMT:v", dos.MODE_NEWFILE).?;
    try testing.expectEqual(@as(i32, -1), dl.SetVBuf(fh, null, 3, -1));
    try testing.expectEqual(dos.ERROR_BAD_NUMBER, dl.IoErr());
    var mine: [16]u8 = undefined;
    try testing.expectEqual(@as(i32, 0), dl.SetVBuf(fh, &mine, dos.BUF_FULL, mine.len));
    try testing.expectEqual(@as(i32, 0), dl.FPuts(fh, "abc"));
    try testing.expectEqual(@as(?[*]u8, &mine), fh.buf);
    try testing.expectEqual(@as(u32, 3), fh.pos);
    var p16: [16]u8 = @splat('p');
    try testing.expectEqual(@as(isize, 16), dl.FWrite(fh, &p16, p16.len)); // a buffer's size: straight
    try testing.expectEqual(@as(u32, 0), fh.pos);

    fh.interactive = true; // as if a console
    try testing.expectEqual(@as(i32, 0), dl.FPuts(fh, "x\n")); // BUF_FULL: waits
    try testing.expectEqual(@as(u32, 2), fh.pos);
    try testing.expectEqual(@as(i32, 0), dl.SetVBuf(fh, null, dos.BUF_LINE, -1)); // flushes
    try testing.expectEqual(@as(u32, 0), fh.pos);
    try testing.expectEqual(@as(i32, 0), dl.FPuts(fh, "y"));
    try testing.expectEqual(@as(u32, 1), fh.pos);
    try testing.expectEqual(@as(i32, '\n'), dl.FPutC(fh, '\n')); // the line goes out
    try testing.expectEqual(@as(u32, 0), fh.pos);
    try testing.expectEqual(@as(i32, 0), dl.SetVBuf(fh, null, dos.BUF_NONE, 64)); // dos's, freed by Close
    try testing.expect(fh.buf_owned and fh.buf_size == 64);
    try testing.expectEqual(@as(i32, 'n'), dl.FPutC(fh, 'n'));
    try testing.expectEqual(@as(u32, 0), fh.pos);
    fh.interactive = false;
    try testing.expect(dl.Close(fh));
    try expectContents(dl, "RAMT:v", "abc" ++ "p" ** 16 ++ "x\ny\nn");

    RamFs.disk.deinit();
    try tearDown(db);
}

test "PutStr, WriteChars, Printf: to Output()" {
    const db = try setUp();
    defer kexec.deinit();
    const dl = base(db);
    var tp: TestProcess = .{};
    tp.enter();
    defer tp.leave();
    try RamFs.mount(db, &tp);

    const out = dl.Open("RAMT:o", dos.MODE_NEWFILE).?;
    try testing.expectEqual(@as(i32, -1), dl.PutStr("none")); // no Output()
    try testing.expectEqual(dos.ERROR_INVALID_LOCK, dl.IoErr());
    _ = dl.SelectOutput(out);
    try testing.expectEqual(@as(i32, 0), dl.PutStr("one "));
    try testing.expectEqual(@as(isize, 4), dl.WriteChars("two ", 4));
    try testing.expectEqual(@as(i32, 7), dos.stdio.Printf(dl, "%d three", .{@as(u32, 3)}));
    _ = dl.SelectOutput(null);
    try testing.expect(dl.Close(out));
    try expectContents(dl, "RAMT:o", "one two 3 three");

    RamFs.disk.deinit();
    try tearDown(db);
}

// --- ReadArgs ---

/// ReadArgs on `line` through the caller's RDArgs, as its CSource.
fn parseLine(dl: *interface.DosBase, rda: *dos.RDArgs, template: [*:0]const u8, line: []const u8, argv: [*]usize) ?*dos.RDArgs {
    rda.* = .{ .source = .{ .buffer = line.ptr, .length = @intCast(line.len) } };
    return dl.ReadArgs(template, argv, rda);
}

fn slotText(slot: usize) []const u8 {
    return std.mem.span(dos.rdargs.string(slot).?);
}

test "ReadArgs: positional items, keywords and aliases, switches, numbers, toggles" {
    const db = try setUp();
    defer kexec.deinit();
    const dl = base(db);
    var tp: TestProcess = .{};
    tp.enter();
    defer tp.leave();

    var rda: dos.RDArgs = .{};
    var argv: [6]usize = .{ 0, 0, 0, 0, 123, 0 };
    const line = "a.txt to \"b c\" quiet num=42 toggle off extra\n";
    try testing.expect(parseLine(dl, &rda, "FROM/A,TO/K,Q=QUIET/S,N=NUM/N,T=TOGGLE/T,REST", line, &argv) == &rda);
    try testing.expectEqualStrings("a.txt", slotText(argv[0]));
    try testing.expectEqualStrings("b c", slotText(argv[1]));
    try testing.expectEqual(std.math.maxInt(usize), argv[2]);
    try testing.expectEqual(@as(?i32, 42), dos.rdargs.number(argv[3]));
    try testing.expectEqual(@as(usize, 0), argv[4]); // off
    try testing.expectEqualStrings("extra", slotText(argv[5]));
    try testing.expectEqual(rda.source.length, rda.source.cur_chr); // the line's end read
    dl.FreeArgs(&rda);
    dl.FreeArgs(&rda); // twice is fine

    // "KEY = value", any case, no newline at the end.
    var two: [2]usize = @splat(0);
    try testing.expect(parseLine(dl, &rda, "NAME/K,SIZE/N", "size = -7 NAME Joe", &two) != null);
    try testing.expectEqual(@as(?i32, -7), dos.rdargs.number(two[1]));
    try testing.expectEqualStrings("Joe", slotText(two[0]));
    try testing.expectEqual(rda.source.length, rda.source.cur_chr);
    dl.FreeArgs(&rda);

    // ReadArgs' own RDArgs, a switch given as /A.
    const own = dl.ReadArgs("S/S/A", &two, null);
    try testing.expect(own == null); // no Input(): nothing given
    try testing.expectEqual(dos.ERROR_REQUIRED_ARG_MISSING, dl.IoErr());
    try testing.expect(parseLine(dl, &rda, "S/S/A", "s\n", &two) != null);
    dl.FreeArgs(&rda);
    try tearDown(db);
}

test "ReadArgs: /M and the /A items after it, /M/N, /F" {
    const db = try setUp();
    defer kexec.deinit();
    const dl = base(db);
    var tp: TestProcess = .{};
    tp.enter();
    defer tp.leave();

    var rda: dos.RDArgs = .{};
    var argv: [3]usize = @splat(0);
    try testing.expect(parseLine(dl, &rda, "FILES/M,TO/A,N/A/N", "a b 5 d\n", &argv) != null);
    const names = dos.rdargs.multi(argv[0]);
    try testing.expectEqual(@as(usize, 2), names.len);
    try testing.expectEqualStrings("b", std.mem.span(names[1]));
    try testing.expectEqualStrings("d", slotText(argv[1])); // the first /A takes the last
    try testing.expectEqual(@as(?i32, 5), dos.rdargs.number(argv[2])); // the text as a number
    dl.FreeArgs(&rda);

    var nums: [2]usize = @splat(0);
    try testing.expect(parseLine(dl, &rda, "N/M/N", "1 -2 30\n", &nums) != null);
    try testing.expectEqual(@as(usize, 3), dos.rdargs.multi(nums[0]).len);
    try testing.expectEqual(@as(i32, -2), dos.rdargs.multiNumber(nums[0], 1));
    dl.FreeArgs(&rda);
    try testing.expect(parseLine(dl, &rda, "N/M/N,X/A", "1 2\n", &nums) == null); // not from /M/N
    try testing.expectEqual(dos.ERROR_REQUIRED_ARG_MISSING, dl.IoErr());
    try testing.expect(parseLine(dl, &rda, "T/T/A,M/M", "a b c\n", &nums) == null); // not for a /T
    try testing.expectEqual(dos.ERROR_REQUIRED_ARG_MISSING, dl.IoErr());
    nums = .{ 0, 99 };
    try testing.expect(parseLine(dl, &rda, "M/M,Z", "\n", &nums) != null);
    try testing.expectEqual(@as(usize, 0), nums[0]); // /M without items
    try testing.expectEqual(@as(usize, 99), nums[1]); // a default stays
    dl.FreeArgs(&rda);

    var cmd: [2]usize = @splat(0);
    try testing.expect(parseLine(dl, &rda, "CMD/A,ARGS/F", "echo  hello  \"world\" ;x  \n", &cmd) != null);
    try testing.expectEqualStrings("echo", slotText(cmd[0]));
    try testing.expectEqualStrings("hello  \"world\" ;x", slotText(cmd[1]));
    dl.FreeArgs(&rda);
    try testing.expect(parseLine(dl, &rda, "CMD/A,ARGS/F", "c \"q r\"  s \n", &cmd) != null);
    try testing.expectEqualStrings("q r  s ", slotText(cmd[1])); // quoted first: nothing stripped
    dl.FreeArgs(&rda);
    try testing.expect(parseLine(dl, &rda, "ARGS/F", "args=  x \"y\" \n", &cmd) != null);
    try testing.expectEqualStrings("  x \"y\"", slotText(cmd[0]));
    dl.FreeArgs(&rda);
    try tearDown(db);
}

test "ReadArgs: errors, the rest of the line skipped, buffers" {
    const db = try setUp();
    defer kexec.deinit();
    const dl = base(db);
    var tp: TestProcess = .{};
    tp.enter();
    defer tp.leave();

    const cases = [_]struct { template: [*:0]const u8, line: []const u8, code: i32 }{
        .{ .template = "A/A", .line = "\n", .code = dos.ERROR_REQUIRED_ARG_MISSING },
        .{ .template = "A/K", .line = "x\n", .code = dos.ERROR_TOO_MANY_ARGS },
        .{ .template = "A,B", .line = "x y z\n", .code = dos.ERROR_TOO_MANY_ARGS },
        .{ .template = "A/K", .line = "a=1 a=2\n", .code = dos.ERROR_TOO_MANY_ARGS },
        .{ .template = "N/N", .line = "12x\n", .code = dos.ERROR_BAD_NUMBER },
        .{ .template = "N/N", .line = "99999999999\n", .code = dos.ERROR_BAD_NUMBER },
        .{ .template = "K/K", .line = "k\n", .code = dos.ERROR_KEY_NEEDS_ARG },
        .{ .template = "T/T", .line = "t maybe\n", .code = dos.ERROR_KEY_NEEDS_ARG },
        .{ .template = "A/M,B/M", .line = "\n", .code = dos.ERROR_BAD_TEMPLATE },
        .{ .template = "A", .line = "\"open\n", .code = dos.ERROR_LINE_TOO_LONG },
        .{ .template = "A", .line = "= x\n", .code = dos.ERROR_LINE_TOO_LONG },
        .{ .template = "S/S/A", .line = "\n", .code = dos.ERROR_REQUIRED_ARG_MISSING },
    };
    var rda: dos.RDArgs = .{};
    var argv: [2]usize = @splat(0);
    for (cases) |case| {
        try testing.expect(parseLine(dl, &rda, case.template, case.line, &argv) == null);
        try testing.expectEqual(case.code, dl.IoErr());
        try testing.expect(rda.da_list == null); // freed
    }
    try testing.expect(parseLine(dl, &rda, "A/K", "a\nnext\n", &argv) == null);
    try testing.expectEqual(@as(isize, 2), rda.source.cur_chr); // up to the line's end

    const text = "one two\n";
    rda = .{ .source = .{ .buffer = text, .length = text.len }, .flags = dos.RDAF_NOALLOC };
    try testing.expect(dl.ReadArgs("A,B", &argv, &rda) == null);
    try testing.expectEqual(dos.ERROR_NO_FREE_STORE, dl.IoErr());

    // A caller's small buffer: items go on in new blocks.
    const long = "abcdefghijklmnopqrstuvwxyz0123456789 second\n";
    var mine: [8]u8 = undefined;
    rda = .{ .source = .{ .buffer = long, .length = long.len }, .buffer = &mine, .buf_siz = mine.len };
    try testing.expect(dl.ReadArgs("A,B", &argv, &rda) != null);
    try testing.expectEqualStrings("abcdefghijklmnopqrstuvwxyz0123456789", slotText(argv[0]));
    try testing.expectEqualStrings("second", slotText(argv[1]));
    dl.FreeArgs(&rda);
    try testing.expect(rda.buffer == null);
    try tearDown(db);
}

test "ReadItem, FindArg, StrToLong" {
    const db = try setUp();
    defer kexec.deinit();
    const dl = base(db);

    const text = "  \"a*\"b*n*e**\" rest=x;comment\n";
    var cs: dos.CSource = .{ .buffer = text, .length = text.len };
    var item: [32]u8 = undefined;
    try testing.expectEqual(dos.ITEM_QUOTED, dl.ReadItem(&item, item.len, &cs));
    try testing.expectEqualStrings("a\"b\n\x1b*", std.mem.sliceTo(&item, 0));
    try testing.expectEqual(dos.ITEM_UNQUOTED, dl.ReadItem(&item, item.len, &cs));
    try testing.expectEqualStrings("rest", std.mem.sliceTo(&item, 0)); // the '=' is read
    try testing.expectEqual(dos.ITEM_UNQUOTED, dl.ReadItem(&item, item.len, &cs));
    try testing.expectEqualStrings("x", std.mem.sliceTo(&item, 0));
    try testing.expectEqual(dos.ITEM_NOTHING, dl.ReadItem(&item, item.len, &cs));
    try testing.expectEqual(@as(u8, ';'), text[@intCast(cs.cur_chr)]); // put back

    cs = .{ .buffer = " =x", .length = 3 };
    try testing.expectEqual(dos.ITEM_EQUAL, dl.ReadItem(&item, item.len, &cs));
    cs = .{ .buffer = "abcd", .length = 4 };
    try testing.expectEqual(dos.ITEM_ERROR, dl.ReadItem(&item, 3, &cs));
    try testing.expectEqual(dos.ITEM_ERROR, dl.ReadItem(&item, 0, &cs));
    cs = .{ .buffer = "abc", .length = 3 }; // no newline: its end is read once
    try testing.expectEqual(dos.ITEM_UNQUOTED, dl.ReadItem(&item, item.len, &cs));
    try testing.expectEqual(dos.ITEM_NOTHING, dl.ReadItem(&item, item.len, &cs));
    try testing.expectEqual(dos.ITEM_NOTHING, dl.ReadItem(&item, item.len, &cs));
    try testing.expectEqual(@as(isize, 3), cs.cur_chr);

    try testing.expectEqual(@as(i32, 0), dl.FindArg("Q=QUICK/S,FROM/A", "quick"));
    try testing.expectEqual(@as(i32, 0), dl.FindArg("Q=QUICK/S,FROM/A", "Q"));
    try testing.expectEqual(@as(i32, 1), dl.FindArg("Q=QUICK/S,FROM/A", "from"));
    try testing.expectEqual(@as(i32, -1), dl.FindArg("Q=QUICK/S,FROM/A", "qui"));
    try testing.expectEqual(@as(i32, -1), dl.FindArg("Q=QUICK/S,FROM/A", "x"));

    var value: i32 = 1;
    try testing.expectEqual(@as(i32, 4), dl.StrToLong(" -42x", &value));
    try testing.expectEqual(@as(i32, -42), value);
    try testing.expectEqual(@as(i32, -1), dl.StrToLong("x", &value));
    try testing.expectEqual(@as(i32, 0), value);
    try testing.expectEqual(@as(i32, 10), dl.StrToLong("2147483647", &value));
    try testing.expectEqual(@as(i32, -1), dl.StrToLong("2147483648", &value));
    try testing.expectEqual(@as(i32, 11), dl.StrToLong("-2147483648", &value));
    try testing.expectEqual(@as(i32, std.math.minInt(i32)), value);
    try tearDown(db);
}

test "ReadArgs: '?' shows the template, the answer comes from Input(); NOPROMPT" {
    const db = try setUp();
    defer kexec.deinit();
    const dl = base(db);
    var tp: TestProcess = .{};
    tp.enter();
    defer tp.leave();
    try RamFs.mount(db, &tp);
    try fileWith(dl, "RAMT:in", "one ?\n?\nthree\n");
    try fileWith(dl, "RAMT:in2", "y\n");
    const out = dl.Open("RAMT:out", dos.MODE_NEWFILE).?;
    _ = dl.SelectOutput(out);

    const in = dl.Open("RAMT:in", dos.MODE_OLDFILE).?;
    _ = dl.SelectInput(in);
    var rda: dos.RDArgs = .{ .ext_help = "more help" };
    var argv: [3]usize = @splat(0);
    try testing.expect(dl.ReadArgs("A,B,C", &argv, &rda) != null); // from Input()
    try testing.expectEqualStrings("one", slotText(argv[0]));
    try testing.expectEqualStrings("three", slotText(argv[1]));
    try testing.expectEqual(@as(usize, 0), argv[2]);
    dl.FreeArgs(&rda);
    try testing.expect(dl.Close(in));

    const in2 = dl.Open("RAMT:in2", dos.MODE_OLDFILE).?;
    _ = dl.SelectInput(in2);
    try testing.expect(parseLine(dl, &rda, "A/A,B/A", "x ?\n", &argv) != null);
    try testing.expectEqualStrings("x", slotText(argv[0]));
    try testing.expectEqualStrings("y", slotText(argv[1])); // after the '?', from Input()
    dl.FreeArgs(&rda);
    rda = .{ .source = .{ .buffer = "?\n", .length = 2 }, .flags = dos.RDAF_NOPROMPT };
    try testing.expect(dl.ReadArgs("A", &argv, &rda) != null);
    try testing.expectEqualStrings("?", slotText(argv[0]));
    dl.FreeArgs(&rda);
    try testing.expectEqual(dos.RDAF_NOPROMPT, rda.flags); // the caller's flags stay

    _ = dl.SelectInput(null);
    try testing.expect(dl.Close(in2));
    _ = dl.SelectOutput(null);
    try testing.expect(dl.Close(out));
    try expectContents(dl, "RAMT:out", "A,B,C: more help: A/A,B/A: ");
    RamFs.disk.deinit();
    try tearDown(db);
}

test "a console keeps what it read ahead when it is written to" {
    const db = try setUp();
    defer kexec.deinit();
    const dl = base(db);
    var tp: TestProcess = .{};
    tp.enter();
    defer tp.leave();
    try RamFs.mount(db, &tp);
    try fileWith(dl, "RAMT:c", "abc");

    const fh = dl.Open("RAMT:c", dos.MODE_READWRITE).?;
    fh.interactive = true; // as if a console
    try testing.expectEqual(@as(i32, 'a'), dl.FGetC(fh));
    try testing.expectEqual(@as(i32, 'X'), dl.FPutC(fh, 'X')); // straight out
    try testing.expectEqual(@as(isize, 1), dl.Write(fh, "Y", 1));
    try testing.expectEqual(@as(isize, 1), dl.FWrite(fh, "Z", 1));
    try testing.expect(dl.Flush(fh)); // keeps it too
    try testing.expectEqual(@as(i32, 'b'), dl.FGetC(fh)); // the read-ahead is still there
    try testing.expectEqual(@as(i32, 'c'), dl.FGetC(fh));
    fh.interactive = false;
    try testing.expect(dl.Close(fh));
    try expectContents(dl, "RAMT:c", "abcXYZ");
    RamFs.disk.deinit();
    try tearDown(db);
}

// --- Fault, variables ---

test "Fault, PrintFault: texts, headers, cutting, the shell's texts" {
    const db = try setUp();
    defer kexec.deinit();
    const dl = base(db);
    var tp: TestProcess = .{};
    tp.enter();
    defer tp.leave();
    try RamFs.mount(db, &tp);

    var buf: [64]u8 = undefined;
    try testing.expectEqual(@as(i32, 22), dl.Fault(dos.ERROR_OBJECT_NOT_FOUND, "open", &buf, buf.len));
    try testing.expectEqualStrings("open: object not found", std.mem.sliceTo(&buf, 0));
    _ = dl.Fault(dos.ERROR_OBJECT_NOT_FOUND, null, &buf, buf.len);
    try testing.expectEqualStrings("object not found", std.mem.sliceTo(&buf, 0));
    _ = dl.Fault(-121, null, &buf, buf.len);
    try testing.expectEqualStrings("Unknown command", std.mem.sliceTo(&buf, 0));
    _ = dl.Fault(999, "x", &buf, buf.len);
    try testing.expectEqualStrings("x: Error 999", std.mem.sliceTo(&buf, 0));
    try testing.expectEqual(@as(i32, 6), dl.Fault(dos.ERROR_OBJECT_NOT_FOUND, null, &buf, 7)); // cut
    try testing.expectEqualStrings("object", std.mem.sliceTo(&buf, 0));
    try testing.expectEqual(@as(i32, 0), dl.Fault(0, "x", &buf, buf.len));
    try testing.expectEqualStrings("", std.mem.sliceTo(&buf, 0));
    try testing.expectEqual(@as(i32, 0), dl.Fault(205, null, &buf, 0));

    try testing.expect(!dl.PrintFault(205, "cd")); // no Output()
    const out = dl.Open("RAMT:f", dos.MODE_NEWFILE).?;
    _ = dl.SelectOutput(out);
    try testing.expect(dl.PrintFault(dos.ERROR_OBJECT_NOT_FOUND, "cd"));
    try testing.expectEqual(dos.ERROR_OBJECT_NOT_FOUND, dl.IoErr());
    try testing.expect(dl.PrintFault(dos.ERROR_BREAK, null));
    _ = dl.SelectOutput(null);
    try testing.expect(dl.Close(out));
    try expectContents(dl, "RAMT:f", "cd: object not found\n***Break\n");
    RamFs.disk.deinit();
    try tearDown(db);
}

test "SetVar, GetVar, FindVar, DeleteVar: local variables and aliases" {
    const db = try setUp();
    defer kexec.deinit();
    const dl = base(db);
    var tp: TestProcess = .{};
    tp.enter();
    defer tp.leave();
    const lv = dos.LV_VAR;
    const la = dos.LV_ALIAS;

    try testing.expect(dl.SetVar("b", "2", -1, lv));
    try testing.expect(dl.SetVar("A", "one", -1, lv));
    try testing.expect(dl.SetVar("a", "dir", -1, la)); // an alias of the same name
    try testing.expectEqualStrings("one", dl.FindVar("a", lv).?.value[0..3]);
    try testing.expectEqualStrings("dir", dl.FindVar("A", la).?.value[0..3]);
    try testing.expect(dl.FindVar("c", lv) == null);
    const last: *dos.LocalVar = @ptrCast(tp.proc.local_vars.tail_pred.?);
    try testing.expectEqualStrings("b", std.mem.span(last.name)); // sorted

    var buf: [16]u8 = undefined;
    try testing.expectEqual(@as(isize, 3), dl.GetVar("A", &buf, buf.len, lv));
    try testing.expectEqualStrings("one", std.mem.sliceTo(&buf, 0));
    try testing.expectEqual(@as(i32, 3), dl.IoErr()); // the whole length
    try testing.expectEqual(@as(isize, 1), dl.GetVar("A", &buf, 2, lv)); // cut
    try testing.expectEqualStrings("o", std.mem.sliceTo(&buf, 0));
    try testing.expectEqual(@as(isize, -1), dl.GetVar("A", &buf, 0, lv));
    try testing.expectEqual(dos.ERROR_BAD_NUMBER, dl.IoErr());
    try testing.expect(dl.SetVar("n", "x\ny", 3, lv));
    try testing.expectEqual(@as(isize, 1), dl.GetVar("n", &buf, buf.len, lv)); // text: to the newline
    try testing.expectEqual(@as(isize, 3), dl.GetVar("n", &buf, buf.len, lv | dos.GVF_BINARY_VAR));
    buf[3] = '#';
    try testing.expectEqual(@as(isize, 3), dl.GetVar("n", &buf, 3, lv | dos.GVF_BINARY_VAR | dos.GVF_DONT_NULL_TERM));
    try testing.expectEqualStrings("x\ny#", buf[0..4]);
    try testing.expect(dl.SetVar("A", "two", -1, lv)); // replaced
    _ = dl.GetVar("A", &buf, buf.len, lv);
    try testing.expectEqualStrings("two", std.mem.sliceTo(&buf, 0));
    dl.FindVar("a", la).?.var_type |= dos.LVF_IGNORE; // hidden
    try testing.expectEqual(@as(isize, -1), dl.GetVar("a", &buf, buf.len, la | dos.GVF_LOCAL_ONLY));
    try testing.expectEqual(dos.ERROR_OBJECT_NOT_FOUND, dl.IoErr());
    try testing.expect(dl.DeleteVar("b", lv | dos.GVF_LOCAL_ONLY));
    try testing.expect(!dl.DeleteVar("b", lv | dos.GVF_LOCAL_ONLY));
    try testing.expectEqual(dos.ERROR_OBJECT_NOT_FOUND, dl.IoErr());
    // An alias that isn't there is not found, locally or anywhere.
    try testing.expect(!dl.DeleteVar("nowhere", la));
    try testing.expectEqual(dos.ERROR_OBJECT_NOT_FOUND, dl.IoErr());
    // A type AllocDosObject doesn't know says so.
    try testing.expect(dl.AllocDosObject(99, null) == null);
    try testing.expectEqual(dos.ERROR_BAD_NUMBER, dl.IoErr());
    process.freeVars(db, &tp.proc);
    try tearDown(db);
}

test "SetVar, GetVar, DeleteVar: global variables in ENV:" {
    const db = try setUp();
    defer kexec.deinit();
    const dl = base(db);
    var tp: TestProcess = .{};
    tp.enter();
    defer tp.leave();
    try RamFs.mount(db, &tp);

    try testing.expect(dl.AssignLate("ENV", "RAMT:ENV")); // instead of dos's RAM:ENV
    try testing.expect(dl.SetVar("g", "hello\nworld", -1, dos.GVF_GLOBAL_ONLY)); // makes RAMT:ENV
    dl.UnLock(dl.Lock("RAMT:ENV/g", dos.SHARED_LOCK).?);
    var buf: [16]u8 = undefined;
    try testing.expectEqual(@as(isize, 5), dl.GetVar("g", &buf, buf.len, dos.LV_VAR)); // no local one
    try testing.expectEqualStrings("hello", std.mem.sliceTo(&buf, 0));
    try testing.expectEqual(@as(i32, 11), dl.IoErr());
    try testing.expectEqual(@as(isize, -1), dl.GetVar("g", &buf, buf.len, dos.GVF_LOCAL_ONLY));
    try testing.expect(dl.SetVar("g", "local", -1, dos.LV_VAR)); // a local one comes first
    _ = dl.GetVar("g", &buf, buf.len, dos.LV_VAR);
    try testing.expectEqualStrings("local", std.mem.sliceTo(&buf, 0));
    _ = dl.GetVar("g", &buf, buf.len, dos.GVF_GLOBAL_ONLY);
    try testing.expectEqualStrings("hello", std.mem.sliceTo(&buf, 0));
    try testing.expect(!dl.SetVar("al", "x", -1, dos.LV_ALIAS | dos.GVF_GLOBAL_ONLY));
    try testing.expectEqual(dos.ERROR_OBJECT_WRONG_TYPE, dl.IoErr());
    try testing.expect(dl.DeleteVar("g", dos.GVF_GLOBAL_ONLY));
    try testing.expectEqual(@as(isize, -1), dl.GetVar("g", &buf, buf.len, dos.GVF_GLOBAL_ONLY));
    try testing.expectEqual(dos.ERROR_OBJECT_NOT_FOUND, dl.IoErr());
    try testing.expect(dl.AssignLock("ENV", null)); // its lock goes before the disk
    process.freeVars(db, &tp.proc);
    RamFs.disk.deinit();
    try tearDown(db);
}

// --- Processes, CLIs ---

/// A process's code run as the running task, as exec runs it: its final
/// code (dos's end) finds the process with FindTask.
fn runAs(proc: *Process) void {
    const saved = kexec.SysBase.this_task;
    kexec.SysBase.this_task = &proc.task;
    kexec.runCode(kexec.SysBase, &proc.task);
    kexec.SysBase.this_task = saved;
}

const ExitHook = struct {
    var data: isize = 0;
    fn hook(rc: i32, exit_data: isize) callconv(.c) i32 {
        _ = rc;
        data = exit_data;
        return 0;
    }
};

test "CompareDates, DateToStr, StrToDate: the four formats, the substitutions, four-digit years" {
    const db = try setUp();
    defer kexec.deinit();
    const dl = base(db);
    var tp: TestProcess = .{};
    tp.enter();
    defer tp.leave();

    // There is no timer.device on the host, so DateStamp() and with it
    // "today" is day 0: 1 Jan 1978, which was a Sunday.
    const a: dos.DateStamp = .{ .days = 10, .minute = 5, .tick = 3 };
    const b: dos.DateStamp = .{ .days = 10, .minute = 5, .tick = 4 };
    try testing.expectEqual(@as(i32, -1), dl.CompareDates(&a, &b));
    try testing.expectEqual(@as(i32, 1), dl.CompareDates(&b, &a));
    try testing.expectEqual(@as(i32, 0), dl.CompareDates(&a, &a));

    var day: [dos.LEN_DATSTRING:0]u8 = @splat(0);
    var text: [dos.LEN_DATSTRING:0]u8 = @splat(0);
    var time: [dos.LEN_DATSTRING:0]u8 = @splat(0);
    var dt: dos.DateTime = .{
        .str_day = &day,
        .str_date = &text,
        .str_time = &time,
    };

    // 16 Sep 2026, 13:45:30. 2026-01-01 is day 17532.
    dt.stamp = .{ .days = 17_790, .minute = 13 * 60 + 45, .tick = 30 * 50 };
    try testing.expect(dl.DateToStr(&dt));
    try testing.expectEqualStrings("16-Sep-2026", std.mem.span(@as([*:0]const u8, &text)));
    try testing.expectEqualStrings("13:45:30", std.mem.span(@as([*:0]const u8, &time)));
    try testing.expectEqualStrings("Wednesday", std.mem.span(@as([*:0]const u8, &day)));

    dt.format = dos.FORMAT_INT;
    try testing.expect(dl.DateToStr(&dt));
    try testing.expectEqualStrings("2026-09-16", std.mem.span(@as([*:0]const u8, &text)));
    dt.format = dos.FORMAT_USA;
    try testing.expect(dl.DateToStr(&dt));
    try testing.expectEqualStrings("09-16-2026", std.mem.span(@as([*:0]const u8, &text)));
    dt.format = dos.FORMAT_CDN;
    try testing.expect(dl.DateToStr(&dt));
    try testing.expectEqualStrings("16-09-2026", std.mem.span(@as([*:0]const u8, &text)));

    // DTF_SUBST, against a "today" of day 0.
    dt.format = dos.FORMAT_DOS;
    dt.flags = dos.DTF_SUBST;
    dt.stamp = .{ .days = 0, .minute = 0, .tick = 0 };
    try testing.expect(dl.DateToStr(&dt));
    try testing.expectEqualStrings("Today", std.mem.span(@as([*:0]const u8, &text)));
    dt.stamp.days = 1;
    try testing.expect(dl.DateToStr(&dt));
    try testing.expectEqualStrings("Tomorrow", std.mem.span(@as([*:0]const u8, &text)));
    dt.stamp.days = 2;
    try testing.expect(dl.DateToStr(&dt));
    try testing.expectEqualStrings("Future", std.mem.span(@as([*:0]const u8, &text)));
    // A week back is a weekday name; further back is the date itself.
    dt.stamp.days = 17_790;
    dt.flags = 0;
    try testing.expect(dl.DateToStr(&dt));
    try testing.expectEqualStrings("16-Sep-2026", std.mem.span(@as([*:0]const u8, &text)));

    // A DateStamp that is no date.
    dt.stamp = .{ .days = 0, .minute = 24 * 60, .tick = 0 };
    try testing.expect(!dl.DateToStr(&dt));

    // StrToDate, and back again.
    dt.stamp = .{};
    dt.str_day = null;
    // StrToDate reads the caller's string, which may be longer than the
    // LEN_DATSTRING a buffer it writes needs ("16-September-2026").
    var in_date: [32:0]u8 = @splat(0);
    var in_time: [32:0]u8 = @splat(0);
    dt.str_date = &in_date;
    dt.str_time = &in_time;
    @memcpy(in_date[0..11], "16-Sep-2026");
    @memcpy(in_time[0..8], "13:45:30");
    try testing.expect(dl.StrToDate(&dt));
    try testing.expectEqual(@as(i32, 17_790), dt.stamp.days);
    try testing.expectEqual(@as(i32, 13 * 60 + 45), dt.stamp.minute);
    try testing.expectEqual(@as(i32, 30 * 50), dt.stamp.tick);

    // "September" as well as "Sep", and hh:mm without the seconds.
    dt.stamp = .{};
    in_date = @splat(0);
    in_time = @splat(0);
    @memcpy(in_date[0..13], "16-September-");
    @memcpy(in_date[13..17], "2026");
    @memcpy(in_time[0..5], "13:45");
    try testing.expect(dl.StrToDate(&dt));
    try testing.expectEqual(@as(i32, 17_790), dt.stamp.days);
    try testing.expectEqual(@as(i32, 0), dt.stamp.tick);

    // Two-digit years still mean what they did. A null string is one
    // the caller doesn't give; an empty one is a string that is no date.
    dt.stamp = .{};
    dt.str_time = null;
    in_date = @splat(0);
    @memcpy(in_date[0..9], "16-Sep-26");
    try testing.expect(dl.StrToDate(&dt));
    try testing.expectEqual(@as(i32, 17_790), dt.stamp.days);
    in_date = @splat(0);
    @memcpy(in_date[0..9], "01-Jan-78");
    try testing.expect(dl.StrToDate(&dt));
    try testing.expectEqual(@as(i32, 0), dt.stamp.days);

    // Today, Yesterday, Tomorrow and a weekday, against day 0 (a Sunday).
    in_date = @splat(0);
    @memcpy(in_date[0..5], "Today");
    try testing.expect(dl.StrToDate(&dt));
    try testing.expectEqual(@as(i32, 0), dt.stamp.days);
    in_date = @splat(0);
    @memcpy(in_date[0..8], "Tomorrow");
    try testing.expect(dl.StrToDate(&dt));
    try testing.expectEqual(@as(i32, 1), dt.stamp.days);
    // Friday last: day 0 is Sunday, so Friday is five days back.
    in_date = @splat(0);
    @memcpy(in_date[0..6], "friday");
    try testing.expect(dl.StrToDate(&dt));
    try testing.expectEqual(@as(i32, -2), dt.stamp.days);
    dt.flags = dos.DTF_FUTURE;
    try testing.expect(dl.StrToDate(&dt));
    try testing.expectEqual(@as(i32, 5), dt.stamp.days);
    dt.flags = 0;

    // Strings that are no date at all.
    in_date = @splat(0);
    @memcpy(in_date[0..11], "32-Sep-2026");
    try testing.expect(!dl.StrToDate(&dt));
    in_date = @splat(0);
    @memcpy(in_date[0..11], "29-Feb-2026"); // 2026 is no leap year
    try testing.expect(!dl.StrToDate(&dt));
    in_date = @splat(0);
    @memcpy(in_date[0..11], "29-Feb-2024"); // but 2024 is
    try testing.expect(dl.StrToDate(&dt));
    in_date = @splat(0);
    @memcpy(in_date[0..7], "rubbish");
    try testing.expect(!dl.StrToDate(&dt));
    in_date = @splat(0);
    @memcpy(in_date[0..15], "01-Jan-12345678"); // a year past four digits
    try testing.expect(!dl.StrToDate(&dt));
    in_date = @splat(0);
    @memcpy(in_date[0..11], "31-Dec-9999"); // the last year there is
    try testing.expect(dl.StrToDate(&dt));
    in_date = @splat(0);
    @memcpy(in_date[0..11], "16-Sep-2026");
    dt.str_time = &in_time;
    in_time = @splat(0);
    @memcpy(in_time[0..8], "24:00:00");
    try testing.expect(!dl.StrToDate(&dt));
    in_time = @splat(0);
    try testing.expect(!dl.StrToDate(&dt)); // an empty time string

    try tearDown(db);
}

test "CheckSignal, GetArgStr, SetArgStr, Delay" {
    const db = try setUp();
    defer kexec.deinit();
    const dl = base(db);
    var tp: TestProcess = .{};
    tp.enter();
    defer tp.leave();

    _ = db.sys_base.SetSignal(exec.SIGBREAKF_CTRL_C, exec.SIGBREAKF_CTRL_C);
    try testing.expectEqual(exec.SIGBREAKF_CTRL_C, dl.CheckSignal(exec.SIGBREAKF_CTRL_C | exec.SIGBREAKF_CTRL_D));
    try testing.expectEqual(@as(u32, 0), dl.CheckSignal(exec.SIGBREAKF_CTRL_C)); // cleared
    try testing.expect(dl.GetArgStr() == null);
    try testing.expect(dl.SetArgStr("a b") == null);
    try testing.expectEqualStrings("a b", std.mem.span(dl.GetArgStr().?));
    _ = dl.SetArgStr(null);
    dl.Delay(0);
    dl.Delay(5); // no timer.device on the host: at once
    try tearDown(db);
}

test "CreateNewProc: streams, dirs, arguments, variables, exit hook, CLI number, path; the end gives them back" {
    const db = try setUp();
    defer kexec.deinit();
    const dl = base(db);
    var tp: TestProcess = .{};
    tp.enter();
    defer tp.leave();
    try RamFs.mount(db, &tp);
    dl.UnLock(dl.CreateDir("RAMT:d").?);
    try fileWith(dl, "RAMT:in", "x");
    try testing.expect(dl.SetVar("v", "1", -1, dos.LV_VAR));
    const in = dl.Open("RAMT:in", dos.MODE_OLDFILE).?;
    const out = dl.Open("RAMT:out", dos.MODE_NEWFILE).?;
    tp.proc.current_dir = dl.Lock("RAMT:d", dos.SHARED_LOCK).?;
    const root = dl.Lock("RAMT:", dos.SHARED_LOCK).?;
    var path = dos.PathNode{ .lock = root };

    const tags = [_]TagItem{
        .{ .tag = dos.NP_Entry, .data = @intFromPtr(&ProcEntry.run) },
        .{ .tag = dos.NP_Input, .data = @intFromPtr(in) },
        .{ .tag = dos.NP_Output, .data = @intFromPtr(out) },
        .{ .tag = dos.NP_Arguments, .data = @intFromPtr("some args") },
        .{ .tag = dos.NP_ExitCode, .data = @intFromPtr(&ExitHook.hook) },
        .{ .tag = dos.NP_ExitData, .data = 42 },
        .{ .tag = dos.NP_UserData, .data = 0x1234 },
        .{ .tag = dos.NP_Cli, .data = 1 },
        .{ .tag = dos.NP_Path, .data = @intFromPtr(&path) },
        .{},
    };
    const proc = dl.CreateNewProc(&tags).?;
    try testing.expectEqual(@as(?*FileHandle, in), proc.cis);
    try testing.expectEqual(@as(?*FileHandle, out), proc.cos);
    const flags = dos.dosextens.PRF_CLOSEINPUT | dos.dosextens.PRF_CLOSEOUTPUT | dos.dosextens.PRF_FREECURRDIR | dos.dosextens.PRF_FREEARGS;
    try testing.expectEqual(flags, proc.flags & flags);
    try testing.expect(proc.current_dir != tp.proc.current_dir); // a copy
    try testing.expectEqual(dos.LOCK_SAME, dl.SameLock(proc.current_dir, tp.proc.current_dir));
    try testing.expectEqualStrings("some args", std.mem.span(proc.arguments.?));
    try testing.expectEqual(@as(usize, 0x1234), @intFromPtr(proc.task.user_data)); // NP_UserData
    const copied_var: *dos.LocalVar = @ptrCast(proc.local_vars.head.?);
    try testing.expectEqualStrings("v", std.mem.span(copied_var.name));
    try testing.expectEqual(@as(u32, 1), proc.task_num);
    try testing.expectEqual(@as(u32, 1), dl.MaxCli());
    try testing.expectEqual(@as(?*Process, proc), dl.FindCliProc(1));
    const copied = proc.cli.?.command_dir.?;
    try testing.expect(copied != &path and copied.next == null);
    try testing.expectEqual(dos.LOCK_SAME, dl.SameLock(copied.lock, root));

    // The line replaced by SetArgStr, as the process itself would: the copy
    // CreateNewProc made is still freed at the end (the leak check below),
    // and the replacement, which is the caller's, is not.
    const saved = kexec.SysBase.this_task;
    kexec.SysBase.this_task = &proc.task;
    try testing.expectEqualStrings("some args", std.mem.span(dl.SetArgStr("replaced").?));
    kexec.SysBase.this_task = saved;

    proc.pkt_wait = tp.proc.pkt_wait; // its packets at the end go to the RAM: disk too
    ExitHook.data = 0;
    runAs(proc);
    try testing.expectEqual(@as(isize, 42), ExitHook.data);
    try testing.expect(dl.FindCliProc(1) == null);
    try testing.expectEqual(@as(u32, 0), dl.MaxCli());
    kexec.RemTask(kexec.SysBase, &proc.task);

    const again = dl.CreateNewProc(&[_]TagItem{ .{ .tag = dos.NP_Entry, .data = @intFromPtr(&ProcEntry.run) }, .{ .tag = dos.NP_Cli, .data = 1 }, .{ .tag = dos.NP_CopyVars, .data = 0 }, .{} }).?;
    try testing.expectEqual(@as(u32, 1), again.task_num); // the number is free again
    try testing.expect(again.local_vars.isEmpty());
    again.pkt_wait = tp.proc.pkt_wait;
    runAs(again);
    kexec.RemTask(kexec.SysBase, &again.task);

    dl.UnLock(root);
    dl.UnLock(tp.proc.current_dir);
    tp.proc.current_dir = null;
    process.freeVars(db, &tp.proc);
    RamFs.disk.deinit();
    try tearDown(db);
}

// --- Commands ---

/// A handler entry that never runs, as a segment's code.
const never_code: dos.SegCode = .{ .entry = &StartupWait.neverRun };

/// A command for RunCommand: ReadArgs("A/A,B/N") from Input(); its return
/// code is B.
const TestCommand = struct {
    var got: [32]u8 = undefined;
    var got_len: usize = 0;
    var line_matched = false;
    var refill_size: u32 = 0;

    fn run(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
        const dl: *interface.DosBase = @ptrCast(sys.OpenLibrary(dos.DOSNAME, 0).?);
        defer sys.CloseLibrary(dl.lib());
        line_matched = std.mem.eql(u8, std.mem.span(dl.GetArgStr().?), args[0..len]);
        var argv: [2]usize = @splat(0);
        const rda = dl.ReadArgs("A/A,B/N", &argv, null) orelse return dos.RETURN_FAIL;
        defer dl.FreeArgs(rda);
        const a = std.mem.span(dos.rdargs.string(argv[0]).?);
        @memcpy(got[0..a.len], a);
        got_len = a.len;
        refill_size = dl.Input().?.buf_size;
        return dos.rdargs.number(argv[1]) orelse 0;
    }
};

/// A command that answers -1 itself and leaves pr_Result2 alone.
fn minusOneCommand(_: *ExecBase, _: [*]const u8, _: usize) callconv(.c) i32 {
    return -1;
}

test "RunCommand: the arguments through Input() and GetArgStr, the return code, Input()'s buffer back" {
    const db = try setUp();
    defer kexec.deinit();
    const dl = base(db);
    var tp: TestProcess = .{};
    tp.enter();
    defer tp.leave();
    try RamFs.mount(db, &tp);
    try fileWith(dl, "RAMT:in", "typed ahead\n");
    const in = dl.Open("RAMT:in", dos.MODE_OLDFILE).?;
    _ = dl.SelectInput(in);
    try testing.expectEqual(@as(i32, 't'), dl.FGetC(in)); // read ahead before

    try testing.expect(dl.AddSegment("tc", &.{ .command = &TestCommand.run }, 0));
    const seg = dl.FindSegment("tc", null, false).?;
    const line = "hello 7\n";
    try testing.expectEqual(@as(i32, 7), dl.RunCommand(&seg.code, 4096, line, line.len));
    try testing.expectEqualStrings("hello", TestCommand.got[0..TestCommand.got_len]);
    try testing.expect(TestCommand.line_matched);
    try testing.expect(dl.GetArgStr() == null); // back
    try testing.expectEqual(@as(i32, 'y'), dl.FGetC(in)); // the read-ahead is back
    try fileWith(dl, "RAMT:answer", "answer 3\n");
    const answer = dl.Open("RAMT:answer", dos.MODE_OLDFILE).?;
    _ = dl.SelectInput(answer);
    try testing.expectEqual(@as(i32, 3), dl.RunCommand(&seg.code, 4096, "?\n", 2)); // '?': the answer from Input()
    try testing.expectEqualStrings("answer", TestCommand.got[0..TestCommand.got_len]);
    try testing.expectEqual(dos.stdio.BUFFER_SIZE, TestCommand.refill_size); // past the 2-byte line, a buffer of its own
    _ = dl.SelectInput(in);
    try testing.expect(dl.Close(answer));
    try testing.expectEqual(@as(i32, dos.RETURN_FAIL), dl.RunCommand(&seg.code, 4096, "\n", 1)); // A/A missing
    try testing.expect(dl.RemSegment(seg));
    const none: dos.SegCode = .{ .entry = &ProcEntry.run };
    try testing.expectEqual(@as(i32, -1), dl.RunCommand(&none, 4096, line, line.len));
    try testing.expectEqual(dos.ERROR_OBJECT_WRONG_TYPE, dl.IoErr());
    // -1 from the command itself is its answer, not a stack that failed.
    const minus: dos.SegCode = .{ .command = &minusOneCommand };
    try testing.expectEqual(@as(i32, -1), dl.RunCommand(&minus, 4096, line, line.len));
    try testing.expectEqual(@as(i32, 0), dl.IoErr());

    _ = dl.SelectInput(null);
    try testing.expect(dl.Close(in));
    RamFs.disk.deinit();
    try tearDown(db);
}

// --- Shells ---

/// A shell for SystemTagList's tests: takes the startup packet, notes what
/// dos gave it, reads a line of its command stream, replies.
const FakeShell = struct {
    var mode: isize = -1;
    var flags: isize = -1;
    var line: [64]u8 = undefined;
    var line_len: usize = 0;
    var streams_ok = false;
    var background = false;

    fn entry(sys: *ExecBase) callconv(.c) void {
        const dl: *interface.DosBase = @ptrCast(sys.OpenLibrary(dos.DOSNAME, 0).?);
        defer sys.CloseLibrary(dl.lib());
        const pkt = dl.WaitPkt().?;
        mode = pkt.args.raw[0];
        flags = pkt.args.raw[1];
        const cli = dl.Cli().?;
        background = cli.background;
        streams_ok = cli.standard_output == dl.Output() and cli.standard_input == dl.Input();
        line_len = 0;
        if (cli.current_input) |commands| if (commands != cli.standard_input) {
            var buf: [64]u8 = undefined;
            if (dl.FGets(commands, &buf, buf.len) != null) {
                line_len = std.mem.indexOfScalar(u8, &buf, 0).?;
                @memcpy(line[0..line_len], buf[0..line_len]);
            }
            _ = dl.Close(commands);
        };
        if (flags & dos.SHF_ASYNCH != 0) dl.ReplyPkt(pkt, 0, 0) else dl.ReplyPkt(pkt, 7, 42);
    }

    /// The caller's pr_PktWait: the new shell runs (as exec would run it),
    /// then its reply is taken.
    fn wait(proc: *Process, sys: *ExecBase) callconv(.c) *exec.Message {
        // A CLI carries its number in its name now, so the test looks the
        // shell up the way anything else would: by which CLI it is.
        const dl: *interface.DosBase = @ptrCast(sys.OpenLibrary(dos.DOSNAME, 0).?);
        const shell: *Process = dl.FindCliProc(1).?;
        runAs(shell);
        kexec.RemTask(kexec.SysBase, &shell.task);
        return sys.GetMsg(&proc.msg_port).?;
    }
};

test "SystemTagList, Execute: a shell with its CLI set up, the startup packet, the return code" {
    const db = try setUp();
    defer kexec.deinit();
    const dl = base(db);
    var tp: TestProcess = .{};
    tp.enter();
    defer tp.leave();
    var in_fh: FileHandle = .{};
    var out_fh: FileHandle = .{};
    tp.proc.cis = &in_fh;
    tp.proc.cos = &out_fh;
    tp.proc.pkt_wait = &FakeShell.wait;
    try testing.expect(dl.AddSegment("testshell", &.{ .entry = &FakeShell.entry }, dos.CMD_SYSTEM));

    const custom = [_]TagItem{ .{ .tag = dos.SYS_CustomShell, .data = @intFromPtr("testshell") }, .{} };
    try testing.expectEqual(@as(i32, 7), dl.SystemTagList("echo hi", &custom));
    try testing.expectEqual(@as(i32, 42), dl.IoErr());
    try testing.expectEqual(@intFromEnum(dos.ShellMode.system), FakeShell.mode);
    try testing.expectEqual(@as(isize, 0), FakeShell.flags);
    try testing.expectEqualStrings("echo hi\n", FakeShell.line[0..FakeShell.line_len]);
    try testing.expect(FakeShell.streams_ok and FakeShell.background);

    const asynch = [_]TagItem{ .{ .tag = dos.SYS_CustomShell, .data = @intFromPtr("testshell") }, .{ .tag = dos.SYS_Asynch, .data = 1 }, .{} };
    try testing.expectEqual(@as(i32, 1), dl.SystemTagList("x", &asynch)); // the new CLI's number
    try testing.expectEqual(dos.SHF_ASYNCH | dos.SHF_CLOSE_INPUT | dos.SHF_CLOSE_OUTPUT, FakeShell.flags);

    try testing.expectEqual(@as(i32, 7), dl.SystemTagList(null, &custom)); // interactive: no command stream
    try testing.expectEqual(@intFromEnum(dos.ShellMode.interactive), FakeShell.mode);
    try testing.expect(!FakeShell.background and FakeShell.line_len == 0);

    // SYS_ScriptFile: an interactive shell reads the script first and its
    // own input after, which is what NewShell's FROM is for.
    var script_text = "echo from the script\n".*;
    const script: *FileHandle = @ptrCast(@alignCast(dl.AllocDosObject(dos.DOS_FILEHANDLE, null).?));
    script.buf = &script_text;
    script.buf_size = script_text.len;
    script.end = script.buf_size;
    script.state = .read;
    const with_script = [_]TagItem{
        .{ .tag = dos.SYS_CustomShell, .data = @intFromPtr("testshell") },
        .{ .tag = dos.SYS_ScriptFile, .data = @intFromPtr(script) },
        .{},
    };
    try testing.expectEqual(@as(i32, 7), dl.SystemTagList(null, &with_script));
    try testing.expectEqual(@intFromEnum(dos.ShellMode.interactive), FakeShell.mode);
    try testing.expect(!FakeShell.background); // a script does not make it one
    try testing.expectEqualStrings("echo from the script\n", FakeShell.line[0..FakeShell.line_len]);

    // A command wins: it is already the shell's first input.
    const both = [_]TagItem{
        .{ .tag = dos.SYS_CustomShell, .data = @intFromPtr("testshell") },
        .{ .tag = dos.SYS_ScriptFile, .data = @intFromPtr(@as(?*FileHandle, null)) },
        .{},
    };
    try testing.expectEqual(@as(i32, 7), dl.SystemTagList("only this", &both));
    try testing.expectEqualStrings("only this\n", FakeShell.line[0..FakeShell.line_len]);

    try testing.expect(!dl.Execute("list", null, null)); // no BootShell
    try testing.expectEqual(dos.ERROR_OBJECT_NOT_FOUND, dl.IoErr());
    try testing.expect(dl.AddSegment("BootShell", &.{ .entry = &FakeShell.entry }, dos.CMD_SYSTEM));
    try testing.expect(dl.Execute("list", null, null));
    try testing.expectEqual(@intFromEnum(dos.ShellMode.execute), FakeShell.mode);
    try testing.expectEqualStrings("list\n", FakeShell.line[0..FakeShell.line_len]);

    // One shell per console: a CLI that reads this console already.
    var console: MsgPort = undefined;
    handlerPort(&console);
    var terminal: FileHandle = .{ .task = &console, .interactive = true };
    const other: *dos.CommandLineInterface = @ptrCast(@alignCast(dl.AllocDosObject(dos.DOS_CLI, null).?));
    var reader: Process = .{};
    reader.cli = other;
    other.standard_input = &terminal;
    other.background = false;
    db.clis[5] = &reader;
    const on_console = [_]TagItem{ .{ .tag = dos.SYS_CustomShell, .data = @intFromPtr("testshell") }, .{ .tag = dos.SYS_Input, .data = @intFromPtr(&terminal) }, .{} };
    try testing.expectEqual(@as(i32, -1), dl.SystemTagList(null, &on_console));
    try testing.expectEqual(dos.ERROR_OBJECT_IN_USE, dl.IoErr());
    try testing.expectEqual(@as(i32, 7), dl.SystemTagList("x", &on_console)); // a command may
    other.background = true; // it gave the console up
    try testing.expectEqual(@as(i32, 7), dl.SystemTagList(null, &on_console));
    db.clis[5] = null;
    dl.FreeDosObject(dos.DOS_CLI, other);

    tp.proc.cis = null;
    tp.proc.cos = null;
    try tearDown(db);
}

const shellmod = @import("../../shell/shell.zig");

test "the shell: variables, aliases, redirection, built-ins, unknown commands, return codes" {
    const db = try setUp();
    defer kexec.deinit();
    const dl = base(db);
    var tp: TestProcess = .{};
    tp.enter();
    defer tp.leave();
    try RamFs.mount(db, &tp);
    const cli: *dos.CommandLineInterface = @ptrCast(@alignCast(dl.AllocDosObject(dos.DOS_CLI, null).?));
    tp.proc.cli = cli;
    try fileWith(dl, "RAMT:script", "set x hello\n" ++
        "echo $x world ; a comment\n" ++
        "echo \"a b\" >RAMT:o2\n" ++
        "alias ll echo [] done\n" ++
        "ll 1 2\n" ++
        "failat 30\n" ++
        "failat\n" ++
        "nosuch\n" ++
        "why\n" ++
        "echo $RC +\nmore\n" ++
        "failat 5\n" ++
        "nocmd\n" ++
        "echo not reached\n");
    try fileWith(dl, "RAMT:empty", "");
    const script = dl.Open("RAMT:script", dos.MODE_OLDFILE).?;
    const out = dl.Open("RAMT:out", dos.MODE_NEWFILE).?;
    const empty = dl.Open("RAMT:empty", dos.MODE_OLDFILE).?; // the commands' standard input (NIL: in dos)
    cli.current_input = script; // a script (Execute's)
    cli.standard_input = empty;
    cli.standard_output = out;
    tp.proc.cos = out;
    tp.proc.current_dir = dl.Lock("RAMT:", dos.SHARED_LOCK).?; // where names are looked for
    try testing.expect(shellmod.runShell(@ptrCast(db.sys_base), .execute));
    dl.UnLock(tp.proc.current_dir);
    tp.proc.current_dir = null;
    try testing.expect(cli.current_input == empty); // the script closed, back to the standard input
    try testing.expectEqual(@as(i32, 10), cli.fail_level); // a script's end sets it back
    _ = dl.SelectOutput(null);
    _ = dl.SelectInput(null);
    try testing.expect(dl.Close(out));
    try testing.expect(dl.Close(empty));
    try expectContents(dl, "RAMT:out", "hello world\n" ++
        "1 2 done\n" ++
        "Fail limit: 30\n" ++
        "nosuch: Unknown command\n" ++ // 10, below the limit: on
        "Last command failed because : object not found\n" ++ // the search's Result2
        "5\n" ++ // Why's RC; "+": "more" belongs to echo's line, not a command
        "nocmd: Unknown command\n" ++
        "nocmd failed returncode 10\n"); // at the limit (5): the script stops
    try expectContents(dl, "RAMT:o2", "a b\n");
    process.freeVars(db, &tp.proc);
    tp.proc.cli = null;
    dl.FreeDosObject(dos.DOS_CLI, cli);
    RamFs.disk.deinit();
    try tearDown(db);
}

/// Bytes of a value into `out`, as the load file has them.
fn put(out: []u8, value: anytype) usize {
    const bytes = std.mem.asBytes(&value);
    @memcpy(out[0..bytes.len], bytes);
    return bytes.len;
}

test "LoadSeg, UnLoadSeg: segments relocated, the entry, a file that isn't one" {
    const db = try setUp();
    defer kexec.deinit();
    const dl = base(db);
    var tp: TestProcess = .{};
    tp.enter();
    defer tp.leave();
    try RamFs.mount(db, &tp);

    // Memory loaded code may use: PSRAM on the board, here a buffer that is
    // its own instruction view (exec's CodeAddress).
    var code_ram: [8192]u8 align(16) = undefined;
    _ = kexec.AddMemList(kexec.SysBase, code_ram.len, kexec.MEMF_EXTERNAL, 0, &code_ram, "loadable").?;
    kexec.code_map.* = .{
        .data_start = @intFromPtr(&code_ram),
        .instruction_start = @intFromPtr(&code_ram),
        .size = code_ram.len,
    };
    defer kexec.code_map.* = .{};

    const lf = dos.loadfile;
    var bytes: [256]u8 = undefined;
    var n: usize = 0;
    n += put(bytes[n..], lf.Header{ .segments = 3, .entry_segment = 0, .entry_offset = 4 });
    // code: the word at 0 points into the data segment, the one at 4 into bss
    n += put(bytes[n..], lf.SegmentHeader{ .kind = .code, .file_size = 8, .mem_size = 8, .reloc_groups = 2 });
    n += put(bytes[n..], @as(u32, 4));
    n += put(bytes[n..], @as(u32, 0));
    // data: 8 bytes in the file, 12 allocated, so the tail is cleared
    n += put(bytes[n..], lf.SegmentHeader{ .kind = .data, .file_size = 8, .mem_size = 12, .reloc_groups = 0 });
    n += put(bytes[n..], @as(u32, 0xAABBCCDD));
    n += put(bytes[n..], @as(u32, 0x11223344));
    n += put(bytes[n..], lf.SegmentHeader{ .kind = .bss, .file_size = 0, .mem_size = 8, .reloc_groups = 0 });
    // then the groups, in segment order: the code's two
    n += put(bytes[n..], lf.RelocGroup{ .target_segment = 1, .count = 1 });
    n += put(bytes[n..], @as(u32, 0));
    n += put(bytes[n..], lf.RelocGroup{ .target_segment = 2, .count = 1 });
    n += put(bytes[n..], @as(u32, 4));
    try fileWith(dl, "RAMT:prog", bytes[0..n]);

    const seg = dl.LoadSeg("RAMT:prog").?;
    const data = seg.next.?;
    const bss = data.next.?;
    try testing.expect(bss.next == null);
    try testing.expectEqual(lf.SegmentKind.code, seg.kind);
    try testing.expectEqual(lf.SegmentKind.data, data.kind);
    try testing.expectEqual(lf.SegmentKind.bss, bss.kind);
    // The entry is where the code runs, 4 bytes in.
    try testing.expectEqual(@intFromPtr(seg.run_address.?) + 4, @intFromPtr(seg.entry.?));
    // Both words got their target segment's base.
    const words: [*]align(1) u32 = @ptrCast(seg.data.?);
    try testing.expectEqual(@as(u32, @truncate(@intFromPtr(data.data.?) + 4)), words[0]);
    try testing.expectEqual(@as(u32, @truncate(@intFromPtr(bss.data.?))), words[1]);
    // The data segment kept its bytes; its tail and the bss are cleared.
    try testing.expectEqual(@as(u32, 0xAABBCCDD), @as(*align(1) const u32, @ptrCast(data.data.?)).*);
    try testing.expectEqual(@as(u8, 0), data.data.?[8]);
    try testing.expectEqual(@as(u8, 0), bss.data.?[0]);
    dl.UnLoadSeg(seg);

    try fileWith(dl, "RAMT:notprog", "no magic here, just text");
    try testing.expect(dl.LoadSeg("RAMT:notprog") == null);
    try testing.expectEqual(dos.ERROR_OBJECT_WRONG_TYPE, dl.IoErr());

    try fileWith(dl, "RAMT:short", bytes[0..24]); // cut off inside the first segment
    try testing.expect(dl.LoadSeg("RAMT:short") == null);
    try testing.expectEqual(dos.ERROR_BAD_HUNK, dl.IoErr());

    // A segment that owns loaded code: RemSegment unloads it (the shell's
    // Resident does this).
    const before = kexec.AvailMem(kexec.SysBase, kexec.MEMF_EXTERNAL);
    const again = dl.LoadSeg("RAMT:prog").?;
    try testing.expect(dl.AddSegment("prog", &.{ .command = @ptrCast(@alignCast(again.entry.?)) }, 0));
    _ = dl.LockSegmentList(false);
    const added = dl.FindSegment("prog", null, false).?;
    added.seg_list = again;
    dl.UnLockSegmentList();
    try testing.expect(dl.RemSegment(added));
    try testing.expectEqual(before, kexec.AvailMem(kexec.SysBase, kexec.MEMF_EXTERNAL));

    dl.UnLoadSeg(null); // null is allowed
    RamFs.disk.deinit();
    try tearDown(db);
}

test "the shell: scripts: Execute with .KEY, nested scripts, If, Else, Skip, Quit, the S bit" {
    const db = try setUp();
    defer kexec.deinit();
    const dl = base(db);
    var tp: TestProcess = .{};
    tp.enter();
    defer tp.leave();
    try RamFs.mount(db, &tp);
    try testing.expect(dl.AssignLate("T", "RAMT:T")); // instead of dos's RAM:T
    const cli: *dos.CommandLineInterface = @ptrCast(@alignCast(dl.AllocDosObject(dos.DOS_CLI, null).?));
    tp.proc.cli = cli;
    try fileWith(dl, "RAMT:sub", ".key word/a,num/n,opt/s,many/m\n" ++
        ".def num 7\n" ++
        "echo word:<word> num:<num> opt:<opt$none> many:<many>\n"); // "=" would split the words
    try fileWith(dl, "RAMT:s2", "echo s2 ran\n");
    try testing.expect(dl.SetProtection("RAMT:s2", dos.FIBF_SCRIPT));
    try fileWith(dl, "RAMT:plain", "not a script\n");
    try fileWith(dl, "RAMT:script", "execute RAMT:sub hello 3 opt a b\n" ++ // a work file, the rest appended
        "execute RAMT:sub again\n" ++ // from the work file: the other one
        "if warn\n" ++
        "echo wrong1\n" ++
        "else\n" ++
        "echo else-part\n" ++
        "endif\n" ++
        "if \"abc\" eq \"ABC\"\n" ++
        "echo equal\n" ++
        "endif\n" ++
        "if 3 gt 12 val\n" ++
        "echo wrong2\n" ++
        "if not\n" ++
        "echo wrong3\n" ++
        "endif\n" ++
        "endif\n" ++
        "if exists RAMT:sub\n" ++
        "echo exists\n" ++
        "endif\n" ++
        "skip there\n" ++
        "echo wrong4\n" ++
        "lab there\n" ++
        "RAMT:s2\n" ++ // its S bit: Execute runs it
        "failat 21\n" ++
        "RAMT:plain\n" ++
        "quit 3\n" ++
        "echo wrong5\n");
    try fileWith(dl, "RAMT:empty", "");
    const script = dl.Open("RAMT:script", dos.MODE_OLDFILE).?;
    const out = dl.Open("RAMT:out", dos.MODE_NEWFILE).?;
    const empty = dl.Open("RAMT:empty", dos.MODE_OLDFILE).?;
    cli.current_input = script;
    cli.standard_input = empty;
    cli.standard_output = out;
    tp.proc.cos = out;
    try testing.expect(shellmod.runShell(@ptrCast(db.sys_base), .execute));
    try testing.expect(cli.current_input == empty);
    try testing.expectEqual(@as(i32, 3), cli.return_code); // Quit's
    try testing.expectEqual(@as(u8, 0), cli.command_file.?[0]); // the last work file deleted
    _ = dl.SelectOutput(null);
    _ = dl.SelectInput(null);
    try testing.expect(dl.Close(out));
    try testing.expect(dl.Close(empty));
    try expectContents(dl, "RAMT:out", "word:hello num:3 opt:opt many:a b\n" ++
        "word:again num:7 opt:none many:\n" ++
        "else-part\n" ++
        "equal\n" ++
        "exists\n" ++
        "s2 ran\n" ++
        "RAMT:plain: file is not executable\n");
    // T: is empty again: every work file deleted
    const t = dl.Lock("RAMT:T", dos.SHARED_LOCK).?;
    var fib: dos.FileInfoBlock = .{};
    try testing.expect(dl.Examine(t, &fib));
    try testing.expect(!dl.ExNext(t, &fib));
    dl.UnLock(t);
    try testing.expect(dl.AssignLock("T", null)); // its lock goes before the disk
    process.freeVars(db, &tp.proc);
    tp.proc.cli = null;
    dl.FreeDosObject(dos.DOS_CLI, cli);
    RamFs.disk.deinit();
    try tearDown(db);
}
