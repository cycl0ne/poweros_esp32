// SPDX-License-Identifier: MIT
//! AUTO: the run a machine makes by itself, from `S:Network-Startup`
//! once the network is up, doing what `ENVARC:Sys/update.prefs` says.
//!
//! Without that file nothing happens at all: a machine says nothing to a
//! server it was never told about. With it, and `ATSTART=YES`, the
//! package it names is looked at once; `APPLY=YES` writes what was found
//! there and then, and `APPLY=NO` - what a machine does unless it was
//! told otherwise, since a build changes daily - says what there is and
//! waits to be asked.
//!
//! **Where there is a desktop it asks there.** The run has no console of
//! its own, so what it found would otherwise go nowhere: a requester on
//! the default public screen offers the update, and the answer is
//! whether to write it now. A machine with no screen - a board on a
//! serial console - is left with the line in the system log, which is
//! where the start's own words are.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const intuition = sdk.intuition;
const wn = intuition.windows;
const prefs = sdk.prefs;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const TagItem = sdk.utility.TagItem;
const shared = @import("_update.zig");
const Run = shared.Run;

/// The title of what it asks on the desktop.
const title = "A newer system";

/// What a line in the log says it is.
const log_mark = "Update: ";

/// What came of looking for `update.prefs`.
pub const Told = union(enum) {
    /// No such file: a machine that was never told where to look, and
    /// looks nowhere.
    none,
    /// A file that is not a line of settings, said already.
    wrong,
    /// What it says.
    settings: *prefs.update.Settings,
};

/// What `update.prefs` says: the running system's copy where there is
/// one, else the one that is kept. A file nobody can read stops the run
/// rather than sending it somewhere unasked.
pub fn settingsOf(run: *Run, into: *prefs.update.Settings) Told {
    const text = prefs.loadWhole(run.sys, run.dl, prefs.update.ENV_FILE) orelse
        prefs.loadWhole(run.sys, run.dl, prefs.update.ENVARC_FILE) orelse return .none;
    defer run.sys.FreeVec(@ptrCast(text.ptr));
    const line = prefs.firstLine(text) orelse return .{ .settings = into };
    if (prefs.update.parse(run.ub, line, into)) |wrong| {
        _ = shared.fail(run, "%s: %s\n", .{ prefs.update.ENVARC_FILE, wrong });
        return .wrong;
    }
    return .{ .settings = into };
}

/// One line into the system log, where a run with no console of its own
/// leaves what it found: `C:Log` shows it with the start's own words.
pub fn logged(run: *Run, comptime format: [:0]const u8, args: anytype) void {
    exec.klog(run.sys, exec.LOG_INFO, log_mark ++ format, args);
}

/// What was found, offered on the desktop: true where it is to be
/// written now, false where it is not, and null where there was no
/// screen to ask on.
pub fn offer(run: *Run) ?bool {
    var body: [256:0]u8 = @splat(0);
    var at: usize = 0;
    at += shared.copy(body[at..], "A newer system is ready.\n\n");
    at += shared.decimal(body[at..], run.written);
    at += shared.copy(body[at..], " files to write, ");
    at += shared.decimal(body[at..], run.deleted);
    at += shared.copy(body[at..], " to delete");
    if (run.kept != 0) {
        at += shared.copy(body[at..], ", ");
        at += shared.decimal(body[at..], run.kept);
        at += shared.copy(body[at..], " changed here and kept");
    }
    at += shared.copy(body[at..], ".\n\nWrite it now?");
    body[at] = 0;
    return asked(run, @ptrCast(&body), "Update now|Later");
}

/// A question on the default public screen: true where the first button
/// was pressed, false for the other, and null where there is no screen
/// to ask on, so the caller can say it another way.
pub fn asked(run: *Run, body: [*:0]const u8, buttons: [*:0]const u8) ?bool {
    const sys = run.sys;
    const lib = sys.OpenLibrary(intuition.INTUITIONNAME, 0) orelse return null;
    defer sys.CloseLibrary(lib);
    const ib: *IntuitionBase = @ptrCast(lib);
    // A requester belongs to a window, and this run has none of its own.
    const window = ib.OpenWindowTagList(&[_]TagItem{
        .{ .tag = wn.WA_Left, .data = 0 },
        .{ .tag = wn.WA_Top, .data = 0 },
        .{ .tag = wn.WA_Width, .data = 16 },
        .{ .tag = wn.WA_Height, .data = 16 },
        .{ .tag = wn.WA_Borderless, .data = 1 },
        .{ .tag = wn.WA_Backdrop, .data = 1 },
        .{ .tag = wn.WA_NoCareRefresh, .data = 1 },
        .{ .tag = wn.WA_RMBTrap, .data = 1 },
        .{},
    }) orelse return null;
    defer ib.CloseWindow(window);
    const easy = intuition.EasyStruct{
        .title = title,
        .text_format = body,
        .gadget_format = buttons,
    };
    return ib.EasyRequestArgs(window, &easy, null, null) == 1;
}
