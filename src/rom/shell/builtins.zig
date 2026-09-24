// SPDX-License-Identifier: MPL-2.0
//! The shell's built-in commands. Each is a CommandFn that the shell puts
//! on the resident list as a CMD_INTERNAL segment and runs through
//! RunCommand, reading its arguments with ReadArgs as a command on the
//! disk does.
//!
//! CD, Echo, Prompt, Failat, Why, Fault, Path, Resident, Set, Setenv,
//! Alias and their Unset forms, Get, Getenv, Stack, Ask, Run, NewShell,
//! EndCli, Quit, If, Else, Skip, Execute, PIPE, and the words a script
//! needs that do nothing by themselves (EndIf, Lab, EndSkip, .key, .bra,
//! .ket).
//!
//! Notes on a few of them:
//!
//! - **CD** takes a pattern as well as a name: when the name cannot be
//!   locked and the medium is there, the pattern is matched and the one
//!   directory it names becomes the current one. Several is
//!   "More than one directory matches".
//! - **NewShell** opens WINDOW (default CON:) twice, for input and output,
//!   and gives the new shell FROM - or S:Shell-startup, if there is one -
//!   to read before its first line from the console. dos refuses an
//!   interactive shell on a console another shell already reads
//!   (ERROR_OBJECT_IN_USE).
//! - **Run** starts a background shell with SystemTagList. Its streams are
//!   its own: NIL: for input and a fresh handle on the console for output,
//!   because SYS_Asynch hands the streams to the shell, which closes them
//!   at its end, and the caller's own Output() must outlive it.
//! - **Setenv** with no name lists the names in ENV:, where a global
//!   variable is a file, with the List command.
//! - **Stack** sizes are in bytes.
//! - The texts a command prints are Fault's, so the words live in one
//!   place. `%TH` in one of them is a name in a field 17 wide, which
//!   RawDoFmt has no conversion for; `faultName` turns it into `%-17s`.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const UtilityBase = sdk.interface.utility.UtilityBase;
const rdargs = dos.rdargs;
const Printf = dos.stdio.Printf;
const shell = @import("shell.zig");
const execute = @import("execute.zig");
const pipe = @import("pipe.zig");

// The shell's texts (Fault's negative codes, global.h).
const STR_CANT_SET = -141;
const STR_TOO_MANY_MATCHES = -142;
const STR_FAULT = -155;
const STR_TH_SYSTEM = -156;
const STR_TH_INTERNAL = -157;
const STR_TH_DISABLED = -158;
const STR_NAME = -159;
const STR_TH_USE_COUNT = -160;
const STR_NEWSHELL_FAILED = -145;
const STR_CURRENT_STACK = -146;
const STR_STACK_LARGE = -147;
const STR_STACK_SMALL = -148;
const STR_LAST_MSG_FAILED = -150;
const STR_NO_RETURN_CODE = -151;
const STR_CURRENT_DIR = -152;
const STR_BAD_RETURN_CODE = -153;
const STR_FAIL_LIMIT = -154;
const STR_NEW_SHELL = -129;
const STR_NOT_EXECUTE = -143;
const STR_MISSING_ELSE = -144;
const MINSTACK = 1600;
const ENVMAX = 256;

pub const Builtin = struct { name: [*:0]const u8, command: dos.CommandFn };

/// The built-ins' names, each with its code.
pub const table = [_]Builtin{
    .{ .name = ".key", .command = &cmdEndif },
    .{ .name = ".bra", .command = &cmdEndif },
    .{ .name = ".ket", .command = &cmdEndif },
    .{ .name = "Why", .command = &cmdWhy },
    .{ .name = "Unsetenv", .command = &cmdSet },
    .{ .name = "Unset", .command = &cmdSet },
    .{ .name = "Unalias", .command = &cmdSet },
    .{ .name = "Stack", .command = &cmdStack },
    .{ .name = "Skip", .command = &cmdSkip },
    .{ .name = "Setenv", .command = &cmdSet },
    .{ .name = "Set", .command = &cmdSet },
    .{ .name = "Run", .command = &cmdRun },
    .{ .name = "Resident", .command = &cmdResident },
    .{ .name = "Quit", .command = &cmdQuit },
    .{ .name = "Prompt", .command = &cmdPrompt },
    .{ .name = "PIPE", .command = &pipe.run },
    .{ .name = "Path", .command = &cmdPath },
    .{ .name = "NewShell", .command = &cmdNewShell },
    .{ .name = "NewCLI", .command = &cmdNewShell },
    .{ .name = "Lab", .command = &cmdEndif },
    .{ .name = "If", .command = &cmdIf },
    .{ .name = "Getenv", .command = &cmdGet },
    .{ .name = "Get", .command = &cmdGet },
    .{ .name = "Fault", .command = &cmdFault },
    .{ .name = "Failat", .command = &cmdFailat },
    .{ .name = "Execute", .command = &execute.run },
    .{ .name = "EndSkip", .command = &cmdEndif },
    .{ .name = "EndShell", .command = &cmdEndCli },
    .{ .name = "EndIf", .command = &cmdEndif },
    .{ .name = "EndCLI", .command = &cmdEndCli },
    .{ .name = "Else", .command = &cmdElse },
    .{ .name = "Echo", .command = &cmdEcho },
    .{ .name = "CD", .command = &cmdCd },
    .{ .name = "Ask", .command = &cmdAsk },
    .{ .name = "Alias", .command = &cmdSet },
};

// --- Helpers ---

fn openDos(sys: *ExecBase) ?*DosBase {
    return @ptrCast(sys.OpenLibrary(dos.DOSNAME, 0) orelse return null);
}

fn closeDos(sys: *ExecBase, dl: *DosBase) void {
    sys.CloseLibrary(dl.lib());
}

fn thisProcess(sys: *ExecBase) *dos.Process {
    return @fieldParentPtr("task", sys.FindTask(null).?);
}

/// ReadArgs, and its fault printed if it fails.
fn getArgs(dl: *DosBase, template: [*:0]const u8, argv: []usize) ?*dos.RDArgs {
    @memset(argv, 0);
    const rda = dl.ReadArgs(template, argv.ptr, null);
    if (rda == null) _ = dl.PrintFault(dl.IoErr(), null);
    return rda;
}

/// A text of Fault's with one %ld (a long: RawDoFmt's %ld is 64 bits).
fn faultNumber(dl: *DosBase, code: i32, value: i64) bool {
    var text: [64]u8 = undefined;
    if (dl.Fault(code, null, &text, text.len) <= 0) return false;
    const stream = exec.fmtStream(.{value});
    _ = dl.VPrintf(@ptrCast(&text), &stream);
    return true;
}

/// A text of Fault's that names something in a column. Those texts are
/// kept with a `%TH` in them, which is a string in a field 0x11 (17) wide;
/// RawDoFmt has no such conversion, so it becomes `%-17s` here.
fn faultName(dl: *DosBase, code: i32, name: [*:0]const u8) void {
    var text: [64]u8 = undefined;
    const n = dl.Fault(code, null, &text, text.len);
    if (n <= 0) return;
    const raw = text[0..@intCast(n)];
    var line: [80]u8 = undefined;
    const at = std.mem.indexOf(u8, raw, "%TH") orelse {
        _ = dl.PutStr(@ptrCast(&text));
        return;
    };
    const out = std.fmt.bufPrintZ(&line, "{s}%-17s{s}", .{ raw[0..at], raw[at + 3 ..] }) catch return;
    const stream = exec.fmtStream(.{name});
    _ = dl.VPrintf(out.ptr, &stream);
}

// --- The commands ---

/// The one directory a pattern names, for CD. Null with `code` set when
/// nothing matched, when more than one directory did, or when the one that
/// did could not be locked.
fn matchOneDir(dl: *DosBase, ub: *UtilityBase, sys: *ExecBase, pattern: [*:0]const u8, code: *i32) ?*dos.FileLock {
    const Anchor = extern struct { ap: dos.AnchorPath = .{}, buf: [256]u8 = @splat(0) };
    const block = sys.AllocVec(@sizeOf(Anchor), exec.MEMF_CLEAR) orelse {
        code.* = dos.ERROR_NO_FREE_STORE;
        return null;
    };
    defer sys.FreeVec(block);
    const anchor: *Anchor = @ptrCast(@alignCast(block));
    anchor.ap.flags = dos.APF_DOWILD;
    anchor.ap.strlen = anchor.buf.len;
    anchor.ap.break_bits = exec.SIGBREAKF_CTRL_C;

    var tokens: [512]u8 = undefined;
    if (ub.ParsePattern(pattern, &tokens, tokens.len) <= 0) {
        code.* = dos.ERROR_OBJECT_NOT_FOUND;
        return null;
    }
    if (dl.MatchFirst(pattern, &anchor.ap) != 0) {
        dl.MatchEnd(&anchor.ap);
        code.* = dos.ERROR_DIR_NOT_FOUND;
        return null;
    }
    var found: ?*dos.FileLock = null;
    code.* = 0;
    while (true) {
        if (anchor.ap.info.dir_entry_type >= 0) {
            if (found == null) {
                // The name is the entry's own, so its directory has to be
                // the current one while it is locked.
                const here = dl.CurrentDir(if (anchor.ap.last) |n| n.lock else null);
                found = dl.Lock(@ptrCast(&anchor.ap.info.file_name), dos.SHARED_LOCK);
                _ = dl.CurrentDir(here);
                if (found == null) code.* = dl.IoErr();
            } else {
                code.* = STR_TOO_MANY_MATCHES;
            }
        }
        if (code.* != 0 or dl.MatchNext(&anchor.ap) != 0) break;
    }
    dl.MatchEnd(&anchor.ap);
    if (code.* != 0) {
        if (found) |l| dl.UnLock(l);
        return null;
    }
    if (found == null) code.* = dos.ERROR_DIR_NOT_FOUND;
    return found;
}

/// CD [DIR]: into a directory (its name as the CLI's), or its name shown.
/// DIR may be a pattern, as long as it names one directory.
pub fn cmdCd(sys: *ExecBase, _: [*]const u8, _: usize) callconv(.c) i32 {
    const dl = openDos(sys) orelse return dos.RETURN_FAIL;
    defer closeDos(sys, dl);
    const ub_lib = sys.OpenLibrary(sdk.interface.utility.NAME, 1) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(ub_lib);
    const ub: *UtilityBase = @ptrCast(ub_lib);
    var argv: [1]usize = undefined;
    const rda = getArgs(dl, "DIR", &argv) orelse return dos.RETURN_FAIL;
    defer dl.FreeArgs(rda);
    var rc: i32 = dos.RETURN_OK;
    var rc2: i32 = 0;
    var data: [256]u8 = undefined;
    body: {
        if (rdargs.string(argv[0])) |dir| {
            const lock = dl.Lock(dir, dos.SHARED_LOCK) orelse lock: {
                rc2 = dl.IoErr();
                // No medium at all is no reason to go looking; anything
                // else may still be a pattern that names a directory.
                if (rc2 == dos.ERROR_NO_DISK or rc2 == dos.ERROR_DEVICE_NOT_MOUNTED) {
                    rc = dos.RETURN_FAIL;
                    break :body;
                }
                break :lock matchOneDir(dl, ub, sys, dir, &rc2) orelse {
                    rc = dos.RETURN_FAIL;
                    break :body;
                };
            };
            var fib: dos.FileInfoBlock = .{};
            if (!dl.Examine(lock, &fib) or fib.dir_entry_type < 0) {
                rc = dos.RETURN_FAIL;
                rc2 = dl.IoErr();
                if (rc2 == 0 or fib.dir_entry_type < 0) rc2 = dos.ERROR_OBJECT_WRONG_TYPE;
                dl.UnLock(lock);
                break :body;
            }
            if (dl.CurrentDir(lock)) |old| dl.UnLock(old);
        }
        if (!dl.NameFromLock(thisProcess(sys).current_dir, &data, 255)) {
            rc2 = dl.IoErr();
            if (rc2 == dos.ERROR_LINE_TOO_LONG) {
                rc2 = 0;
            } else {
                rc = dos.RETURN_ERROR;
                break :body;
            }
        }
        if (argv[0] != 0) {
            if (!dl.SetCurrentDirName(@ptrCast(&data))) {
                rc2 = dl.IoErr();
                rc = dos.RETURN_FAIL;
            }
        } else {
            _ = Printf(dl, "%s\n", .{@as([:0]const u8, std.mem.span(@as([*:0]u8, @ptrCast(&data))))});
        }
    }
    if (rc != 0 and rc2 != 0) {
        _ = dl.PrintFault(rc2, null);
        if (rc2 == dos.ERROR_LINE_TOO_LONG) {
            rc = 0;
            rc2 = 0;
        }
    }
    _ = dl.SetIoErr(rc2);
    return rc;
}

/// ECHO [strings] [NOLINE] [FIRST n] [LEN n] [TO file].
pub fn cmdEcho(sys: *ExecBase, _: [*]const u8, _: usize) callconv(.c) i32 {
    const dl = openDos(sys) orelse return dos.RETURN_FAIL;
    defer closeDos(sys, dl);
    var argv: [5]usize = undefined;
    const rda = getArgs(dl, "/M,NOLINE/S,FIRST/K/N,LEN/K/N,TO/K", &argv) orelse return dos.RETURN_ERROR;
    defer dl.FreeArgs(rda);
    const fh = if (rdargs.string(argv[4])) |to| (dl.Open(to, dos.MODE_NEWFILE) orelse return dos.RETURN_ERROR) else dl.Output();
    defer if (argv[4] != 0) {
        _ = dl.Close(fh);
    };
    const strings = rdargs.multi(argv[0]);
    if (strings.len == 0) return dos.RETURN_OK;
    for (strings, 0..) |text, i| {
        var msg: []const u8 = std.mem.span(text);
        if (rdargs.number(argv[2])) |first_arg| {
            var first: isize = first_arg - 1;
            if (first >= @as(isize, @intCast(msg.len))) first = @as(isize, @intCast(msg.len)) - 1;
            if (first >= 0) msg = msg[@intCast(first)..];
        }
        if (rdargs.number(argv[3])) |len| {
            if (len >= 0 and len < msg.len) {
                const n: usize = @intCast(len);
                msg = if (argv[2] == 0) msg[msg.len - n ..] else msg[0..n];
            }
        }
        if (i > 0) _ = dl.FPutC(fh, ' ');
        _ = dl.FWrite(fh, msg.ptr, @intCast(msg.len));
    }
    if (argv[1] == 0) {
        _ = dl.FPutC(fh, '\n');
    } else {
        _ = dl.Flush(fh);
    }
    return dos.RETURN_OK;
}

/// PROMPT [text]: default "%N.%S> ".
pub fn cmdPrompt(sys: *ExecBase, _: [*]const u8, _: usize) callconv(.c) i32 {
    const dl = openDos(sys) orelse return dos.RETURN_FAIL;
    defer closeDos(sys, dl);
    var argv: [1]usize = undefined;
    const rda = getArgs(dl, "PROMPT", &argv) orelse return dos.RETURN_ERROR;
    defer dl.FreeArgs(rda);
    if (!dl.SetPrompt(rdargs.string(argv[0]) orelse "%N.%S> ")) {
        _ = dl.PrintFault(dl.IoErr(), null);
        return dos.RETURN_ERROR;
    }
    return dos.RETURN_OK;
}

/// FAILAT [limit]: the return code scripts stop at, or shown.
pub fn cmdFailat(sys: *ExecBase, _: [*]const u8, _: usize) callconv(.c) i32 {
    const dl = openDos(sys) orelse return dos.RETURN_FAIL;
    defer closeDos(sys, dl);
    var argv: [1]usize = undefined;
    const rda = getArgs(dl, "RCLIM/N", &argv) orelse return dos.RETURN_FAIL;
    defer dl.FreeArgs(rda);
    const cli = dl.Cli() orelse return dos.RETURN_FAIL;
    if (rdargs.number(argv[0])) |level| {
        if (level > 0) {
            cli.fail_level = level;
            return dos.RETURN_OK;
        }
        _ = dl.PrintFault(STR_BAD_RETURN_CODE, null);
        return dos.RETURN_FAIL;
    }
    return if (faultNumber(dl, STR_FAIL_LIMIT, cli.fail_level)) dos.RETURN_OK else dos.RETURN_FAIL;
}

/// WHY: why the last command failed (cli_Result2).
pub fn cmdWhy(sys: *ExecBase, _: [*]const u8, _: usize) callconv(.c) i32 {
    const dl = openDos(sys) orelse return dos.RETURN_FAIL;
    defer closeDos(sys, dl);
    var argv: [1]usize = undefined;
    const rda = getArgs(dl, "", &argv) orelse return dos.RETURN_ERROR;
    defer dl.FreeArgs(rda);
    const code = if (dl.Cli()) |cli| cli.result2 else 0;
    if (code != 0) {
        var header: [48]u8 = undefined;
        _ = dl.Fault(STR_LAST_MSG_FAILED, null, &header, 44);
        _ = dl.PrintFault(code, @ptrCast(&header));
    } else {
        _ = dl.PrintFault(STR_NO_RETURN_CODE, null);
    }
    _ = dl.SetIoErr(code);
    return dos.RETURN_WARN; // so the shell keeps cli_Result2
}

/// FAULT codes...: each one's text.
pub fn cmdFault(sys: *ExecBase, _: [*]const u8, _: usize) callconv(.c) i32 {
    const dl = openDos(sys) orelse return dos.RETURN_FAIL;
    defer closeDos(sys, dl);
    var argv: [1]usize = undefined;
    const rda = getArgs(dl, "/N/M", &argv) orelse return dos.RETURN_ERROR;
    defer dl.FreeArgs(rda);
    var rc: i32 = dos.RETURN_OK;
    var code: i32 = 0;
    for (0..rdargs.multi(argv[0]).len) |i| {
        rc = dos.RETURN_WARN;
        code = rdargs.multiNumber(argv[0], i);
        _ = faultNumber(dl, STR_FAULT, code);
        _ = dl.PrintFault(code, "");
    }
    _ = dl.SetIoErr(code);
    return rc;
}

/// ENDCLI, ENDSHELL: this shell ends after the command.
pub fn cmdEndCli(sys: *ExecBase, _: [*]const u8, _: usize) callconv(.c) i32 {
    const dl = openDos(sys) orelse return dos.RETURN_FAIL;
    defer closeDos(sys, dl);
    var argv: [1]usize = undefined;
    const rda = getArgs(dl, "", &argv) orelse return dos.RETURN_ERROR;
    defer dl.FreeArgs(rda);
    shell.doEnd(sys, dl);
    return dos.RETURN_OK;
}

/// QUIT [rc]: the rest of the script skipped.
pub fn cmdQuit(sys: *ExecBase, _: [*]const u8, _: usize) callconv(.c) i32 {
    const dl = openDos(sys) orelse return dos.RETURN_FAIL;
    defer closeDos(sys, dl);
    var argv: [1]usize = undefined;
    const rda = getArgs(dl, "RC/N", &argv) orelse return dos.RETURN_ERROR;
    defer dl.FreeArgs(rda);
    const rc = rdargs.number(argv[0]) orelse dos.RETURN_OK;
    var code: i32 = 0;
    if (rc < 0) {
        code = dos.ERROR_LINE_TOO_LONG;
        _ = dl.PrintFault(code, null);
        _ = dl.SetIoErr(code);
        return dos.RETURN_ERROR;
    }
    if (dl.Cli()) |cli| {
        code = cli.result2;
        if (cli.current_input != cli.standard_input) {
            _ = dl.SelectInput(cli.current_input);
            var eat: [128]u8 = undefined;
            while (dl.FGets(dl.Input(), &eat, eat.len) != null) {}
        }
    }
    _ = dl.SetIoErr(code);
    return rc;
}

/// PATH [dirs] [ADD] [SHOW] [RESET] [REMOVE] [QUIET]: the command path.
pub fn cmdPath(sys: *ExecBase, _: [*]const u8, _: usize) callconv(.c) i32 {
    const dl = openDos(sys) orelse return dos.RETURN_FAIL;
    defer closeDos(sys, dl);
    var argv: [6]usize = undefined;
    const rda = getArgs(dl, "PATH/M,ADD/S,SHOW/S,RESET/S,REMOVE/S,QUIET/S", &argv) orelse return dos.RETURN_ERROR;
    defer dl.FreeArgs(rda);
    const cli = dl.Cli() orelse return dos.RETURN_ERROR;
    var show = argv[2] != 0;
    if (argv[0] == 0 and argv[1] == 0 and argv[3] == 0 and argv[4] == 0) show = true;
    const remove = argv[4] != 0;
    if (argv[3] != 0) {
        var node = cli.command_dir;
        while (node) |n| {
            node = n.next;
            dl.UnLock(n.lock);
            sys.FreeVec(n);
        }
        cli.command_dir = null;
    }
    for (rdargs.multi(argv[0])) |dir| {
        const lock = dl.Lock(dir, dos.SHARED_LOCK) orelse {
            _ = dl.PrintFault(dl.IoErr(), dir);
            return dos.RETURN_ERROR;
        };
        var fib: dos.FileInfoBlock = .{};
        if (!dl.Examine(lock, &fib) or fib.dir_entry_type < 0) {
            dl.UnLock(lock);
            _ = dl.PrintFault(dos.ERROR_OBJECT_WRONG_TYPE, dir);
            return dos.RETURN_ERROR;
        }
        // on the list already? (added: skipped; REMOVE: taken off)
        var link: *?*dos.PathNode = &cli.command_dir;
        var seen = false;
        while (link.*) |n| {
            if (dl.SameLock(n.lock, lock) == dos.LOCK_SAME) {
                seen = true;
                if (remove) {
                    link.* = n.next;
                    dl.UnLock(n.lock);
                    sys.FreeVec(n);
                }
                break;
            }
            link = &n.next;
        }
        if (seen or remove) {
            dl.UnLock(lock);
            continue;
        }
        const block = sys.AllocVec(@sizeOf(dos.PathNode), exec.MEMF_CLEAR) orelse {
            dl.UnLock(lock);
            _ = dl.PrintFault(dos.ERROR_NO_FREE_STORE, null);
            return dos.RETURN_ERROR;
        };
        const node: *dos.PathNode = @ptrCast(@alignCast(block));
        node.* = .{ .lock = lock };
        link.* = node;
    }
    if (show) {
        _ = dl.PrintFault(STR_CURRENT_DIR, null);
        var node = cli.command_dir;
        while (node) |n| : (node = n.next) {
            if (dl.CheckSignal(exec.SIGBREAKF_CTRL_C) != 0) {
                _ = dl.PrintFault(dos.ERROR_BREAK, null);
                break;
            }
            var name: [ENVMAX]u8 = undefined;
            if (dl.NameFromLock(n.lock, &name, name.len)) {
                _ = dl.PutStr(@ptrCast(&name));
                _ = dl.PutStr("\n");
            } else {
                _ = dl.PrintFault(dl.IoErr(), null);
            }
        }
        _ = dl.PutStr("C:\n");
    }
    return dos.RETURN_OK;
}

const AddHow = struct {
    /// FORCE: add it even without the P bit.
    force: bool,
    /// SYSTEM: a segment the shell doesn't run and Resident won't remove.
    system: bool,
    /// REPLACE: something of that name has to be there already, and its
    /// code is what changes.
    replace: bool,
};

/// RESIDENT name [file] [ADD|REPLACE]: the file loaded (LoadSeg) and put on
/// the resident list under `name`, so it runs from memory until it is
/// removed. A built-in that was removed (disabled) goes back on instead.
/// A file needs the P bit (pure: several processes may run the one
/// copy) unless FORCE is given.
fn addResident(dl: *DosBase, name: [*:0]const u8, file: [*:0]const u8, how: AddHow) i32 {
    // Already on the list?
    _ = dl.LockSegmentList(false);
    const found = dl.FindSegment(name, null, false) orelse dl.FindSegment(name, null, true);
    var code: i32 = 0;
    var warn = false;
    var replaced = false;
    var old: ?*dos.Segment = null;
    if (how.replace and found == null) {
        // REPLACE wants something to replace.
        code = dos.ERROR_OBJECT_NOT_FOUND;
        warn = true;
    } else if (found) |s| {
        if (s.uc > 0) {
            code = dos.ERROR_OBJECT_IN_USE; // a shell is running it
        } else if (s.uc <= dos.CMD_INTERNAL) {
            s.uc = dos.CMD_INTERNAL; // a built-in that was removed, back on
            replaced = true;
        } else if (s.uc < 0) {
            code = dos.ERROR_DELETE_PROTECTED; // system code stays
        } else {
            old = s; // a user segment nobody runs: it makes way
        }
    }
    dl.UnLockSegmentList();
    if (replaced) return dos.RETURN_OK;
    if (code != 0) {
        _ = dl.PrintFault(code, name);
        _ = dl.SetIoErr(code);
        return if (warn) dos.RETURN_WARN else dos.RETURN_ERROR;
    }

    if (!how.force) {
        const lock = dl.Lock(file, dos.SHARED_LOCK) orelse {
            const err = dl.IoErr();
            _ = dl.PrintFault(err, file);
            _ = dl.SetIoErr(err);
            return dos.RETURN_ERROR;
        };
        var fib: dos.FileInfoBlock = .{};
        const pure = dl.Examine(lock, &fib) and fib.protection & dos.FIBF_PURE != 0;
        dl.UnLock(lock);
        if (!pure) { // "object not pure"
            _ = dl.PrintFault(dos.ERROR_OBJECT_WRONG_TYPE, file);
            _ = dl.SetIoErr(dos.ERROR_OBJECT_WRONG_TYPE);
            return dos.RETURN_ERROR;
        }
    }

    const seg = dl.LoadSeg(file) orelse {
        const err = dl.IoErr();
        _ = dl.PrintFault(err, file);
        _ = dl.SetIoErr(err);
        return dos.RETURN_ERROR;
    };
    const entry = seg.entry orelse {
        dl.UnLoadSeg(seg);
        _ = dl.PrintFault(dos.ERROR_FILE_NOT_OBJECT, file);
        _ = dl.SetIoErr(dos.ERROR_FILE_NOT_OBJECT);
        return dos.RETURN_ERROR;
    };
    if (old) |s| _ = dl.RemSegment(s); // its code goes with it
    const seg_type: i32 = if (how.system) dos.CMD_SYSTEM else 0;
    if (!dl.AddSegment(name, &.{ .command = @ptrCast(@alignCast(entry)) }, seg_type)) {
        const err = dl.IoErr();
        dl.UnLoadSeg(seg);
        _ = dl.PrintFault(err, name);
        _ = dl.SetIoErr(err);
        return dos.RETURN_ERROR;
    }
    // The loaded code belongs to the segment now: RemSegment unloads it.
    _ = dl.LockSegmentList(false);
    if (dl.FindSegment(name, null, how.system)) |s| s.seg_list = seg;
    dl.UnLockSegmentList();
    return dos.RETURN_OK;
}

/// RESIDENT [name [file]] [REMOVE] [ADD] [REPLACE] [FORCE] [SYSTEM]: the
/// resident list, a command taken off it (a built-in is disabled), or a
/// file loaded onto it.
pub fn cmdResident(sys: *ExecBase, _: [*]const u8, _: usize) callconv(.c) i32 {
    const dl = openDos(sys) orelse return dos.RETURN_FAIL;
    defer closeDos(sys, dl);
    var argv: [7]usize = undefined;
    const rda = getArgs(dl, "NAME,FILE,REMOVE/S,ADD/S,REPLACE/S,PURE=FORCE/S,SYSTEM/S", &argv) orelse return dos.RETURN_ERROR;
    defer dl.FreeArgs(rda);
    const name = rdargs.string(argv[0]) orelse rdargs.string(argv[1]);
    if (name) |n| {
        if (argv[2] == 0) return addResident(dl, dl.FilePart(n), rdargs.string(argv[1]) orelse n, .{
            .force = argv[5] != 0,
            .system = argv[6] != 0,
            .replace = argv[4] != 0,
        });
        const part = dl.FilePart(n);
        _ = dl.LockSegmentList(false);
        const seg = dl.FindSegment(part, null, false) orelse dl.FindSegment(part, null, true);
        var code: i32 = 0;
        var remove_it: ?*dos.Segment = null;
        if (seg) |s| {
            if (s.uc <= dos.CMD_INTERNAL) {
                s.uc = dos.CMD_DISABLED;
            } else if (s.uc < 0) {
                code = dos.ERROR_OBJECT_IN_USE;
            } else {
                remove_it = s;
            }
        } else {
            code = dos.ERROR_OBJECT_NOT_FOUND;
        }
        dl.UnLockSegmentList();
        if (remove_it) |s| {
            if (!dl.RemSegment(s)) code = dl.IoErr();
        }
        if (code != 0) {
            _ = dl.PrintFault(code, part);
            _ = dl.SetIoErr(code);
            return dos.RETURN_WARN;
        }
        return dos.RETURN_OK;
    }
    // The header and the three fixed lines are texts of Fault's, so the
    // words live in one place.
    var label_name: [16]u8 = undefined;
    if (dl.Fault(STR_NAME, null, &label_name, 8) > 0) {
        faultName(dl, STR_TH_USE_COUNT, @ptrCast(&label_name));
    }
    var seg = dl.LockSegmentList(true);
    defer dl.UnLockSegmentList();
    while (seg) |s| : (seg = s.next) {
        if (dl.CheckSignal(exec.SIGBREAKF_CTRL_C) != 0) {
            _ = dl.PrintFault(dos.ERROR_BREAK, null);
            break;
        }
        const label: [*:0]const u8 = s.name;
        if (s.uc == dos.CMD_DISABLED) {
            faultName(dl, STR_TH_DISABLED, label);
        } else if (s.uc <= dos.CMD_INTERNAL) {
            faultName(dl, STR_TH_INTERNAL, label);
        } else if (s.uc >= 0) {
            _ = Printf(dl, "%-17s %4d\n", .{ @as([:0]const u8, std.mem.span(label)), s.uc });
        } else if (argv[6] != 0) {
            faultName(dl, STR_TH_SYSTEM, label);
        }
    }
    return dos.RETURN_OK;
}

/// SET, SETENV, ALIAS [name [value]] and UNSET, UNSETENV, UNALIAS name:
/// which one is the command's name (GetProgramName).
pub fn cmdSet(sys: *ExecBase, _: [*]const u8, _: usize) callconv(.c) i32 {
    const dl = openDos(sys) orelse return dos.RETURN_FAIL;
    defer closeDos(sys, dl);
    const ub_lib = sys.OpenLibrary(sdk.interface.utility.NAME, 1) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(ub_lib);
    const ub: *UtilityBase = @ptrCast(ub_lib);
    var program: [32]u8 = @splat(0);
    _ = dl.GetProgramName(&program, 31);
    const command = dl.FilePart(@ptrCast(&program));
    const len = std.mem.len(command);
    const remove = len > 0 and ub.ToUpper(command[0]) == 'U';
    const kind = if (remove) len - 2 else len; // unsetenv: 8 - 2 = 6
    const mode: u32 = switch (kind) {
        6 => dos.GVF_GLOBAL_ONLY | dos.LV_VAR, // setenv
        5 => dos.GVF_LOCAL_ONLY | dos.LV_ALIAS, // alias
        else => dos.GVF_LOCAL_ONLY | dos.LV_VAR, // set
    };
    var argv: [2]usize = undefined;
    const rda = getArgs(dl, if (remove) "NAME" else "NAME,STRING/F", &argv) orelse return dos.RETURN_ERROR;
    defer dl.FreeArgs(rda);
    if (rdargs.string(argv[0])) |name| {
        if (std.mem.len(name) > 32) {
            _ = dl.PrintFault(dos.ERROR_LINE_TOO_LONG, null);
            return dos.RETURN_ERROR;
        }
        if (remove) {
            _ = dl.DeleteVar(name, mode);
            return dos.RETURN_OK;
        }
        if (rdargs.string(argv[1])) |value| {
            const n: isize = @intCast(@min(std.mem.len(value), 255));
            if (!dl.SetVar(name, value, n, mode)) {
                var text: [48]u8 = undefined;
                if (dl.Fault(STR_CANT_SET, null, &text, text.len) > 0) {
                    const stream = exec.fmtStream(.{@as([:0]const u8, std.mem.span(name))});
                    _ = dl.VPrintf(@ptrCast(&text), &stream);
                }
                return dos.RETURN_ERROR;
            }
            return dos.RETURN_OK;
        }
        if (ub.Stricmp(command, "alias") == 0) {
            var value: [256]u8 = undefined;
            if (dl.GetVar(name, &value, 255, mode) < 0) {
                _ = dl.SetIoErr(dos.ERROR_OBJECT_NOT_FOUND);
                return dos.RETURN_WARN;
            }
            _ = Printf(dl, "%s\n", .{@as([:0]const u8, std.mem.span(@as([*:0]u8, @ptrCast(&value))))});
        }
        return dos.RETURN_OK;
    }
    if (mode & dos.GVF_GLOBAL_ONLY != 0) return listGlobals(dl);
    const proc = thisProcess(sys);
    if (proc.local_vars.head == null) return dos.RETURN_OK;
    var node = proc.local_vars.head;
    while (node) |n| : (node = n.succ) {
        if (n.succ == null) break;
        if (dl.CheckSignal(exec.SIGBREAKF_CTRL_C) != 0) {
            _ = dl.PrintFault(dos.ERROR_BREAK, null);
            break;
        }
        const v: *dos.LocalVar = @ptrCast(n);
        if (v.var_type != (mode & 0xFF)) continue;
        var value: [256]u8 = undefined;
        var shown: usize = 0;
        if (v.flags & dos.GVF_BINARY_VAR != 0) {
            @memcpy(value[0..8], "[BINARY]");
            shown = 8;
        } else {
            shown = @min(v.len, 255);
            @memcpy(value[0..shown], v.value[0..shown]);
            for (value[0..shown]) |*c| {
                if (c.* == 0x1B or c.* == 0x9B) c.* = 127; // no escapes on the terminal
            }
        }
        value[shown] = 0;
        _ = Printf(dl, "%-17s %s\n", .{ @as([:0]const u8, std.mem.span(v.name)), @as([:0]const u8, value[0..shown :0]) });
    }
    return dos.RETURN_OK;
}

/// Setenv without a name: the names in ENV:, which is where a global
/// variable is a file, listed by the List command.
fn listGlobals(dl: *DosBase) i32 {
    _ = dl.SystemTagList("List env: QUICK NOHEAD FILES", null);
    return dos.RETURN_OK;
}

/// GET, GETENV name: a local (Get) or global (Getenv) variable's value.
pub fn cmdGet(sys: *ExecBase, _: [*]const u8, _: usize) callconv(.c) i32 {
    const dl = openDos(sys) orelse return dos.RETURN_FAIL;
    defer closeDos(sys, dl);
    const ub_lib = sys.OpenLibrary(sdk.interface.utility.NAME, 1) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(ub_lib);
    const ub: *UtilityBase = @ptrCast(ub_lib);
    var argv: [1]usize = undefined;
    const rda = getArgs(dl, "NAME/A", &argv) orelse return dos.RETURN_ERROR;
    defer dl.FreeArgs(rda);
    var program: [32]u8 = @splat(0);
    var mode: u32 = dos.GVF_LOCAL_ONLY | dos.LV_VAR;
    if (dl.GetProgramName(&program, 31) and ub.Stricmp(dl.FilePart(@ptrCast(&program)), "getenv") == 0) mode = dos.GVF_GLOBAL_ONLY | dos.LV_VAR;
    var value: [ENVMAX + 1]u8 = undefined;
    const got = dl.GetVar(rdargs.string(argv[0]).?, &value, ENVMAX, mode);
    if (got < 0) {
        _ = dl.PrintFault(dl.IoErr(), null);
        return dos.RETURN_WARN;
    }
    var len: usize = std.mem.len(@as([*:0]u8, @ptrCast(&value)));
    const rc: i32 = if (len == ENVMAX - 1) dos.RETURN_WARN else dos.RETURN_OK;
    if (len == 0 or value[len - 1] != '\n') {
        value[len] = '\n';
        len += 1;
    }
    _ = dl.WriteChars(&value, @intCast(len));
    return rc;
}

/// STACK [size]: the stack commands get (bytes), or shown.
pub fn cmdStack(sys: *ExecBase, _: [*]const u8, _: usize) callconv(.c) i32 {
    const dl = openDos(sys) orelse return dos.RETURN_FAIL;
    defer closeDos(sys, dl);
    var argv: [1]usize = undefined;
    const rda = getArgs(dl, "SIZE/N", &argv) orelse return dos.RETURN_ERROR;
    defer dl.FreeArgs(rda);
    const cli = dl.Cli();
    var rc: i32 = dos.RETURN_ERROR;
    var rc2: i32 = 0;
    if (rdargs.number(argv[0])) |size| {
        rc2 = STR_STACK_SMALL;
        if (size >= MINSTACK) {
            rc2 = STR_STACK_LARGE;
            if (sys.AllocVec(@intCast(size), 0)) |probe| {
                sys.FreeVec(probe);
                rc2 = 0;
                rc = dos.RETURN_OK;
                if (cli) |c| c.default_stack = @intCast(size);
            }
        }
    } else {
        const size: i64 = if (cli) |c| c.default_stack else 0;
        if (faultNumber(dl, STR_CURRENT_STACK, size)) rc = dos.RETURN_OK;
    }
    if (rc != dos.RETURN_OK) _ = dl.PrintFault(rc2, null);
    _ = dl.SetIoErr(rc2);
    return rc;
}

/// ASK prompt: YES answers 5, anything else 0.
pub fn cmdAsk(sys: *ExecBase, _: [*]const u8, _: usize) callconv(.c) i32 {
    const dl = openDos(sys) orelse return dos.RETURN_FAIL;
    defer closeDos(sys, dl);
    var argv: [1]usize = undefined;
    const rda = getArgs(dl, "PROMPT/A", &argv) orelse return dos.RETURN_ERROR;
    defer dl.FreeArgs(rda);
    var query: [2]usize = undefined;
    const answer = while (true) {
        _ = Printf(dl, "%s ", .{@as([:0]const u8, std.mem.span(rdargs.string(argv[0]).?))});
        _ = dl.Flush(dl.Output());
        query = .{ 0, 0 };
        if (dl.ReadArgs("Y=YES/S,N=NO/S", &query, null)) |got| break got;
    };
    dl.FreeArgs(answer);
    return if (query[0] != 0) dos.RETURN_WARN else dos.RETURN_OK;
}

/// RUN command: in a background shell of its own, on NIL: and a new "*".
pub fn cmdRun(sys: *ExecBase, _: [*]const u8, _: usize) callconv(.c) i32 {
    const dl = openDos(sys) orelse return dos.RETURN_FAIL;
    defer closeDos(sys, dl);
    var argv: [1]usize = undefined;
    const rda = getArgs(dl, "COMMAND/F", &argv) orelse return dos.RETURN_ERROR;
    defer dl.FreeArgs(rda);
    const command = rdargs.string(argv[0]) orelse return dos.RETURN_OK;
    const in = dl.Open("NIL:", dos.MODE_OLDFILE) orelse return dos.RETURN_ERROR;
    const out = dl.Open("*", dos.MODE_NEWFILE) orelse dl.Open("NIL:", dos.MODE_NEWFILE) orelse {
        _ = dl.Close(in);
        return dos.RETURN_ERROR;
    };
    const tags = [_]sdk.utility.TagItem{
        .{ .tag = dos.SYS_Input, .data = @intFromPtr(in) },
        .{ .tag = dos.SYS_Output, .data = @intFromPtr(out) },
        .{ .tag = dos.SYS_Asynch, .data = 1 },
        .{ .tag = dos.SYS_UserShell, .data = 1 },
        .{},
    };
    const number = dl.SystemTagList(command, &tags);
    if (number < 0) {
        _ = dl.Close(in);
        _ = dl.Close(out);
        return dos.RETURN_ERROR;
    }
    _ = Printf(dl, "[CLI %ld]\n", .{@as(i64, number)});
    return dos.RETURN_OK;
}

/// The script a new shell reads before its console when FROM says nothing.
const SHELL_STARTUP = "S:Shell-startup";

/// The console a new shell gets when WINDOW says nothing: a window of its
/// own across the top of the display, with a close gadget, since a shell
/// somebody asked for is one they are meant to be able to put away. The
/// machine's own shell, which dos starts, has neither a size nor a close
/// gadget: it covers the display and stays.
const default_window: [*:0]const u8 = "CON:0/0//300/PowerOS Shell/CLOSE";

/// NEWSHELL, NEWCLI [WINDOW] [FROM]: another shell on WINDOW (default
/// CON:), reading FROM (else S:Shell-startup, if there is one) before it
/// takes its first line from the console.
pub fn cmdNewShell(sys: *ExecBase, _: [*]const u8, _: usize) callconv(.c) i32 {
    const dl = openDos(sys) orelse return dos.RETURN_FAIL;
    defer closeDos(sys, dl);
    var argv: [2]usize = undefined;
    const rda = getArgs(dl, "WINDOW,FROM", &argv) orelse return dos.RETURN_ERROR;
    defer dl.FreeArgs(rda);
    const window = rdargs.string(argv[0]) orelse default_window;

    // FROM must be there when it is named; the default script is taken
    // only if it happens to exist.
    var script: ?*dos.FileHandle = null;
    if (rdargs.string(argv[1])) |from| {
        script = dl.Open(from, dos.MODE_OLDFILE) orelse {
            const code = dl.IoErr();
            _ = dl.PrintFault(code, from);
            _ = dl.SetIoErr(code);
            return dos.RETURN_ERROR;
        };
    } else {
        script = dl.Open(SHELL_STARTUP, dos.MODE_OLDFILE);
    }

    // dos opens the console and gives the new shell both directions of the
    // one handle: a console name that makes a window makes one per Open,
    // so opening it twice here would put two windows on the screen.
    const tags = [_]sdk.utility.TagItem{
        .{ .tag = dos.SYS_Window, .data = @intFromPtr(window) },
        .{ .tag = dos.SYS_Asynch, .data = 1 },
        .{ .tag = dos.SYS_UserShell, .data = 1 },
        .{ .tag = dos.SYS_ScriptFile, .data = @intFromPtr(script) },
        .{},
    };
    const number = dl.SystemTagList(null, &tags);
    if (number < 0) {
        const code = dl.IoErr();
        if (script) |f| _ = dl.Close(f);
        _ = dl.PrintFault(if (code != 0) code else STR_NEWSHELL_FAILED, if (code != 0) "NewShell" else null);
        _ = dl.SetIoErr(code);
        return dos.RETURN_ERROR;
    }
    _ = faultNumber(dl, STR_NEW_SHELL, number);
    return dos.RETURN_OK;
}

// --- Scripts ---

/// The CLI if it is reading a script (not its standard input); else "Must
/// be in a command file".
fn inScript(dl: *DosBase) ?*dos.CommandLineInterface {
    if (dl.Cli()) |cli| if (cli.current_input != cli.standard_input) return cli;
    _ = dl.PrintFault(STR_NOT_EXECUTE, null);
    return null;
}

/// The rest of the script's line read: '\n', or -1 at the end.
fn eatLine(dl: *DosBase) i32 {
    while (true) {
        const c = dl.FGetC(dl.Input());
        if (c == '\n' or c == -1) return c;
    }
}

/// If compares strings without case, the difference of the first
/// characters that differ (the shorter one's end counts).
fn compare(ub: *UtilityBase, a: [*:0]const u8, b: [*:0]const u8) i32 {
    var i: usize = 0;
    while (true) : (i += 1) {
        const d = @as(i32, ub.ToUpper(a[i])) - @as(i32, ub.ToUpper(b[i]));
        if (d != 0 or a[i] == 0 or b[i] == 0) return d;
    }
}

/// IF [NOT] [WARN] [ERROR] [FAIL] [a EQ|GT|GE b [VAL]] [EXISTS name]: when
/// false, the script's lines up to the matching ELSE or ENDIF are skipped.
/// No condition is false.
pub fn cmdIf(sys: *ExecBase, _: [*]const u8, _: usize) callconv(.c) i32 {
    const dl = openDos(sys) orelse return dos.RETURN_FAIL;
    defer closeDos(sys, dl);
    const ub_lib = sys.OpenLibrary(sdk.interface.utility.NAME, 1) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(ub_lib);
    const ub: *UtilityBase = @ptrCast(ub_lib);
    var argv: [10]usize = undefined;
    const rda = getArgs(dl, "NOT/S,WARN/S,ERROR/S,FAIL/S,,EQ/K,GT/K,GE/K,VAL/S,EXISTS/K", &argv) orelse return dos.RETURN_ERROR;
    defer dl.FreeArgs(rda);
    const cli = inScript(dl) orelse return dos.RETURN_ERROR;
    const last = cli.return_code;
    var value = false;
    if (rdargs.string(argv[9])) |name| {
        if (dl.Lock(name, dos.SHARED_LOCK)) |lock| {
            dl.UnLock(lock);
            value = true;
        }
    } else if (argv[1] != 0) {
        value = last >= dos.RETURN_WARN;
    } else if (argv[2] != 0) {
        value = last >= dos.RETURN_ERROR;
    } else if (argv[3] != 0) {
        value = last >= dos.RETURN_FAIL;
    } else if (rdargs.string(argv[4])) |first| {
        const second = rdargs.string(argv[5]) orelse rdargs.string(argv[6]) orelse rdargs.string(argv[7]) orelse "";
        var a: i32 = 0;
        var b: i32 = 0;
        if (argv[8] != 0) {
            _ = dl.StrToLong(first, &a);
            _ = dl.StrToLong(second, &b);
        } else {
            a = compare(ub, first, second);
        }
        value = if (argv[5] != 0) a == b else if (argv[6] != 0) a > b else a >= b;
    }
    if (argv[0] != 0) value = !value;
    if (value) return dos.RETURN_OK;

    _ = dl.SelectInput(cli.current_input);
    var nest: i32 = 0;
    var more: i32 = 1;
    var buff: [32]u8 = undefined;
    while (nest >= 0 and more > 0) {
        if (dl.ReadItem(&buff, buff.len, null) == dos.ITEM_UNQUOTED) {
            switch (dl.FindArg("IF,ELSE,ENDIF", @ptrCast(&buff))) {
                0 => nest += 1,
                1 => if (nest == 0) {
                    nest -= 1;
                },
                2 => nest -= 1,
                else => {},
            }
        }
        more = eatLine(dl);
    }
    if (nest >= 0) {
        _ = dl.PrintFault(STR_MISSING_ELSE, null);
        return dos.RETURN_ERROR;
    }
    return dos.RETURN_OK;
}

/// ELSE: reached after IF's true part, so the lines up to the matching
/// ENDIF are skipped.
pub fn cmdElse(sys: *ExecBase, _: [*]const u8, _: usize) callconv(.c) i32 {
    const dl = openDos(sys) orelse return dos.RETURN_FAIL;
    defer closeDos(sys, dl);
    const cli = inScript(dl) orelse return dos.RETURN_ERROR;
    _ = dl.SelectInput(cli.current_input);
    var nest: i32 = 0;
    var buff: [256]u8 = undefined;
    while (nest >= 0) {
        if (dl.ReadItem(&buff, buff.len, null) == dos.ITEM_UNQUOTED) {
            switch (dl.FindArg("IF,ENDIF", @ptrCast(&buff))) {
                0 => nest += 1,
                1 => nest -= 1,
                else => {},
            }
        }
        if (eatLine(dl) < 0) break;
    }
    if (nest >= 0) {
        _ = dl.PrintFault(STR_MISSING_ELSE, null);
        return dos.RETURN_ERROR;
    }
    return dos.RETURN_OK;
}

/// SKIP [label] [BACK]: on to the line after "LAB label" (without a
/// label, the next LAB), from the script's start with BACK; ENDSKIP stops
/// it (return code 5).
pub fn cmdSkip(sys: *ExecBase, _: [*]const u8, _: usize) callconv(.c) i32 {
    const dl = openDos(sys) orelse return dos.RETURN_FAIL;
    defer closeDos(sys, dl);
    var argv: [2]usize = undefined;
    const rda = getArgs(dl, "LABEL,BACK/S", &argv) orelse return dos.RETURN_ERROR;
    defer dl.FreeArgs(rda);
    const cli = inScript(dl) orelse return dos.RETURN_ERROR;
    _ = dl.SelectInput(cli.current_input);
    if (argv[1] != 0) {
        _ = dl.Flush(dl.Input());
        _ = dl.Seek(dl.Input(), 0, dos.OFFSET_BEGINNING);
    }
    const label = rdargs.string(argv[0]);
    var rc: i32 = dos.RETURN_ERROR;
    var more = true;
    var buff: [256]u8 = undefined;
    while (rc == dos.RETURN_ERROR and more) {
        if (dl.ReadItem(&buff, buff.len, null) == dos.ITEM_UNQUOTED) {
            switch (dl.FindArg("LAB,ENDSKIP", @ptrCast(&buff))) {
                0 => if (dl.ReadItem(&buff, buff.len, null) != dos.ITEM_NOTHING) {
                    if (label) |l| if (dl.FindArg(l, @ptrCast(&buff)) == 0) {
                        rc = dos.RETURN_OK;
                    };
                } else if (label == null) {
                    rc = dos.RETURN_OK;
                },
                1 => rc = dos.RETURN_WARN,
                else => {},
            }
        }
        more = dl.FGets(dl.Input(), &buff, buff.len) != null;
    }
    if (rc == dos.RETURN_ERROR) {
        _ = dl.PrintFault(dos.ERROR_OBJECT_NOT_FOUND, null);
        _ = dl.SetIoErr(dos.ERROR_OBJECT_NOT_FOUND);
    }
    return rc;
}

/// ENDIF, LAB, ENDSKIP, .KEY, .BRA, .KET: nothing (for scripts).
pub fn cmdEndif(_: *ExecBase, _: [*]const u8, _: usize) callconv(.c) i32 {
    return dos.RETURN_OK;
}
