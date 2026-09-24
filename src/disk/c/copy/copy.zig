// SPDX-License-Identifier: MIT
//! Copy: files and directories, from one place to another. Built against
//! the SDK only.
//!
//!   Copy FROM/M,TO/A,ALL/S,QUIET/S,BUF=BUFFER/K/N,CLONE/S,DATES/S,
//!        NOPRO/S,COM/S,NOREQ/S
//!
//!   Copy file TO ram:                 one file into a directory
//!   Copy file TO ram:other            one file under another name
//!   Copy #?.info TO ram: QUIET        everything a pattern matches
//!   Copy DH0:s TO ram:s ALL           a directory and everything below it
//!   Copy ENVARC: TO RAM:ENV ALL       what S:Startup-Sequence does
//!
//! FROM takes several names, and each of them may be a pattern. With more
//! than one source, or with a pattern, TO has to be a directory and each
//! entry keeps its own name inside it; one source and a TO that is not a
//! directory copies to that exact name.
//!
//! ALL steps into directories, making them on the other side as it goes
//! ("[created]" when it had to). Without it a directory is named and
//! passed over. QUIET says nothing at all.
//!
//! What travels with the bytes: the protection bits always, less the
//! archive bit, unless NOPRO; the date with DATES or CLONE; the comment
//! with COM or CLONE. A handler that does not know one of those packets is
//! not an error - not every file system keeps all three.
//!
//! BUFFER is the copy buffer in bytes. Without it the buffer is the file's
//! own size, at most 64 KiB and at least 1024, so a small file costs one
//! read and a big one does not cost the whole of memory. NOREQ is taken
//! and does nothing: there are no requesters to turn off.
//!
//! Copying a directory into itself would never end, so before stepping
//! into one the destination's parents are walked: if the source is among
//! them it stops with "Infinite loop".

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const rdargs = dos.rdargs;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "Copy";
const VERSION_STRING = "\x00$VER: Copy 1.0 (16.9.2026)\r\n";

const template = "FROM/M,TO/A,ALL/S,QUIET/S,BUF=BUFFER/K/N,CLONE/S,DATES/S,NOPRO/S,COM/S,NOREQ/S";
const arg_from = 0;
const arg_to = 1;
const arg_all = 2;
const arg_quiet = 3;
const arg_buffer = 4;
const arg_clone = 5;
const arg_dates = 6;
const arg_nopro = 7;
const arg_com = 8;
const arg_noreq = 9;
const arg_count = 10;

const MSG_DIR = "%s (Dir)";
const MSG_DIR_CREATE = "   [created]\n";
const MSG_COPIED = "copied.\n";
const MSG_TABIN = "        ";
const MSG_DELETED = "Destination file \"%s\" removed.\n";
const MSG_NOOPEN = "Can't open %s for ";
const MSG_INOUT = "%sput - ";
const MSG_IN = "in";
const MSG_OUT = "out";
const MSG_IOERROR = "Error in %sing - ";
const MSG_READ = "read";
const MSG_WRITE = "writ";
const MSG_RECURS = "\nInfinite loop in \"%s\".\n";
const MSG_DEST_WRONG_DIR = "Destination must be a directory.\n";

const max_path = 256;
/// How wide one level of the listing is.
const tab_size = 8;
/// The most a buffer takes when its size was not asked for.
const max_buffer = 64 * 1024;
const min_buffer = 1024;
/// How deep it goes; each level costs a lock, not a stack frame.
const max_depth = 32;

const Anchor = extern struct {
    ap: dos.AnchorPath = .{},
    buf: [max_path]u8 = @splat(0),
};

const Run = struct {
    sys: *ExecBase,
    dl: *DosBase,
    to: [*:0]const u8,
    all: bool,
    quiet: bool,
    clone: bool,
    dates: bool,
    nopro: bool,
    com: bool,
    /// BUFFER's size, 0 when each file sizes its own.
    buffer: usize,
    /// The destination is a directory, so every entry keeps its own name.
    /// True when more than one thing is being copied; the directory is
    /// made if it was not there.
    into_dir: bool,
    /// More than one FROM was given, whatever any single one of them is.
    many_args: bool = false,
    /// The directory being copied into, as the walk goes down and up.
    outlock: ?*dos.FileLock = null,
    /// More than one thing is being copied, so each is named as it goes.
    many: bool = false,
    level: i32 = 0,
    rc: i32 = dos.RETURN_OK,
    res2: i32 = 0,
    stop: bool = false,
};

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(lib);
    const dl: *DosBase = @ptrCast(lib);

    var argv: [arg_count]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);

    const from = rdargs.multi(argv[arg_from]);
    const to = rdargs.string(argv[arg_to]).?;

    var run: Run = .{
        .sys = sys,
        .dl = dl,
        .to = to,
        .all = argv[arg_all] != 0,
        .quiet = argv[arg_quiet] != 0,
        .clone = argv[arg_clone] != 0,
        .dates = argv[arg_dates] != 0,
        .nopro = argv[arg_nopro] != 0,
        .com = argv[arg_com] != 0,
        .buffer = if (rdargs.number(argv[arg_buffer])) |n| @intCast(@max(n, 1)) else 0,
        .into_dir = false,
        .many_args = from.len > 1,
        .many = from.len > 1,
    };

    const anchor_block = sys.AllocVec(@sizeOf(Anchor), exec.MEMF_CLEAR) orelse {
        _ = dl.PrintFault(dos.ERROR_NO_FREE_STORE, COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer sys.FreeVec(anchor_block);
    const anchor: *Anchor = @ptrCast(@alignCast(anchor_block));

    // With no FROM at all the current directory is the source, which is
    // what "Copy TO ram:" means.
    const nothing = [_][*:0]const u8{""};
    const sources = if (from.len == 0) nothing[0..] else from;

    for (sources) |source| {
        walk(&run, anchor, source);
        if (run.stop) break;
    }
    if (run.outlock) |lock| dl.UnLock(lock);
    _ = dl.Flush(dl.Output());
    _ = dl.SetIoErr(run.res2);
    return run.rc;
}

/// One FROM: everything it names, with the destination directory walking
/// down and up beside it.
fn walk(run: *Run, anchor: *Anchor, source: [*:0]const u8) void {
    const dl = run.dl;
    anchor.* = .{};
    anchor.ap.flags = dos.APF_DOWILD;
    anchor.ap.strlen = anchor.buf.len;
    anchor.ap.break_bits = exec.SIGBREAKF_CTRL_C;

    run.level = 0;
    var err = dl.MatchFirst(source, &anchor.ap);
    defer {
        dl.MatchEnd(&anchor.ap);
        if (run.outlock) |lock| dl.UnLock(lock);
        run.outlock = null;
    }
    if (err != 0) {
        if (err != dos.ERROR_NO_MORE_ENTRIES) failWith(run, err, source);
        return;
    }

    // One thing or many? A pattern, a directory, or more than one FROM all
    // mean more than one thing is being copied, so each is named as it
    // goes and the destination has to be a directory - made if it is not
    // there. A destination that is already a directory takes the entries
    // by their own names whatever the source was, which is what
    // "Copy file RAM:" means.
    const wild = anchor.ap.flags & dos.APF_ITSWILD != 0;
    const source_is_dir = anchor.ap.info.dir_entry_type > 0;
    run.many = run.many_args or wild or source_is_dir;
    run.into_dir = run.many or isDir(run, run.to);

    // A plain directory is stepped into at once: what is copied is what is
    // inside it, and the destination directory is TO itself.
    if (!wild and source_is_dir) {
        anchor.ap.flags |= dos.APF_DODIR;
        err = dl.MatchNext(&anchor.ap);
        if (err != 0 and err != dos.ERROR_NO_MORE_ENTRIES) {
            failWith(run, err, source);
            return;
        }
    }

    if (run.into_dir and !openDestination(run)) return;

    while (err == 0) {
        const ap = &anchor.ap;
        if (ap.flags & dos.APF_DIDDIR != 0) {
            ap.flags &= ~dos.APF_DIDDIR;
            // At the top the source directory itself is done.
            if (run.level == 0) break;
            leaveDir(run, ap);
            err = dl.MatchNext(ap);
            continue;
        }
        if (dl.CheckSignal(exec.SIGBREAKF_CTRL_C) != 0) {
            _ = dl.PrintFault(dos.ERROR_BREAK, null);
            run.rc = dos.RETURN_WARN;
            run.res2 = dos.ERROR_BREAK;
            run.stop = true;
            return;
        }

        if (ap.info.dir_entry_type > 0) {
            if (!run.quiet) {
                tab(run, run.level + 1);
                _ = Printf(dl, MSG_DIR, .{@as([*:0]const u8, @ptrCast(&ap.info.file_name))});
            }
            if (!run.all or run.level >= max_depth) {
                if (!run.quiet) _ = dl.PutStr("\n");
                err = dl.MatchNext(ap);
                continue;
            }
            if (!enterDir(run, ap)) return;
            ap.flags |= dos.APF_DODIR;
            err = dl.MatchNext(ap);
            continue;
        }

        copyFile(run, ap);
        if (run.stop) return;
        err = dl.MatchNext(ap);
    }
    if (err != 0 and err != dos.ERROR_NO_MORE_ENTRIES) failWith(run, err, source);
}

/// Whether a name is there and is a directory.
fn isDir(run: *Run, name: [*:0]const u8) bool {
    const lock = run.dl.Lock(name, dos.SHARED_LOCK) orelse return false;
    defer run.dl.UnLock(lock);
    var fib: dos.FileInfoBlock = .{};
    return run.dl.Examine(lock, &fib) and fib.dir_entry_type > 0;
}

/// The destination directory: locked if it is there, made if it is not.
fn openDestination(run: *Run) bool {
    const dl = run.dl;
    if (dl.Lock(run.to, dos.SHARED_LOCK)) |lock| {
        var fib: dos.FileInfoBlock = .{};
        if (!dl.Examine(lock, &fib)) {
            dl.UnLock(lock);
            failWith(run, dl.IoErr(), run.to);
            return false;
        }
        if (fib.dir_entry_type < 0) {
            dl.UnLock(lock);
            _ = dl.PutStr(MSG_DEST_WRONG_DIR);
            run.rc = dos.RETURN_ERROR;
            run.stop = true;
            return false;
        }
        run.outlock = lock;
        return true;
    }
    const made = dl.CreateDir(run.to) orelse {
        failWith(run, dl.IoErr(), run.to);
        run.stop = true;
        return false;
    };
    dl.UnLock(made);
    if (!run.quiet) _ = Printf(dl, "   %s" ++ MSG_DIR_CREATE, .{run.to});
    run.outlock = dl.Lock(run.to, dos.SHARED_LOCK) orelse {
        failWith(run, dl.IoErr(), run.to);
        run.stop = true;
        return false;
    };
    return true;
}

/// Into a directory below the top: the one on the other side is locked,
/// or made.
fn enterDir(run: *Run, ap: *dos.AnchorPath) bool {
    const dl = run.dl;
    const name: [*:0]const u8 = @ptrCast(&ap.info.file_name);

    if (!run.into_dir) {
        if (!run.quiet) _ = dl.PutStr("\n");
        run.level += 1;
        return true;
    }

    // Copying a directory into itself never ends: the destination's
    // parents are walked, and the source must not be among them.
    const here = dl.CurrentDir(if (ap.last) |n| n.lock else null);
    const inside = dl.Lock(name, dos.SHARED_LOCK);
    _ = dl.CurrentDir(here);
    if (inside) |source_dir| {
        defer dl.UnLock(source_dir);
        var up = dl.DupLock(run.outlock);
        while (up) |lock| {
            if (dl.SameLock(source_dir, lock) == dos.LOCK_SAME) {
                dl.UnLock(lock);
                _ = Printf(dl, MSG_RECURS, .{name});
                run.rc = dos.RETURN_ERROR;
                run.stop = true;
                return false;
            }
            const parent = dl.ParentDir(lock);
            dl.UnLock(lock);
            up = parent;
        }
    }

    const was = dl.CurrentDir(run.outlock);
    var made = false;
    var opened = dl.Lock(name, dos.SHARED_LOCK);
    if (opened == null) {
        opened = dl.CreateDir(name);
        made = true;
    }
    _ = dl.CurrentDir(was);
    const lock = opened orelse {
        if (!run.quiet) _ = dl.PutStr("\n");
        failWith(run, dl.IoErr(), name);
        run.stop = true;
        return false;
    };
    if (!run.quiet) _ = dl.PutStr(if (made) MSG_DIR_CREATE else "\n");
    // The parent stays until the walk comes back up.
    if (run.outlock) |old| dl.UnLock(old);
    run.outlock = lock;
    run.level += 1;
    return true;
}

/// Back out of a directory: the destination goes up with it, and the
/// directory takes the source's date if it was asked for.
fn leaveDir(run: *Run, ap: *dos.AnchorPath) void {
    const dl = run.dl;
    if (run.level > 0) run.level -= 1;
    if (!run.into_dir) return;
    const child = run.outlock orelse return;
    const parent = dl.ParentDir(child);
    dl.UnLock(child);
    run.outlock = parent;
    if (parent != null and (run.clone or run.dates)) {
        const was = dl.CurrentDir(parent);
        _ = dl.SetFileDate(@ptrCast(&ap.info.file_name), &ap.info.date);
        _ = dl.CurrentDir(was);
    }
}

/// One file's bytes, and then what travels with them.
fn copyFile(run: *Run, ap: *dos.AnchorPath) void {
    const dl = run.dl;
    const sys = run.sys;
    const name: [*:0]const u8 = @ptrCast(&ap.info.file_name);

    const was_in = dl.CurrentDir(if (ap.last) |n| n.lock else null);
    const in = dl.Open(name, dos.MODE_OLDFILE);
    _ = dl.CurrentDir(was_in);
    if (in == null) {
        cantOpen(run, name, false);
        return;
    }

    const was_out = dl.CurrentDir(run.outlock);
    const out = if (run.into_dir) dl.Open(name, dos.MODE_NEWFILE) else dl.Open(run.to, dos.MODE_NEWFILE);
    _ = dl.CurrentDir(was_out);
    if (out == null) {
        _ = dl.Close(in);
        cantOpen(run, if (run.into_dir) name else run.to, true);
        return;
    }

    if (run.many and !run.quiet) {
        tab(run, run.level);
        _ = Printf(dl, "   %s..", .{name});
        _ = dl.Flush(dl.Output());
    }

    // The file's own size, within reason: a small file costs one read and
    // a big one does not cost the whole of memory.
    var size: usize = run.buffer;
    if (size == 0) {
        size = @intCast(@min(ap.info.size, max_buffer));
        if (size < min_buffer) size = min_buffer;
    }
    const block = sys.AllocVec(size, exec.MEMF_ANY) orelse {
        _ = dl.Close(in);
        _ = dl.Close(out);
        failWith(run, dos.ERROR_NO_FREE_STORE, name);
        run.stop = true;
        return;
    };
    defer sys.FreeVec(block);
    const bytes: [*]u8 = @ptrCast(block);

    var reading = true;
    var failed = false;
    while (true) {
        if (dl.CheckSignal(exec.SIGBREAKF_CTRL_C) != 0) {
            _ = dl.PrintFault(dos.ERROR_BREAK, null);
            _ = dl.SetIoErr(0);
            failed = true;
            run.stop = true;
            break;
        }
        const got = dl.Read(in, bytes, @intCast(size));
        if (got < 0) {
            failed = true;
            break;
        }
        if (got == 0) break;
        reading = false;
        if (dl.Write(out, bytes, got) != got) {
            failed = true;
            break;
        }
        reading = true;
    }
    const code = if (failed) dl.IoErr() else 0;
    _ = dl.Close(out);
    _ = dl.Close(in);

    if (failed) {
        // A half-written file is worse than none.
        const target: [*:0]const u8 = if (run.into_dir) name else run.to;
        if (code != 0) {
            _ = Printf(dl, MSG_IOERROR, .{@as([*:0]const u8, if (reading) MSG_READ else MSG_WRITE)});
            _ = dl.PrintFault(code, null);
            run.rc = dos.RETURN_ERROR;
            run.res2 = code;
        }
        const was = dl.CurrentDir(run.outlock);
        _ = Printf(dl, MSG_DELETED, .{target});
        _ = dl.DeleteFile(target);
        _ = dl.CurrentDir(was);
        return;
    }

    if (run.many and !run.quiet) _ = dl.PutStr(MSG_COPIED);

    // What travels with the bytes. A handler that doesn't know one of
    // these packets is not a failure: not every file system keeps all
    // three.
    const target: [*:0]const u8 = if (run.into_dir) name else run.to;
    const was = dl.CurrentDir(run.outlock);
    defer _ = dl.CurrentDir(was);
    if (!run.nopro) keep(run, dl.SetProtection(target, ap.info.protection & ~dos.FIBF_ARCHIVE));
    if (run.dates or run.clone) keep(run, dl.SetFileDate(target, &ap.info.date));
    if (run.com or run.clone) keep(run, dl.SetComment(target, @ptrCast(&ap.info.comment)));
}

/// An attribute that would not go on. Only a real refusal counts.
fn keep(run: *Run, done: bool) void {
    if (done) return;
    const code = run.dl.IoErr();
    if (code == dos.ERROR_ACTION_NOT_KNOWN) return;
    _ = run.dl.PrintFault(code, null);
    if (run.rc < dos.RETURN_WARN) run.rc = dos.RETURN_WARN;
    run.res2 = code;
}

fn cantOpen(run: *Run, name: [*:0]const u8, output: bool) void {
    const dl = run.dl;
    const code = dl.IoErr();
    _ = Printf(dl, MSG_NOOPEN, .{name});
    _ = Printf(dl, MSG_INOUT, .{@as([*:0]const u8, if (output) MSG_OUT else MSG_IN)});
    _ = dl.PrintFault(code, null);
    if (run.rc < dos.RETURN_WARN) run.rc = dos.RETURN_WARN;
    run.res2 = code;
}

fn failWith(run: *Run, code: i32, name: [*:0]const u8) void {
    _ = run.dl.PrintFault(code, name);
    run.rc = dos.RETURN_FAIL;
    run.res2 = code;
}

/// One level of the listing.
fn tab(run: *Run, levels: i32) void {
    var left = levels;
    while (left > 0) : (left -= 1) _ = run.dl.WriteChars(MSG_TABIN, tab_size);
}

/// The "$VER:" string every PowerOS module carries, which `Version <file>`
/// looks for. Nothing refers to it, so it needs both an export and a
/// section of its own that program.ld KEEPs.
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;
