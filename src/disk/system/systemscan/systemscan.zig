// SPDX-License-Identifier: MIT
//! SystemScan: what this machine is made of, written down as one text -
//! to read in a window and to carry away as a file. Built against the SDK
//! only.
//!
//!   SystemScan TO
//!
//! TO is the drawer the report is saved in. Without it the field at the
//! top starts at `POWEROS:Scans` where a volume of that name is in - the
//! boot partition of the medium a machine is first started from, a FAT
//! volume any other system reads - and at `SYS:Scans` otherwise. The
//! field's button asks for a drawer (asl.library's requester, through
//! getfile.gadget).
//!
//! **The report** is made as the window opens, and again with Scan. Its
//! first part is the tool's own: every PCI function no driver has
//! claimed, by what its class code says it is - the network, display,
//! sound, storage and USB controllers first, since those are the drivers
//! a new machine is missing - with its place, its IDs and its subsystem,
//! as pci.library found it. After that come the listings the system's
//! own commands give, each under a heading with the command that made
//! it, run with their output sent into the report (`sections`): the
//! system's version, the board, the devices by what they speak, the
//! memory, the PCI functions in short and in full, the USB buses, the
//! displays, the sound outputs, the network, the drives, the system log
//! and the PCI functions' configuration space. A command that is not on
//! the disk leaves the shell's own line under its heading.
//!
//! It is written to `T:SystemScan.txt` and read back into the window,
//! which shows it in a field that can be read, selected and copied but
//! not changed.
//!
//! **Save** writes that text into the drawer the field names, made where
//! it is not there, as `scan-<year><month><day>-<hour><minute><second>.txt`
//! by the machine's clock, and says under the field what the file is
//! called - or why it could not be written.
//!
//! The commands run one after the other on the window's own process, so
//! the window answers again when the report is there: a second or two,
//! most of it pci.library and the USB buses looking at the machine the
//! first time they are asked.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const pci = sdk.pci;
const intuition = sdk.intuition;
const utility = sdk.utility;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const UtilityBase = sdk.interface.utility.UtilityBase;
const PCIBase = sdk.interface.pci.PCIBase;
const TagItem = utility.TagItem;
const Object = intuition.Object;
const rdargs = dos.rdargs;
const Printf = dos.stdio.Printf;
const FPrintf = dos.stdio.FPrintf;
const gc = intuition.gadgetclass;
const lg = intuition.layoutgclass;
const wn = intuition.windows;
const wc = intuition.windowclass;
const classusr = intuition.classusr;
const gf = sdk.gadgets.getfile;
const tx = sdk.gadgets.text;
const te = sdk.gadgets.textedit;

pub const COMMAND_NAME = "SystemScan";
const VERSION = "1.0";
const VERSION_STRING = "\x00$VER: " ++ COMMAND_NAME ++ " " ++ VERSION ++ " (13.11.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;
const SCREEN_TITLE = COMMAND_NAME ++ " " ++ VERSION;

const template = "TO";
const arg_to = 0;

const MSG_NOLIBRARY = "%s: can't open %s\n";
const MSG_NOMEMORY = "%s: no memory\n";
const MSG_NOWINDOW = "%s: no window\n";

/// The gadgets.
const ID_DRAWER = 1;
const ID_SAVE = 2;
const ID_SCAN = 3;

/// Where the report is written before it is shown.
const report_path = "T:SystemScan.txt";
/// The drawers the field starts at: on the boot partition of the medium
/// the machine was started from, where that is a volume, else on the
/// system's own.
const medium_drawer = "POWEROS:Scans";
const medium_volume = "POWEROS:";
const system_drawer = "SYS:Scans";

/// The most of a report that is read back and shown.
const report_most: i64 = 4 << 20;
/// How many rows of the screen's font the report's field shows at least.
const rows_shown = 24;
const path_max = 256;
/// How many of dos's ticks a second is.
const ticks_per_second = 50;

/// A listing in the report: its heading, and the command whose output
/// it is.
const Section = struct { title: [*:0]const u8, command: [*:0]const u8 };

/// The listings, in the report's order: what the machine is first, what
/// is in it next, what the system made of it after that, and the long
/// ones last.
const sections = [_]Section{
    .{ .title = "The system", .command = "C:Version" },
    .{ .title = "The machine", .command = "C:Platform" },
    .{ .title = "The board and its parts", .command = "C:ShowConfig" },
    .{ .title = "The devices, by what they speak", .command = "C:ShowConfig DEVICES" },
    .{ .title = "Memory", .command = "C:Avail" },
    .{ .title = "PCI functions", .command = "C:PCIInfo" },
    .{ .title = "PCI functions, below their bridges", .command = "C:PCIInfo TREE" },
    .{ .title = "USB", .command = "C:USBInfo" },
    .{ .title = "USB, in full", .command = "C:USBInfo FULL" },
    .{ .title = "Displays", .command = "C:Rtg FULL" },
    .{ .title = "Sound outputs", .command = "C:Audio LIST" },
    .{ .title = "Network", .command = "C:net/NetStatus INTERFACES" },
    .{ .title = "Drives and volumes", .command = "C:Info" },
    .{ .title = "The system log", .command = "C:Log LINES 400" },
    .{ .title = "PCI functions, in full", .command = "C:PCIInfo FULL" },
    .{ .title = "PCI functions, their configuration space", .command = "C:PCIInfo HEX" },
};

/// A kind of PCI function a machine needs a driver for, by the first
/// byte of its class code, in the order the report lists them.
const Kind = struct { base: u8, name: [*:0]const u8 };

const kinds = [_]Kind{
    .{ .base = 0x02, .name = "Network controllers" },
    .{ .base = 0x03, .name = "Display controllers" },
    .{ .base = 0x04, .name = "Sound and video" },
    .{ .base = 0x01, .name = "Storage controllers" },
    .{ .base = 0x0C, .name = "USB and other serial buses" },
    .{ .base = 0x0D, .name = "Wireless controllers" },
    .{ .base = 0x07, .name = "Serial ports and other lines" },
    .{ .base = 0x09, .name = "Input devices" },
};

/// The class codes whose functions nothing drives and nothing needs to:
/// bridges, and what is part of the chipset - memory controllers, the
/// system's own peripherals, processors.
fn chipsetPart(base: u8) bool {
    return switch (base) {
        0x05, 0x06, 0x08, 0x0B => true,
        else => false,
    };
}

fn listed(base: u8) bool {
    for (kinds) |kind| if (kind.base == base) return true;
    return false;
}

fn pair(tag: utility.Tag, data: usize) TagItem {
    return .{ .tag = tag, .data = data };
}

/// A line under the field: what the window last did.
const Line = struct {
    text: [path_max + 64:0]u8 = @splat(0),
    length: usize = 0,

    fn ptr(line: *const Line) [*:0]const u8 {
        return @ptrCast(&line.text);
    }

    fn say(line: *Line, sys: *ExecBase, comptime format: [:0]const u8, args: anytype) void {
        comptime exec.checkFormat(format, @TypeOf(args));
        line.text = @splat(0);
        line.length = 0;
        const stream = exec.fmtStream(args);
        _ = sys.RawDoFmt(format, &stream, &putChar, line);
    }

    fn putChar(char: u8, data: ?*anyopaque) callconv(.c) void {
        const line: *Line = @ptrCast(@alignCast(data.?));
        if (char == 0 or line.length >= line.text.len) return;
        line.text[line.length] = char;
        line.length += 1;
    }
};

const App = struct {
    sys: *ExecBase,
    dl: *DosBase,
    ib: *IntuitionBase,
    ub: *UtilityBase,

    object: ?*Object = null,
    window: ?*intuition.Window = null,
    drawer_field: ?*Object = null,
    status_gadget: ?*Object = null,
    report_field: ?*Object = null,

    /// The drawer the field starts at.
    drawer: [path_max:0]u8 = @splat(0),
    status: Line = .{},
    /// The report as it was read back, and how much of it there is.
    report: ?[*]u8 = null,
    report_length: usize = 0,

    fn set(app: *App, object: ?*Object, tags: []const TagItem) void {
        _ = app.ib.SetGadgetAttrsTagList(object orelse return, app.window, tags.ptr);
    }

    fn showStatus(app: *App) void {
        app.set(app.status_gadget, &.{ pair(tx.TEXT_Text, @intFromPtr(app.status.ptr())), .{} });
    }

    /// What the field holds now, or an empty text.
    fn fieldText(app: *App) [*:0]const u8 {
        var at: usize = 0;
        _ = app.ib.GetAttr(gf.GETFILE_FullFile, app.drawer_field orelse return "", &at);
        if (at == 0) return "";
        return @ptrFromInt(at);
    }

    /// The machine looked at, the report written, read back and shown.
    fn scan(app: *App) void {
        const sys = app.sys;
        app.status.say(sys, "Looking at the machine ...", .{});
        app.showStatus();
        if (app.report) |old| sys.FreeVec(old);
        app.report = null;
        app.report_length = 0;
        if (!write(app)) {
            app.status.say(sys, "The report could not be written to %s.", .{@as([*:0]const u8, report_path)});
            app.showStatus();
            return;
        }
        app.read();
        app.set(app.report_field, &.{
            pair(te.TEXTEDIT_Text, @intFromPtr(app.report orelse @as([*]const u8, ""))),
            pair(te.TEXTEDIT_TextLength, app.report_length),
            .{},
        });
        app.status.say(sys, "%d bytes. Save writes them into the drawer above.", .{@as(u32, @intCast(app.report_length))});
        app.showStatus();
    }

    /// The report read back from where it was written.
    fn read(app: *App) void {
        const dl = app.dl;
        const file = dl.Open(report_path, dos.MODE_OLDFILE) orelse return;
        defer _ = dl.Close(file);
        const end = dl.Seek(file, 0, dos.OFFSET_END);
        const size = dl.Seek(file, 0, dos.OFFSET_BEGINNING);
        _ = end;
        if (size <= 0) return;
        const wanted: usize = @intCast(@min(size, report_most));
        const memory: [*]u8 = @ptrCast(app.sys.AllocVec(wanted, exec.MEMF_ANY) orelse return);
        const got = dl.Read(file, memory, @intCast(wanted));
        if (got <= 0) {
            app.sys.FreeVec(memory);
            return;
        }
        app.report = memory;
        app.report_length = @intCast(got);
    }

    /// The report written into the drawer the field names, under a name
    /// made of the machine's date and time.
    fn save(app: *App) void {
        const sys = app.sys;
        const dl = app.dl;
        const text = app.report orelse {
            app.status.say(sys, "There is no report to save: Scan makes one.", .{});
            return app.showStatus();
        };
        const drawer = app.fieldText();
        var length: usize = 0;
        while (drawer[length] != 0) length += 1;
        if (length == 0 or length > path_max - 32) {
            app.status.say(sys, "Name a drawer to save the report in.", .{});
            return app.showStatus();
        }
        if (!dl.CreateDirs(drawer, true)) {
            var why: [80:0]u8 = @splat(0);
            _ = dl.Fault(dl.IoErr(), null, &why, why.len);
            app.status.say(sys, "%s: %s", .{ drawer, @as([*:0]const u8, @ptrCast(&why)) });
            return app.showStatus();
        }
        var stamp: dos.DateStamp = .{};
        _ = dl.DateStamp(&stamp);
        const seconds: u32 = @intCast(@as(i64, stamp.days) * 86400 + @as(i64, stamp.minute) * 60 + @divTrunc(stamp.tick, ticks_per_second));
        var clock: utility.ClockData = .{};
        app.ub.Amiga2Date(seconds, &clock);
        var name: Line = .{};
        const last = drawer[length - 1];
        name.say(sys, "%s%sscan-%04d%02d%02d-%02d%02d%02d.txt", .{
            drawer,               @as([*:0]const u8, if (last == ':' or last == '/') "" else "/"),
            @as(u32, clock.year), @as(u32, clock.month),
            @as(u32, clock.mday), @as(u32, clock.hour),
            @as(u32, clock.min),  @as(u32, clock.sec),
        });
        const file = dl.Open(name.ptr(), dos.MODE_NEWFILE) orelse {
            var why: [80:0]u8 = @splat(0);
            _ = dl.Fault(dl.IoErr(), null, &why, why.len);
            app.status.say(sys, "%s: %s", .{ name.ptr(), @as([*:0]const u8, @ptrCast(&why)) });
            return app.showStatus();
        };
        const wrote = dl.Write(file, text, @intCast(app.report_length));
        const closed = dl.Close(file);
        if (wrote != @as(isize, @intCast(app.report_length)) or !closed) {
            app.status.say(sys, "%s could not be written whole.", .{name.ptr()});
        } else {
            app.status.say(sys, "Saved as %s.", .{name.ptr()});
        }
        app.showStatus();
    }
};

/// The whole report written to `report_path`; false when the file could
/// not be made.
fn write(app: *App) bool {
    const dl = app.dl;
    const file = dl.Open(report_path, dos.MODE_NEWFILE) orelse return false;
    defer _ = dl.Close(file);
    var stamp: dos.DateStamp = .{};
    _ = dl.DateStamp(&stamp);
    const seconds: u32 = @intCast(@as(i64, stamp.days) * 86400 + @as(i64, stamp.minute) * 60 + @divTrunc(stamp.tick, ticks_per_second));
    var clock: utility.ClockData = .{};
    app.ub.Amiga2Date(seconds, &clock);
    _ = FPrintf(dl, file, "%s %s: what this machine is made of, on %02d.%02d.%04d at %02d:%02d by its clock.\n", .{
        @as([*:0]const u8, COMMAND_NAME), @as([*:0]const u8, VERSION),
        @as(u32, clock.mday),             @as(u32, clock.month),
        @as(u32, clock.year),             @as(u32, clock.hour),
        @as(u32, clock.min),
    });
    writeUndriven(app, file);
    // A command reads nothing: its input is the empty device.
    const nothing = dl.Open("NIL:", dos.MODE_OLDFILE);
    defer if (nothing) |handle| {
        _ = dl.Close(handle);
    };
    for (sections) |section| {
        _ = FPrintf(dl, file, "\n==== %s (%s) ====\n\n", .{ section.title, section.command });
        _ = dl.Flush(file);
        _ = dl.SystemTagList(section.command, &[_]TagItem{
            pair(dos.SYS_Input, @intFromPtr(nothing)),
            pair(dos.SYS_Output, @intFromPtr(file)),
            .{},
        });
    }
    return true;
}

/// The report's own part: the PCI functions no driver has claimed, by
/// kind, the kinds a machine needs drivers for first.
fn writeUndriven(app: *App, file: *dos.FileHandle) void {
    const dl = app.dl;
    const sys = app.sys;
    _ = dl.FPuts(file, "\n==== PCI functions no driver has claimed ====\n\n");
    const pci_lib = sys.OpenLibrary(pci.PCINAME, 2) orelse {
        _ = dl.FPuts(file, "This machine has no pci.library: nothing here is found on PCI.\n");
        return;
    };
    defer sys.CloseLibrary(pci_lib);
    const pb: *PCIBase = @ptrCast(pci_lib);
    var total: u32 = 0;
    var undriven: u32 = 0;
    var it = pb.FindPCIDevice(null, pci.PCI_ANY, pci.PCI_ANY);
    while (it) |function| : (it = pb.FindPCIDevice(function, pci.PCI_ANY, pci.PCI_ANY)) {
        total += 1;
        if (function.owner == null and !chipsetPart(baseOf(function))) undriven += 1;
    }
    _ = FPrintf(dl, file, "%d functions on PCI, %d of them with no driver (bridges and the chipset's own parts not counted).\n", .{ total, undriven });
    for (kinds) |kind| {
        var first = true;
        it = pb.FindPCIDevice(null, pci.PCI_ANY, pci.PCI_ANY);
        while (it) |function| : (it = pb.FindPCIDevice(function, pci.PCI_ANY, pci.PCI_ANY)) {
            if (function.owner != null or baseOf(function) != kind.base) continue;
            if (first) _ = FPrintf(dl, file, "\n%s:\n", .{kind.name});
            first = false;
            writeFunction(dl, file, function);
        }
    }
    var first = true;
    it = pb.FindPCIDevice(null, pci.PCI_ANY, pci.PCI_ANY);
    while (it) |function| : (it = pb.FindPCIDevice(function, pci.PCI_ANY, pci.PCI_ANY)) {
        const base = baseOf(function);
        if (function.owner != null or listed(base) or chipsetPart(base)) continue;
        if (first) _ = dl.FPuts(file, "\nOther functions:\n");
        first = false;
        writeFunction(dl, file, function);
    }
    _ = dl.FPuts(file, "\nWith a driver:\n");
    it = pb.FindPCIDevice(null, pci.PCI_ANY, pci.PCI_ANY);
    while (it) |function| : (it = pb.FindPCIDevice(function, pci.PCI_ANY, pci.PCI_ANY)) {
        const owner = function.owner orelse continue;
        _ = FPrintf(dl, file, "  %04x:%02x:%02x.%d  %04x:%04x  class %06x  %s\n", .{
            @as(u32, function.segment),   @as(u32, function.bus),       @as(u32, function.device), @as(u32, function.function),
            @as(u32, function.vendor_id), @as(u32, function.device_id), function.class_code,       owner,
        });
    }
}

/// The first byte of a function's class code: what kind of thing it is.
fn baseOf(function: *const pci.PCIDevice) u8 {
    return @truncate(function.class_code >> 16);
}

/// A function with no driver: where it is, its IDs, its class code, its
/// revision and whose board it is on.
fn writeFunction(dl: *DosBase, file: *dos.FileHandle, function: *const pci.PCIDevice) void {
    _ = FPrintf(dl, file, "  %04x:%02x:%02x.%d  %04x:%04x  class %06x  rev %02x", .{
        @as(u32, function.segment),   @as(u32, function.bus),       @as(u32, function.device), @as(u32, function.function),
        @as(u32, function.vendor_id), @as(u32, function.device_id), function.class_code,       @as(u32, function.revision),
    });
    _ = FPrintf(dl, file, "  subsystem %04x:%04x\n", .{ @as(u32, function.subsystem_vendor), @as(u32, function.subsystem_id) });
}

fn button(ib: *IntuitionBase, text: [*:0]const u8, id: usize) ?*Object {
    return ib.NewObjectTagList(null, classusr.FRBUTTONCLASS, &[_]TagItem{
        pair(gc.GA_Text, @intFromPtr(text)),
        pair(gc.GA_ID, id),
        pair(gc.GA_RelVerify, 1),
        .{},
    });
}

/// The window's whole layout, or null when something could not be made.
fn buildLayout(app: *App) ?*Object {
    const ib = app.ib;
    app.drawer_field = ib.NewObjectTagList(null, gf.GETFILE_CLASS, &[_]TagItem{
        pair(gc.GA_ID, ID_DRAWER),
        pair(gc.GA_RelVerify, 1),
        pair(gc.GA_TabCycle, 1),
        pair(gf.GETFILE_TitleText, @intFromPtr("Which drawer is the report saved in?")),
        pair(gf.GETFILE_DrawersOnly, 1),
        pair(gf.GETFILE_Drawer, @intFromPtr(@as([*:0]const u8, @ptrCast(&app.drawer)))),
        .{},
    });
    const save_button = button(ib, "_Save", ID_SAVE);
    const scan_button = button(ib, "S_can", ID_SCAN);
    app.status_gadget = ib.NewObjectTagList(null, tx.TEXT_CLASS, &[_]TagItem{
        pair(tx.TEXT_Text, @intFromPtr(app.status.ptr())),
        pair(tx.TEXT_Scroll, 1),
        pair(gc.GA_Width, 720),
        .{},
    });
    app.report_field = ib.NewObjectTagList(null, te.TEXTEDIT_CLASS, &[_]TagItem{
        pair(te.TEXTEDIT_ReadOnly, 1),
        pair(te.TEXTEDIT_Scrollers, 1),
        .{},
    });
    const top = ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
        pair(lg.LAYOUTA_Orientation, lg.LORIENT_HORIZ),
        pair(lg.LAYOUTA_Spacing, 6),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(app.drawer_field orelse return null)),
        pair(lg.CHILDA_Label, @intFromPtr("Save _in")),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(save_button orelse return null)),
        pair(lg.CHILDA_WeightWidth, 0),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(scan_button orelse return null)),
        pair(lg.CHILDA_WeightWidth, 0),
        .{},
    }) orelse return null;
    return ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
        pair(lg.LAYOUTA_Orientation, lg.LORIENT_VERT),
        pair(lg.LAYOUTA_Margin, 6),
        pair(lg.LAYOUTA_Spacing, 6),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(top)),
        pair(lg.CHILDA_WeightHeight, 0),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(app.status_gadget orelse return null)),
        pair(lg.CHILDA_WeightHeight, 0),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(app.report_field orelse return null)),
        pair(lg.CHILDA_MinHeight, rows_shown * fontHeight(app)),
        .{},
    });
}

/// How tall a row of the screen's font is, which the report's least
/// height is measured in.
fn fontHeight(app: *App) usize {
    const screen = app.ib.LockPubScreen(null) orelse return 16;
    defer app.ib.UnlockPubScreen(null, screen);
    const info = app.ib.GetScreenDrawInfo(screen);
    defer app.ib.FreeScreenDrawInfo(screen, info);
    const font = info.font orelse return 16;
    return font.image.height;
}

/// Whether a volume named as `medium_volume` is in, asked without a
/// requester for it.
fn mediumIn(sys: *ExecBase, dl: *DosBase) bool {
    const process: *dos.Process = @ptrCast(@alignCast(sys.FindTask(null).?));
    const asked = process.window_ptr;
    process.window_ptr = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));
    defer process.window_ptr = asked;
    const lock = dl.Lock(medium_volume, dos.SHARED_LOCK) orelse return false;
    dl.UnLock(lock);
    return true;
}

fn copyText(into: *[path_max:0]u8, text: [*:0]const u8) void {
    var at: usize = 0;
    while (at < path_max and text[at] != 0) : (at += 1) into[at] = text[at];
    into[at] = 0;
}

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(dos_lib);
    const dl: *DosBase = @ptrCast(dos_lib);

    var argv: [1]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);

    var libraries: [5]?*exec.Library = @splat(null);
    defer for (libraries) |lib| sys.CloseLibrary(lib);
    const wanted = [_][*:0]const u8{
        intuition.INTUITIONNAME, utility.UTILITYNAME, gf.GETFILE_LIBRARY, tx.TEXT_LIBRARY, te.TEXTEDIT_LIBRARY,
    };
    for (wanted, 0..) |name, index| {
        libraries[index] = sys.OpenLibrary(name, 0) orelse {
            _ = Printf(dl, MSG_NOLIBRARY, .{ COMMAND_NAME, name });
            return dos.RETURN_FAIL;
        };
    }
    const ib: *IntuitionBase = @ptrCast(libraries[0].?);
    const ub: *UtilityBase = @ptrCast(libraries[1].?);

    const memory = sys.AllocVec(@sizeOf(App), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse {
        _ = Printf(dl, MSG_NOMEMORY, .{COMMAND_NAME});
        return dos.RETURN_FAIL;
    };
    defer sys.FreeVec(memory);
    const app: *App = @ptrCast(@alignCast(memory));
    app.* = .{ .sys = sys, .dl = dl, .ib = ib, .ub = ub };
    defer if (app.report) |report| sys.FreeVec(report);

    if (rdargs.string(argv[arg_to])) |to| {
        copyText(&app.drawer, to);
    } else {
        copyText(&app.drawer, if (mediumIn(sys, dl)) medium_drawer else system_drawer);
    }

    const layout = buildLayout(app) orelse {
        _ = Printf(dl, MSG_NOMEMORY, .{COMMAND_NAME});
        return dos.RETURN_FAIL;
    };
    app.object = ib.NewObjectTagList(null, classusr.WINDOWCLASS, &[_]TagItem{
        pair(wn.WA_Title, @intFromPtr("SystemScan")),
        pair(wn.WA_ScreenTitle, @intFromPtr(SCREEN_TITLE)),
        pair(wn.WA_CloseGadget, 1),
        pair(wn.WA_DragBar, 1),
        pair(wn.WA_DepthGadget, 1),
        pair(wn.WA_SizeGadget, 1),
        pair(wn.WA_Activate, 1),
        pair(wc.WINDOWA_Layout, @intFromPtr(layout)),
        .{},
    }) orelse {
        ib.DisposeObject(layout);
        _ = Printf(dl, MSG_NOMEMORY, .{COMMAND_NAME});
        return dos.RETURN_FAIL;
    };
    defer ib.DisposeObject(app.object);
    var open = wc.WmOpen{};
    if (ib.SendMessage(app.object.?, @ptrCast(&open)) == 0) {
        _ = Printf(dl, MSG_NOWINDOW, .{COMMAND_NAME});
        return dos.RETURN_FAIL;
    }
    var at: usize = 0;
    _ = ib.GetAttr(wc.WINDOWA_Window, app.object.?, &at);
    app.window = @ptrFromInt(at);

    app.scan();

    var code_word: u32 = 0;
    var handle = wc.WmHandleInput{ .code = &code_word };
    while (true) {
        var mask: usize = 0;
        _ = ib.GetAttr(wc.WINDOWA_SigMask, app.object.?, &mask);
        const got = sys.Wait(@as(u32, @intCast(mask)) | exec.SIGBREAKF_CTRL_C);
        if (got & exec.SIGBREAKF_CTRL_C != 0) return dos.RETURN_OK;
        while (true) {
            const word = ib.SendMessage(app.object.?, @ptrCast(&handle));
            if (word == wc.WMHI_LASTMSG) break;
            switch (word & wc.WMHI_CLASSMASK) {
                wc.WMHI_CLOSEWINDOW => return dos.RETURN_OK,
                wc.WMHI_GADGETUP => switch (word & wc.WMHI_GADGETMASK) {
                    ID_SAVE => app.save(),
                    ID_SCAN => app.scan(),
                    else => {},
                },
                else => {},
            }
        }
    }
}
