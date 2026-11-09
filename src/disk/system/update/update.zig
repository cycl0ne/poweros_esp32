// SPDX-License-Identifier: MIT
//! Update: this system brought up to a newer release package, in a
//! window. Built against the SDK only.
//!
//!   Update FROM
//!
//! FROM is the package to look at - a directory, or an address a server
//! answers. Without it the window looks where `ENVARC:Sys/update.prefs`
//! says, else where the system was installed from, and shows which one
//! that was in the field at the top. The field's button asks for a
//! drawer (asl.library's requester, through getfile.gadget); an address
//! is typed in.
//!
//! **A check as the window opens.** The package's list is held against
//! the one this machine was given, and every path something would happen
//! to is a row: what would happen to it, the path, and how much would be
//! written. The line under the switches says what it comes to. Check
//! looks again - at what the field names - and so does a drawer picked,
//! Return in the field, or a switch changed:
//!
//! - **With the kernel** writes the files the firmware reads as well,
//!   into the partition it reads them from; it starts as BOOT in
//!   `update.prefs` has it.
//! - **Replace changed files** writes the package's own over a file that
//!   was changed on this machine, where the package changed it too.
//!
//! **Update** writes what the check found, the gauge filling by the bytes
//! written; **Stop** ends it where it is, with what was written in place
//! and this machine's list as it was, so the next check finds the rest.
//! **Restart** starts the machine again through `C:Reboot` once an update
//! has written something - with the kernel written to a partition the
//! firmware is to try, on that partition, for one start.
//!
//! **Keep this system** is there when this system came up on the
//! partition the firmware was told to try: a look as the window opens
//! (`ConfirmUpdate` with `UPD_Check`) holds where the firmware says it
//! started this system from against `autoboot.txt`, and the button makes
//! that partition the one the firmware starts from.
//!
//! **The package read is kept.** A check that read a package the field
//! named writes it into `update.prefs` as SOURCE - in `ENVARC:` and
//! `ENV:`, the file's other settings as they were - so the window,
//! `C:Update` and the look at start go there next. A file that does not
//! read as a line of settings is not written over, and one written new
//! does not look at every start, as no file did not.
//!
//! **Only what changed is redrawn.** The work is done on a process of its
//! own (`worker.zig`), through update.library, so the window keeps
//! answering while a package is read over the network. A look or a check
//! shows that it is going only once it has taken half a second
//! (timer.device): one done sooner changes the window once, where what it
//! found differs, its rows put in the list in one go. A button, a switch
//! or a line is only told when what it shows changes, and the list is
//! taken away without being drawn. The field and the switches stay live
//! while a check goes; a change stops it and checks again.

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
const icc = intuition.icclass;
const timer = sdk.devices.timer;
const lb = sdk.gadgets.listbrowser;
const gf = sdk.gadgets.getfile;
const tx = sdk.gadgets.text;
const cb_class = sdk.gadgets.checkbox;
const fg = sdk.gadgets.fuelgauge;

pub const COMMAND_NAME = "Update";
const VERSION = "1.3";
const VERSION_STRING = "\x00$VER: " ++ COMMAND_NAME ++ " " ++ VERSION ++ " (09.11.2026)\r\n";
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
const ID_RESTART = 8;
const ID_KEEP = 9;

/// A field says which key ended it, as the raw key it was: Return and the
/// keypad's Enter check, where Tab and a press elsewhere only leave it.
const raw_return: u32 = 0x44;
const raw_enter: u32 = 0x43;

fn entered(code: u32) bool {
    return code == raw_return or code == raw_enter;
}

/// How many rows the list shows without the window being made taller.
const rows_shown = 10;

/// How long a look or a check goes before the window shows it going:
/// below it a check reads as an answer, above it as a wait.
const quiet_us = 500_000;

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
    /// It says something else than its gadget was last told.
    changed: bool = false,

    fn ptr(line: *const Line) [*:0]const u8 {
        return @ptrCast(&line.text);
    }

    /// `format` with `args` added at the end.
    fn add(line: *Line, sys: *ExecBase, comptime format: [:0]const u8, args: anytype) void {
        comptime exec.checkFormat(format, @TypeOf(args));
        const stream = exec.fmtStream(args);
        _ = sys.RawDoFmt(format, &stream, &putChar, line);
    }

    /// The line set to `format` with `args`; changed only where that is
    /// not what it says already.
    fn say(line: *Line, sys: *ExecBase, comptime format: [:0]const u8, args: anytype) void {
        var next: Line = .{};
        next.add(sys, format, args);
        line.take(&next);
    }

    /// The line made to say what `next` says.
    fn take(line: *Line, next: *const Line) void {
        if (line.length == next.length) {
            var same = true;
            for (line.text[0..line.length], next.text[0..next.length]) |was, now| {
                if (was != now) same = false;
            }
            if (same) return;
        }
        line.text = next.text;
        line.length = next.length;
        line.changed = true;
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
    ub: *UtilityBase,

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
    restart_button: ?*Object = null,
    keep_button: ?*Object = null,

    /// What the list shows: the rows of the last run.
    rows: exec.List = .{},
    /// A check's rows, put in the list once it has ended.
    pending: exec.List = .{},
    /// What the run came to, and what to do about it.
    status: Line = .{},
    note: Line = .{},
    /// What the field is set to.
    source: [worker.source_max:0]u8 = @splat(0),
    /// SOURCE as `update.prefs` has it, and the package a check read
    /// when the field named none - the one the library looks for on its
    /// own. Neither is written into the file again.
    kept_source: [worker.source_max:0]u8 = @splat(0),
    own_source: [worker.source_max:0]u8 = @splat(0),

    /// The run on its process, and what it said last.
    job: Job = undefined,
    heard_line: [worker.line_max:0]u8 = @splat(0),
    wrote_bytes: u64 = 0,
    wrote_files: u32 = 0,
    /// Stop pressed for the run going.
    stop_asked: bool = false,
    /// The check going was stopped for a change, and starts again.
    again: bool = false,
    /// The window shows the run going.
    busy: bool = false,
    /// What the gauge was last told.
    gauge_max: u64 = 0,
    gauge_level: u64 = 0,
    /// The last check's bytes to write, which the gauge goes up to, and
    /// whether it found anything to do.
    to_write: u64 = 0,
    work_found: bool = false,
    /// An update has written something, which a restart runs; and with
    /// the kernel, into a partition the firmware is to try.
    restart_wanted: bool = false,
    tried: bool = false,
    /// This system came up on the partition being tried, which Keep
    /// keeps.
    keep_offered: bool = false,

    /// The half second after which a look or a check shows it is going;
    /// no port, and every run shows it at once.
    quiet: timer.TimeRequest = .{},
    quiet_port: ?*exec.MsgPort = null,
    quiet_pending: bool = false,

    // --- the gadgets ---------------------------------------------------------------

    fn set(app: *App, object: ?*Object, tags: []const TagItem) void {
        _ = app.ib.SetGadgetAttrsTagList(object orelse return, app.window, tags.ptr);
    }

    /// A gadget made usable or not - told only where that changes it, so
    /// that it is not drawn again as it was.
    fn enable(app: *App, object: ?*Object, on: bool) void {
        const gadget = object orelse return;
        const off = gc.gadget(gadget).flags & gc.GFLG_DISABLED != 0;
        if (off != on) return;
        app.set(gadget, &.{ pair(gc.GA_Disabled, @intFromBool(!on)), .{} });
    }

    /// The list taken away from its gadget, which is not drawn without
    /// it: what it shows next is drawn once, as the list is given back.
    fn detachList(app: *App) void {
        _ = app.ib.SetGadgetAttrsTagList(app.list orelse return, null, &[_]TagItem{ pair(lb.LISTBROWSER_Rows, lb.LISTBROWSER_DETACH), .{} });
    }

    fn attachList(app: *App) void {
        app.set(app.list, &.{ pair(lb.LISTBROWSER_Rows, @intFromPtr(&app.rows)), .{} });
    }

    /// The rows a check found put in the list in place of the ones it
    /// had, in one change.
    fn showPending(app: *App) void {
        app.detachList();
        lb.freeRows(app.sys, &app.rows);
        while (app.sys.RemHead(&app.pending)) |node| app.sys.AddTail(&app.rows, node);
        app.attachList();
    }

    fn checked(app: *App, object: ?*Object) bool {
        var value: usize = 0;
        _ = app.ib.GetAttr(cb_class.CHECKBOX_Checked, object orelse return false, &value);
        return value != 0;
    }

    /// What the field holds now, or an empty text.
    fn fieldText(app: *App) [*:0]const u8 {
        var at: usize = 0;
        _ = app.ib.GetAttr(gf.GETFILE_FullFile, app.source_field orelse return "", &at);
        if (at == 0) return "";
        return @ptrFromInt(at);
    }

    /// The field set to `text`, which the drawer requester opens in.
    fn showSource(app: *App, text: [*:0]const u8) void {
        worker.copyText(&app.source, text);
        app.set(app.source_field, &.{
            pair(gf.GETFILE_Drawer, @intFromPtr(@as([*:0]const u8, @ptrCast(&app.source)))),
            pair(gf.GETFILE_File, @intFromPtr("")),
            .{},
        });
    }

    fn showLine(app: *App, object: ?*Object, line: *Line) void {
        if (!line.changed) return;
        line.changed = false;
        app.set(object, &.{ pair(tx.TEXT_Text, @intFromPtr(line.ptr())), .{} });
    }

    fn showStatus(app: *App) void {
        app.showLine(app.status_gadget, &app.status);
        app.showLine(app.note_gadget, &app.note);
    }

    /// The buttons and switches as the run allows: Stop only while one
    /// goes, Update once a check found work, and while an update or a
    /// keep goes nothing that starts another. A check leaves the field
    /// and the switches live - a change checks again.
    fn showButtons(app: *App) void {
        const going = app.job.running();
        const held = going and !app.looking();
        app.enable(app.source_field, !held);
        app.enable(app.check_button, !held);
        app.enable(app.boot_box, !held);
        app.enable(app.force_box, !held);
        app.enable(app.update_button, !going and app.work_found);
        app.enable(app.stop_button, going);
        app.enable(app.restart_button, !going and app.restart_wanted);
        app.enable(app.keep_button, !going and app.keep_offered);
    }

    /// Whether the run going only looks: a look at this system, or a
    /// check.
    fn looking(app: *const App) bool {
        return app.job.kind == .look or app.job.kind == .check;
    }

    fn showGauge(app: *App, level: u64, most: u64) void {
        const top: u64 = @max(1, (most + gauge_unit - 1) / gauge_unit);
        const max: u64 = @min(top, gauge_most);
        const done: u64 = if (most != 0 and level >= most) max else @min(level / gauge_unit, max);
        if (max == app.gauge_max and done == app.gauge_level) return;
        app.gauge_max = max;
        app.gauge_level = done;
        app.set(app.gauge, &.{
            pair(fg.GAUGE_Max, @intCast(max)),
            pair(fg.GAUGE_Level, @intCast(done)),
            .{},
        });
    }

    // --- the half second -----------------------------------------------------------

    /// The half second started; false without timer.device.
    fn armQuiet(app: *App) bool {
        const port = app.quiet_port orelse return false;
        app.disarmQuiet();
        // An aborted request leaves its port's signal set.
        _ = app.sys.SetSignal(0, port.sigMask());
        app.quiet.node.command = timer.TR_ADDREQUEST;
        app.quiet.time = timer.TimeVal.fromMicros(quiet_us);
        app.sys.SendIO(&app.quiet.node);
        app.quiet_pending = true;
        return true;
    }

    fn disarmQuiet(app: *App) void {
        if (!app.quiet_pending) return;
        _ = app.sys.AbortIO(&app.quiet.node);
        _ = app.sys.WaitIO(&app.quiet.node);
        app.quiet_pending = false;
    }

    fn quietSignal(app: *const App) u32 {
        return if (app.quiet_port) |port| port.sigMask() else 0;
    }

    /// The half second is up: a run still going is shown going.
    fn quietEnded(app: *App) void {
        if (!app.quiet_pending or app.sys.CheckIO(&app.quiet.node) == null) return;
        _ = app.sys.WaitIO(&app.quiet.node);
        app.quiet_pending = false;
        if (app.job.running() and !app.busy) app.showBusy();
    }

    // --- a run ---------------------------------------------------------------------

    /// A run started: a look at this system, a check of what the field
    /// names, the update the last check found, or this system kept. A
    /// look and a check change nothing on the window for half a second;
    /// an update and a keep are shown going at once.
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
        app.stop_asked = false;
        app.again = false;
        app.busy = false;
        app.heard_line = @splat(0);
        app.wrote_bytes = 0;
        app.wrote_files = 0;
        lb.freeRows(app.sys, &app.pending);
        if (!job.start()) {
            app.status.say(app.sys, "There is no process to run the update on.", .{});
            app.note.say(app.sys, "", .{});
            app.showStatus();
            app.showButtons();
            return;
        }
        if (app.looking() and app.armQuiet()) return;
        app.showBusy();
    }

    /// A check asked for - by Check, a drawer picked, Return in the field
    /// or a switch changed. A check going is stopped and starts again on
    /// what the window says now; a look going is followed by a check of
    /// its own.
    fn askCheck(app: *App) void {
        if (!app.job.running()) return app.begin(.check);
        if (app.job.kind != .check) return;
        app.again = true;
        app.job.stop();
    }

    /// The run shown going: what it does on the status line, Stop, and
    /// for an update the list and the gauge started again.
    fn showBusy(app: *App) void {
        app.busy = true;
        const kind = app.job.kind;
        if (kind == .update) {
            app.detachList();
            lb.freeRows(app.sys, &app.rows);
            app.attachList();
            app.showGauge(0, app.to_write);
        }
        const doing: [*:0]const u8 = switch (kind) {
            .look => "Looking at this system ...",
            .check => "Looking at the package ...",
            .update => "Updating ...",
            .keep => "Keeping this system ...",
        };
        if (app.heard_line[0] != 0 and kind != .look) {
            app.status.say(app.sys, "%s", .{@as([*:0]const u8, @ptrCast(&app.heard_line))});
        } else {
            app.status.say(app.sys, "%s", .{doing});
        }
        app.note.say(app.sys, "", .{});
        app.showStatus();
        app.showButtons();
    }

    /// The machine started again through C:Reboot, on the partition the
    /// update wrote for a try where it wrote one. What comes back is a
    /// restart that did not happen, said with why.
    fn restart(app: *App) void {
        const dl = app.dl;
        const sys = app.sys;
        const nil_in = dl.Open("NIL:", dos.MODE_OLDFILE);
        defer if (nil_in) |file| {
            _ = dl.Close(file);
        };
        const nil_out = dl.Open("NIL:", dos.MODE_NEWFILE);
        defer if (nil_out) |file| {
            _ = dl.Close(file);
        };
        const line: [*:0]const u8 = if (app.tried) "C:Reboot TRYBOOT FORCE" else "C:Reboot FORCE";
        app.status.say(sys, "Restarting ...", .{});
        app.note.say(sys, "", .{});
        app.showStatus();
        const code = dl.SystemTagList(line, &[_]TagItem{
            pair(if (nil_in != null) dos.SYS_Input else sdk.utility.TAG_IGNORE, @intFromPtr(nil_in)),
            pair(if (nil_out != null) dos.SYS_Output else sdk.utility.TAG_IGNORE, @intFromPtr(nil_out)),
            .{},
        });
        switch (code) {
            dos.RETURN_WARN => app.status.say(sys, "The firmware has no start to try, so nothing was restarted.", .{}),
            dos.RETURN_FAIL => app.status.say(sys, "The firmware's flag for a tried start could not be set, so nothing was restarted.", .{}),
            else => if (code < 0)
                app.status.say(sys, "C:Reboot is not there, so nothing was restarted.", .{})
            else
                app.status.say(sys, "C:Reboot answered %ld, and nothing was restarted.", .{@as(i64, code)}),
        }
        app.showStatus();
    }

    /// What the run has said since the last look. An update's rows are
    /// added to the list as they come, the newest in sight; a check's
    /// wait for its end. The last line goes on the status line and the
    /// gauge moves on, once the run is shown going.
    fn heard(app: *App) void {
        var fresh: exec.List = .{};
        fresh.init(.unknown);
        app.job.take(&fresh, &app.heard_line, &app.wrote_bytes, &app.wrote_files);
        if (app.job.kind != .update) {
            while (app.sys.RemHead(&fresh)) |node| app.sys.AddTail(&app.pending, node);
        } else if (fresh.first() != null) {
            app.detachList();
            var count: usize = 0;
            while (app.sys.RemHead(&fresh)) |node| app.sys.AddTail(&app.rows, node);
            var node = app.rows.first();
            while (node) |it| : (node = it.next()) count += 1;
            var visible: usize = 0;
            _ = app.ib.GetAttr(lb.LISTBROWSER_Visible, app.list.?, &visible);
            if (count > visible) {
                app.set(app.list, &.{
                    pair(lb.LISTBROWSER_Rows, @intFromPtr(&app.rows)),
                    pair(lb.LISTBROWSER_Top, count - visible),
                    .{},
                });
            } else app.attachList();
        }
        if (!app.busy) return;
        if (app.heard_line[0] != 0 and app.job.kind != .look) {
            app.status.say(app.sys, "%s", .{@as([*:0]const u8, @ptrCast(&app.heard_line))});
            app.showLine(app.status_gadget, &app.status);
        }
        if (app.job.kind == .update) app.showGauge(app.wrote_bytes, app.to_write);
    }

    /// The run has ended: what it came to on the status line, what to do
    /// about it under it, a check's rows in the list.
    fn ended(app: *App) void {
        app.heard();
        app.disarmQuiet();
        const job = &app.job;
        const info = &job.info;
        const sys = app.sys;
        if (app.again) {
            // Stopped for a change: what it found so far is not shown.
            app.begin(.check);
            return;
        }
        switch (job.kind) {
            // Its words are not shown, only what it found; the check
            // that opening the window starts follows it.
            .look => {
                app.keep_offered = job.code == dos.RETURN_WARN;
                app.begin(.check);
                return;
            },
            // What ConfirmUpdate said is on the status line already.
            .keep => {
                if (job.code == dos.RETURN_OK) app.keep_offered = false;
                if (app.heard_line[0] == 0) {
                    app.status.say(sys, "%s", .{@as([*:0]const u8, if (job.code == dos.RETURN_OK) "Kept: the machine starts this system from now on." else "This system could not be kept.")});
                }
                app.note.say(sys, "", .{});
                app.busy = false;
                app.showStatus();
                app.showButtons();
                return;
            },
            .check, .update => {},
        }
        var note: Line = .{};
        var status: Line = .{};
        if (job.kind == .check) {
            app.showPending();
            app.showGauge(0, 0);
        }
        // The field shows the package that was read, where it was empty.
        const named = job.source[0] != 0;
        if (!named and job.used[0] != 0) {
            worker.copyText(&app.own_source, @ptrCast(&job.used));
            if (app.fieldText()[0] == 0) app.showSource(@ptrCast(&job.used));
        }

        if (app.stop_asked and job.code != dos.RETURN_OK) {
            // Between two files or in the middle of one: what was put in
            // place is what the run said it wrote.
            if (job.kind == .update) {
                var size: [16:0]u8 = @splat(0);
                update.bytesAsText(&size, app.wrote_bytes);
                status.add(sys, "Stopped: %d files written (%s).", .{ app.wrote_files, @as([*:0]const u8, @ptrCast(&size)) });
                note.add(sys, "What was written stays. Check shows what is left to do.", .{});
            } else {
                status.add(sys, "Stopped.", .{});
            }
            app.work_found = false;
        } else if (job.code == dos.RETURN_FAIL) {
            status.add(sys, "%s", .{@as([*:0]const u8, if (app.heard_line[0] != 0) @ptrCast(&app.heard_line) else "The update could not finish.")});
            if (job.kind == .update) note.add(sys, "What was written stays. Check shows what is left to do.", .{});
            app.work_found = false;
        } else {
            if (named) app.keepSource(&note);
            const checking = job.kind == .check;
            if (!update.changes(info) and info.kept == 0 and info.boot_written == 0) {
                status.add(sys, "Nothing to do: this system is what the package holds.", .{});
                app.work_found = false;
            } else {
                var size: [16:0]u8 = @splat(0);
                update.bytesAsText(&size, info.written_bytes);
                if (checking) {
                    status.add(sys, "The update writes %d files (%s)", .{ info.written, @as([*:0]const u8, @ptrCast(&size)) });
                    if (info.deleted != 0) status.add(sys, ", deletes %d", .{info.deleted});
                    if (info.made != 0) status.add(sys, ", makes %d drawers", .{info.made});
                } else {
                    status.add(sys, "Updated: %d files written (%s)", .{ info.written, @as([*:0]const u8, @ptrCast(&size)) });
                    if (info.deleted != 0) status.add(sys, ", %d deleted", .{info.deleted});
                    if (info.made != 0) status.add(sys, ", %d drawers made", .{info.made});
                }
                if (job.boot and info.boot_written != 0) {
                    status.add(sys, ", the kernel among them", .{});
                }
                status.add(sys, ".", .{});
            }
            // Where the package could not be kept, that is what is said.
            if (note.length == 0) {
                if (info.kept != 0 and !job.force) {
                    note.add(sys, "%d files changed on this machine are left as they are: switch on Replace changed files to replace them.", .{info.kept});
                } else if (!job.boot and info.boot != 0) {
                    note.add(sys, "The kernel was not checked: switch on With the kernel to check it too.", .{});
                }
            }
            if (checking) {
                app.work_found = update.changes(info) or info.boot_written != 0;
                app.to_write = info.written_bytes;
            } else {
                app.work_found = false;
                app.showGauge(app.to_write, app.to_write);
                if (update.changes(info) or info.boot_written != 0) app.restart_wanted = true;
                if (info.tried != 0) {
                    // The partition being tried is the one just written,
                    // not this system's.
                    app.tried = true;
                    app.keep_offered = false;
                    note = .{};
                    note.add(sys, "Restart starts the new kernel once, as a try. Once it is up, Keep this system there makes it stay; if it does not come up, the next start is this system again.", .{});
                } else if (app.restart_wanted and note.length == 0) {
                    note.add(sys, "Restart the machine to run what was written.", .{});
                }
            }
        }
        if (app.keep_offered and note.length == 0) {
            note.add(sys, "This system was started once, as a try: Keep this system makes the machine start it from now on.", .{});
        }
        app.status.take(&status);
        app.note.take(&note);
        app.busy = false;
        app.showStatus();
        app.showButtons();
    }

    /// The package a check read where the field named it kept as SOURCE
    /// in `update.prefs`, unless it is the one kept already or the one
    /// the library looks for on its own. What went wrong is said in
    /// `note`.
    fn keepSource(app: *App, note: *Line) void {
        const source: [*:0]const u8 = @ptrCast(&app.job.source);
        if (sameText(source, @ptrCast(&app.kept_source))) return;
        if (app.kept_source[0] == 0 and sameText(source, @ptrCast(&app.own_source))) return;
        if (!saveSource(app.sys, app.dl, app.ub, source)) {
            note.add(app.sys, "The package could not be kept in %s.", .{@as([*:0]const u8, prefs.update.ENVARC_FILE)});
            return;
        }
        worker.copyText(&app.kept_source, source);
    }
};

/// Whether two texts are the same.
fn sameText(one: [*:0]const u8, other: [*:0]const u8) bool {
    var at: usize = 0;
    while (one[at] == other[at]) : (at += 1) {
        if (one[at] == 0) return true;
    }
    return false;
}

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
/// A drawer picked in the field's requester is told to the window
/// (`ICTARGET_IDCMP`); Return in it ends as the field's GADGETUP.
fn buildLayout(app: *App, boot: bool) ?*Object {
    const ib = app.ib;
    app.source_field = ib.NewObjectTagList(null, gf.GETFILE_CLASS, &[_]TagItem{
        pair(gc.GA_ID, ID_SOURCE),
        pair(gc.GA_RelVerify, 1),
        pair(gc.GA_TabCycle, 1),
        pair(icc.ICA_TARGET, icc.ICTARGET_IDCMP),
        pair(gf.GETFILE_TitleText, @intFromPtr("Which drawer is the package?")),
        pair(gf.GETFILE_DrawersOnly, 1),
        pair(gf.GETFILE_Drawer, @intFromPtr(@as([*:0]const u8, @ptrCast(&app.source)))),
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
    app.restart_button = button(ib, "Restart", ID_RESTART);
    app.keep_button = button(ib, "Keep this system", ID_KEEP);

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
        pair(lg.LAYOUTA_AddChild, @intFromPtr(app.restart_button orelse return null)),
        pair(lg.CHILDA_WeightWidth, 0),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(app.keep_button orelse return null)),
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

/// What `update.prefs` says: ENV:'s copy first, then ENVARC:'s. A file
/// that is not a line of settings says nothing; the check says what is
/// wrong with it.
fn loadPrefs(sys: *ExecBase, dl: *DosBase, ub: *UtilityBase) ?prefs.update.Settings {
    const text = prefs.loadWhole(sys, dl, prefs.update.ENV_FILE) orelse
        prefs.loadWhole(sys, dl, prefs.update.ENVARC_FILE) orelse return null;
    defer sys.FreeVec(@ptrCast(text.ptr));
    var settings: prefs.update.Settings = .{};
    const first = prefs.firstLine(text) orelse return null;
    if (prefs.update.parse(ub, first, &settings) != null) return null;
    return settings;
}

/// `source` written into `update.prefs` as SOURCE, in ENVARC: and in
/// ENV:, its other settings as ENVARC:'s file has them. Where there is
/// none it is written new, looking at no start - as no file did not;
/// one that does not read as a line of settings is not written over.
/// Whether ENVARC:'s was written.
fn saveSource(sys: *ExecBase, dl: *DosBase, ub: *UtilityBase, source: [*:0]const u8) bool {
    const file = prefs.update;
    var settings: file.Settings = .{ .at_start = false };
    if (prefs.loadWhole(sys, dl, file.ENVARC_FILE)) |text| {
        defer sys.FreeVec(@ptrCast(text.ptr));
        if (prefs.firstLine(text)) |first| {
            if (file.parse(ub, first, &settings) != null) return false;
        }
    }
    worker.copyText(&settings.source, source);
    var text: [file.header.len + file.max_line + 1]u8 = undefined;
    @memcpy(text[0..file.header.len], file.header);
    var length: usize = file.header.len;
    length += file.write(&settings, text[length..]);
    text[length] = '\n';
    length += 1;
    const kept = prefs.save(dl, file.ENVARC_FILE, text[0..length]);
    _ = prefs.save(dl, file.ENV_FILE, text[0..length]);
    return kept;
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
        gf.GETFILE_LIBRARY,      tx.TEXT_LIBRARY,       cb_class.CHECKBOX_LIBRARY, fg.GAUGE_LIBRARY,
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
    app.* = .{ .sys = sys, .dl = dl, .ib = ib, .gb = gb, .ub = ub };
    app.rows.init(.unknown);
    defer lb.freeRows(sys, &app.rows);
    app.pending.init(.unknown);
    defer lb.freeRows(sys, &app.pending);
    if (!app.job.init(sys, dl)) {
        _ = Printf(dl, MSG_NOMEMORY, .{COMMAND_NAME});
        return dos.RETURN_FAIL;
    }
    defer app.job.free();

    // The half second; without timer.device every run is shown at once.
    const quiet_port = sys.CreateMsgPort();
    defer if (quiet_port) |port| sys.DeleteMsgPort(port);
    const timer_open = quiet_port != null and
        sys.OpenDevice(sdk.interface.timer.NAME, timer.UNIT_MICROHZ, &app.quiet.node, 0) == 0;
    defer if (timer_open) {
        app.disarmQuiet();
        sys.CloseDevice(&app.quiet.node);
    };
    if (timer_open) {
        app.quiet.node.message.reply_port = quiet_port;
        app.quiet_port = quiet_port;
    }

    const settings = loadPrefs(sys, dl, ub) orelse prefs.update.Settings{};
    worker.copyText(&app.kept_source, @ptrCast(&settings.source));
    if (rdargs.string(argv[arg_from])) |from| worker.copyText(&app.source, from);

    const layout = buildLayout(app, settings.boot) orelse {
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
        pair(wn.WA_IDCMP, wn.IDCMP_IDCMPUPDATE),
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

    app.begin(.look);

    const news = app.job.signal();
    const ends = app.job.endSignal();
    const quiet = app.quietSignal();
    var code_word: u32 = 0;
    var handle = wc.WmHandleInput{ .code = &code_word };
    while (true) {
        var mask: usize = 0;
        _ = ib.GetAttr(wc.WINDOWA_SigMask, app.object.?, &mask);
        const got = sys.Wait(@as(u32, @intCast(mask)) | news | ends | quiet | exec.SIGBREAKF_CTRL_C);
        if (got & exec.SIGBREAKF_CTRL_C != 0) return dos.RETURN_OK;
        if (got & news != 0) app.heard();
        if (got & ends != 0 and app.job.finished()) app.ended();
        if (got & quiet != 0) app.quietEnded();

        while (true) {
            const word = ib.SendMessage(app.object.?, @ptrCast(&handle));
            if (word == wc.WMHI_LASTMSG) break;
            switch (word & wc.WMHI_CLASSMASK) {
                wc.WMHI_CLOSEWINDOW => return dos.RETURN_OK,
                // A drawer picked in the field's requester.
                wc.WMHI_IDCMPUPDATE => {
                    var updated: usize = 0;
                    _ = ib.GetAttr(wc.WINDOWA_GadgetID, app.object.?, &updated);
                    if (updated == ID_SOURCE) app.askCheck();
                },
                wc.WMHI_GADGETUP => switch (word & wc.WMHI_GADGETMASK) {
                    ID_CHECK, ID_BOOT, ID_FORCE => app.askCheck(),
                    ID_SOURCE => if (entered(code_word)) app.askCheck(),
                    ID_UPDATE => if (app.work_found and !app.job.running()) app.begin(.update),
                    ID_RESTART => if (app.restart_wanted and !app.job.running()) app.restart(),
                    ID_KEEP => if (app.keep_offered and !app.job.running()) app.begin(.keep),
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
