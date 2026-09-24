// SPDX-License-Identifier: MPL-2.0
//! The shell, a ROM module "shell" built against the SDK only.
//! dos.library's init puts it on the resident list under the names
//! "shell", "BootShell" and "CLI"; SystemTagList and Execute start it as a CLI
//! process with its CLI already set up, and send ACTION_STARTUP with a
//! ShellMode and SHF_* flags (see dos's system.zig).
//!
//! The command loop:
//! - A console (cli_Interactive: not a background CLI, reading
//!   cli_StandardInput) gets the prompt: cli_Prompt with %N (the CLI
//!   number), %S (the directory's name), %R (the last return code), %%,
//!   then $variables expanded.
//! - ReadItem reads the command's name from cli_CurrentInput. An unquoted
//!   name may be an alias (a local LV_ALIAS variable): its text replaces
//!   it, and "[]" in it takes the rest of the line. $variables are
//!   expanded (local, then global; "*$" escapes).
//! - The rest of the line: ";" starts a comment (outside quotes), "+" at
//!   the end continues on the next line, and after a space "<file",
//!   ">file", ">>file" and "<>file" redirect (not after the first word
//!   of Run and Set). $variables again, and "echo" (a local variable "on")
//!   shows the line.
//! - `command` (backquotes) in the command's name and its line is replaced
//!   by what the command prints ("*`" is a plain backquote).
//! - The command: the resident list (FindSegment: user segments, then
//!   CMD_INTERNAL ones: the built-ins and the ROM's commands; CMD_SYSTEM
//!   and CMD_DISABLED ones aren't run), also as "C:name"; then a script
//!   (a file with the S bit) where the name says, or in the path and C:,
//!   which Execute runs; a directory's name changes into it (CD). It runs
//!   through RunCommand with cli_DefaultStack, the line as its arguments.
//! - Its return code goes to cli_ReturnCode and the local variable RC,
//!   IoErr to cli_Result2 and Result2; a failure (at or above
//!   cli_FailLevel) outside a console says "... failed returncode"; a
//!   command that can't be found says "Unknown command".
//! - The end of cli_CurrentInput ends a script (back to the standard
//!   input; Execute's work file, cli_CommandFile, is deleted), a System()
//!   command stream, or the shell; EndCLI (the background flag set) ends it
//!   too.
//!
//! No programs from disk (no LoadSeg: a file that isn't a script is "file
//! is not executable"); no pipes yet; every `command` of a line is
//! replaced, and one that can't start counts as failing (20); dos sets the
//! CLI up; the prompt goes out through FPuts, so its text isn't a VFWritef
//! format; EndCLI is noticed by the background flag.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const UtilityBase = sdk.interface.utility.UtilityBase;
const FileHandle = dos.FileHandle;
const Printf = dos.stdio.Printf;
pub const builtins = @import("builtins.zig");
const pipe = @import("pipe.zig");
const workfile = dos.workfile;

pub const SHELL_NAME = "shell";
const SHELL_VERSION = 1;
const SHELL_REVISION = 0;
const BUILD_DATE = "16.9.2026";
const SHELL_VERSION_STRING =
    "\x00$VER: " ++ SHELL_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ SHELL_VERSION, SHELL_REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

const MAXCOMMAND = 511;
const MAXALIAS = 255;
pub const NAMEMAX = 103;

// The shell's texts (Fault's negative codes).
const ERROR_REDIRECT = -118;
const ERROR_COMMAND_LONG = -124;
const STR_UNKNOWN_COMMAND = -121;
const STR_ERROR_COMMAND = -122;
const STR_FAILED_RETURNCODE = -161;
/// What run answers when the command didn't run at all.
const NOT_RUN = -9999;
const END = -1;

/// The shell's state, one per shell process.
const Global = struct {
    sys: *ExecBase,
    dl: *DosBase,
    ub: *UtilityBase,
    proc: *dos.Process,
    cli: *dos.CommandLineInterface,
    /// The command (or alias) text, then the argument line.
    cbuffer: [MAXCOMMAND + 1]u8 = undefined,
    /// An alias's text after its first word: read before the input.
    alias: [MAXALIAS + 1]u8 = undefined,
    /// expand's copy.
    buffer: [MAXCOMMAND + 1]u8 = undefined,
    /// The alias's length, how far it has been read, and "[]": 0 none yet,
    /// 1 reading the input into it, 2 done.
    cpos: usize = 0,
    count: usize = 0,
    fill: u8 = 0,
    echo: bool = false,
    /// The last command's IoErr.
    res2: i32 = 0,
    /// What ended the argument line: a newline or the end.
    last_ch: i32 = '\n',
};

fn span(buf: []const u8) []const u8 {
    return buf[0 .. std.mem.indexOfScalar(u8, buf, 0) orelse buf.len];
}

// --- Startup and the end ---

/// The shell process: ACTION_STARTUP (dp_Arg1 the ShellMode, dp_Arg2
/// SHF_*), then the command loop; a synchronous start is replied at the
/// end with the last return code and Result2.
fn shellEntry(sys: *ExecBase) callconv(.c) void {
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return;
    defer sys.CloseLibrary(dos_lib);
    const dl: *DosBase = @ptrCast(dos_lib);
    const pkt = dl.WaitPkt() orelse return;
    const mode: dos.ShellMode = switch (pkt.args.raw[0]) {
        1 => .system,
        2 => .execute,
        else => .interactive,
    };
    const flags = pkt.args.raw[1];
    const asynch = flags & dos.SHF_ASYNCH != 0;
    const cli = dl.Cli() orelse return dl.ReplyPkt(pkt, -1, dos.ERROR_OBJECT_WRONG_TYPE);
    if (asynch) dl.ReplyPkt(pkt, 0, 0);
    if (!runShell(sys, mode) and !asynch) return dl.ReplyPkt(pkt, -1, dos.ERROR_NO_FREE_STORE);

    const in = cli.standard_input;
    const out = cli.standard_output;
    if (out) |o| _ = dl.Flush(o);
    if (flags & dos.SHF_CLOSE_OUTPUT != 0 and out != null) _ = dl.Close(out);
    if (flags & dos.SHF_CLOSE_INPUT != 0 and in != null and !(flags & dos.SHF_CLOSE_OUTPUT != 0 and in == out)) _ = dl.Close(in);
    cli.standard_input = null;
    cli.standard_output = null;
    cli.current_input = null;
    _ = dl.SelectInput(null);
    _ = dl.SelectOutput(null);
    if (!asynch) dl.ReplyPkt(pkt, cli.return_code, cli.result2);
}

/// The shell on the running process, which has its CLI set up: the
/// built-ins on the resident list, then the command loop until the end.
/// False without memory. The host tests run it directly.
pub fn runShell(sys: *ExecBase, mode: dos.ShellMode) bool {
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return false;
    defer sys.CloseLibrary(dos_lib);
    const util_lib = sys.OpenLibrary(sdk.interface.utility.NAME, 1) orelse return false;
    defer sys.CloseLibrary(util_lib);
    const dl: *DosBase = @ptrCast(dos_lib);
    const cli = dl.Cli() orelse return false;
    const block = sys.AllocVec(@sizeOf(Global), exec.MEMF_CLEAR) orelse return false;
    defer sys.FreeVec(block);
    const gv: *Global = @ptrCast(@alignCast(block));
    gv.* = .{
        .sys = sys,
        .dl = dl,
        .ub = @ptrCast(util_lib),
        .proc = @fieldParentPtr("task", sys.FindTask(null).?),
        .cli = cli,
    };
    commandLoop(gv, mode);
    return true;
}

fn commandLoop(gv: *Global, mode: dos.ShellMode) void {
    const dl = gv.dl;
    const cli = gv.cli;
    addBuiltins(gv);
    if (cli.set_name == null or cli.set_name.?[0] == 0) {
        if (gv.proc.current_dir) |dir| {
            var name: [256]u8 = undefined;
            if (dl.NameFromLock(dir, &name, name.len)) _ = dl.SetCurrentDirName(@ptrCast(&name));
        }
    }
    var number: [16]u8 = undefined;
    const text = std.fmt.bufPrintZ(&number, "{d}", .{gv.proc.task_num}) catch unreachable;
    _ = dl.SetVar("process", text.ptr, -1, dos.LV_VAR | dos.GVF_LOCAL_ONLY);
    // The pipe character, unless this shell's parent set another.
    var pchar: [8]u8 = undefined;
    if (dl.GetVar("_pchar", &pchar, pchar.len - 1, dos.LV_VAR | dos.GVF_LOCAL_ONLY) <= 0)
        _ = dl.SetVar("_pchar", "|", -1, dos.LV_VAR | dos.GVF_LOCAL_ONLY);
    setv(gv, 0);
    const started_background = cli.background;

    var failed = false;
    var ch: i32 = 0;
    while (true) {
        while (true) {
            cli.interactive = !cli.background and cli.current_input == cli.standard_input and mode != .system;
            _ = dl.SelectInput(cli.current_input);
            _ = dl.SelectOutput(cli.standard_output);
            if (cli.interactive) {
                prompt(gv);
            } else {
                if (dl.CheckSignal(exec.SIGBREAKF_CTRL_D) != 0) {
                    failed = true;
                    _ = dl.PrintFault(dos.ERROR_BREAK, "SHELL");
                }
                if (failed) break;
            }
            failed = false;
            var value: [32]u8 = undefined;
            gv.echo = dl.GetVar("echo", &value, 31, dos.LV_VAR | dos.GVF_LOCAL_ONLY) > 0 and
                gv.ub.Strnicmp("on", @ptrCast(&value), 2) == 0;

            var name: [NAMEMAX + 1]u8 = undefined;
            const item = dl.ReadItem(&name, NAMEMAX, null);
            ch = 0;
            if (item != dos.ITEM_NOTHING) {
                failed = true;
                if (item > 0) {
                    ch = doCommand(gv, item, &name, &failed);
                } else {
                    _ = dl.PrintFault(STR_ERROR_COMMAND, null);
                }
            }
            // the rest of the line
            while (ch != '\n' and ch != END) ch = dl.FGetC(dl.Input());
            if (cli.background != started_background) { // EndCLI
                ch = END;
                break;
            }
            if (mode == .system and cli.current_input == cli.standard_input) break;
            if (ch == END) break;
        }
        // cli_CurrentInput ended
        if (cli.current_input == cli.standard_input) {
            if (ch == END and !cli.background) doEnd(gv.sys, dl);
            deleteCommandFile(dl, cli);
            return;
        }
        _ = dl.Close(cli.current_input);
        deleteCommandFile(dl, cli);
        cli.current_input = cli.standard_input;
        if (mode == .system) return;
        cli.fail_level = dos.CLI_INITIAL_FAIL_LEVEL;
    }
}

/// EndCLI's part: a script stops, the CLI becomes a
/// background one (which ends the loop), and a console says "Process n
/// ending".
pub fn doEnd(sys: *ExecBase, dl: *DosBase) void {
    const cli = dl.Cli() orelse return;
    if (cli.current_input != cli.standard_input) {
        _ = dl.Close(cli.current_input);
        cli.current_input = cli.standard_input;
    }
    deleteCommandFile(dl, cli);
    cli.background = true;
    // One shell less is using the shell's code.
    if (dl.LockSegmentList(false) != null) {
        if (dl.FindSegment("CLI", null, true)) |seg| {
            if (seg.uc > 0) seg.uc -= 1;
        }
        dl.UnLockSegmentList();
    }
    if (!cli.interactive) return;
    const me: *dos.Process = @fieldParentPtr("task", sys.FindTask(null).?);
    var text: [48]u8 = undefined;
    const n: usize = @intCast(@max(dl.Fault(-149, null, &text, text.len), 0)); // "Process %N ending"
    const at = std.mem.indexOf(u8, text[0..n], "%N") orelse n;
    const rest = if (at + 2 <= n) text[at + 2 .. n] else "";
    var line: [64]u8 = undefined;
    const out = std.fmt.bufPrintZ(&line, "{s}{d}{s}\n", .{ text[0..at], me.task_num, rest }) catch return;
    _ = dl.PutStr(out.ptr);
}

/// Execute's last work file (cli_CommandFile) deleted, once its script
/// has ended.
pub fn deleteCommandFile(dl: *DosBase, cli: *dos.CommandLineInterface) void {
    const file = cli.command_file orelse return;
    if (file[0] == 0) return;
    if (!dl.DeleteFile(file)) {
        _ = dl.SetProtection(file, 0);
        _ = dl.DeleteFile(file);
    }
    file[0] = 0;
}

// --- The prompt, variables ---

fn prompt(gv: *Global) void {
    const dl = gv.dl;
    const cli = gv.cli;
    const text: []const u8 = if (cli.prompt) |p| std.mem.span(p) else "";
    var out: [MAXALIAS + 1]u8 = undefined;
    var n: usize = 0;
    var i: usize = 0;
    while (i < text.len and n + 24 < out.len) : (i += 1) {
        if (text[i] != '%' or i + 1 >= text.len) {
            if (text[i] != '%') {
                out[n] = text[i];
                n += 1;
            }
            continue;
        }
        i += 1;
        switch (gv.ub.ToUpper(text[i])) {
            'S' => {
                const name: []const u8 = if (cli.set_name) |s| std.mem.span(s) else "";
                const len = @min(name.len, out.len - 24 - n);
                @memcpy(out[n..][0..len], name[0..len]);
                n += len;
            },
            'N' => n += (std.fmt.bufPrint(out[n..], "{d}", .{gv.proc.task_num}) catch out[n..n]).len,
            'R' => n += (std.fmt.bufPrint(out[n..], "{d}", .{cli.return_code}) catch out[n..n]).len,
            '%' => {
                out[n] = '%';
                n += 1;
            },
            else => { // the % becomes a space
                out[n] = ' ';
                out[n + 1] = text[i];
                n += 2;
            },
        }
    }
    out[n] = 0;
    _ = expand(gv, &out, MAXALIAS);
    _ = ticks(gv, &out, MAXALIAS);
    _ = dl.FPuts(dl.Output(), @ptrCast(&out));
    _ = dl.Flush(dl.Output());
}

/// $name, ${name} and $$ replaced by the
/// variable's value (local, then global) in `to` (`mc` bytes); an unknown
/// one stays as it is; "*$" is a "$". The length, or -1 when it doesn't
/// fit (cut).
fn expand(gv: *Global, to: [*]u8, mc: usize) isize {
    const len = std.mem.len(@as([*:0]u8, @ptrCast(to)));
    if (len >= mc) return -1;
    const from = &gv.buffer;
    @memcpy(from[0 .. len + 1], to[0 .. len + 1]);
    var rp: usize = 0;
    var p: usize = 0;
    var maxlen: isize = @intCast(mc);
    var lastrp: u8 = 0;
    while (from[rp] != 0) {
        if (from[rp] != '$') {
            lastrp = if (lastrp == '*') 0 else from[rp];
            to[p] = from[rp];
            p += 1;
            rp += 1;
            maxlen -= 1;
        } else if (lastrp == '*') { // "*$": the star goes
            lastrp = 0;
            to[p - 1] = from[rp];
            rp += 1;
            maxlen -= 1;
        } else {
            var name: [40]u8 = undefined;
            var q: usize = 0;
            const brace = rp;
            var bracend = rp;
            rp += 1;
            if (from[rp] == '{') {
                rp += 1;
                while (from[rp] != 0 and from[rp] != '}' and q < 32) : (rp += 1) {
                    name[q] = from[rp];
                    q += 1;
                }
                bracend = rp + 1;
                if (from[rp] != 0) rp += 1;
            } else if (from[rp] == 0) {
                to[p] = '$';
                p += 1;
                break;
            } else if (from[rp] == '$') {
                name[q] = '$';
                q += 1;
                rp += 1;
                bracend = rp;
            } else {
                while (q < 32) {
                    const c = gv.ub.ToUpper(from[rp]);
                    if (!((c >= '0' and c <= '9') or (c >= 'A' and c <= 'Z') or c > 160)) break;
                    name[q] = from[rp];
                    q += 1;
                    rp += 1;
                }
                bracend = rp;
            }
            name[q] = 0;
            var value: [128]u8 = undefined;
            if (gv.dl.GetVar(@ptrCast(&name), &value, 127, 0) < 0) {
                var b = brace;
                while (b < bracend and p + 1 < mc) : (b += 1) {
                    to[p] = from[b];
                    p += 1;
                }
            } else {
                var k: usize = 0;
                while (value[k] != 0 and value[k] != '\n' and maxlen > 0 and p + 1 < mc) : (k += 1) {
                    to[p] = value[k];
                    p += 1;
                    maxlen -= 1;
                }
            }
        }
        if (maxlen <= 0 or p + 1 >= mc) {
            to[mc - 1] = 0;
            return -1;
        }
    }
    to[p] = 0;
    return @intCast(p);
}

/// RC and Result2, the local variables of the last command's results.
fn setv(gv: *Global, rc: i32) void {
    var text: [16]u8 = undefined;
    const r = std.fmt.bufPrintZ(&text, "{d}", .{rc}) catch unreachable;
    _ = gv.dl.SetVar("RC", r.ptr, -1, dos.LV_VAR | dos.GVF_LOCAL_ONLY);
    const r2 = std.fmt.bufPrintZ(&text, "{d}", .{gv.res2}) catch unreachable;
    _ = gv.dl.SetVar("Result2", r2.ptr, -1, dos.LV_VAR | dos.GVF_LOCAL_ONLY);
}

// --- Commands ---

/// The built-ins onto the resident list as CMD_INTERNAL segments, once
/// (another shell may have put them there).
fn addBuiltins(gv: *Global) void {
    const dl = gv.dl;
    var installed = false;
    _ = dl.LockSegmentList(true);
    var seg = dl.FindSegment("alias", null, true);
    while (seg) |s| : (seg = dl.FindSegment("alias", s, true)) {
        if (s.code.command == &builtins.cmdSet) installed = true;
    }
    dl.UnLockSegmentList();
    if (installed) return;
    for (builtins.table) |b| _ = dl.AddSegment(b.name, &.{ .command = b.command }, dos.CMD_INTERNAL);
}

const Found = struct {
    code: dos.SegCode,
    /// A user segment, whose use count is up while it runs.
    counted: ?*dos.Segment,
    /// Run and Set: no redirection after their first word.
    special: bool,
};

/// A resident command by name (also "C:name"); user
/// segments count their use.
fn findCommand(gv: *Global, name: [*:0]const u8) ?Found {
    const dl = gv.dl;
    _ = dl.LockSegmentList(false);
    defer dl.UnLockSegmentList();
    var seg = dl.FindSegment(name, null, false) orelse dl.FindSegment(name, null, true);
    if (seg == null and gv.ub.Strnicmp(name, "c:", 2) == 0) {
        const part = dl.FilePart(name);
        seg = dl.FindSegment(part, null, false) orelse dl.FindSegment(part, null, true);
    }
    const s = seg orelse return null;
    if (s.uc < 0 and (s.uc > dos.CMD_INTERNAL or s.uc <= dos.CMD_DISABLED)) return null;
    if (s.code.command == null) return null;
    if (s.uc >= 0) s.uc += 1;
    const command = s.code.command.?;
    return .{
        .code = s.code,
        .counted = if (s.uc > 0) s else null,
        .special = command == &builtins.cmdRun or command == &builtins.cmdSet,
    };
}

fn releaseCommand(gv: *Global, found: Found) void {
    const s = found.counted orelse return;
    _ = gv.dl.LockSegmentList(false);
    defer gv.dl.UnLockSegmentList();
    if (s.uc > 0) s.uc -= 1;
}

/// Whether the rest of the line has the pipe character
/// outside quotes, after a space. What the alias still holds comes first,
/// then what the input has read but not given out yet.
fn wantsPipe(gv: *Global, name: [*:0]const u8) bool {
    const dl = gv.dl;
    if (gv.ub.Stricmp(name, pipe.COMMAND_NAME) == 0) return false; // PIPE itself
    const pc = pipe.pipeChar(dl);
    var quoted = false;
    var last: u8 = ' ';
    const alias = gv.alias[gv.count..gv.cpos];
    if (scanForPipe(alias, pc, &quoted, &last)) |found| return found;
    const fh = dl.Input() orelse return false;
    const buf = fh.buf orelse return false;
    if (fh.pos > fh.end) return false;
    return scanForPipe(buf[fh.pos..fh.end], pc, &quoted, &last) orelse false;
}

/// The bytes up to the line's end: true when the character is there, false
/// when the line ended first, null when it may go on in the next piece.
fn scanForPipe(bytes: []const u8, pc: u8, quoted: *bool, last: *u8) ?bool {
    for (bytes) |c| {
        if (c == '\n') return false;
        if (c == '"') quoted.* = !quoted.*;
        if (!quoted.* and c == pc and last.* == ' ') return true;
        last.* = c;
    }
    return null;
}

/// The command's name in front of what is left of the line, so PIPE gets the
/// whole thing.
fn pipeLine(gv: *Global, name: [*:0]const u8) bool {
    var text: [MAXALIAS + 1]u8 = undefined;
    const len = std.mem.len(name);
    if (len + 1 + gv.cpos - gv.count >= MAXALIAS) return false;
    @memcpy(text[0..len], name[0..len]);
    text[len] = ' ';
    const rest = gv.alias[gv.count..gv.cpos];
    @memcpy(text[len + 1 ..][0..rest.len], rest);
    const total = len + 1 + rest.len;
    @memcpy(gv.alias[0..total], text[0..total]);
    gv.alias[total] = 0;
    gv.cpos = total;
    gv.count = 0;
    return true;
}

const Kind = enum { none, directory, script, program };

/// What `name` is in `dir` (null: the current directory): a directory, a
/// script (the S bit), a program to load (any other file), or nothing.
fn testScript(gv: *Global, name: [*:0]const u8, dir: ?*dos.FileLock) Kind {
    const dl = gv.dl;
    const old = if (dir) |d| dl.CurrentDir(d) else null;
    defer if (dir != null) {
        _ = dl.CurrentDir(old);
    };
    const lock = dl.Lock(name, dos.SHARED_LOCK) orelse {
        if (gv.res2 != dos.ERROR_FILE_NOT_OBJECT) gv.res2 = dl.IoErr();
        return .none;
    };
    defer dl.UnLock(lock);
    var fib: dos.FileInfoBlock = .{};
    if (!dl.Examine(lock, &fib)) return .none;
    if (fib.dir_entry_type >= 0) return .directory;
    if (fib.protection & dos.FIBF_SCRIPT != 0) return .script;
    return .program;
}

const Search = struct {
    kind: Kind = .none,
    /// A script found in the path or C:: its directory, for PROGDIR:.
    home: ?*dos.FileLock = null,
};

/// What runs from disk without LoadSeg: a script
/// where the name says (the current directory), then, for a plain name, in
/// the path and in C:; a directory where the name says (an implicit CD).
fn findScript(gv: *Global, name: [*:0]const u8) Search {
    const dl = gv.dl;
    var dirfound = false;
    switch (testScript(gv, name, null)) {
        .script, .program => |kind| return .{ .kind = kind },
        .directory => dirfound = true,
        .none => {},
    }
    if (@intFromPtr(dl.FilePart(name)) == @intFromPtr(name)) {
        var node = gv.cli.command_dir;
        while (node) |n| : (node = n.next) {
            switch (testScript(gv, name, n.lock)) {
                .script, .program => |kind| return .{ .kind = kind, .home = dl.DupLock(n.lock) },
                else => {},
            }
        }
        if (dl.Lock("C:", dos.SHARED_LOCK)) |c| {
            switch (testScript(gv, name, c)) {
                .script, .program => |kind| return .{ .kind = kind, .home = c },
                else => dl.UnLock(c),
            }
        }
    }
    return .{ .kind = if (dirfound) .directory else .none };
}

/// The line for Execute: the script's name first, "PROGDIR:" before
/// it when it was found in the path or C:, a "*" before its "*", "$" and
/// '"', in quotes if it was quoted; then what followed it. False if that
/// doesn't fit.
fn scriptLine(gv: *Global, name: [*:0]const u8, quoted: bool, via_path: bool) bool {
    var text: [MAXALIAS + 1]u8 = undefined;
    var n: usize = 0;
    const Add = struct {
        fn byte(t: *[MAXALIAS + 1]u8, at: *usize, c: u8) bool {
            if (at.* + 1 >= MAXALIAS) return false;
            t[at.*] = c;
            at.* += 1;
            return true;
        }
    };
    if (via_path) for ("PROGDIR:") |c| {
        if (!Add.byte(&text, &n, c)) return false;
    };
    if (quoted and !Add.byte(&text, &n, '"')) return false;
    for (std.mem.span(name)) |c| {
        if ((c == '*' or c == '$' or c == '"') and !Add.byte(&text, &n, '*')) return false;
        if (!Add.byte(&text, &n, c)) return false;
    }
    if (quoted and !Add.byte(&text, &n, '"')) return false;
    if (!Add.byte(&text, &n, ' ')) return false;
    for (gv.alias[0..gv.cpos]) |c| {
        if (!Add.byte(&text, &n, c)) return false;
    }
    if (text[n - 1] != ' ' and !Add.byte(&text, &n, ' ')) return false;
    @memcpy(gv.alias[0..n], text[0..n]);
    gv.alias[n] = 0;
    gv.cpos = n;
    return true;
}

/// One command: its name (an alias's text instead), found and run with the
/// rest of the line, its results kept. Returns what ended the line if that
/// was read, else 0.
fn doCommand(gv: *Global, item: i32, name: *[NAMEMAX + 1]u8, failed: *bool) i32 {
    const dl = gv.dl;
    const cli = gv.cli;
    gv.res2 = 0;
    gv.cpos = 0;
    gv.count = 0;
    gv.fill = 0;
    gv.alias[0] = 0;
    const name_z: [*:0]u8 = @ptrCast(name);

    var current_alias: ?*dos.LocalVar = null;
    var got: isize = -1;
    if (item == dos.ITEM_UNQUOTED) {
        got = dl.GetVar(name_z, &gv.cbuffer, MAXALIAS, dos.LV_ALIAS);
        if (got >= 0) current_alias = dl.FindVar(name_z, dos.LV_ALIAS);
    }
    if (got < 0) {
        const len = std.mem.len(name_z);
        @memcpy(gv.cbuffer[0 .. len + 1], name[0 .. len + 1]);
    }
    _ = expand(gv, &gv.cbuffer, MAXCOMMAND);
    var ticked: isize = 0;
    if (current_alias == null) ticked = ticks(gv, &gv.cbuffer, MAXCOMMAND);
    if (item == dos.ITEM_UNQUOTED) {
        const text = span(&gv.cbuffer);
        if (std.mem.indexOfScalar(u8, text, ' ')) |space| {
            const rest = text[space + 1 ..];
            const len = @min(rest.len, MAXALIAS - 2);
            @memcpy(gv.alias[0..len], rest[0..len]);
            gv.alias[len] = ' ';
            gv.alias[len + 1] = 0;
            gv.cpos = len + 1;
        }
    }
    var n: usize = 0;
    while (n < NAMEMAX and gv.cbuffer[n] != 0 and (item == dos.ITEM_QUOTED or gv.cbuffer[n] != ' ')) : (n += 1) name[n] = gv.cbuffer[n];
    name[n] = 0;
    if (current_alias) |a| {
        ticked = ticks(gv, name, NAMEMAX);
        a.var_type |= dos.LVF_IGNORE;
    }

    var ch: i32 = 0;
    var rc: i32 = NOT_RUN;
    if (ticked < 0) {
        rc = @intCast(-ticked); // a backquoted command failed
    } else {
        // A pipe character further along the line (wantsPipe): the
        // whole line, this first word included, goes to PIPE.
        if (wantsPipe(gv, name_z)) {
            if (pipeLine(gv, name_z)) {
                @memcpy(name[0..5], "PIPE\x00");
            } else {
                gv.res2 = dos.ERROR_LINE_TOO_LONG;
            }
        }
        var found = findCommand(gv, name_z);
        var home: ?*dos.FileLock = null;
        var loaded: ?*dos.SegList = null;
        const old_home = gv.proc.home_dir;
        if (found == null) {
            const search = findScript(gv, name_z);
            switch (search.kind) {
                .none => {},
                .script => if (scriptLine(gv, name_z, item == dos.ITEM_QUOTED, search.home != null)) {
                    home = search.home;
                    if (home != null) gv.proc.home_dir = home;
                    @memcpy(name[0..8], "Execute\x00");
                    found = findCommand(gv, name_z);
                } else {
                    if (search.home) |h| dl.UnLock(h);
                    gv.res2 = dos.ERROR_LINE_TOO_LONG;
                },
                .program => { // a file to load: LoadSeg, run, UnLoadSeg
                    const old_dir = if (search.home) |h| dl.CurrentDir(h) else null;
                    const seg = dl.LoadSeg(name_z);
                    if (search.home != null) _ = dl.CurrentDir(old_dir);
                    if (search.home) |h| dl.UnLock(h);
                    if (seg) |s| {
                        if (s.entry) |code| {
                            loaded = s;
                            cli.module = s;
                            found = .{ .code = .{ .command = @ptrCast(@alignCast(code)) }, .counted = null, .special = false };
                        } else {
                            dl.UnLoadSeg(s);
                            gv.res2 = dos.ERROR_FILE_NOT_OBJECT;
                        }
                    } else {
                        // Not a load file at all: ERROR_FILE_NOT_OBJECT.
                        gv.res2 = dl.IoErr();
                        if (gv.res2 == 0 or gv.res2 == dos.ERROR_OBJECT_WRONG_TYPE) gv.res2 = dos.ERROR_FILE_NOT_OBJECT;
                    }
                },
                .directory => { // an implicit CD
                    const len = std.mem.len(name_z);
                    if (len + 1 + gv.cpos < MAXALIAS) {
                        std.mem.copyBackwards(u8, gv.alias[len + 1 .. len + 1 + gv.cpos + 1], gv.alias[0 .. gv.cpos + 1]);
                        @memcpy(gv.alias[0..len], name[0..len]);
                        gv.alias[len] = ' ';
                        gv.cpos += len + 1;
                        if (gv.cpos == len + 1) gv.alias[gv.cpos] = 0;
                        found = findCommand(gv, "CD");
                    }
                },
            }
        }
        if (gv.echo) {
            _ = Printf(dl, "%s ", .{std.mem.span(name_z)});
            _ = dl.Flush(dl.Output());
        }
        if (found) |f| {
            _ = dl.SetProgramName(name_z);
            rc = runLine(gv, &f.code, f.special);
            ch = gv.last_ch;
            releaseCommand(gv, f);
        }
        if (home) |h| {
            gv.proc.home_dir = old_home;
            dl.UnLock(h);
        }
        if (loaded) |s| { // the program has run
            cli.module = null;
            dl.UnLoadSeg(s);
        }
    }
    _ = dl.SelectOutput(cli.standard_output);
    if (rc == NOT_RUN or rc == -1) {
        rc = dos.RETURN_ERROR;
        if (gv.res2 == 0 or gv.res2 == dos.ERROR_OBJECT_NOT_FOUND or gv.res2 == dos.ERROR_DEVICE_NOT_MOUNTED) {
            _ = dl.PrintFault(STR_UNKNOWN_COMMAND, name_z);
        } else {
            _ = dl.PrintFault(gv.res2, name_z);
        }
    }
    if (rc == 0 or gv.res2 < 0) gv.res2 = 0;
    if (rc >= 0 and rc < cli.fail_level) failed.* = false;
    if (failed.* and !cli.interactive) {
        var text: [64]u8 = undefined;
        if (dl.Fault(STR_FAILED_RETURNCODE, null, &text, text.len) > 0) {
            const stream = exec.fmtStream(.{ @as([:0]const u8, std.mem.span(name_z)), @as(i64, rc) });
            _ = dl.VPrintf(@ptrCast(&text), &stream);
        }
    }
    cli.return_code = rc;
    setv(gv, rc);
    if (current_alias) |a| a.var_type &= ~dos.LVF_IGNORE;
    _ = dl.SelectInput(cli.current_input);
    cli.result2 = gv.res2;
    return ch;
}

// --- The argument line ---

/// The next character: the alias's text first, with "[]" standing for
/// the rest of the input line; then the input.
fn getchar(gv: *Global, lastch: i32) i32 {
    if (gv.count < gv.cpos and gv.fill != 1) {
        const ch: i32 = gv.alias[gv.count];
        gv.count += 1;
        if (gv.fill == 0 and ch == '[' and gv.alias[gv.count] == ']' and lastch != '*') {
            gv.fill = 1;
            gv.count += 1;
            return fromInput(gv);
        }
        return ch;
    }
    return fromInput(gv);
}

fn fromInput(gv: *Global) i32 {
    var ch = gv.dl.FGetC(gv.dl.Input());
    if ((ch == '\n' or ch == END) and gv.fill == 1) {
        gv.fill = 2; // the input line is in; the alias goes on
        if (gv.count < gv.cpos and gv.cpos < MAXALIAS) {
            gv.alias[gv.cpos] = @truncate(@as(u32, @bitCast(ch)));
            gv.cpos += 1;
            ch = gv.alias[gv.count];
        }
    }
    if (gv.fill != 1) gv.count += 1;
    return ch;
}

fn ungetchar(gv: *Global) void {
    if (gv.count >= gv.cpos or gv.fill != 0) {
        if (gv.fill != 1) gv.count -= 1;
        _ = gv.dl.UnGetC(gv.dl.Input(), -1);
    } else if (gv.count > 0) {
        gv.count -= 1;
    }
}

/// A redirection's file name, from the alias's text or the input.
fn readItemShell(gv: *Global, string: *[NAMEMAX + 1]u8) i32 {
    var res: i32 = 1;
    while (gv.fill != 1 and gv.count < gv.cpos and gv.alias[gv.count] == ' ') gv.count += 1;
    if (gv.count < gv.cpos and gv.fill != 1) {
        var i: usize = 0;
        while (gv.count < gv.cpos and gv.alias[gv.count] != ' ' and i < NAMEMAX) : (i += 1) {
            string[i] = gv.alias[gv.count];
            gv.count += 1;
            if (gv.fill != 0 or (string[i] == '[' and gv.alias[gv.count] == ']')) {
                if (gv.fill == 0) gv.count += 1;
                res = gv.dl.ReadItem(string[i..].ptr, @intCast(NAMEMAX - i), null);
                if (res > 0) {
                    i += std.mem.len(@as([*:0]u8, @ptrCast(string[i..].ptr)));
                    break;
                }
            }
        }
        string[i] = 0;
    } else {
        res = gv.dl.ReadItem(string, NAMEMAX, null);
        if (res > 0 and gv.fill != 1) gv.count += std.mem.len(@as([*:0]u8, @ptrCast(string)));
    }
    return res;
}

fn openf(gv: *Global, name: *[NAMEMAX + 1]u8, mode: i32) ?*FileHandle {
    _ = expand(gv, name, NAMEMAX);
    const fh = gv.dl.Open(@ptrCast(name), mode);
    if (fh == null) _ = gv.dl.SetIoErr(ERROR_REDIRECT);
    return fh;
}

/// A redirection failed, or the line is too long: the streams opened so far
/// close, and the command doesn't run.
fn notRun(gv: *Global, code: i32, in: ?*FileHandle, out: ?*FileHandle) i32 {
    if (in) |f| _ = gv.dl.Close(f);
    if (out) |f| _ = gv.dl.Close(f);
    gv.res2 = code;
    return NOT_RUN;
}

/// The rest of the line read into the argument line (comments,
/// quotes, "+" continuations, redirections), then the command through
/// RunCommand on the right streams.
fn runLine(gv: *Global, code: *const dos.SegCode, special: bool) i32 {
    const dl = gv.dl;
    const cli = gv.cli;
    var in: ?*FileHandle = null;
    var out: ?*FileHandle = null;
    const termin = cli.standard_input;
    const termout = dl.Output();
    gv.count = 0;
    gv.fill = 0;
    var ch = getchar(gv, 0);
    while (ch == ' ' or ch == '\t') ch = getchar(gv, 0);

    var state: i32 = 1; // < 0 in quotes, > 0 outside, 0 in a comment
    var lastch: i32 = ' ';
    var past_begin = false;
    var pos: usize = 0;
    var file: [NAMEMAX + 1]u8 = undefined;
    const buf = &gv.cbuffer;
    while (true) {
        var c = ch;
        var redirected = false;
        switch (ch) {
            ';' => if (state > 0) {
                state = 0;
            },
            '"' => if (lastch != '*') {
                state = -state;
            },
            '+' => if (getchar(gv, lastch) == '\n') {
                c = '\n';
            } else ungetchar(gv),
            '>' => redirect: {
                if (state <= 0 or out != null or lastch != ' ' or (past_begin and special)) break :redirect;
                ch = getchar(gv, 0);
                const append = ch == '>';
                if (!append) ungetchar(gv);
                if (readItemShell(gv, &file) <= 0) {
                    ch = ' ';
                    break :redirect;
                }
                if (append) {
                    out = openf(gv, &file, dos.MODE_READWRITE);
                    if (out) |o| _ = dl.Seek(o, 0, dos.OFFSET_END);
                }
                if (out == null) out = openf(gv, &file, dos.MODE_NEWFILE);
                if (out == null) return notRun(gv, ERROR_REDIRECT, in, out);
                ch = ' ';
                redirected = true;
            },
            '<' => redirect: {
                if (state <= 0 or in != null or lastch != ' ' or (past_begin and special)) break :redirect;
                ch = getchar(gv, 0);
                const both = ch == '>';
                if (!both) ungetchar(gv);
                if (readItemShell(gv, &file) <= 0) {
                    ch = ' ';
                    break :redirect;
                }
                in = openf(gv, &file, dos.MODE_OLDFILE);
                if (in == null) return notRun(gv, ERROR_REDIRECT, in, out);
                if (both) { // "<>": output to the same handler's "*"
                    const console = gv.proc.console_task;
                    gv.proc.console_task = in.?.task;
                    out = dl.Open("*", dos.MODE_NEWFILE);
                    gv.proc.console_task = console;
                    if (out == null) return notRun(gv, ERROR_REDIRECT, in, out);
                }
                ch = ' ';
                redirected = true;
            },
            else => {},
        }
        if (!redirected) {
            const at_end = ch == '\n' or ch == END;
            var keep = true;
            if (!at_end) {
                if (state == 0) {
                    keep = false; // a comment
                } else if (ch != ' ' and ch != '\t') {
                    past_begin = true;
                }
            }
            if (keep) {
                buf[pos] = @truncate(@as(u32, @bitCast(c)));
                pos += 1;
                if (pos > MAXCOMMAND) return notRun(gv, ERROR_COMMAND_LONG, in, out);
                if (at_end) break;
            }
        }
        lastch = if (ch == '*' and lastch == '*') 0 else ch;
        ch = getchar(gv, lastch);
    }
    gv.last_ch = ch;
    if (pos > 0) buf[pos - 1] = '\n'; // RunCommand wants a newline
    buf[pos] = 0;
    _ = expand(gv, buf, MAXCOMMAND);
    const ticked = ticks(gv, buf, MAXCOMMAND);
    if (ticked < 0) {
        if (in) |f| _ = dl.Close(f);
        if (out) |f| _ = dl.Close(f);
        return @intCast(-ticked);
    }
    const len = std.mem.len(@as([*:0]u8, @ptrCast(buf)));
    if (gv.echo) {
        _ = dl.FPuts(dl.Output(), @ptrCast(buf));
        _ = dl.Flush(dl.Output());
    }
    _ = dl.SelectInput(in orelse termin);
    _ = dl.SelectOutput(out orelse termout);
    _ = dl.SetIoErr(0);
    _ = dl.CheckSignal(exec.SIGBREAKF_CTRL_C);
    const rc = dl.RunCommand(code, cli.default_stack, buf, @intCast(len));
    gv.res2 = dl.IoErr();
    if (in) |f| _ = dl.Close(f);
    if (out) |f| _ = dl.Close(f);
    return rc;
}

// --- Backquotes ---

/// Each `command` in `string` (at most `mc` bytes) replaced
/// by what it prints, run through System() into T:tick$n, its newlines as
/// spaces; "*`" is a plain backquote. The new length, or the negative
/// return code of a command that failed (at or above the fail level, or
/// couldn't start): its output is shown and `string` becomes "`command`".
fn ticks(gv: *Global, string: [*]u8, mc: usize) isize {
    const dl = gv.dl;
    var len = std.mem.len(@as([*:0]u8, @ptrCast(string)));
    if (len == 0 or len > mc) return @intCast(len);
    var i: usize = 0;
    var lastch: u8 = 0;
    while (i < len) {
        const ch = string[i];
        if (ch != '`') {
            lastch = if (ch == '*' and lastch == '*') 0 else ch;
            i += 1;
            continue;
        }
        if (lastch == '*') { // "*`": the star goes, the backquote stays
            removeAt(string, &len, i - 1);
            lastch = '`';
            continue;
        }
        var j = i + 1;
        var last: u8 = 0;
        const closed = while (j < len) {
            const c = string[j];
            if (c == '`') {
                if (last != '*') break true;
                removeAt(string, &len, j - 1); // a backquote for the command
                last = '`';
                continue;
            }
            last = if (c == '*' and last == '*') 0 else c;
            j += 1;
        } else false;
        if (!closed) break;

        const buf = &gv.buffer;
        const cmd_len = j - i - 1;
        @memcpy(buf[0..cmd_len], string[i + 1 .. j]);
        buf[cmd_len] = 0;
        var fname: [24]u8 = undefined;
        const tick = std.fmt.bufPrintZ(&fname, "T:tick${d}", .{gv.proc.task_num}) catch unreachable;
        const file = workfile.open(dl, tick.ptr, dos.MODE_NEWFILE) orelse break;
        // echoing the backquoted command's lines doesn't work well
        const echo_var = if (gv.echo) dl.FindVar("echo", dos.LV_VAR) else null;
        if (echo_var) |e| e.var_type |= dos.LVF_IGNORE;
        const tags = [_]sdk.utility.TagItem{
            .{ .tag = dos.SYS_Input, .data = 0 },
            .{ .tag = dos.SYS_Output, .data = @intFromPtr(file) },
            .{ .tag = dos.SYS_UserShell, .data = 1 },
            .{},
        };
        var rc = dl.SystemTagList(@ptrCast(buf), &tags);
        if (rc >= 0 and rc < gv.cli.fail_level) {
            rc = 0;
        } else {
            gv.res2 = dl.IoErr();
            if (rc < 0) rc = dos.RETURN_FAIL;
            string[0] = '`';
            @memcpy(string[1..][0..cmd_len], buf[0..cmd_len]);
            string[cmd_len + 1] = '`';
            string[cmd_len + 2] = 0;
        }
        _ = dl.Close(file);
        if (echo_var) |e| e.var_type &= ~dos.LVF_IGNORE;

        var k: usize = 0;
        if (dl.Open(tick.ptr, dos.MODE_OLDFILE)) |f| {
            const got = dl.Read(f, buf, MAXCOMMAND);
            if (got > 0) k = @intCast(got);
            _ = dl.Close(f);
        }
        _ = dl.DeleteFile(tick.ptr);
        if (k > 0 and buf[k - 1] == '\n') k -= 1;
        for (buf[0..k]) |*c| {
            if (c.* == '\n') c.* = ' ';
        }
        if (rc != 0) {
            if (k > 0) {
                buf[k] = 0;
                _ = Printf(dl, "%s\n", .{buf[0..k :0]});
            }
            return -@as(isize, rc);
        }
        // string[0..i] ++ output ++ the rest after the closing backquote
        const tail = len - (j + 1);
        k = @min(k, mc - i - tail);
        if (i + k > j + 1) {
            std.mem.copyBackwards(u8, string[i + k .. i + k + tail], string[j + 1 .. j + 1 + tail]);
        } else {
            std.mem.copyForwards(u8, string[i + k .. i + k + tail], string[j + 1 .. j + 1 + tail]);
        }
        @memcpy(string[i..][0..k], buf[0..k]);
        len = i + k + tail;
        string[len] = 0;
        i += k;
        lastch = 0;
    }
    return @intCast(len);
}

/// The byte at `at` taken out of the C string `string` of length `len`.
fn removeAt(string: [*]u8, len: *usize, at: usize) void {
    std.mem.copyForwards(u8, string[at .. len.* - 1], string[at + 1 .. len.*]);
    len.* -= 1;
    string[len.*] = 0;
}

export const shell_tag: exec.ResidentHandler linksection(".resident") = .{
    .resident = .{
        .match_tag = &shell_tag.resident,
        .version = SHELL_VERSION,
        // Shaped like a dos handler - the entry in the word after the tag -
        // without being one: dos gives this out as shell, BootShell and
        // CLI, and what starts a shell does not answer packets.
        .type = .shell,
        .pri = -122,
        .name = SHELL_NAME,
        .id_string = SHELL_VERSION_STRING[1..], // past the NUL: a C string
    },
    .handler = &shellEntry,
};
