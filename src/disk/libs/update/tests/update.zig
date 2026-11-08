// SPDX-License-Identifier: MIT
//! Host tests of update.library, made from its ROM tag on the ROM's exec,
//! utility and dos, with a RAM disk as WORK:, SYS: a drawer on it holding
//! an installed system and its list, and a package beside it: a run
//! checked, then done, what it says heard through a hook; a file changed
//! on the machine kept, and FORCE taking the package's; a run with no
//! package to read saying why.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const utility = sdk.utility;
const update = sdk.update;
const manifest = sdk.install.manifest;
const host = @import("host_rom");
const kexec = host.exec;
const update_init = @import("../update_init.zig");

const testing = std.testing;
const DosBase = sdk.interface.dos.DosBase;
const UpdateBase = sdk.interface.update.UpdateBase;
const TagItem = utility.TagItem;

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

/// Memory lent to exec for a test: a run's piece is 64 KiB, more than
/// the host tests' own memory holds beside the disk.
var lent: [512 * 1024]u8 align(16) = undefined;

/// exec, utility and dos with memory lent; a process with WORK: behind
/// it, SYS: assigned to WORK:Sys with `C` and `System` in it; the
/// library made and opened.
const Rig = struct {
    db: *host.dos.DosBase,
    region: *exec.MemHeader = undefined,
    proc: dos.Process = .{},
    saved: ?*kexec.Task = null,
    library: *exec.Library = undefined,
    upd: *UpdateBase = undefined,

    fn init(rig: *Rig) !void {
        rig.* = .{ .db = try host.dos.testSetUp() };
        rig.region = rig.sysLib().AddMemList(lent.len, exec.MEMF_ANY, 0, &lent, "lent").?;
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
        for ([_][*:0]const u8{ "WORK:Sys", "WORK:Sys/C", "WORK:Sys/System", "WORK:Package", "WORK:Package/system", "WORK:Package/system/C" }) |name| {
            dl.UnLock(dl.CreateDir(name) orelse return error.NoDir);
        }
        try testing.expect(dl.AssignLock("SYS", dl.Lock("WORK:Sys", dos.SHARED_LOCK)));

        const lib = kexec.InitResident(kexec.SysBase, &update_init.update_library_tag, null) orelse return error.NoUpdate;
        rig.library = @ptrCast(@alignCast(lib));
        rig.upd = @ptrCast(rig.sysLib().OpenLibrary(update.UPDATENAME, 1) orelse return error.NoBase);
    }

    fn sysLib(_: *Rig) *sdk.interface.exec.ExecBase {
        return kexec.SysBase.iface();
    }

    fn dosLib(rig: *Rig) *DosBase {
        return host.dos.testBase(rig.db);
    }

    /// The library closed and expunged, the assign and the disk taken
    /// down with every library, and nothing left behind.
    fn deinit(rig: *Rig) !void {
        rig.sysLib().CloseLibrary(rig.upd.lib());
        _ = rig.sysLib().RemLibrary(rig.library);
        try testing.expect(kexec.FindName(kexec.SysBase, &kexec.SysBase.lib_list, update.UPDATENAME) == null);
        _ = rig.dosLib().AssignLock("SYS", null);
        Disk.disk.deinit();
        kexec.SysBase.cpu().this_task = rig.saved.?;
        try host.dos.testTearDown(rig.db);
        try testing.expectEqual(@intFromPtr(rig.region.upper) - @intFromPtr(rig.region.lower), rig.region.free);
        rig.sysLib().Remove(&rig.region.node);
        kexec.deinit();
    }

    /// A file on the disk.
    fn write(rig: *Rig, name: [*:0]const u8, bytes: []const u8) !void {
        const dl = rig.dosLib();
        const fh = dl.Open(name, dos.MODE_NEWFILE) orelse return error.NoFile;
        defer _ = dl.Close(fh);
        try testing.expectEqual(@as(isize, @intCast(bytes.len)), dl.Write(fh, bytes.ptr, @intCast(bytes.len)));
    }

    /// A file read whole, into `into`.
    fn read(rig: *Rig, name: [*:0]const u8, into: []u8) ![]u8 {
        const dl = rig.dosLib();
        const fh = dl.Open(name, dos.MODE_OLDFILE) orelse return error.NoFile;
        defer _ = dl.Close(fh);
        const got = dl.Read(fh, into.ptr, @intCast(into.len));
        return into[0..@intCast(got)];
    }
};

/// A file for a list: its path in a package and its bytes.
const Shipped = struct { path: []const u8, bytes: []const u8 };

/// A list of `files` - the two halves' drawers, then the files, in the
/// order a list keeps - into `into`: its text.
fn listOf(files: []const Shipped, into: []u8) []const u8 {
    var at: usize = 0;
    @memcpy(into[0..manifest.preamble.len], manifest.preamble);
    at += manifest.preamble.len;
    var counts: manifest.Counts = .{};
    const drawers = [_][]const u8{ "system", "system/C" };
    for (drawers) |path| counts.add(.{ .kind = .drawer, .path = path });
    for (files) |file| counts.add(.{ .kind = .file, .path = file.path, .size = file.bytes.len });
    at += manifest.headerLine(.{ .chip = sdk.hardware.chip, .counts = counts }, into[at..]);
    for (drawers) |path| at += manifest.entryLine(.{ .kind = .drawer, .path = path }, into[at..]);
    for (files) |file| {
        const crc = dos.flashfs.crcEnd(dos.flashfs.crcAdd(dos.flashfs.crcStart(), file.bytes));
        at += manifest.entryLine(.{ .kind = .file, .path = file.path, .crc = crc, .size = file.bytes.len }, into[at..]);
    }
    return into[0..at];
}

/// What a hook heard: each path's row as `what path`, a line apart, the
/// files written and their bytes, and the last line said.
const Heard = struct {
    rows: [1024]u8 = undefined,
    rows_used: usize = 0,
    wrote: u32 = 0,
    wrote_bytes: u64 = 0,
    last: [256]u8 = undefined,
    last_used: usize = 0,
    failed: bool = false,
    object: ?*anyopaque = null,

    fn entry(hook: *utility.Hook, object: ?*anyopaque, message: ?*anyopaque) callconv(.c) usize {
        const heard: *Heard = @ptrCast(@alignCast(hook.data.?));
        const said: *const update.UpdateMessage = @ptrCast(@alignCast(message.?));
        heard.object = object;
        const text = std.mem.span(said.text);
        switch (said.kind) {
            update.UPDM_PATH => {
                const what = std.mem.span(said.what);
                for ([_][]const u8{ what, " ", text, "\n" }) |piece| {
                    @memcpy(heard.rows[heard.rows_used..][0..piece.len], piece);
                    heard.rows_used += piece.len;
                }
            },
            update.UPDM_WROTE => {
                heard.wrote += 1;
                heard.wrote_bytes += said.bytes;
            },
            else => {
                const length = @min(text.len, heard.last.len);
                @memcpy(heard.last[0..length], text[0..length]);
                heard.last_used = length;
                heard.failed = said.failed != 0;
            },
        }
        return 0;
    }

    fn rowsSaid(heard: *const Heard) []const u8 {
        return heard.rows[0..heard.rows_used];
    }

    fn lastSaid(heard: *const Heard) []const u8 {
        return heard.last[0..heard.last_used];
    }
};

const old_tool = "the tool as it was installed\n";
const new_tool = "the tool as the build has it now, longer\n";
const fresh_tool = "a tool the build has begun to ship\n";

/// The machine as it was installed: SYS:C/Tool and its list; the package:
/// Tool changed, New added.
fn installed(rig: *Rig) !void {
    var text: [1024]u8 = undefined;
    try rig.write("SYS:C/Tool", old_tool);
    try rig.write("SYS:System/manifest", listOf(&.{.{ .path = "system/C/Tool", .bytes = old_tool }}, &text));
    try rig.write("WORK:Package/system/C/New", fresh_tool);
    try rig.write("WORK:Package/system/C/Tool", new_tool);
    try rig.write("WORK:Package/manifest", listOf(&.{
        .{ .path = "system/C/New", .bytes = fresh_tool },
        .{ .path = "system/C/Tool", .bytes = new_tool },
    }, &text));
}

test "a run checked, then done: what it would write said, then written, and the package's list the machine's own" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit() catch unreachable;
    try installed(&rig);
    const upd = rig.upd;

    var heard: Heard = .{};
    var hook: utility.Hook = .{ .entry = &Heard.entry, .data = &heard };
    const run = upd.CreateUpdate(&[_]TagItem{
        .{ .tag = update.UPD_Source, .data = @intFromPtr("WORK:Package") },
        .{ .tag = update.UPD_Hook, .data = @intFromPtr(&hook) },
        .{},
    }) orelse return error.NoRun;

    try testing.expectEqual(dos.RETURN_WARN, upd.DoUpdate(run, &[_]TagItem{ .{ .tag = update.UPD_Check, .data = 1 }, .{} }));
    try testing.expectEqualStrings("new SYS:C/New\nnewer SYS:C/Tool\n", heard.rowsSaid());
    try testing.expectEqual(@as(u32, 0), heard.wrote);
    try testing.expectEqual(@as(?*anyopaque, @ptrCast(run)), heard.object);
    var info: update.UpdateInfo = .{};
    upd.GetUpdateInfo(run, &info);
    try testing.expectEqualStrings("WORK:Package", std.mem.span(info.source));
    try testing.expectEqual(@as(u32, 2), info.files);
    try testing.expectEqual(@as(u32, 2), info.written);
    try testing.expectEqual(@as(u64, fresh_tool.len + new_tool.len), info.written_bytes);
    try testing.expect(update.changes(&info));
    var bytes: [256]u8 = undefined;
    try testing.expectEqualStrings(old_tool, try rig.read("SYS:C/Tool", &bytes));

    heard = .{};
    try testing.expectEqual(dos.RETURN_OK, upd.DoUpdate(run, null));
    try testing.expectEqualStrings("new SYS:C/New\nnewer SYS:C/Tool\nlist SYS:System/manifest\n", heard.rowsSaid());
    try testing.expectEqual(@as(u32, 2), heard.wrote);
    try testing.expectEqual(@as(u64, fresh_tool.len + new_tool.len), heard.wrote_bytes);
    try testing.expectEqualStrings(new_tool, try rig.read("SYS:C/Tool", &bytes));
    try testing.expectEqualStrings(fresh_tool, try rig.read("SYS:C/New", &bytes));
    var list: [1024]u8 = undefined;
    var theirs: [1024]u8 = undefined;
    try testing.expectEqualStrings(try rig.read("WORK:Package/manifest", &theirs), try rig.read("SYS:System/manifest", &list));

    // Done once, nothing is left to do.
    heard = .{};
    try testing.expectEqual(dos.RETURN_OK, upd.DoUpdate(run, &[_]TagItem{ .{ .tag = update.UPD_Check, .data = 1 }, .{} }));
    try testing.expectEqualStrings("", heard.rowsSaid());
    upd.GetUpdateInfo(run, &info);
    try testing.expect(!update.changes(&info));
    upd.DeleteUpdate(run);
}

test "a file changed on the machine is kept, and FORCE takes the package's" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit() catch unreachable;
    try installed(&rig);
    const mine = "the tool as somebody here changed it\n";
    try rig.write("SYS:C/Tool", mine);
    const upd = rig.upd;

    var heard: Heard = .{};
    var hook: utility.Hook = .{ .entry = &Heard.entry, .data = &heard };
    const run = upd.CreateUpdate(&[_]TagItem{
        .{ .tag = update.UPD_Source, .data = @intFromPtr("WORK:Package") },
        .{ .tag = update.UPD_Hook, .data = @intFromPtr(&hook) },
        .{},
    }) orelse return error.NoRun;
    defer upd.DeleteUpdate(run);

    try testing.expectEqual(dos.RETURN_WARN, upd.DoUpdate(run, &[_]TagItem{ .{ .tag = update.UPD_Check, .data = 1 }, .{} }));
    try testing.expectEqualStrings("new SYS:C/New\nkept SYS:C/Tool\n", heard.rowsSaid());
    var info: update.UpdateInfo = .{};
    upd.GetUpdateInfo(run, &info);
    try testing.expectEqual(@as(u32, 1), info.kept);
    try testing.expectEqual(@as(u32, 1), info.written);

    heard = .{};
    try testing.expectEqual(dos.RETURN_OK, upd.DoUpdate(run, &[_]TagItem{ .{ .tag = update.UPD_Force, .data = 1 }, .{} }));
    try testing.expectEqualStrings("new SYS:C/New\nnewer SYS:C/Tool\nlist SYS:System/manifest\n", heard.rowsSaid());
    var bytes: [256]u8 = undefined;
    try testing.expectEqualStrings(new_tool, try rig.read("SYS:C/Tool", &bytes));
}

test "a run with no package to read is not made, and says why" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit() catch unreachable;
    const upd = rig.upd;

    var heard: Heard = .{};
    var hook: utility.Hook = .{ .entry = &Heard.entry, .data = &heard };
    const hooked = [_]TagItem{ .{ .tag = update.UPD_Hook, .data = @intFromPtr(&hook) }, .{} };
    try testing.expect(upd.CreateUpdate(&hooked) == null);
    try testing.expect(heard.failed);
    try testing.expect(std.mem.startsWith(u8, heard.lastSaid(), "no package named"));

    // One named that is not there: made, and its walk fails.
    heard = .{};
    const run = upd.CreateUpdate(&[_]TagItem{
        .{ .tag = update.UPD_Source, .data = @intFromPtr("WORK:Nothing") },
        .{ .tag = update.UPD_Hook, .data = @intFromPtr(&hook) },
        .{},
    }) orelse return error.NoRun;
    defer upd.DeleteUpdate(run);
    try testing.expectEqual(dos.RETURN_FAIL, upd.DoUpdate(run, null));
    try testing.expect(heard.failed);
}
