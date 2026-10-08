// SPDX-License-Identifier: MIT
//! Host tests of icon.library: the fields as text both ways; then the
//! library made from its ROM tag on the ROM's exec, utility and dos, with
//! a RAM disk as WORK: and ENV: assigned to a drawer on it - icons
//! written, read back and deleted, pictures plain and interlaced, the
//! defaults built in and from ENV: with their pictures shared, the kinds
//! a file without an icon gets, the tool types and the names of copies.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const icon = sdk.icon;
const iconfile = icon.file;
const host = @import("host_rom");
const kexec = host.exec;
const icon_init = @import("../icon_init.zig");

const testing = std.testing;
const DosBase = sdk.interface.dos.DosBase;
const IconBase = sdk.interface.icon.IconBase;

// --- the fields alone ---------------------------------------------------------

test "the fields: an icon's written as text and read back, unknown lines passed over" {
    var drawer = icon.DrawerData{ .left = 40, .top = 30, .width = 400, .height = 200, .current_x = 0, .current_y = -12, .flags = icon.DDFLAGS_SHOWALL, .view_modes = icon.DDVM_BYNAME };
    const types = [_]?[*:0]const u8{ "FILETYPE=text", "DONOTWAIT", null };
    const object = icon.DiskObject{
        .kind = icon.WBDRAWER,
        .current_x = 120,
        .current_y = -4,
        .default_tool = "SYS:Programs/MultiView\nnot this",
        .tool_types = &types,
        .stack_size = 16384,
        .drawer_data = &drawer,
    };
    var text: [512]u8 = undefined;
    const length = iconfile.writeFields(&object, &text).?;
    try testing.expectEqualStrings(
        "KIND=DRAWER\nAT=120,-4\nTOOL=SYS:Programs/MultiView\nTYPE=FILETYPE=text\nTYPE=DONOTWAIT\nSTACK=16384\nWINDOW=40,30,400,200\nSCROLL=0,-12\nVIEW=NAME\nSHOW=ALL\n",
        text[0..length],
    );
    var small: [20]u8 = undefined;
    try testing.expect(iconfile.writeFields(&object, &small) == null);

    var fields = iconfile.Fields{ .text = "kind = tool\r\nNOTAKEY=1\nno equals\nAt=1,2\n" };
    const first = fields.next().?;
    try testing.expectEqual(iconfile.Key.kind, first.key);
    try testing.expectEqual(@as(?u32, icon.WBTOOL), iconfile.kindOf(first.value));
    const second = fields.next().?;
    try testing.expectEqual(iconfile.Key.at, second.key);
    try testing.expectEqual([2]i32{ 1, 2 }, iconfile.numbers(2, second.value).?);
    try testing.expect(fields.next() == null);
    try testing.expect(iconfile.numbers(2, "1,2,3") == null);
    try testing.expect(iconfile.numbers(4, "1,2") == null);
    try testing.expect(iconfile.number("99999999999") == null);
    try testing.expectEqual(@as(?u32, icon.DDVM_BYSIZE), iconfile.viewOf("size"));
}

// --- the library on a RAM disk -------------------------------------------------

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

/// Memory lent to exec for a test: pictures, the files they come from
/// and their unpacked rows are more than the host tests' 80 KiB hold.
var lent: [512 * 1024]u8 align(16) = undefined;

/// exec, utility and dos with memory lent; a process with WORK: behind it
/// and ENV: a drawer on it holding `Sys`; icon.library made and opened.
const Rig = struct {
    db: *host.dos.DosBase,
    region: *exec.MemHeader = undefined,
    proc: dos.Process = .{},
    saved: ?*kexec.Task = null,
    library: *exec.Library = undefined,
    ib: *IconBase = undefined,

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
        dl.UnLock(dl.CreateDir("WORK:Env") orelse return error.NoDir);
        dl.UnLock(dl.CreateDir("WORK:Env/Sys") orelse return error.NoDir);
        try testing.expect(dl.AssignLock("ENV", dl.Lock("WORK:Env", dos.SHARED_LOCK)));

        const lib = kexec.InitResident(kexec.SysBase, &icon_init.icon_library_tag, null) orelse return error.NoIcon;
        rig.library = @ptrCast(@alignCast(lib));
        rig.ib = @ptrCast(rig.sysLib().OpenLibrary(icon.ICONNAME, 1) orelse return error.NoBase);
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
        rig.sysLib().CloseLibrary(rig.ib.lib());
        _ = rig.sysLib().RemLibrary(rig.library);
        try testing.expect(kexec.FindName(kexec.SysBase, &kexec.SysBase.lib_list, icon.ICONNAME) == null);
        _ = rig.dosLib().AssignLock("ENV", null);
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

const plain_png = @embedFile("plain.png");
const interlaced_png = @embedFile("interlaced.png");
const drawer_png = @embedFile("../images/drawer.png");

/// The pixel the two test pictures have at x, y: red, green, blue,
/// coverage.
fn testPixel(x: u32, y: u32) [4]u8 {
    return .{
        @truncate((x * 37 + y * 11) % 256),
        @truncate((x * 5 + y * 53) % 256),
        @truncate((x * 91 + y * 7 + 40) % 256),
        if ((x + y) % 5 != 0) 255 else @truncate((x * 20) % 256),
    };
}

fn expectTestPicture(image: *const icon.IconImage) !void {
    try testing.expectEqual(@as(u32, 13), image.width);
    try testing.expectEqual(@as(u32, 11), image.height);
    for (0..11) |y| for (0..13) |x| {
        const at = (y * 13 + x) * 4;
        try testing.expectEqualSlices(u8, &testPixel(@intCast(x), @intCast(y)), image.pixels[at..][0..4]);
    };
}

test "a picture without fields is an icon, plain or interlaced, of the kind of what it belongs to" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit() catch unreachable;
    const dl = rig.dosLib();
    const ib = rig.ib;

    try rig.write("WORK:Plain", "text");
    try rig.write("WORK:Plain.info", plain_png);
    dl.UnLock(dl.CreateDir("WORK:Laced") orelse return error.NoDir);
    try rig.write("WORK:Laced.info", interlaced_png);

    const plain = ib.GetDiskObject("WORK:Plain") orelse return error.NoIcon;
    defer ib.FreeDiskObject(plain);
    try testing.expectEqual(icon.WBPROJECT, plain.kind);
    try testing.expectEqual(icon.NO_ICON_POSITION, plain.current_x);
    try testing.expect(plain.drawer_data == null and plain.default_tool == null and plain.tool_types == null);
    try expectTestPicture(plain.image.?);

    const laced = ib.GetDiskObject("WORK:Laced") orelse return error.NoIcon;
    defer ib.FreeDiskObject(laced);
    try testing.expectEqual(icon.WBDRAWER, laced.kind);
    try testing.expect(laced.drawer_data != null);
    try expectTestPicture(laced.image.?);

    try testing.expect(ib.GetDiskObject("WORK:Nothing") == null);
    try testing.expectEqual(dos.ERROR_OBJECT_NOT_FOUND, dl.IoErr());
    try rig.write("WORK:Text.info", "not a picture at all");
    try testing.expect(ib.GetDiskObject("WORK:Text") == null);
    try testing.expectEqual(dos.ERROR_OBJECT_WRONG_TYPE, dl.IoErr());
}

test "an icon written, read back the same, its file a PNG still, then deleted" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit() catch unreachable;
    const dl = rig.dosLib();
    const ib = rig.ib;
    try rig.write("WORK:Notes.info", plain_png);

    const object = ib.GetDiskObject("WORK:Notes") orelse return error.NoIcon;
    defer ib.FreeDiskObject(object);
    // The program's own tool types and tool, hung on the icon to write it.
    const types = [_]?[*:0]const u8{ "FILETYPE=text|ascii", "WAIT", null };
    object.tool_types = &types;
    object.default_tool = "SYS:Programs/Notepad";
    object.current_x = 64;
    object.current_y = 32;
    object.stack_size = 20000;
    try testing.expect(ib.PutDiskObject("WORK:Copy", object));

    var bytes: [4096]u8 = undefined;
    const file = try rig.read("WORK:Copy.info", &bytes);
    try testing.expectEqualSlices(u8, &sdk.datatypes.png.decode.signature, file[0..8]);
    const fields = (try iconfile.fieldsOf(file)).?;
    try testing.expectEqualStrings("KIND=PROJECT\nAT=64,32\nTOOL=SYS:Programs/Notepad\nTYPE=FILETYPE=text|ascii\nTYPE=WAIT\nSTACK=20000\n", fields);
    try testing.expectEqual(@as(u32, 13), (try sdk.datatypes.png.decode.readInfo(file)).width);

    const back = ib.GetDiskObject("WORK:Copy") orelse return error.NoIcon;
    defer ib.FreeDiskObject(back);
    try testing.expectEqual(icon.WBPROJECT, back.kind);
    try testing.expectEqual(@as(i32, 64), back.current_x);
    try testing.expectEqual(@as(u32, 20000), back.stack_size);
    try testing.expectEqualStrings("SYS:Programs/Notepad", std.mem.span(back.default_tool.?));
    try testing.expectEqualStrings("WAIT", std.mem.span(back.tool_types.?[1].?));
    try testing.expect(back.tool_types.?[2] == null);
    try expectTestPicture(back.image.?);
    const value = ib.FindToolType(back.tool_types, "filetype").?;
    try testing.expect(ib.MatchToolValue(value, "ASCII"));

    // Written once more over itself, the file is the same.
    try testing.expect(ib.PutDiskObject("WORK:Copy", back));
    var again: [4096]u8 = undefined;
    try testing.expectEqualSlices(u8, file, try rig.read("WORK:Copy.info", &again));

    try testing.expect(ib.DeleteDiskObject("WORK:Copy"));
    try testing.expect(ib.GetDiskObject("WORK:Copy") == null);
    try testing.expect(ib.DeleteDiskObject("WORK:Copy"));
    try testing.expect(dl.Lock("WORK:Notes", dos.SHARED_LOCK) == null);

    // An icon without a picture, and a name too long to have one.
    const empty = ib.GetDiskObject(null) orelse return error.NoIcon;
    defer ib.FreeDiskObject(empty);
    try testing.expect(empty.image == null and empty.kind == 0);
    try testing.expect(!ib.PutDiskObject("WORK:Empty", empty));
    try testing.expectEqual(dos.ERROR_REQUIRED_ARG_MISSING, dl.IoErr());
    var long: [260]u8 = @splat('x');
    @memcpy(long[0..5], "WORK:");
    long[259] = 0;
    try testing.expect(!ib.PutDiskObject(@ptrCast(&long), object));
    try testing.expectEqual(dos.ERROR_INVALID_COMPONENT_NAME, dl.IoErr());
}

test "the defaults: built in and shared, ENV:'s taking over, kept while unchanged, gone again" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit() catch unreachable;
    const dl = rig.dosLib();
    const ib = rig.ib;

    const first = ib.GetDefDiskObject(icon.WBDRAWER) orelse return error.NoIcon;
    defer ib.FreeDiskObject(first);
    const second = ib.GetDefDiskObject(icon.WBDRAWER) orelse return error.NoIcon;
    defer ib.FreeDiskObject(second);
    try testing.expectEqual(icon.WBDRAWER, first.kind);
    try testing.expectEqual(@as(u32, 48), first.image.?.width);
    try testing.expectEqual(first.image.?, second.image.?);
    try testing.expectEqual(icon.NO_ICON_POSITION, first.current_x);
    try testing.expect(first.drawer_data != null);
    for (1..6) |kind| {
        const object = ib.GetDefDiskObject(@intCast(kind)) orelse return error.NoIcon;
        try testing.expectEqual(@as(u32, @intCast(kind)), object.kind);
        ib.FreeDiskObject(object);
    }
    try testing.expect(ib.GetDefDiskObject(7) == null);
    try testing.expectEqual(dos.ERROR_BAD_NUMBER, dl.IoErr());

    // A default of ENV:'s: written by PutDefDiskObject from an icon of the
    // kind, it is what the next one is made from.
    try rig.write("WORK:Mine.info", plain_png);
    dl.UnLock(dl.CreateDir("WORK:Mine") orelse return error.NoDir);
    const mine = ib.GetDiskObject("WORK:Mine") orelse return error.NoIcon;
    mine.default_tool = "C:List";
    mine.current_x = 5;
    mine.current_y = 5;
    try testing.expect(!ib.PutDefDiskObject(mine)); // ENVARC: is not there
    ib.FreeDiskObject(mine);
    const from_env = ib.GetDefDiskObject(icon.WBDRAWER) orelse return error.NoIcon;
    try testing.expectEqual(@as(u32, 13), from_env.image.?.width);
    try testing.expectEqualStrings("C:List", std.mem.span(from_env.default_tool.?));
    try testing.expectEqual(icon.NO_ICON_POSITION, from_env.current_x);
    // Unchanged, the same picture again.
    const again = ib.GetDefDiskObject(icon.WBDRAWER) orelse return error.NoIcon;
    try testing.expectEqual(from_env.image.?, again.image.?);
    ib.FreeDiskObject(again);
    ib.FreeDiskObject(from_env);

    // A file of another kind does not do; one removed leaves the built-in.
    const object = ib.GetDiskObject("ENV:Sys/def_drawer") orelse return error.NoIcon;
    try testing.expect(ib.PutDiskObject("ENV:Sys/def_tool", object));
    ib.FreeDiskObject(object);
    const tool = ib.GetDefDiskObject(icon.WBTOOL) orelse return error.NoIcon;
    try testing.expectEqual(@as(u32, 48), tool.image.?.width);
    ib.FreeDiskObject(tool);
    try testing.expect(dl.DeleteFile("ENV:Sys/def_drawer.info"));
    const built_in = ib.GetDefDiskObject(icon.WBDRAWER) orelse return error.NoIcon;
    try testing.expectEqual(@as(u32, 48), built_in.image.?.width);
    try testing.expect(built_in.default_tool == null);
    ib.FreeDiskObject(built_in);
}

test "a file without an icon: a disk, a drawer, a tool, a script, a project, and Disk" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit() catch unreachable;
    const dl = rig.dosLib();
    const ib = rig.ib;

    dl.UnLock(dl.CreateDir("WORK:Drawer") orelse return error.NoDir);
    try rig.write("WORK:Program", "PSG1 and then the rest");
    try rig.write("WORK:Data", "PSG1 but not to be run");
    try testing.expect(dl.SetProtection("WORK:Data", dos.FIBF_EXECUTE));
    try rig.write("WORK:Script", "echo hello");
    try testing.expect(dl.SetProtection("WORK:Script", dos.FIBF_SCRIPT));
    try rig.write("WORK:Letter", "Dear ...");

    const cases = [_]struct { name: [*:0]const u8, kind: u32 }{
        .{ .name = "WORK:", .kind = icon.WBDISK },
        .{ .name = "WORK:Disk", .kind = icon.WBDISK },
        .{ .name = "WORK:Drawer", .kind = icon.WBDRAWER },
        .{ .name = "WORK:Program", .kind = icon.WBTOOL },
        .{ .name = "WORK:Data", .kind = icon.WBPROJECT },
        .{ .name = "WORK:Script", .kind = icon.WBPROJECT },
        .{ .name = "WORK:Letter", .kind = icon.WBPROJECT },
    };
    var shared: ?*const icon.IconImage = null;
    for (cases) |case| {
        const object = ib.GetDiskObjectNew(case.name) orelse {
            std.debug.print("no icon for {s}\n", .{case.name});
            return error.NoIcon;
        };
        defer ib.FreeDiskObject(object);
        try testing.expectEqual(case.kind, object.kind);
        try testing.expectEqual(icon.NO_ICON_POSITION, object.current_x);
        if (case.kind == icon.WBPROJECT) {
            if (shared) |image| try testing.expectEqual(image, object.image.?);
            shared = object.image.?;
        }
    }
    try testing.expect(ib.GetDiskObjectNew("WORK:Nothing") == null);

    // A volume's own icon is Disk.info in its root.
    try rig.write("WORK:Disk.info", plain_png);
    const disk = ib.GetDiskObjectNew("WORK:") orelse return error.NoIcon;
    defer ib.FreeDiskObject(disk);
    try testing.expectEqual(icon.WBDISK, disk.kind);
    try testing.expectEqual(@as(u32, 13), disk.image.?.width);

    // A script's default, when ENV: gives one.
    const project = ib.GetDefDiskObject(icon.WBPROJECT) orelse return error.NoIcon;
    project.default_tool = "C:IconX";
    try testing.expect(ib.PutDiskObject("ENV:Sys/def_script", project));
    ib.FreeDiskObject(project);
    const script = ib.GetDiskObjectNew("WORK:Script") orelse return error.NoIcon;
    defer ib.FreeDiskObject(script);
    try testing.expectEqualStrings("C:IconX", std.mem.span(script.default_tool.?));
}

test "the tool types and the names of copies, as 3.1's examples have them" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit() catch unreachable;
    const ib = rig.ib;

    const types = [_]?[*:0]const u8{ "FILETYPES=all", "FILETYPE=text", "TEMPDIR=:t", "DONOTWAIT", null };
    try testing.expectEqualStrings("text", std.mem.span(ib.FindToolType(&types, "FILETYPE").?));
    try testing.expectEqualStrings("text", std.mem.span(ib.FindToolType(&types, "filetype").?));
    try testing.expectEqualStrings(":t", std.mem.span(ib.FindToolType(&types, "TEMPDIR").?));
    try testing.expectEqualStrings("", std.mem.span(ib.FindToolType(&types, "donotwait").?));
    try testing.expect(ib.FindToolType(&types, "MAXSIZE") == null);
    try testing.expect(ib.FindToolType(null, "MAXSIZE") == null);

    try testing.expect(ib.MatchToolValue("text", "text"));
    try testing.expect(ib.MatchToolValue("text", "TEXT"));
    try testing.expect(!ib.MatchToolValue("text", "data"));
    try testing.expect(ib.MatchToolValue("a|b|c", "a"));
    try testing.expect(ib.MatchToolValue("a|b|c", "b"));
    try testing.expect(!ib.MatchToolValue("a|b|c", "d"));
    try testing.expect(!ib.MatchToolValue("a|b|c", "a|b"));

    const names = [_][2][]const u8{
        .{ "foo", "Copy_of_foo" },
        .{ "Copy_of_foo", "Copy_2_of_foo" },
        .{ "copy_2_of_foo", "Copy_3_of_foo" },
        .{ "Copy_199_of_foo", "Copy_200_of_foo" },
        .{ "copy foo", "Copy_of_copy foo" },
        .{ "copy_0_of_foo", "Copy_1_of_foo" },
        .{ "copy of foo", "Copy_2_of_foo" },
        .{ "Copy_5", "Copy_of_Copy_5" },
    };
    for (names) |pair| {
        var given: [64:0]u8 = @splat(0);
        @memcpy(given[0..pair[0].len], pair[0]);
        var into: [256]u8 = undefined;
        try testing.expectEqualStrings(pair[1], std.mem.span(ib.BumpRevision(&into, &given)));
    }
    var long: [300:0]u8 = @splat('n');
    var into: [256]u8 = undefined;
    const bumped = std.mem.span(ib.BumpRevision(&into, &long));
    try testing.expectEqual(@as(usize, 255), bumped.len);
    try testing.expectEqualStrings("Copy_of_nnn", bumped[0..11]);
}
