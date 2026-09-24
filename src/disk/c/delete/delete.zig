// SPDX-License-Identifier: MIT
//! Delete: names, or patterns, deleted one after another. Built against the
//! SDK only.
//!
//!   Delete FILE/M/A,ALL/S,QUIET/S,FORCE/S
//!
//! Each name may be a pattern (MatchFirst/MatchNext). ALL goes into a
//! directory and deletes what is in it first, then the directory itself.
//! FORCE clears the delete-protect bit rather than stopping at it. QUIET
//! keeps it from naming what it deleted.
//!
//! A name that matched nothing leaves RETURN_WARN, and each name deleted is
//! printed with "  Deleted" after it.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const rdargs = dos.rdargs;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "Delete";
const VERSION_STRING = "\x00$VER: Delete 1.0 (16.9.2026)\r\n";

const template = "FILE/M/A,ALL/S,QUIET/S,FORCE/S";
const arg_file = 0;
const arg_all = 1;
const arg_quiet = 2;
const arg_force = 3;

/// The longest path it builds: the size of the buffers here.
const max_path = 256;
/// How deep ALL goes. Each level keeps a path buffer on the stack, so this
/// is what holds it in hand.
const max_depth = 15;

const MSG_NO_FILES = "No file to delete\n";
const MSG_DELETED = "  Deleted\n";

const Anchor = extern struct {
    ap: dos.AnchorPath = .{},
    buf: [max_path]u8 = @splat(0),
};

const Run = struct {
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
            remove(&run, @ptrCast(&anchor.buf), 0);
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
fn remove(run: *Run, name: [*:0]const u8, depth: u32) void {
    if (breakNow(run)) return;
    const dl = run.dl;
    if (dl.DeleteFile(name)) return say(run, name);

    const why = dl.IoErr();
    if (why == dos.ERROR_DELETE_PROTECTED and run.force) {
        if (dl.SetProtection(name, 0) and dl.DeleteFile(name)) return say(run, name);
    }
    if (why == dos.ERROR_DIRECTORY_NOT_EMPTY and run.all) {
        if (depth >= max_depth) {
            _ = dl.PrintFault(dos.ERROR_TOO_MANY_LEVELS, name);
            run.failed = true;
            return;
        }
        if (emptyDir(run, name, depth) and dl.DeleteFile(name)) return say(run, name);
    }
    _ = dl.PrintFault(dl.IoErr(), name);
    run.failed = true;
}

fn say(run: *Run, name: [*:0]const u8) void {
    if (run.quiet) return;
    _ = Printf(run.dl, "%s", .{name});
    _ = run.dl.PutStr(MSG_DELETED);
}

/// Ctrl-C, once. The reference's Delete cannot be stopped at all, which is
/// no use on a tree that takes a while.
fn breakNow(run: *Run) bool {
    if (run.stopped) return true;
    if (run.dl.CheckSignal(exec.SIGBREAKF_CTRL_C) == 0) return false;
    _ = run.dl.PrintFault(dos.ERROR_BREAK, null);
    run.stopped = true;
    run.failed = true;
    return true;
}

/// Everything inside a directory. Each entry is deleted by name, so this
/// asks a handler for nothing that every one of them cannot do; the walk
/// starts again after each one, since a handler is free to give the entries
/// in any order and one of them has just gone.
fn emptyDir(run: *Run, name: [*:0]const u8, depth: u32) bool {
    const dl = run.dl;
    while (true) {
        if (breakNow(run)) return false;
        const lock = dl.Lock(name, dos.SHARED_LOCK) orelse return false;
        var fib: dos.FileInfoBlock = .{};
        if (!dl.Examine(lock, &fib)) {
            dl.UnLock(lock);
            return false;
        }
        if (!dl.ExNext(lock, &fib)) {
            dl.UnLock(lock);
            return true; // nothing left in it
        }
        dl.UnLock(lock);

        var path: [max_path:0]u8 = @splat(0);
        if (!join(dl, &path, name, @ptrCast(&fib.file_name))) {
            _ = dl.PrintFault(dos.ERROR_LINE_TOO_LONG, name);
            run.failed = true;
            return false;
        }
        const was = run.failed;
        remove(run, @ptrCast(&path), depth + 1);
        if (run.failed != was) return false; // it will not go; stop here
    }
}

/// A directory and a name into one path, through dos's AddPart.
fn join(dl: *DosBase, into: *[max_path:0]u8, dir: [*:0]const u8, name: [*:0]const u8) bool {
    var i: usize = 0;
    while (dir[i] != 0) : (i += 1) {
        if (i + 1 >= into.len) return false;
        into[i] = dir[i];
    }
    into[i] = 0;
    return dl.AddPart(@ptrCast(into), name, into.len);
}

/// The "$VER:" string every PowerOS module carries, which `Version <file>`
/// looks for. Nothing refers to it, so it needs both an export and a
/// section of its own that program.ld KEEPs: the linker collects unused
/// sections, and a plain constant never reaches the file at all - which is
/// all the comptime reference that used to stand here achieved.
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;
