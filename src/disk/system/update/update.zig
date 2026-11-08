// SPDX-License-Identifier: MIT
//! Update: this system brought up to a newer release package, in a
//! window. Built against the SDK only.
//!
//!   Update FROM
//!
//! FROM is the package to look at - a directory, or an address a server
//! answers. Without it the window looks where `ENVARC:Sys/update.prefs`
//! says, else where the system was installed from, and shows which one
//! that was in the field at the top.
//!
//! **A check as the window opens.** The package's list is held against
//! the one this machine was given, and every path something would happen
//! to is a row: what would happen to it, the path, and how much would be
//! written. The line under the switches says what it comes to. Check
//! looks again - at what the field names, so another package is typed in
//! and checked - and so does a switch changed:
//!
//! - **With the kernel** writes the files the firmware reads as well,
//!   into the partition it reads them from; it starts as BOOT in
//!   `update.prefs` has it.
//! - **Replace changed files** writes the package's own over a file that
//!   was changed on this machine, where the package changed it too.
//!
//! **Update** writes what the check found, the gauge filling by the bytes
//! written; **Stop** ends it between two files, with what was written in
//! place and this machine's list as it was, so the next check finds the
//! rest.
//!
//! The work is done on a process of its own (`worker.zig`), through
//! update.library, so the window keeps answering while a package is read
//! over the network.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const update = sdk.update;
const prefs = sdk.prefs;
const intuition = sdk.intuition;
const graphics = sdk.graphics;
const worker = @import("worker.zig");
const Job = worker.Job;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const GraphicsBase = sdk.interface.graphics.GraphicsBase;
const UtilityBase = sdk.interface.utility.UtilityBase;
const TagItem = sdk.utility.TagItem;
const Object = intuition.Object;
const rdargs = dos.rdargs;
const Printf = dos.stdio.Printf;
const gc = intuition.gadgetclass;
const lg = intuition.layoutgclass;
const wn = intuition.windows;
const wc = intuition.windowclass;
const classusr = intuition.classusr;
const lb = sdk.gadgets.listbrowser;
const st = sdk.gadgets.string;
const tx = sdk.gadgets.text;
const cb_class = sdk.gadgets.checkbox;
const fg = sdk.gadgets.fuelgauge;

pub const COMMAND_NAME = "Update";
const VERSION = "1.0";
const VERSION_STRING = "\x00$VER: " ++ COMMAND_NAME ++ " " ++ VERSION ++ " (08.11.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;
const SCREEN_TITLE = COMMAND_NAME ++ " " ++ VERSION;

const template = "FROM";
const arg_from = 0;
const arg_count = 1;

const MSG_NOLIBRARY = "%s: can't open %s\n";
const MSG_NOMEMORY = "%s: no memory\n";
const MSG_NOWINDOW = "%s: no window\n";

/// The gadgets.
const ID_SOURCE = 1;
const ID_CHECK = 2;
const ID_BOOT = 3;
const ID_FORCE = 4;
const ID_LIST = 5;
const ID_UPDATE = 6;
const ID_STOP = 7;

/// A field says which key ended it, as the raw key it was: Return and the
/// keypad's Enter check, where Tab and a press elsewhere only leave it.
const raw_return: u32 = 0x44;
const raw_enter: u32 = 0x43;

fn entered(code: u32) bool {
    return code == raw_return or code == raw_enter;
}

/// How many rows the list shows without the window being made taller.
const rows_shown = 10;

/// The gauge counts KiB, which a whole system's worth fits in, and goes
/// up to the most its level holds.
const gauge_unit = 1024;
const gauge_most: u64 = 0x7FFF_FFFF;

const columns = [_]lb.Column{
    .{ .title = "What", .weight = 1 },
    .{ .title = "Path", .weight = 6 },
    .{ .title = "Size", .weight = 1, .flags = lb.COLUMN_RIGHT },
    .{},
};

fn pair(tag: sdk.utility.Tag, data: usize) TagItem {
    return .{ .tag = tag, .data = data };
}

/// A line a text gadget shows, which it points at rather than copies: it
/// stays where it is and is only ever written over.
const Line = struct {
    text: [worker.line_max:0]u8 = @splat(0),
    length: usize = 0,

    fn ptr(line: *const Line) [*:0]const u8 {
        return @ptrCast(&line.text);
    }

    /// The line set to `format` with `args`, whatever it said before.
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
    gb: *GraphicsBase,

    object: ?*Object = null,
    window: ?*intuition.Window = null,

    source_field: ?*Object = null,
    check_button: ?*Object = null,
    boot_box: ?*Object = null,
    force_box: ?*Object = null,
    status_gadget: ?*Object = null,
    note_gadget: ?*Object = null,
    list: ?*Object = null,
    gauge: ?*Object = null,
    update_button: ?*Object = null,
    stop_button: ?*Object = null,

    /// What the list shows: the rows of the last run.
    rows: exec.List = .{},
    /// What the run came to, and what to do about it.
    status: Line = .{},
    note: Line = .{},
    /// The field's text, kept for it.
    source: [worker.source_max:0]u8 = @splat(0),

    /// The run on its process, and what it said last.
    job: Job = undefined,
    heard_line: [worker.line_max:0]u8 = @splat(0),
    wrote_bytes: u64 = 0,
    wrote_files: u32 = 0,
    /// Stop pressed for the run going.
    stop_asked: bool = false,
    /// The last check's bytes to write, which the gauge goes up to, and
    /// whether it found anything to do.
    to_write: u64 = 0,
    work_found: bool = false,

    // --- the gadgets ---------------------------------------------------------------

    fn set(app: *App, object: ?*Object, tags: []const TagItem) void {
        _ = app.ib.SetGadgetAttrsTagList(object orelse return, app.window, tags.ptr);
    }

    fn enable(app: *App, object: ?*Object, on: bool) void {
        app.set(object, &.{ pair(gc.GA_Disabled, @intFromBool(!on)), .{} });
    }

    fn checked(app: *App, object: ?*Object) bool {
        var value: usize = 0;
        _ = app.ib.GetAttr(cb_class.CHECKBOX_Checked, object orelse return false, &value);
        return value != 0;
    }

    /// What the field holds now, or an empty text.
    fn fieldText(app: *App) [*:0]const u8 {
        var at: usize = 0;
        _ = app.ib.GetAttr(gc.STRINGA_TextVal, app.source_field orelse return "", &at);
        if (at == 0) return "";
        return @ptrFromInt(at);
    }

    fn showStatus(app: *App) void {
        app.set(app.status_gadget, &.{ pair(tx.TEXT_Text, @intFromPtr(app.status.ptr())), .{} });
        app.set(app.note_gadget, &.{ pair(tx.TEXT_Text, @intFromPtr(app.note.ptr())), .{} });
    }

    /// The buttons and switches as the run allows: nothing that starts a
    /// run while one goes, Stop only then, Update once a check found work.
    fn showButtons(app: *App) void {
        const going = app.job.running();
        app.enable(app.source_field, !going);
        app.enable(app.check_button, !going);
        app.enable(app.boot_box, !going);
        app.enable(app.force_box, !going);
        app.enable(app.update_button, !going and app.work_found);
        app.enable(app.stop_button, going);
    }

    fn showGauge(app: *App, level: u64, most: u64) void {
        const top: u64 = @max(1, (most + gauge_unit - 1) / gauge_unit);
        const max: u64 = @min(top, gauge_most);
        const done: u64 = if (most != 0 and level >= most) max else @min(level / gauge_unit, max);
        app.set(app.gauge, &.{
            pair(fg.GAUGE_Max, @intCast(max)),
            pair(fg.GAUGE_Level, @intCast(done)),
            .{},
        });
    }

    // --- a run ---------------------------------------------------------------------

    /// A run started: a check of what the field names, or the update the
    /// last check found.
    fn begin(app: *App, kind: worker.Kind) void {
        if (app.job.running()) return;
        const job = &app.job;
        job.kind = kind;
        if (kind == .check) {
            worker.copyText(&job.source, app.fieldText());
            job.boot = app.checked(app.boot_box);
            job.force = app.checked(app.force_box);
            app.work_found = false;
        }
        app.set(app.list, &.{ pair(lb.LISTBROWSER_Rows, lb.LISTBROWSER_DETACH), .{} });
        lb.freeRows(app.sys, &app.rows);
        app.set(app.list, &.{ pair(lb.LISTBROWSER_Rows, @intFromPtr(&app.rows)), .{} });
        app.stop_asked = false;
        app.wrote_bytes = 0;
        app.wrote_files = 0;
        app.showGauge(0, if (kind == .update) app.to_write else 0);
        if (!job.start()) {
            app.status.say(app.sys, "no process to run the update on", .{});
            app.note.say(app.sys, "", .{});
        } else {
            app.status.say(app.sys, "%s", .{@as([*:0]const u8, if (kind == .check) "Looking at the package ..." else "Updating ...")});
            app.note.say(app.sys, "", .{});
        }
        app.showStatus();
        app.showButtons();
    }

    /// What the run has said since the last look: its rows added to the
    /// list, the last line on the status line, the gauge moved on.
    fn heard(app: *App) void {
        var fresh: exec.List = .{};
        fresh.init(.unknown);
        app.job.take(&fresh, &app.heard_line, &app.wrote_bytes, &app.wrote_files);
        if (fresh.first() != null) {
            app.set(app.list, &.{ pair(lb.LISTBROWSER_Rows, lb.LISTBROWSER_DETACH), .{} });
            var count: usize = 0;
            while (app.sys.RemHead(&fresh)) |node| app.sys.AddTail(&app.rows, node);
            var node = app.rows.first();
            while (node) |it| : (node = it.next()) count += 1;
            app.set(app.list, &.{ pair(lb.LISTBROWSER_Rows, @intFromPtr(&app.rows)), .{} });
            // The newest row in sight.
            var visible: usize = 0;
            _ = app.ib.GetAttr(lb.LISTBROWSER_Visible, app.list.?, &visible);
            if (count > visible) app.set(app.list, &.{ pair(lb.LISTBROWSER_Top, count - visible), .{} });
        }
        if (app.heard_line[0] != 0) {
            app.status.say(app.sys, "%s", .{@as([*:0]const u8, @ptrCast(&app.heard_line))});
            app.set(app.status_gadget, &.{ pair(tx.TEXT_Text, @intFromPtr(app.status.ptr())), .{} });
        }
        if (app.job.kind == .update) app.showGauge(app.wrote_bytes, app.to_write);
    }

    /// The run has ended: what it came to on the status line, what to do
    /// about it under it.
    fn ended(app: *App) void {
        app.heard();
        const job = &app.job;
        const info = &job.info;
        const sys = app.sys;
        app.note.say(sys, "", .{});
        // The field shows the package that was read, where it was empty.
        if (app.fieldText()[0] == 0 and job.used[0] != 0) {
            worker.copyText(&app.source, @ptrCast(&job.used));
            app.set(app.source_field, &.{ pair(gc.STRINGA_TextVal, @intFromPtr(@as([*:0]const u8, @ptrCast(&app.source)))), .{} });
        }

        if (app.stop_asked and job.code != dos.RETURN_OK) {
            // Between two files or in the middle of one: what was put in
            // place is what the run said it wrote.
            if (job.kind == .update) {
                var size: [16:0]u8 = @splat(0);
                update.bytesAsText(&size, app.wrote_bytes);
                app.status.say(sys, "Stopped: %d files written (%s).", .{ app.wrote_files, @as([*:0]const u8, @ptrCast(&size)) });
                app.note.say(sys, "What was written stays; Check says what is left.", .{});
            } else {
                app.status.say(sys, "Stopped.", .{});
            }
            app.work_found = false;
        } else if (job.code == dos.RETURN_FAIL) {
            if (app.heard_line[0] == 0) app.status.say(sys, "The update could not finish.", .{});
            if (job.kind == .update) app.note.say(sys, "What was written stays; Check says what is left.", .{});
            app.work_found = false;
        } else if (!update.changes(info) and info.kept == 0 and info.boot_written == 0) {
            app.status.say(sys, "Nothing to do: this system is what that package holds.", .{});
            if (!job.boot and info.boot != 0) {
                app.note.say(sys, "The %d files the firmware reads are in the package too: With the kernel looks at them.", .{info.boot});
            }
            app.work_found = false;
        } else {
            const checking = job.kind == .check;
            var size: [16:0]u8 = @splat(0);
            update.bytesAsText(&size, info.written_bytes);
            app.status.say(sys, "%s: %d written (%s), %d deleted, %d kept as they are, %d drawers made.", .{
                @as([*:0]const u8, if (checking) "Would be" else "Done"),
                info.written,
                @as([*:0]const u8, @ptrCast(&size)),
                info.deleted,
                info.kept,
                info.made,
            });
            if (job.boot and info.boot_written != 0) {
                app.note.say(sys, "%d of the files the firmware reads %s.", .{
                    info.boot_written, @as([*:0]const u8, if (checking) "would be written" else "were written"),
                });
            } else if (info.kept != 0 and !job.force) {
                app.note.say(sys, "What is kept was changed on this machine; Replace changed files takes the package's own.", .{});
            } else if (!job.boot and info.boot != 0) {
                app.note.say(sys, "The %d files the firmware reads are in the package too: With the kernel writes them.", .{info.boot});
            }
            if (checking) {
                app.work_found = update.changes(info) or info.boot_written != 0;
                app.to_write = info.written_bytes;
            } else {
                app.work_found = false;
                app.showGauge(app.to_write, app.to_write);
                if (info.tried != 0) {
                    app.note.say(sys, "The new kernel is tried once at the next start: restart with C:Reboot TRYBOOT, then keep it with Update CONFIRM.", .{});
                } else if (update.changes(info) or info.boot_written != 0) {
                    app.note.say(sys, "Restart to run what was written.", .{});
                }
            }
        }
        app.showStatus();
        app.showButtons();
    }
};

fn button(ib: *IntuitionBase, text: [*:0]const u8, id: usize) ?*Object {
    return ib.NewObjectTagList(null, classusr.FRBUTTONCLASS, &[_]TagItem{
        pair(gc.GA_Text, @intFromPtr(text)),
        pair(gc.GA_ID, id),
        pair(gc.GA_RelVerify, 1),
        .{},
    });
}

/// A line of the status: one too wide for the window goes along inside
/// it, so a long reason is read whole.
fn textLine(ib: *IntuitionBase, text: [*:0]const u8) ?*Object {
    return ib.NewObjectTagList(null, tx.TEXT_CLASS, &[_]TagItem{
        pair(tx.TEXT_Text, @intFromPtr(text)),
        pair(tx.TEXT_Scroll, 1),
        pair(gc.GA_Width, 640),
        .{},
    });
}

/// The window's whole layout, or null when something could not be made.
fn buildLayout(app: *App, boot: bool) ?*Object {
    const ib = app.ib;
    app.source_field = ib.NewObjectTagList(null, st.STRING_CLASS, &[_]TagItem{
        pair(gc.GA_ID, ID_SOURCE),
        pair(gc.GA_RelVerify, 1),
        pair(gc.GA_TabCycle, 1),
        pair(gc.STRINGA_MaxChars, worker.source_max),
        pair(gc.STRINGA_TextVal, @intFromPtr(@as([*:0]const u8, @ptrCast(&app.source)))),
        .{},
    });
    app.check_button = button(ib, "Check", ID_CHECK);
    app.boot_box = ib.NewObjectTagList(null, cb_class.CHECKBOX_CLASS, &[_]TagItem{
        pair(gc.GA_ID, ID_BOOT),
        pair(gc.GA_RelVerify, 1),
        pair(cb_class.CHECKBOX_Checked, @intFromBool(boot)),
        .{},
    });
    app.force_box = ib.NewObjectTagList(null, cb_class.CHECKBOX_CLASS, &[_]TagItem{
        pair(gc.GA_ID, ID_FORCE),
        pair(gc.GA_RelVerify, 1),
        .{},
    });
    app.status_gadget = textLine(ib, app.status.ptr());
    app.note_gadget = textLine(ib, app.note.ptr());
    app.list = ib.NewObjectTagList(null, lb.LISTBROWSER_CLASS, &[_]TagItem{
        pair(gc.GA_ID, ID_LIST),
        pair(lb.LISTBROWSER_Columns, @intFromPtr(&columns)),
        pair(lb.LISTBROWSER_Rows, @intFromPtr(&app.rows)),
        .{},
    });
    app.gauge = ib.NewObjectTagList(null, fg.GAUGE_CLASS, &[_]TagItem{
        pair(fg.GAUGE_Level, 0),
        pair(fg.GAUGE_Percent, 1),
        pair(fg.GAUGE_Format, @intFromPtr("%ld%%")),
        .{},
    });
    app.update_button = button(ib, "Update", ID_UPDATE);
    app.stop_button = button(ib, "Stop", ID_STOP);

    const row_height = fontHeight(app);
    const top = ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
        pair(lg.LAYOUTA_Orientation, lg.LORIENT_HORIZ),
        pair(lg.LAYOUTA_Spacing, 6),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(app.source_field orelse return null)),
        pair(lg.CHILDA_Label, @intFromPtr("_Package")),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(app.check_button orelse return null)),
        pair(lg.CHILDA_WeightWidth, 0),
        .{},
    }) orelse return null;
    const switches = ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
        pair(lg.LAYOUTA_Orientation, lg.LORIENT_HORIZ),
        pair(lg.LAYOUTA_Spacing, 12),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(app.boot_box orelse return null)),
        pair(lg.CHILDA_Label, @intFromPtr("With the _kernel")),
        pair(lg.CHILDA_WeightWidth, 0),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(app.force_box orelse return null)),
        pair(lg.CHILDA_Label, @intFromPtr("_Replace changed files")),
        pair(lg.CHILDA_WeightWidth, 0),
        .{},
    }) orelse return null;
    const run_group = ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
        pair(lg.LAYOUTA_Orientation, lg.LORIENT_VERT),
        pair(lg.LAYOUTA_FrameTitle, @intFromPtr("What the update does")),
        pair(lg.LAYOUTA_Margin, 6),
        pair(lg.LAYOUTA_Spacing, 4),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(app.status_gadget orelse return null)),
        pair(lg.CHILDA_WeightHeight, 0),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(app.note_gadget orelse return null)),
        pair(lg.CHILDA_WeightHeight, 0),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(app.list orelse return null)),
        pair(lg.CHILDA_MinHeight, rows_shown * row_height + 24),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(app.gauge orelse return null)),
        pair(lg.CHILDA_WeightHeight, 0),
        .{},
    }) orelse return null;
    const buttons = ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
        pair(lg.LAYOUTA_Orientation, lg.LORIENT_HORIZ),
        pair(lg.LAYOUTA_Spacing, 8),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(app.update_button orelse return null)),
        pair(lg.CHILDA_WeightWidth, 0),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(app.stop_button orelse return null)),
        pair(lg.CHILDA_WeightWidth, 0),
        .{},
    }) orelse return null;
    return ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
        pair(lg.LAYOUTA_Orientation, lg.LORIENT_VERT),
        pair(lg.LAYOUTA_Margin, 6),
        pair(lg.LAYOUTA_Spacing, 6),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(top)),
        pair(lg.CHILDA_WeightHeight, 0),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(switches)),
        pair(lg.CHILDA_WeightHeight, 0),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(run_group)),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(buttons)),
        pair(lg.CHILDA_WeightHeight, 0),
        .{},
    });
}

/// How tall a row of the screen's font is, which the list's least height
/// is measured in.
fn fontHeight(app: *App) usize {
    const screen = app.ib.LockPubScreen(null) orelse return 16;
    defer app.ib.UnlockPubScreen(null, screen);
    const info = app.ib.GetScreenDrawInfo(screen);
    defer app.ib.FreeScreenDrawInfo(screen, info);
    const font = info.font orelse return 16;
    var extent = graphics.FontExtent{};
    app.gb.FontExtent(font, &extent);
    return @max(@as(usize, @intCast(@max(extent.height, 8))), 8);
}

/// Whether `update.prefs` asks for the firmware's files: ENV:'s copy
/// first, then ENVARC:'s. A file that is not a line of settings asks for
/// nothing; the check says what is wrong with it.
fn bootWanted(sys: *ExecBase, dl: *DosBase, ub: *UtilityBase) bool {
    const text = prefs.loadWhole(sys, dl, prefs.update.ENV_FILE) orelse
        prefs.loadWhole(sys, dl, prefs.update.ENVARC_FILE) orelse return false;
    defer sys.FreeVec(@ptrCast(text.ptr));
    var settings: prefs.update.Settings = .{};
    const first = prefs.firstLine(text) orelse return false;
    if (prefs.update.parse(ub, first, &settings) != null) return false;
    return settings.boot;
}

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(dos_lib);
    const dl: *DosBase = @ptrCast(dos_lib);

    var argv: [arg_count]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);

    var libraries: [8]?*exec.Library = @splat(null);
    defer for (libraries) |lib| sys.CloseLibrary(lib);
    const wanted = [_][*:0]const u8{
        intuition.INTUITIONNAME, graphics.GRAPHICSNAME, sdk.utility.UTILITYNAME,   lb.LISTBROWSER_LIBRARY,
        st.STRING_LIBRARY,       tx.TEXT_LIBRARY,       cb_class.CHECKBOX_LIBRARY, fg.GAUGE_LIBRARY,
    };
    for (wanted, 0..) |name, index| {
        libraries[index] = sys.OpenLibrary(name, 0) orelse {
            _ = Printf(dl, MSG_NOLIBRARY, .{ COMMAND_NAME, name });
            return dos.RETURN_FAIL;
        };
    }
    const ib: *IntuitionBase = @ptrCast(libraries[0].?);
    const gb: *GraphicsBase = @ptrCast(libraries[1].?);
    const ub: *UtilityBase = @ptrCast(libraries[2].?);

    const memory = sys.AllocVec(@sizeOf(App), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse {
        _ = Printf(dl, MSG_NOMEMORY, .{COMMAND_NAME});
        return dos.RETURN_FAIL;
    };
    defer sys.FreeVec(memory);
    const app: *App = @ptrCast(@alignCast(memory));
    app.* = .{ .sys = sys, .dl = dl, .ib = ib, .gb = gb };
    app.rows.init(.unknown);
    defer lb.freeRows(sys, &app.rows);
    if (!app.job.init(sys, dl)) {
        _ = Printf(dl, MSG_NOMEMORY, .{COMMAND_NAME});
        return dos.RETURN_FAIL;
    }
    defer app.job.free();

    if (rdargs.string(argv[arg_from])) |from| worker.copyText(&app.source, from);

    const layout = buildLayout(app, bootWanted(sys, dl, ub)) orelse {
        _ = Printf(dl, MSG_NOMEMORY, .{COMMAND_NAME});
        return dos.RETURN_FAIL;
    };
    app.object = ib.NewObjectTagList(null, classusr.WINDOWCLASS, &[_]TagItem{
        pair(wn.WA_Title, @intFromPtr("Update")),
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

    app.begin(.check);

    const news = app.job.signal();
    const ends = app.job.endSignal();
    var code_word: u32 = 0;
    var handle = wc.WmHandleInput{ .code = &code_word };
    while (true) {
        var mask: usize = 0;
        _ = ib.GetAttr(wc.WINDOWA_SigMask, app.object.?, &mask);
        const got = sys.Wait(@as(u32, @intCast(mask)) | news | ends | exec.SIGBREAKF_CTRL_C);
        if (got & exec.SIGBREAKF_CTRL_C != 0) return dos.RETURN_OK;
        if (got & news != 0) app.heard();
        if (got & ends != 0 and app.job.finished()) app.ended();

        while (true) {
            const word = ib.SendMessage(app.object.?, @ptrCast(&handle));
            if (word == wc.WMHI_LASTMSG) break;
            switch (word & wc.WMHI_CLASSMASK) {
                wc.WMHI_CLOSEWINDOW => return dos.RETURN_OK,
                wc.WMHI_GADGETUP => switch (word & wc.WMHI_GADGETMASK) {
                    ID_CHECK, ID_BOOT, ID_FORCE => app.begin(.check),
                    ID_SOURCE => if (entered(code_word)) app.begin(.check),
                    ID_UPDATE => if (app.work_found) app.begin(.update),
                    ID_STOP => if (app.job.running()) {
                        app.stop_asked = true;
                        app.job.stop();
                        app.status.say(sys, "Stopping ...", .{});
                        app.showStatus();
                    },
                    else => {},
                },
                else => {},
            }
        }
    }
}
