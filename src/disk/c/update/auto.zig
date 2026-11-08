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
const update = sdk.update;
const Command = @import("update.zig").Command;
const fail = @import("update.zig").fail;

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
pub fn settingsOf(command: *Command, into: *prefs.update.Settings) Told {
    const text = prefs.loadWhole(command.sys, command.dl, prefs.update.ENV_FILE) orelse
        prefs.loadWhole(command.sys, command.dl, prefs.update.ENVARC_FILE) orelse return .none;
    defer command.sys.FreeVec(@ptrCast(text.ptr));
    const line = prefs.firstLine(text) orelse return .{ .settings = into };
    if (prefs.update.parse(command.ub, line, into)) |wrong| {
        _ = fail(command, "%s: %s\n", .{ prefs.update.ENVARC_FILE, wrong });
        return .wrong;
    }
    return .{ .settings = into };
}

/// One line into the system log, where a run with no console of its own
/// leaves what it found: `C:Log` shows it with the start's own words.
pub fn logged(command: *Command, comptime format: [:0]const u8, args: anytype) void {
    exec.klog(command.sys, exec.LOG_INFO, log_mark ++ format, args);
}

/// What was found, offered on the desktop: true where it is to be
/// written now, false where it is not, and null where there was no
/// screen to ask on.
pub fn offer(command: *Command) ?bool {
    const info = &command.info;
    var body: [256:0]u8 = @splat(0);
    var at: usize = 0;
    at += copy(body[at..], "A newer system is ready.\n\n");
    at += update.decimal(body[at..], info.written);
    at += copy(body[at..], " files to write, ");
    at += update.decimal(body[at..], info.deleted);
    at += copy(body[at..], " to delete");
    if (info.kept != 0) {
        at += copy(body[at..], ", ");
        at += update.decimal(body[at..], info.kept);
        at += copy(body[at..], " changed here and kept");
    }
    at += copy(body[at..], ".\n\nWrite it now?");
    body[at] = 0;
    return asked(command, @ptrCast(&body), "Update now|Later");
}

/// A question on the default public screen: true where the first button
/// was pressed, false for the other, and null where there is no screen
/// to ask on, so the caller can say it another way.
pub fn asked(command: *Command, body: [*:0]const u8, buttons: [*:0]const u8) ?bool {
    const sys = command.sys;
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

/// `from` into `into`: how many bytes.
fn copy(into: []u8, from: []const u8) usize {
    const room = @min(into.len, from.len);
    @memcpy(into[0..room], from[0..room]);
    return room;
}
