// SPDX-License-Identifier: MIT
//! Delete: names, or patterns, deleted one after another. Built against the
//! SDK only.
//!
//!   Delete FILE/M/A,ALL/S,QUIET/S,FORCE/S
//!
//! Each name may be a pattern (MatchFirst/MatchNext). ALL deletes a
//! directory with all it holds, innermost first, by dos's DeleteTree,
//! and stops at the first object that will not go.
//! FORCE clears the delete-protect bit rather than stopping at it. QUIET
//! keeps it from naming what it deleted.
//!
//! A name that matched nothing leaves RETURN_WARN, and each name deleted is
//! printed with "  Deleted" after it.
//!
//! A command cannot delete the directory it was loaded from: the shell holds
//! that directory as the command's PROGDIR: while it runs, so
//! `RAM:work/Delete RAM:work ALL` empties the drawer and then says the
//! drawer itself is in use. Another Delete, loaded from somewhere else,
//! takes it away.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const utility = sdk.utility;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const rdargs = dos.rdargs;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "Delete";
const VERSION_STRING = "\x00$VER: Delete 1.2 (09.11.2026)\r\n";

const template = "FILE/M/A,ALL/S,QUIET/S,FORCE/S";
const arg_file = 0;
const arg_all = 1;
const arg_quiet = 2;
const arg_force = 3;

/// The longest name a pattern matches, dos's limit.
const max_path = dos.path_max;

const MSG_NO_FILES = "No file to delete\n";
const MSG_DELETED = "  Deleted\n";

const Anchor = extern struct {
    ap: dos.AnchorPath = .{},
    buf: [max_path]u8 = @splat(0),
};

const Run = struct {
    sys: *ExecBase,
    dl: *DosBase,
    all: bool,
    quiet: bool,
    force: bool,
    failed: bool = false,
    /// A Ctrl-C was seen; nothing more is deleted.
    stopped: bool = false,
};

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(lib);
    const dl: *DosBase = @ptrCast(lib);

    var argv: [4]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);

    var run: Run = .{
        .sys = sys,
        .dl = dl,
        .all = argv[arg_all] != 0,
        .quiet = argv[arg_quiet] != 0,
        .force = argv[arg_force] != 0,
    };

    const patterns = rdargs.multi(argv[arg_file]);
    if (patterns.len == 0) {
        _ = dl.PutStr(MSG_NO_FILES);
        return dos.RETURN_WARN;
    }
    for (patterns) |pattern| {
        if (run.stopped) break;
        var anchor: Anchor = .{};
        anchor.ap.strlen = anchor.buf.len;
        anchor.ap.break_bits = exec.SIGBREAKF_CTRL_C;
        var err = dl.MatchFirst(pattern, &anchor.ap);
        var found = false;
        while (err == 0) : (err = dl.MatchNext(&anchor.ap)) {
            found = true;
            remove(&run, @ptrCast(&anchor.buf));
            if (run.stopped) break;
        }
        dl.MatchEnd(&anchor.ap);
        if (err != dos.ERROR_NO_MORE_ENTRIES) {
            _ = dl.PrintFault(err, pattern);
            run.failed = true;
        } else if (!found) {
            _ = dl.PrintFault(dos.ERROR_OBJECT_NOT_FOUND, pattern);
            run.failed = true;
        }
        _ = dl.Flush(dl.Output());
    }
    return if (run.failed) dos.RETURN_WARN else dos.RETURN_OK;
}

/// One object: the file, or with ALL a whole directory, innermost first.
fn remove(run: *Run, name: [*:0]const u8) void {
    if (breakNow(run)) return;
    const dl = run.dl;
    if (run.all) {
        var hook: utility.Hook = .{ .entry = told, .data = run };
        if (!dl.DeleteTree(name, if (run.force) dos.DELF_FORCE else 0, &hook)) run.failed = true;
        return;
    }
    if (dl.DeleteFile(name)) return say(run, name);
    if (dl.IoErr() == dos.ERROR_DELETE_PROTECTED and run.force) {
        if (dl.SetProtection(name, 0) and dl.DeleteFile(name)) return say(run, name);
    }
    _ = dl.PrintFault(dl.IoErr(), name);
    run.failed = true;
}

/// DeleteTree's hook: each object named as it goes, or why it would not;
/// Ctrl-C stops the walk.
fn told(hook: *utility.Hook, object: ?*anyopaque, message: ?*anyopaque) callconv(.c) usize {
    _ = object;
    const run: *Run = @ptrCast(@alignCast(hook.data.?));
    const deleted: *const dos.DeleteMsg = @ptrCast(@alignCast(message.?));
    if (deleted.failure == 0) {
        say(run, deleted.name);
    } else {
        _ = run.dl.PrintFault(deleted.failure, deleted.name);
        run.failed = true;
    }
    return @intFromBool(breakNow(run));
}

fn say(run: *Run, name: [*:0]const u8) void {
    if (run.quiet) return;
    _ = Printf(run.dl, "%s", .{name});
    _ = run.dl.PutStr(MSG_DELETED);
}

/// Ctrl-C, once: deleting a large tree takes a while, and has to be
/// stoppable.
fn breakNow(run: *Run) bool {
    if (run.stopped) return true;
    if (run.dl.CheckSignal(exec.SIGBREAKF_CTRL_C) == 0) return false;
    _ = run.dl.PrintFault(dos.ERROR_BREAK, null);
    run.stopped = true;
    run.failed = true;
    return true;
}

/// The "$VER:" string every PowerOS module carries, which `Version <file>`
/// looks for. Nothing refers to it, so it needs both an export and a
/// section of its own that program.ld KEEPs: the linker collects unused
/// sections, and a plain constant never reaches the file at all - which is
/// all the comptime reference that used to stand here achieved.
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;
